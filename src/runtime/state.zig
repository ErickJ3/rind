//! Container state allocation.
//!
//! Owns ID generation, the per-container directory triplet under
//! `~/.rind/{containers,bundles,overlays}/<id>/`, and the initial
//! `state.json`. This module only fills the static fields
//! (`id`, `id_full`, optional `name`, `image_ref`, `image_digest`,
//! `status: "created"`, `started_at`); `pid` / status transitions
//! are not yet implemented.
//!
//! ID derivation: `sha256(realtime_ns_be ‖ 16 random bytes)` →
//! lowercase hex; first 12 chars are the Docker-style short ID,
//! the full 64-char hex is recorded inside `state.json` for
//! collision-resistant bookkeeping.
//!
//! Atomic triplet mkdir: `containers/<id>` first, then
//! `bundles/<id>`, then `overlays/<id>`. If any fails with
//! `PathAlreadyExists`, the partial set created on this attempt is
//! removed and a fresh ID is drawn. Collisions are vanishingly
//! unlikely (sha256 over real-time + 128 bits of entropy); the
//! retry budget is defence in depth against a corrupted root.
//!
//! `state.json` is written via `createFileAtomic` with `replace =
//! false` (first write); same idiom as `Store.writeIndex`.
//!
//! Naming note: `runtime/libcrun.zig` already exports `Container`
//! as the opaque libcrun handle. The `Container` type below is the
//! state record produced by this allocator. Callers that need both
//! should disambiguate via namespace (`runtime.state.Container` vs
//! `runtime.libcrun.Container`) or local type aliases.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Length of the short container ID (first N hex chars). Docker
/// convention.
pub const id_short_length: usize = 12;

/// Length of the full hex ID stored inside `state.json`.
pub const id_full_length: usize = 64;

/// Number of times `allocate` will retry on a directory-collision
/// before surfacing `IdCollisionExhausted`. With sha256 over
/// real-time + 128 bits of entropy a single collision is already
/// astronomically unlikely; this bound is defence in depth.
pub const id_collision_max_retries: u8 = 8;

/// Subdirectory of `root` holding per-container metadata
/// (`<id>/state.json`, future bundle pointers).
pub const containers_subpath: []const u8 = "containers";

/// Subdirectory of `root` holding OCI runtime bundles.
pub const bundles_subpath: []const u8 = "bundles";

/// Subdirectory of `root` holding overlay upper/work/merged trees.
pub const overlays_subpath: []const u8 = "overlays";

/// Subdirectory of `root` handed to libcrun as its OCI state root.
/// Kept separate from `containers_subpath` because libcrun owns the
/// `<state_root>/<id>/` tree exclusively (writes its own
/// `state.json`, lock files, etc.) and would refuse to start a new
/// container there if rind's metadata already lives at the same path.
pub const runtime_subpath: []const u8 = "runtime";

/// File name (relative to `containers/<id>/`) for the persisted
/// state document.
pub const state_filename: []const u8 = "state.json";

/// Initial value of the `status` field in a freshly-allocated
/// `state.json`.
pub const initial_status: []const u8 = "created";

/// Closed semantic error set for state allocation. Returned in
/// addition to the underlying filesystem and JSON-encoding error
/// sets (composed at each public function's signature).
pub const StateError = error{
    /// `allocate` exhausted `id_collision_max_retries` attempts to
    /// find a free directory triplet. Effectively impossible under
    /// normal conditions; signals a corrupted or maliciously
    /// pre-populated root.
    IdCollisionExhausted,
};

