//! `rind images` subcommand.
//!
//! Read-side counterpart to `rind pull`: enumerates locally tagged
//! manifests in `index.json`, reads each manifest blob plus its image
//! config to compute the total compressed layer size and `created_at`,
//! and renders the result as a fixed-width table or a stable JSON
//! array.
//!
//! Local-only: never touches the registry. The single new piece of
//! parsing is `image/config.zig`; the rest is glue over `Store` and
//! `manifest.parseManifest`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const clap = @import("clap");

const layout = @import("../store/layout.zig");
const manifest_mod = @import("../registry/manifest.zig");
const digest_mod = @import("../image/digest.zig");
const config_mod = @import("../image/config.zig");

/// Output format. `human` is the TTY default; `json` is the stable
/// machine-readable array consumed by tooling.
pub const OutputKind = enum { human, json };

/// Validated argv for `rind images`.
pub const ImagesArgs = struct {
    /// `--output {human,json}`. Defaults to human.
    output: OutputKind = .human,
};

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\    --output <kind>     Output format: human (default) or json.
    \\
);

const value_parsers = .{
    .kind = clap.parsers.enumeration(OutputKind),
};

/// One-line usage banner. Stable enough that scripts can grep it.
pub const usage_line: []const u8 = "Usage: rind images [--output human|json]";

/// Cap on a manifest blob read into memory. Same magnitude rind uses
/// elsewhere — real OCI manifests are kilobytes, not megabytes.
const manifest_max_bytes: usize = 8 * 1024 * 1024;
/// Cap on a config blob. Image configs are tiny in practice.
const config_max_bytes: usize = 4 * 1024 * 1024;

/// Parse argv (after `images` has been peeled off) into a validated
/// `ImagesArgs`. `iter` is consumed; `gpa` backs clap's working arena.
/// Returns `error.Usage` for any structural problem and writes a
/// one-line diagnostic to `err_writer`.
pub fn parseArgs(
    gpa: Allocator,
    iter: anytype,
    err_writer: *Io.Writer,
) !ImagesArgs {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, value_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch {
        err_writer.print("{s}\n", .{usage_line}) catch {};
        return error.Usage;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try err_writer.print("{s}\n", .{usage_line});
        return error.Usage;
    }

    return .{ .output = res.args.output orelse .human };
}

/// No-op kept for symmetry with `pull.parseArgs` / `pull.freeArgs`.
/// `ImagesArgs` owns no allocations to free.
pub fn freeArgs(gpa: Allocator, args: ImagesArgs) void {
    _ = gpa;
    _ = args;
}

/// One row of the `images` listing. All slices borrow from caller
/// storage (typically the parsed `index.json` and an arena holding the
/// parsed manifests/configs).
const ImageRow = struct {
    /// `org.opencontainers.image.ref.name` annotation value.
    ref: []const u8,
    /// Manifest blob digest.
    digest: digest_mod.Digest,
    /// Sum of unique layer blob sizes in this image's manifest.
    size: u64,
    /// `image.config.created` verbatim. Null when the config omits it.
    created_at: ?[]const u8,
};

fn lessByRef(_: void, a: ImageRow, b: ImageRow) bool {
    return std.mem.lessThan(u8, a.ref, b.ref);
}

