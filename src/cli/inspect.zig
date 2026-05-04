//! `rind inspect <image>` subcommand.
//!
//! Read-side counterpart to `rind pull` / `rind images`: dumps the OCI
//! image config JSON for a single locally-stored image. Resolution
//! supports tag refs (matched literally against the
//! `org.opencontainers.image.ref.name` annotation in `index.json`) and
//! digest refs (`name@sha256:<hex>`, where the digest names a manifest
//! present in the index).
//!
//! Output is JSON only — the command exists for machine consumption.
//! Two formats: pretty (`--output json`, default) and one-line
//! (`--output json-compact`). Compact output is the verbatim config
//! blob bytes; pretty round-trips through `std.json.Value` so fields
//! the project's `ImageConfig` model does not enumerate are still
//! emitted.
//!
//! Local-only: never touches the registry. Pairs with `rind pull`
//! and `rind images` on the read side.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const clap = @import("clap");

const layout = @import("../store/layout.zig");
const manifest_mod = @import("../registry/manifest.zig");
const digest_mod = @import("../image/digest.zig");
const image_ref = @import("../image/ref.zig");

/// Output format. `json` is pretty (two-space indent, default);
/// `@"json-compact"` writes the raw config blob bytes on a single line.
/// The enum tag is spelled `json-compact` so clap's `enumeration`
/// parser accepts the literal `--output json-compact` string.
pub const OutputKind = enum { json, @"json-compact" };

/// Validated argv for `rind inspect`.
pub const InspectArgs = struct {
    /// Image reference. Either a tag (`alpine:3.19`) or a digest
    /// reference (`alpine@sha256:<hex>`). Allocator-owned (duped from
    /// clap's working arena in `parseArgs`).
    ref: []const u8,
    /// `--output {json,json-compact}`. Defaults to pretty `json`.
    output: OutputKind = .json,
};

/// Errors specific to the inspect verb. Storage and parse errors are
/// surfaced from the helpers being called (`Store.read*`,
/// `manifest_mod.parseManifest`, `image_ref.parse`).
pub const InspectError = error{
    /// No descriptor in `index.json` matched the supplied ref. The
    /// image either was never pulled or has been removed.
    RefNotFound,
    /// The matching descriptor's mediaType is not a single-platform
    /// manifest (e.g. it's an image-index). Inspect only resolves
    /// single-manifest references.
    UnsupportedMediaType,
};

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\    --output <kind>     Output format: json (pretty, default) or json-compact.
    \\<str>                   Image reference (e.g. alpine:3.19 or alpine@sha256:...).
    \\
);

const value_parsers = .{
    .str = clap.parsers.string,
    .kind = clap.parsers.enumeration(OutputKind),
};

/// One-line usage banner. Stable enough that scripts can grep it.
pub const usage_line: []const u8 = "Usage: rind inspect <image> [--output json|json-compact]";

/// Cap on a manifest blob read into memory. Same magnitude as `images`.
const manifest_max_bytes: usize = 8 * 1024 * 1024;
/// Cap on a config blob.
const config_max_bytes: usize = 4 * 1024 * 1024;

/// Parse argv (after `inspect` has been peeled off) into a validated
/// `InspectArgs`. `iter` is consumed; `gpa` backs clap's working arena
/// and owns the duplicated `ref` slice. Returns `error.Usage` for any
/// structural problem and writes a one-line diagnostic to `err_writer`.
pub fn parseArgs(
    gpa: Allocator,
    iter: anytype,
    err_writer: *Io.Writer,
) !InspectArgs {
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

    const ref = res.positionals[0] orelse {
        try err_writer.print("{s}\n", .{usage_line});
        return error.Usage;
    };

    const ref_owned = try gpa.dupe(u8, ref);
    errdefer gpa.free(ref_owned);

    return .{
        .ref = ref_owned,
        .output = res.args.output orelse .json,
    };
}

/// Free the `ref` slice owned by `args`. Mirrors the dupe done in
/// `parseArgs`; `gpa` must be the same allocator.
pub fn freeArgs(gpa: Allocator, args: InspectArgs) void {
    gpa.free(args.ref);
}