/// Snapshot of an allocated container. The three directories
/// `<root>/containers/<id>/`, `<root>/bundles/<id>/`, and
/// `<root>/overlays/<id>/` exist on disk; `state.json` exists at
/// `<root>/containers/<id>/state.json`. All slice fields are
/// heap-duped onto the allocator passed to `allocate` and freed by
/// `deinit`.
pub const Container = struct {
    /// 12-char short ID (Docker prefix). Stable across restarts.
    id: [id_short_length]u8,
    /// 64-char full hex ID. Recorded inside `state.json`.
    id_full: [id_full_length]u8,
    /// Optional human name. Currently always `null`; `--name` and
    /// uniqueness enforcement are not yet wired.
    name: ?[]const u8 = null,
    /// Image ref string the container was allocated for
    /// (e.g. `alpine:3.19`).
    image_ref: []const u8,
    /// Image manifest digest in canonical `sha256:<hex>` form.
    image_digest: []const u8,
    /// Wall-clock allocation time in RFC 3339 / ISO 8601
    /// (`YYYY-MM-DDTHH:MM:SSZ`, UTC).
    started_at: []const u8,

    /// Free heap copies of the slice fields. Safe to call exactly
    /// once on a `Container` returned from `allocate`.
    pub fn deinit(self: *Container, gpa: Allocator) void {
        gpa.free(self.image_ref);
        gpa.free(self.image_digest);
        gpa.free(self.started_at);
        if (self.name) |n| gpa.free(n);
        self.* = undefined;
    }
};

/// Persisted shape of `state.json`. Field names are the canonical
/// snake_case wire form. Future fields (`pid`, `exit_code`,
/// `signal`) are not yet implemented; `allocate` only fills the
/// static subset below, which is the only shape readers should
/// expect on disk today.
pub const StatePersisted = struct {
    /// Short 12-char ID.
    id: []const u8,
    /// Full 64-char hex ID.
    id_full: []const u8,
    /// Human name (currently always null).
    name: ?[]const u8 = null,
    /// Image ref string.
    image_ref: []const u8,
    /// Image manifest digest (`sha256:<hex>`).
    image_digest: []const u8,
    /// Lifecycle status. Initialised to `"created"` here; the
    /// `"running"` / `"exited"` walk is not yet implemented.
    status: []const u8 = initial_status,
    /// Allocation timestamp (RFC 3339 UTC).
    started_at: []const u8,
};

/// Composed error set returned by `allocate`.
pub const AllocateError =
    StateError ||
    Io.Dir.CreateDirError ||
    Io.Dir.CreateDirPathError ||
    Io.Dir.CreateFileAtomicError ||
    Io.Dir.DeleteTreeError ||
    Io.File.Atomic.LinkError ||
    Io.File.Writer.Error ||
    std.json.Stringify.Error ||
    Allocator.Error;

/// Allocate a fresh container under `root` (typically `~/.rind/`).
///
/// On success, three sibling directories exist on disk under
/// `root` (`containers/<id>`, `bundles/<id>`, `overlays/<id>`),
/// and `<root>/containers/<id>/state.json` carries the static
/// fields. `image_ref`, `image_digest`, and `name` (if any) are
/// heap-duped onto `gpa`; the caller frees via `Container.deinit`.
///
/// `root` must already exist as a writable directory (the function
/// will create the three top-level subdirs `containers`, `bundles`,
/// `overlays` on demand but does not `mkdir -p` the path to `root`
/// itself).
pub fn allocate(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    image_ref: []const u8,
    image_digest: []const u8,
    name: ?[]const u8,
) AllocateError!Container {
    const default_source: IdSource = .{ .fill_fn = defaultIdFill, .ctx = null };
    return allocateWithIdSource(io, gpa, root, image_ref, image_digest, name, default_source);
}

const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

/// Function-pointer hook for ID generation. The default impl
/// hashes wall-clock + 16 random bytes; tests inject deterministic
/// sequences to exercise the collision-retry path.
const IdSource = struct {
    fill_fn: *const fn (io: Io, ctx: ?*anyopaque, out: *[id_full_length]u8) void,
    ctx: ?*anyopaque,
};

fn defaultIdFill(io: Io, ctx: ?*anyopaque, out: *[id_full_length]u8) void {
    _ = ctx;
    var seed: [24]u8 = undefined;
    const ts = Io.Clock.now(.real, io);
    const ns_low: i64 = @truncate(ts.nanoseconds);
    std.mem.writeInt(i64, seed[0..8], ns_low, .big);
    io.random(seed[8..24]);

    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&seed, &hash, .{});
    out.* = std.fmt.bytesToHex(hash, .lower);
}