/// List images in `store`. Reads `index.json`, then for each tagged
/// manifest reads the manifest + config blobs to compute total size
/// and `created_at`. Writes a fixed-width table or JSON array to
/// `stdout` per `args.output`. Errors propagate to the caller; the
/// caller maps them to exit codes.
pub fn run(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    args: ImagesArgs,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    _ = stderr;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var parsed_index = try store.readIndex(io, gpa);
    defer parsed_index.deinit();

    var rows: std.ArrayList(ImageRow) = .empty;
    defer rows.deinit(gpa);

    for (parsed_index.value.manifests) |desc| {
        const ann = desc.annotations orelse continue;
        const ref_name = ann.map.get(layout.ref_name_annotation) orelse continue;

        const mt = manifest_mod.MediaType.fromString(desc.mediaType) orelse
            return error.UnsupportedMediaType;
        if (!mt.isSingle()) return error.UnsupportedMediaType;

        const m_digest = try digest_mod.Digest.parse(desc.digest);
        const m_bytes = try store.readBlobAlloc(io, aa, m_digest, manifest_max_bytes);
        const m = try manifest_mod.parseManifest(aa, m_bytes, mt);

        const c_digest = try digest_mod.Digest.parse(m.config.digest);
        const c_bytes = try store.readBlobAlloc(io, aa, c_digest, config_max_bytes);
        const cfg = try config_mod.parse(aa, c_bytes);

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(aa);
        var size_total: u64 = 0;
        for (m.layers) |lyr| {
            const gop = try seen.getOrPut(aa, lyr.digest);
            if (!gop.found_existing) size_total += lyr.size;
        }

        try rows.append(gpa, .{
            .ref = ref_name,
            .digest = m_digest,
            .size = size_total,
            .created_at = cfg.created,
        });
    }

    std.mem.sort(ImageRow, rows.items, {}, lessByRef);

    switch (args.output) {
        .human => try renderHuman(stdout, rows.items),
        .json => try renderJson(stdout, rows.items),
    }
    try stdout.flush();
}

const col1_w: usize = 32;
const col2_w: usize = 15;
const col3_w: usize = 13;

/// Width of the date prefix shown in the human CREATED column.
/// ISO 8601 timestamps always start with `YYYY-MM-DD` (10 chars); the
/// time-of-day suffix is dropped so the column stays narrow. JSON
/// output keeps the full timestamp.
const created_date_len: usize = 10;

/// Number of hex characters shown in the human IMAGE ID column. The
/// `sha256:` prefix is dropped — at 12 hex chars the collision space
/// is 2^48, comfortably unique within a single host's local store.
const short_id_hex: usize = 12;

fn writePadded(w: *Io.Writer, s: []const u8, width: usize) Io.Writer.Error!void {
    try w.writeAll(s);
    if (s.len < width) {
        var n: usize = width - s.len;
        while (n > 0) : (n -= 1) try w.writeByte(' ');
    }
}

/// Decimal SI byte sizes (matches `docker images` and `go-units.HumanSize`).
/// Sub-kilobyte renders as raw bytes; everything else uses two decimals
/// so the column stays narrow without losing useful precision.
fn writeHumanSize(w: *Io.Writer, n: u64) Io.Writer.Error!void {
    const units = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB" };
    if (n < 1000) {
        try w.print("{d}B", .{n});
        return;
    }
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= 1000.0 and i + 1 < units.len) : (i += 1) {
        v /= 1000.0;
    }
    try w.print("{d:.2}{s}", .{ v, units[i] });
}

fn renderHuman(w: *Io.Writer, rows: []const ImageRow) Io.Writer.Error!void {
    try writePadded(w, "REPOSITORY:TAG", col1_w);
    try writePadded(w, "IMAGE ID", col2_w);
    try writePadded(w, "CREATED", col3_w);
    try w.writeAll("SIZE\n");

    for (rows) |row| {
        try writePadded(w, row.ref, col1_w);

        var hex_buf: [digest_mod.hex_length]u8 = undefined;
        const hex = row.digest.encodedHex(&hex_buf);
        try writePadded(w, hex[0..short_id_hex], col2_w);

        const created_full = row.created_at orelse "<unknown>";
        const created = created_full[0..@min(created_full.len, created_date_len)];
        try writePadded(w, created, col3_w);

        try writeHumanSize(w, row.size);
        try w.writeByte('\n');
    }
}