/// Inspect a single image. Resolves `args.ref` to a manifest descriptor
/// in `index.json`, reads the manifest, then writes its config blob to
/// `stdout` per `args.output`. Errors propagate to the caller; the
/// caller maps them to exit codes. Missing image → `error.RefNotFound`.
pub fn run(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    args: InspectArgs,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    _ = stderr;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const ref = try image_ref.parse(aa, args.ref);

    var parsed_index = try store.readIndex(io, gpa);
    defer parsed_index.deinit();

    const desc = findDescriptor(parsed_index.value, ref, args.ref) orelse
        return error.RefNotFound;

    const mt = manifest_mod.MediaType.fromString(desc.mediaType) orelse
        return error.UnsupportedMediaType;
    if (!mt.isSingle()) return error.UnsupportedMediaType;

    const m_digest = try digest_mod.Digest.parse(desc.digest);
    const m_bytes = try store.readBlobAlloc(io, aa, m_digest, manifest_max_bytes);
    const m = try manifest_mod.parseManifest(aa, m_bytes, mt);

    const c_digest = try digest_mod.Digest.parse(m.config.digest);
    const c_bytes = try store.readBlobAlloc(io, aa, c_digest, config_max_bytes);

    switch (args.output) {
        .@"json-compact" => {
            try stdout.writeAll(c_bytes);
            try stdout.writeByte('\n');
        },
        .json => {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, c_bytes, .{});
            try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, stdout);
            try stdout.writeByte('\n');
        },
    }
    try stdout.flush();
}

/// Find the descriptor in `index` matching `ref`. Tag refs match the
/// literal `raw_ref` against `org.opencontainers.image.ref.name`; this
/// mirrors what `Store.tag` writes (the user's pull-time string,
/// uncanonicalized). Digest refs (`name@sha256:<hex>`) match against
/// the descriptor's manifest digest. Returns `null` on no match.
fn findDescriptor(
    index: layout.Index,
    ref: image_ref.ImageRef,
    raw_ref: []const u8,
) ?layout.Descriptor {
    for (index.manifests) |desc| {
        if (ref.digest) |d| {
            if (std.mem.eql(u8, desc.digest, d)) return desc;
        } else {
            const ann = desc.annotations orelse continue;
            const name = ann.map.get(layout.ref_name_annotation) orelse continue;
            if (std.mem.eql(u8, name, raw_ref)) return desc;
        }
    }
    return null;
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

fn parseFromSlice(gpa: Allocator, argv: []const []const u8, err_writer: *Io.Writer) !InspectArgs {
    var iter: SliceIter = .{ .items = argv };
    return parseArgs(gpa, &iter, err_writer);
}

test "parseArgs default --output is json" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{"alpine:3.19"}, &err_buf.writer);
    defer freeArgs(gpa, a);
    try testing.expectEqual(OutputKind.json, a.output);
    try testing.expectEqualStrings("alpine:3.19", a.ref);
}

test "parseArgs accepts --output json-compact" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{ "--output", "json-compact", "alpine:3.19" }, &err_buf.writer);
    defer freeArgs(gpa, a);
    try testing.expectEqual(OutputKind.@"json-compact", a.output);
}

test "parseArgs accepts --output json explicit" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{ "--output", "json", "x:y" }, &err_buf.writer);
    defer freeArgs(gpa, a);
    try testing.expectEqual(OutputKind.json, a.output);
}

test "parseArgs rejects missing positional" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{}, &err_buf.writer));
    try testing.expect(std.mem.indexOf(u8, err_buf.written(), "Usage:") != null);
}

test "parseArgs rejects unknown flag" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{ "--bogus", "alpine:3.19" }, &err_buf.writer));
}

test "parseArgs rejects unknown --output value" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{ "--output", "bogus", "alpine:3.19" }, &err_buf.writer));
}

test "parseArgs --help is treated as a usage exit" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{"--help"}, &err_buf.writer));
}