fn allocateWithIdSource(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    image_ref: []const u8,
    image_digest: []const u8,
    name: ?[]const u8,
    id_source: IdSource,
) AllocateError!Container {
    try root.createDirPath(io, containers_subpath);
    try root.createDirPath(io, bundles_subpath);
    try root.createDirPath(io, overlays_subpath);

    var attempt: u8 = 0;
    while (attempt < id_collision_max_retries) : (attempt += 1) {
        var id_full: [id_full_length]u8 = undefined;
        id_source.fill_fn(io, id_source.ctx, &id_full);

        var path_buf: [128]u8 = undefined;
        const containers_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
            containers_subpath, id_full[0..id_short_length],
        }) catch unreachable;

        root.createDir(io, containers_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        var bundles_path_buf: [128]u8 = undefined;
        const bundles_path = std.fmt.bufPrint(&bundles_path_buf, "{s}/{s}", .{
            bundles_subpath, id_full[0..id_short_length],
        }) catch unreachable;

        root.createDir(io, bundles_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try root.deleteTree(io, containers_path);
                continue;
            },
            else => |e| {
                root.deleteTree(io, containers_path) catch {};
                return e;
            },
        };

        var overlays_path_buf: [128]u8 = undefined;
        const overlays_path = std.fmt.bufPrint(&overlays_path_buf, "{s}/{s}", .{
            overlays_subpath, id_full[0..id_short_length],
        }) catch unreachable;

        root.createDir(io, overlays_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try root.deleteTree(io, containers_path);
                try root.deleteTree(io, bundles_path);
                continue;
            },
            else => |e| {
                root.deleteTree(io, containers_path) catch {};
                root.deleteTree(io, bundles_path) catch {};
                return e;
            },
        };

        var started_buf: [32]u8 = undefined;
        const started_at_local = formatStartedAt(io, &started_buf);

        var short: [id_short_length]u8 = undefined;
        @memcpy(&short, id_full[0..id_short_length]);

        const ref_owned = try gpa.dupe(u8, image_ref);
        errdefer gpa.free(ref_owned);
        const digest_owned = try gpa.dupe(u8, image_digest);
        errdefer gpa.free(digest_owned);
        const started_owned = try gpa.dupe(u8, started_at_local);
        errdefer gpa.free(started_owned);
        const name_owned: ?[]const u8 = if (name) |n| try gpa.dupe(u8, n) else null;
        errdefer if (name_owned) |n| gpa.free(n);

        const persisted: StatePersisted = .{
            .id = short[0..],
            .id_full = id_full[0..],
            .name = name_owned,
            .image_ref = ref_owned,
            .image_digest = digest_owned,
            .started_at = started_owned,
        };

        try writeStateJson(io, root, containers_path, persisted);

        return .{
            .id = short,
            .id_full = id_full,
            .name = name_owned,
            .image_ref = ref_owned,
            .image_digest = digest_owned,
            .started_at = started_owned,
        };
    }

    return StateError.IdCollisionExhausted;
}

fn writeStateJson(
    io: Io,
    root: Io.Dir,
    containers_path: []const u8,
    persisted: StatePersisted,
) (Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.LinkError ||
    Io.File.Writer.Error ||
    std.json.Stringify.Error)!void {
    var file_path_buf: [192]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{
        containers_path, state_filename,
    }) catch unreachable;

    var atomic = try root.createFileAtomic(io, file_path, .{ .replace = false });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &write_buf);
    std.json.Stringify.value(persisted, stringify_options, &fw.interface) catch |err| switch (err) {
        error.WriteFailed => return fw.err.?,
    };
    fw.interface.flush() catch return fw.err.?;

    try atomic.link(io);
}

fn formatStartedAt(io: Io, buf: *[32]u8) []const u8 {
    const ts = Io.Clock.now(.real, io);
    const ns: i96 = ts.nanoseconds;
    const sec_signed: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
    const sec_unsigned: u64 = if (sec_signed < 0) 0 else @intCast(sec_signed);

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = sec_unsigned };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
}

const testing = std.testing;

fn isLowerHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