fn renderJson(w: *Io.Writer, rows: []const ImageRow) Io.Writer.Error!void {
    if (rows.len == 0) {
        try w.writeAll("[]\n");
        return;
    }
    try w.writeAll("[\n");
    for (rows, 0..) |row, i| {
        try w.writeAll("  {\n");

        try w.writeAll("    \"ref\": ");
        try writeJsonString(w, row.ref);
        try w.writeAll(",\n");

        var dig_buf: [digest_mod.string_length]u8 = undefined;
        const full = row.digest.toString(&dig_buf);
        try w.writeAll("    \"digest\": ");
        try writeJsonString(w, full);
        try w.writeAll(",\n");

        try w.print("    \"size\": {d},\n", .{row.size});

        try w.writeAll("    \"created_at\": ");
        if (row.created_at) |c| {
            try writeJsonString(w, c);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("\n  }");
        if (i + 1 < rows.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("]\n");
}

fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

const testing = std.testing;

const SliceIter = struct {
    items: []const []const u8,
    idx: usize = 0,
    pub fn next(self: *SliceIter) ?[]const u8 {
        if (self.idx >= self.items.len) return null;
        defer self.idx += 1;
        return self.items[self.idx];
    }
};

fn parseFromSlice(gpa: Allocator, argv: []const []const u8, err_writer: *Io.Writer) !ImagesArgs {
    var iter: SliceIter = .{ .items = argv };
    return parseArgs(gpa, &iter, err_writer);
}

test "parseArgs default is human" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{}, &err_buf.writer);
    try testing.expectEqual(OutputKind.human, a.output);
}

test "parseArgs accepts --output json" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{ "--output", "json" }, &err_buf.writer);
    try testing.expectEqual(OutputKind.json, a.output);
}

test "parseArgs rejects unknown flag" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{"--bogus"}, &err_buf.writer));
}

test "parseArgs --help is treated as a usage exit" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{"--help"}, &err_buf.writer));
}

test "parseArgs rejects unknown --output value" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{ "--output", "bogus" }, &err_buf.writer));
}

fn fixedDigest(byte: u8) digest_mod.Digest {
    var d: digest_mod.Digest = undefined;
    @memset(&d.bytes, byte);
    return d;
}

const fixture_rows = [_]ImageRow{
    .{
        .ref = "alpine:3.19",
        .digest = .{ .bytes = [_]u8{0x11} ** 32 },
        .size = 7791693,
        .created_at = "2024-01-27T00:30:48.6Z",
    },
    .{
        .ref = "ghcr.io/foo/bar:v2",
        .digest = .{ .bytes = [_]u8{0x22} ** 32 },
        .size = 15234567,
        .created_at = "2024-03-15T10:00:00Z",
    },
};

test "renderHuman snapshot" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try renderHuman(&buf.writer, &fixture_rows);
    const expected = @embedFile("testdata/images_human.txt");
    try testing.expectEqualStrings(expected, buf.written());
}

test "renderJson snapshot" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try renderJson(&buf.writer, &fixture_rows);
    const expected = @embedFile("testdata/images.json");
    try testing.expectEqualStrings(expected, buf.written());
}

test "renderJson empty store emits empty array" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try renderJson(&buf.writer, &.{});
    try testing.expectEqualStrings("[]\n", buf.written());
}

test "renderHuman handles missing created_at" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const rows = [_]ImageRow{
        .{ .ref = "x:1", .digest = fixedDigest(0x33), .size = 10, .created_at = null },
    };
    try renderHuman(&buf.writer, &rows);
    try testing.expect(std.mem.indexOf(u8, buf.written(), "<unknown>") != null);
}

test "renderJson emits null for missing created_at" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const rows = [_]ImageRow{
        .{ .ref = "x:1", .digest = fixedDigest(0x44), .size = 10, .created_at = null },
    };
    try renderJson(&buf.writer, &rows);
    try testing.expect(std.mem.indexOf(u8, buf.written(), "\"created_at\": null") != null);
}

test "renderHuman sort discipline (rows are pre-sorted)" {
    var unsorted = [_]ImageRow{
        .{ .ref = "z:1", .digest = fixedDigest(0xaa), .size = 1, .created_at = null },
        .{ .ref = "a:1", .digest = fixedDigest(0xbb), .size = 2, .created_at = null },
    };
    std.mem.sort(ImageRow, &unsorted, {}, lessByRef);
    try testing.expectEqualStrings("a:1", unsorted[0].ref);
    try testing.expectEqualStrings("z:1", unsorted[1].ref);
}