const fixture_cfg_bytes: []const u8 =
    "{\"architecture\":\"amd64\",\"os\":\"linux\",\"created\":\"2024-05-02T12:00:00Z\",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:0000000000000000000000000000000000000000000000000000000000000000\"]}}";

fn seedFixture(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    ref_name: []const u8,
) !digest_mod.Digest {
    const cfg_dig = digest_mod.Hasher.hash(fixture_cfg_bytes);
    var cfg_reader: Io.Reader = .fixed(fixture_cfg_bytes);
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
        \\  "layers": []
        \\}}
    , .{ cfg_dig_str, fixture_cfg_bytes.len });
    defer gpa.free(manifest_bytes);

    const m_dig = digest_mod.Hasher.hash(manifest_bytes);
    var m_reader: Io.Reader = .fixed(manifest_bytes);
    try store.putBlob(io, m_dig, &m_reader);

    try store.tag(io, gpa, ref_name, .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = m_dig,
        .size = manifest_bytes.len,
    });

    return m_dig;
}

test "run by tag emits the config blob (compact)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    _ = try seedFixture(io, gpa, &store, "alpine:3.19");

    const ref_buf = try gpa.dupe(u8, "alpine:3.19");
    defer gpa.free(ref_buf);
    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    try run(io, gpa, &store, .{ .ref = ref_buf, .output = .@"json-compact" }, &out_buf.writer, &err_buf.writer);

    const expected_compact = @embedFile("testdata/inspect_compact.json");
    try testing.expectEqualStrings(expected_compact, out_buf.written());
}

test "run by tag emits pretty config blob (default)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    _ = try seedFixture(io, gpa, &store, "alpine:3.19");

    const ref_buf = try gpa.dupe(u8, "alpine:3.19");
    defer gpa.free(ref_buf);
    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    try run(io, gpa, &store, .{ .ref = ref_buf, .output = .json }, &out_buf.writer, &err_buf.writer);

    const expected_pretty = @embedFile("testdata/inspect_pretty.json");
    try testing.expectEqualStrings(expected_pretty, out_buf.written());
}

test "run by digest matches run by tag (compact)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    const m_dig = try seedFixture(io, gpa, &store, "alpine:3.19");
    var m_dig_buf: [digest_mod.string_length]u8 = undefined;
    const m_dig_str = m_dig.toString(&m_dig_buf);

    const digest_ref = try std.fmt.allocPrint(gpa, "alpine@{s}", .{m_dig_str});
    defer gpa.free(digest_ref);

    var by_tag: Io.Writer.Allocating = .init(gpa);
    defer by_tag.deinit();
    var by_dig: Io.Writer.Allocating = .init(gpa);
    defer by_dig.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const tag_ref_buf = try gpa.dupe(u8, "alpine:3.19");
    defer gpa.free(tag_ref_buf);
    try run(io, gpa, &store, .{ .ref = tag_ref_buf, .output = .@"json-compact" }, &by_tag.writer, &err_buf.writer);
    try run(io, gpa, &store, .{ .ref = digest_ref, .output = .@"json-compact" }, &by_dig.writer, &err_buf.writer);

    try testing.expectEqualStrings(by_tag.written(), by_dig.written());
}

test "run on missing tag returns RefNotFound" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    const ref_buf = try gpa.dupe(u8, "alpine:3.19");
    defer gpa.free(ref_buf);
    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    try testing.expectError(
        error.RefNotFound,
        run(io, gpa, &store, .{ .ref = ref_buf, .output = .json }, &out_buf.writer, &err_buf.writer),
    );
}

test "run on missing digest returns RefNotFound" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    _ = try seedFixture(io, gpa, &store, "alpine:3.19");

    const bogus_digest_ref = "alpine@sha256:dead0000000000000000000000000000000000000000000000000000000000ad";
    const ref_buf = try gpa.dupe(u8, bogus_digest_ref);
    defer gpa.free(ref_buf);
    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    try testing.expectError(
        error.RefNotFound,
        run(io, gpa, &store, .{ .ref = ref_buf, .output = .json }, &out_buf.writer, &err_buf.writer),
    );
}