test "allocate creates the three dirs and a parseable state.json" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try allocate(
        testing.io,
        testing.allocator,
        root,
        "alpine:3.19",
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        null,
    );
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, id_short_length), c.id.len);
    try testing.expectEqual(@as(usize, id_full_length), c.id_full.len);
    try testing.expect(isLowerHex(c.id[0..]));
    try testing.expect(isLowerHex(c.id_full[0..]));
    try testing.expect(std.mem.startsWith(u8, c.id_full[0..], c.id[0..]));

    var path_buf: [128]u8 = undefined;
    const containers_id = try std.fmt.bufPrint(&path_buf, "containers/{s}", .{c.id[0..]});
    var bundles_buf: [128]u8 = undefined;
    const bundles_id = try std.fmt.bufPrint(&bundles_buf, "bundles/{s}", .{c.id[0..]});
    var overlays_buf: [128]u8 = undefined;
    const overlays_id = try std.fmt.bufPrint(&overlays_buf, "overlays/{s}", .{c.id[0..]});

    const c_stat = try root.statFile(testing.io, containers_id, .{});
    try testing.expectEqual(Io.File.Kind.directory, c_stat.kind);
    const b_stat = try root.statFile(testing.io, bundles_id, .{});
    try testing.expectEqual(Io.File.Kind.directory, b_stat.kind);
    const o_stat = try root.statFile(testing.io, overlays_id, .{});
    try testing.expectEqual(Io.File.Kind.directory, o_stat.kind);

    var state_path_buf: [192]u8 = undefined;
    const state_path = try std.fmt.bufPrint(&state_path_buf, "{s}/{s}", .{
        containers_id, state_filename,
    });
    const bytes = try root.readFileAlloc(testing.io, state_path, testing.allocator, .limited(8 * 1024));
    defer testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(StatePersisted, testing.allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testing.expectEqualStrings(c.id[0..], parsed.value.id);
    try testing.expectEqualStrings(c.id_full[0..], parsed.value.id_full);
    try testing.expect(parsed.value.name == null);
    try testing.expectEqualStrings("alpine:3.19", parsed.value.image_ref);
    try testing.expectEqualStrings("sha256:0000000000000000000000000000000000000000000000000000000000000000", parsed.value.image_digest);
    try testing.expectEqualStrings(initial_status, parsed.value.status);
    try testing.expect(parsed.value.started_at.len > 0);
}

test "consecutive allocations produce unique IDs and both triplets exist" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c1 = try allocate(testing.io, testing.allocator, root, "alpine:3.19", "sha256:aa", null);
    defer c1.deinit(testing.allocator);
    var c2 = try allocate(testing.io, testing.allocator, root, "alpine:3.19", "sha256:bb", null);
    defer c2.deinit(testing.allocator);

    try testing.expect(!std.mem.eql(u8, c1.id[0..], c2.id[0..]));
    try testing.expect(!std.mem.eql(u8, c1.id_full[0..], c2.id_full[0..]));

    var containers_dir = try root.openDir(testing.io, containers_subpath, .{ .iterate = true });
    defer containers_dir.close(testing.io);
    var it = containers_dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 2), n);
}

test "allocate carries a name through to state.json when supplied" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try allocate(testing.io, testing.allocator, root, "alpine:3.19", "sha256:cc", "web");
    defer c.deinit(testing.allocator);

    try testing.expectEqualStrings("web", c.name.?);

    var state_path_buf: [192]u8 = undefined;
    const state_path = try std.fmt.bufPrint(&state_path_buf, "containers/{s}/{s}", .{
        c.id[0..], state_filename,
    });
    const bytes = try root.readFileAlloc(testing.io, state_path, testing.allocator, .limited(8 * 1024));
    defer testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(StatePersisted, testing.allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testing.expectEqualStrings("web", parsed.value.name.?);
}

const RetrySeq = struct {
    ids: []const [id_full_length]u8,
    cursor: usize = 0,

    fn fill(io: Io, ctx: ?*anyopaque, out: *[id_full_length]u8) void {
        _ = io;
        const self: *RetrySeq = @ptrCast(@alignCast(ctx.?));
        const i = if (self.cursor >= self.ids.len) self.ids.len - 1 else self.cursor;
        out.* = self.ids[i];
        self.cursor += 1;
    }
};