test "run lists tagged image from a tmp store" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    const cfg_bytes =
        \\{
        \\  "architecture": "amd64",
        \\  "os": "linux",
        \\  "created": "2024-05-02T12:00:00Z",
        \\  "rootfs": {
        \\    "type": "layers",
        \\    "diff_ids": ["sha256:0000000000000000000000000000000000000000000000000000000000000000"]
        \\  }
        \\}
    ;
    const cfg_dig = digest_mod.Hasher.hash(cfg_bytes);
    var cfg_reader: Io.Reader = .fixed(cfg_bytes);
    try store.putBlob(io, cfg_dig, &cfg_reader);

    var cfg_dig_buf: [digest_mod.string_length]u8 = undefined;
    const cfg_dig_str = cfg_dig.toString(&cfg_dig_buf);

    const manifest_bytes = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schemaVersion": 2,
        \\  "mediaType": "application/vnd.oci.image.manifest.v1+json",
        \\  "config": {{
        \\    "mediaType": "application/vnd.oci.image.config.v1+json",
        \\    "digest": "{s}",
        \\    "size": {d}
        \\  }},
        \\  "layers": [
        \\    {{
        \\      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
        \\      "digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
        \\      "size": 1024
        \\    }}
        \\  ]
        \\}}
    , .{ cfg_dig_str, cfg_bytes.len });
    defer gpa.free(manifest_bytes);

    const m_dig = digest_mod.Hasher.hash(manifest_bytes);
    var m_reader: Io.Reader = .fixed(manifest_bytes);
    try store.putBlob(io, m_dig, &m_reader);

    try store.tag(io, gpa, "alpine:3.19", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = m_dig,
        .size = manifest_bytes.len,
    });

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    try run(io, gpa, &store, .{ .output = .json }, &out_buf.writer, &err_buf.writer);

    var m_dig_buf: [digest_mod.string_length]u8 = undefined;
    const m_dig_str = m_dig.toString(&m_dig_buf);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "alpine:3.19") != null);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), m_dig_str) != null);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"size\": 1024") != null);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "2024-05-02T12:00:00Z") != null);
}

test "run dedupes repeated layers in the size total" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    const cfg_bytes =
        \\{"architecture":"amd64","os":"linux","created":"2024-01-01T00:00:00Z","rootfs":{"type":"layers","diff_ids":[]}}
    ;
    const cfg_dig = digest_mod.Hasher.hash(cfg_bytes);
    var cfg_reader: Io.Reader = .fixed(cfg_bytes);
    try store.putBlob(io, cfg_dig, &cfg_reader);

    var cfg_dig_buf: [digest_mod.string_length]u8 = undefined;
    const cfg_dig_str = cfg_dig.toString(&cfg_dig_buf);

    // Two layer entries share the same digest — total should be 500, not 1000.
    const manifest_bytes = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schemaVersion": 2,
        \\  "mediaType": "application/vnd.oci.image.manifest.v1+json",
        \\  "config": {{
        \\    "mediaType": "application/vnd.oci.image.config.v1+json",
        \\    "digest": "{s}",
        \\    "size": {d}
        \\  }},
        \\  "layers": [
        \\    {{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:5555555555555555555555555555555555555555555555555555555555555555","size":500}},
        \\    {{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:5555555555555555555555555555555555555555555555555555555555555555","size":500}}
        \\  ]
        \\}}
    , .{ cfg_dig_str, cfg_bytes.len });
    defer gpa.free(manifest_bytes);

    const m_dig = digest_mod.Hasher.hash(manifest_bytes);
    var m_reader: Io.Reader = .fixed(manifest_bytes);
    try store.putBlob(io, m_dig, &m_reader);

    try store.tag(io, gpa, "dup:1", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = m_dig,
        .size = manifest_bytes.len,
    });

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    try run(io, gpa, &store, .{ .output = .json }, &out_buf.writer, &err_buf.writer);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"size\": 500") != null);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"size\": 1000") == null);
}

test "run on empty store emits header only / empty array" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    {
        var out_buf: Io.Writer.Allocating = .init(gpa);
        defer out_buf.deinit();
        var err_buf: Io.Writer.Allocating = .init(gpa);
        defer err_buf.deinit();
        try run(io, gpa, &store, .{ .output = .json }, &out_buf.writer, &err_buf.writer);
        try testing.expectEqualStrings("[]\n", out_buf.written());
    }

    {
        var out_buf: Io.Writer.Allocating = .init(gpa);
        defer out_buf.deinit();
        var err_buf: Io.Writer.Allocating = .init(gpa);
        defer err_buf.deinit();
        try run(io, gpa, &store, .{ .output = .human }, &out_buf.writer, &err_buf.writer);
        try testing.expect(std.mem.startsWith(u8, out_buf.written(), "REPOSITORY:TAG"));
    }
}