test "allocate retries past a pre-existing containers/<id> collision" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try root.createDirPath(testing.io, containers_subpath);
    try root.createDirPath(testing.io, "containers/aaaaaaaaaaaa");

    var seq = RetrySeq{
        .ids = &[_][id_full_length]u8{
            ("a" ** id_full_length).*,
            ("b" ** id_full_length).*,
        },
    };
    var c = try allocateWithIdSource(
        testing.io,
        testing.allocator,
        root,
        "alpine:3.19",
        "sha256:dd",
        null,
        .{ .fill_fn = RetrySeq.fill, .ctx = &seq },
    );
    defer c.deinit(testing.allocator);

    try testing.expectEqualStrings("bbbbbbbbbbbb", c.id[0..]);
    const stat = try root.statFile(testing.io, "containers/bbbbbbbbbbbb", .{});
    try testing.expectEqual(Io.File.Kind.directory, stat.kind);
}

test "allocate rolls back containers/<id> when bundles/<id> collides" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try root.createDirPath(testing.io, bundles_subpath);
    try root.createDirPath(testing.io, "bundles/cccccccccccc");

    var seq = RetrySeq{
        .ids = &[_][id_full_length]u8{
            ("c" ** id_full_length).*,
            ("d" ** id_full_length).*,
        },
    };
    var c = try allocateWithIdSource(
        testing.io,
        testing.allocator,
        root,
        "alpine:3.19",
        "sha256:ee",
        null,
        .{ .fill_fn = RetrySeq.fill, .ctx = &seq },
    );
    defer c.deinit(testing.allocator);

    try testing.expectEqualStrings("dddddddddddd", c.id[0..]);

    // The orphan containers/cccccccccccc from attempt 1 must be rolled back.
    try testing.expectError(
        error.FileNotFound,
        root.statFile(testing.io, "containers/cccccccccccc", .{}),
    );

    // The pre-created bundles/cccccccccccc must remain.
    const bstat = try root.statFile(testing.io, "bundles/cccccccccccc", .{});
    try testing.expectEqual(Io.File.Kind.directory, bstat.kind);

    // The new triplet must exist.
    _ = try root.statFile(testing.io, "containers/dddddddddddd", .{});
    _ = try root.statFile(testing.io, "bundles/dddddddddddd", .{});
    _ = try root.statFile(testing.io, "overlays/dddddddddddd", .{});
}

test "allocate surfaces IdCollisionExhausted after the retry budget" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try root.createDirPath(testing.io, containers_subpath);
    try root.createDirPath(testing.io, "containers/eeeeeeeeeeee");

    var seq = RetrySeq{
        .ids = &[_][id_full_length]u8{("e" ** id_full_length).*},
    };
    try testing.expectError(StateError.IdCollisionExhausted, allocateWithIdSource(
        testing.io,
        testing.allocator,
        root,
        "alpine:3.19",
        "sha256:ff",
        null,
        .{ .fill_fn = RetrySeq.fill, .ctx = &seq },
    ));
}

test "StatePersisted round-trips through std.json" {
    const original: StatePersisted = .{
        .id = "abcdefabcdef",
        .id_full = "abcdefabcdef" ++ ("0" ** 52),
        .name = null,
        .image_ref = "alpine:3.19",
        .image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .started_at = "2026-05-03T12:34:56Z",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(original, stringify_options, &aw.writer);

    var parsed = try std.json.parseFromSlice(StatePersisted, testing.allocator, aw.writer.buffered(), .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testing.expectEqualStrings(original.id, parsed.value.id);
    try testing.expectEqualStrings(original.id_full, parsed.value.id_full);
    try testing.expect(parsed.value.name == null);
    try testing.expectEqualStrings(original.image_ref, parsed.value.image_ref);
    try testing.expectEqualStrings(original.image_digest, parsed.value.image_digest);
    try testing.expectEqualStrings(initial_status, parsed.value.status);
    try testing.expectEqualStrings(original.started_at, parsed.value.started_at);
}
