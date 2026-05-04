//! Container state allocation, lifecycle transitions, and `/proc` liveness.
//!
//! Owns ID generation, the per-container directory triplet under
//! `~/.rind/{containers,bundles,overlays}/<id>/`, and the
//! `state.json` lifecycle. `allocate` writes the initial document
//! (`status = .created`); `transition` advances it to `.running`
//! (with init pid) and `.exited` (with exit_code or signal) using
//! atomic temp+rename so concurrent readers never see a partial
//! file. `liveness` consults `/proc/<pid>/status` to detect stale
//! `.running` records (init reaped externally, etc.).
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
//! `state.json` is written via `createFileAtomic` - `link` for the
//! first write (`allocate`), `replace` for subsequent transitions.
//! Atomicity comes from the underlying `rename(2)`, which is atomic
//! within a single filesystem on Linux (ext4/btrfs/xfs); concurrent
//! `read` callers see either the prior or the new document, never
//! a half-written one.
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

/// Minimum prefix length the resolver accepts for id-prefix matching.
/// Below this we refuse the lookup (`PrefixTooShort`), too easy to
/// match an unintended container otherwise. Docker uses the same floor.
pub const id_prefix_min: usize = 4;

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

/// Lifecycle status persisted in `state.json`. Serialises to JSON as
/// the lowercase variant name (`"created"`, `"running"`, `"exited"`).
pub const Status = enum {
    /// Triplet allocated, libcrun not yet invoked.
    created,
    /// libcrun has the container; init pid recorded in `pid`.
    running,
    /// Container returned. Exactly one of `exit_code` / `signal` set.
    exited,
};

/// Closed semantic error set for state operations. Returned in
/// addition to the underlying filesystem and JSON-encoding error
/// sets (composed at each public function's signature).
pub const StateError = error{
    /// `allocate` exhausted `id_collision_max_retries` attempts to
    /// find a free directory triplet. Effectively impossible under
    /// normal conditions; signals a corrupted or maliciously
    /// pre-populated root.
    IdCollisionExhausted,
    /// `read`/`transition` could not open `state.json` (container
    /// directory missing or stripped by an external `--rm`).
    StateFileNotFound,
    /// `read` parsed `state.json` but it did not match the persisted
    /// schema (corrupted on-disk document or schema-version skew).
    StateFileCorrupt,
};

/// Closed semantic error set for `resolveTarget`. Disjoint from
/// `StateError` so callers can pattern-match on the lookup outcome
/// without conflating it with read/parse failures of any individual
/// `state.json`.
pub const ResolveError = error{
    /// No container's `name` field matched exactly and no short ID
    /// began with the supplied prefix.
    ContainerNotFound,
    /// Two or more short IDs share the supplied prefix. Caller can
    /// re-walk via `collectPrefixMatches` to render the offending
    /// IDs into a diagnostic.
    AmbiguousId,
    /// Supplied needle is shorter than `id_prefix_min` and didn't
    /// match any name. Refusing to match such a short prefix avoids
    /// silent surprises when only one container happens to begin with
    /// the two letters the user typed today.
    PrefixTooShort,
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
    /// Resolved `process.args` joined with single spaces (Docker
    /// convention for the COMMAND column in `ps`). `null` when the
    /// caller could not resolve the argv at allocation time.
    command: ?[]const u8 = null,
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
        if (self.command) |c| gpa.free(c);
        self.* = undefined;
    }
};

/// Persisted shape of `state.json`. Field names are the canonical
/// snake_case wire form. `pid` is set on `.running`, `exit_code` /
/// `signal` on `.exited` (exactly one of the latter pair).
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
    /// Resolved `process.args` joined with single spaces. Omitted from
    /// the on-disk JSON when null (`emit_null_optional_fields = false`).
    command: ?[]const u8 = null,
    /// Lifecycle status.
    status: Status = .created,
    /// Allocation timestamp (RFC 3339 UTC).
    started_at: []const u8,
    /// libcrun init pid; set when status reaches `.running`.
    pid: ?i32 = null,
    /// Normal-exit code (0..255); set when status is `.exited` and
    /// the container was not terminated by signal.
    exit_code: ?i32 = null,
    /// Terminating signal number; set when status is `.exited` and
    /// the container was killed by signal.
    signal: ?i32 = null,
};

/// Selective field updates for `transition`. The new `status` is
/// always set; the optional fields default to `null`, which means
/// "preserve the prior persisted value". To advance from `.running`
/// to `.exited` while keeping the recorded pid, the caller passes
/// `pid = null` (preserve) and the new `exit_code` / `signal`.
pub const TransitionFields = struct {
    status: Status,
    pid: ?i32 = null,
    exit_code: ?i32 = null,
    signal: ?i32 = null,
};

/// Outcome of querying `/proc/<pid>/status`. `.zombie` indicates the
/// init process has exited but is still waiting to be reaped — for
/// rind this means a `--rm`-less run whose orchestrator died before
/// recording the exit code.
pub const Liveness = enum {
    /// Process exists and is in any non-zombie state.
    alive,
    /// `/proc/<pid>/status` is gone (ESRCH / FileNotFound).
    exited,
    /// Process exists but its `State:` line begins with `Z`.
    zombie,
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
    command: ?[]const u8,
) AllocateError!Container {
    const default_source: IdSource = .{ .fill_fn = defaultIdFill, .ctx = null };
    return allocateWithIdSource(io, gpa, root, image_ref, image_digest, name, command, default_source);
}

const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

/// Function-pointer hook for ID generation. The default impl hashes
/// wall-clock + 16 random bytes; tests inject deterministic sequences
/// to exercise the collision-retry path or to build fixtures with
/// chosen prefixes (`runtime/state_test_seams.zig`-style usage).
pub const IdSource = struct {
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

/// Test-only seam exposed for fixtures that need a chosen ID. Callers
/// outside the test suite should use `allocate`.
pub fn allocateWithIdSource(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    image_ref: []const u8,
    image_digest: []const u8,
    name: ?[]const u8,
    command: ?[]const u8,
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
        const command_owned: ?[]const u8 = if (command) |c| try gpa.dupe(u8, c) else null;
        errdefer if (command_owned) |c| gpa.free(c);

        const persisted: StatePersisted = .{
            .id = short[0..],
            .id_full = id_full[0..],
            .name = name_owned,
            .image_ref = ref_owned,
            .image_digest = digest_owned,
            .command = command_owned,
            .started_at = started_owned,
        };

        try writeStateJson(io, root, containers_path, persisted);

        return .{
            .id = short,
            .id_full = id_full,
            .name = name_owned,
            .image_ref = ref_owned,
            .image_digest = digest_owned,
            .command = command_owned,
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

/// Composed error set returned by `transition`.
pub const TransitionError =
    StateError ||
    Io.Dir.ReadFileAllocError ||
    Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.ReplaceError ||
    Io.File.Writer.Error ||
    std.json.Stringify.Error;

/// Composed error set returned by `read`.
pub const ReadError =
    StateError ||
    Io.Dir.ReadFileAllocError;

const state_doc_max_bytes: usize = 64 * 1024;

/// Atomically rewrite `containers/<container_id>/state.json` with
/// `fields` merged onto the existing document. Static fields (`id`,
/// `id_full`, `image_*`, `started_at`, `name`) are preserved; only
/// the lifecycle pair (`status`, `pid`, `exit_code`, `signal`) is
/// updated.
///
/// Atomic via temp+rename: concurrent `read` callers see either the
/// pre-transition document or the post-transition document, never a
/// partial write. The caller must serialise concurrent `transition`
/// calls on the same `container_id` — last writer wins, prior
/// transitions can be overwritten.
pub fn transition(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    container_id: []const u8,
    fields: TransitionFields,
) TransitionError!void {
    var path_buf: [192]u8 = undefined;
    const containers_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
        containers_subpath, container_id,
    }) catch unreachable;

    var file_path_buf: [192]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{
        containers_path, state_filename,
    }) catch unreachable;

    const bytes = root_dir.readFileAlloc(io, file_path, gpa, .limited(state_doc_max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return StateError.StateFileNotFound,
        else => |e| return e,
    };
    defer gpa.free(bytes);

    var parsed = std.json.parseFromSlice(StatePersisted, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return StateError.StateFileCorrupt;
    defer parsed.deinit();

    const updated: StatePersisted = .{
        .id = parsed.value.id,
        .id_full = parsed.value.id_full,
        .name = parsed.value.name,
        .image_ref = parsed.value.image_ref,
        .image_digest = parsed.value.image_digest,
        .command = parsed.value.command,
        .status = fields.status,
        .started_at = parsed.value.started_at,
        .pid = fields.pid orelse parsed.value.pid,
        .exit_code = fields.exit_code orelse parsed.value.exit_code,
        .signal = fields.signal orelse parsed.value.signal,
    };

    var atomic = try root_dir.createFileAtomic(io, file_path, .{ .replace = true });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &write_buf);
    std.json.Stringify.value(updated, stringify_options, &fw.interface) catch |err| switch (err) {
        error.WriteFailed => return fw.err.?,
    };
    fw.interface.flush() catch return fw.err.?;

    try atomic.replace(io);
}

/// Read the persisted `state.json` for `container_id`. Returns a
/// parsed document that owns its own backing allocations; caller
/// must invoke `parsed.deinit()`.
pub fn read(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    container_id: []const u8,
) ReadError!std.json.Parsed(StatePersisted) {
    var path_buf: [192]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{
        containers_subpath, container_id, state_filename,
    }) catch unreachable;

    const bytes = root_dir.readFileAlloc(io, file_path, gpa, .limited(state_doc_max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return StateError.StateFileNotFound,
        else => |e| return e,
    };
    defer gpa.free(bytes);

    return std.json.parseFromSlice(StatePersisted, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return StateError.StateFileCorrupt;
}

/// Read `/proc/<pid>/status` and classify the process. ESRCH (the
/// file went missing between open and read or never existed) maps
/// to `.exited`. A `State:` line starting with `Z` maps to `.zombie`.
/// Any other state — including an unparseable file — is reported as
/// `.alive`, since failure to classify shouldn't cause the caller to
/// declare a process dead.
pub fn liveness(io: Io, pid: i32) Liveness {
    _ = io;
    if (pid <= 0) return .exited;

    var path_buf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid}) catch return .exited;

    const fd = std.posix.openatZ(
        std.posix.AT.FDCWD,
        path.ptr,
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return .exited,
        else => return .alive,
    };
    defer _ = std.os.linux.close(fd);

    var buf: [4096]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return .alive;
    if (n == 0) return .alive;

    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        const prefix: []const u8 = "State:";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = std.mem.trimStart(u8, line[prefix.len..], " \t");
        if (rest.len == 0) return .alive;
        return if (rest[0] == 'Z') .zombie else .alive;
    }
    return .alive;
}

/// Composed error set returned by `resolveTarget`. Folds in the
/// filesystem and JSON failures that may surface while walking the
/// `containers/` directory.
pub const ResolveTargetError =
    ResolveError ||
    Io.Dir.OpenError ||
    Io.Dir.Iterator.Error ||
    Allocator.Error;

/// exact name, full short ID, or short-ID
/// prefix `>= id_prefix_min` to a 12-char short ID. Walks
/// `<root_dir>/containers/`. A name match short-circuits the walk and
/// always wins over an ID-prefix match.
///
/// Per-container `state.json` open/parse failures are skipped silently
/// (debug-logged); a single corrupt record never aborts resolution.
pub fn resolveTarget(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    needle: []const u8,
) ResolveTargetError![id_short_length]u8 {
    if (needle.len == 0) return ResolveError.ContainerNotFound;

    var containers_dir = root_dir.openDir(io, containers_subpath, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return ResolveError.ContainerNotFound,
        else => |e| return e,
    };
    defer containers_dir.close(io);

    var matches: usize = 0;
    var first_match: [id_short_length]u8 = undefined;

    var it = containers_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != id_short_length) continue;

        var parsed = read(io, gpa, root_dir, entry.name) catch |err| {
            std.log.debug("rind: resolveTarget: skip {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        defer parsed.deinit();

        if (parsed.value.name) |n| {
            if (std.mem.eql(u8, n, needle)) {
                var out: [id_short_length]u8 = undefined;
                @memcpy(&out, entry.name[0..id_short_length]);
                return out;
            }
        }

        if (needle.len < id_prefix_min) continue;
        if (needle.len > id_short_length) continue;
        if (!std.mem.startsWith(u8, entry.name, needle)) continue;

        if (matches == 0) {
            @memcpy(&first_match, entry.name[0..id_short_length]);
        }
        matches += 1;
    }

    if (matches == 1) return first_match;
    if (matches > 1) return ResolveError.AmbiguousId;

    if (needle.len < id_prefix_min) return ResolveError.PrefixTooShort;
    return ResolveError.ContainerNotFound;
}

/// Collect up to `out.len` short IDs whose `containers/<id>/` directory
/// name starts with `needle`. Used by `cli/rm.zig` on the `AmbiguousId`
/// error path to render the offending IDs into a diagnostic. Returns the
/// number of IDs written; caller passes a small fixed-size buffer
pub fn collectPrefixMatches(
    io: Io,
    root_dir: Io.Dir,
    needle: []const u8,
    out: [][id_short_length]u8,
) Io.Dir.OpenError!usize {
    if (out.len == 0) return 0;
    if (needle.len < id_prefix_min) return 0;
    if (needle.len > id_short_length) return 0;

    var containers_dir = root_dir.openDir(io, containers_subpath, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |e| return e,
    };
    defer containers_dir.close(io);

    var n: usize = 0;
    var it = containers_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != id_short_length) continue;
        if (!std.mem.startsWith(u8, entry.name, needle)) continue;
        @memcpy(&out[n], entry.name[0..id_short_length]);
        n += 1;
        if (n == out.len) break;
    }
    return n;
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
    try testing.expectEqual(Status.created, parsed.value.status);
    try testing.expect(parsed.value.started_at.len > 0);
    try testing.expectEqual(@as(?i32, null), parsed.value.pid);
    try testing.expectEqual(@as(?i32, null), parsed.value.exit_code);
    try testing.expectEqual(@as(?i32, null), parsed.value.signal);
}

test "consecutive allocations produce unique IDs and both triplets exist" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c1 = try allocate(testing.io, testing.allocator, root, "alpine:3.19", "sha256:aa", null, null);
    defer c1.deinit(testing.allocator);
    var c2 = try allocate(testing.io, testing.allocator, root, "alpine:3.19", "sha256:bb", null, null);
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

    var c = try allocate(testing.io, testing.allocator, root, "alpine:3.19", "sha256:cc", "web", "/bin/sh -c hi");
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
    try testing.expectEqualStrings("/bin/sh -c hi", parsed.value.command.?);
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
    try testing.expectEqual(Status.created, parsed.value.status);
    try testing.expectEqualStrings(original.started_at, parsed.value.started_at);
}

test "transition: created -> running -> exited preserves prior pid" {
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
        "sha256:00",
        null,
        "/bin/sh",
    );
    defer c.deinit(testing.allocator);

    {
        var parsed = try read(testing.io, testing.allocator, root, c.id[0..]);
        defer parsed.deinit();
        try testing.expectEqual(Status.created, parsed.value.status);
        try testing.expectEqual(@as(?i32, null), parsed.value.pid);
        try testing.expectEqualStrings("/bin/sh", parsed.value.command.?);
    }

    try transition(testing.io, testing.allocator, root, c.id[0..], .{
        .status = .running,
        .pid = 4242,
    });

    {
        var parsed = try read(testing.io, testing.allocator, root, c.id[0..]);
        defer parsed.deinit();
        try testing.expectEqual(Status.running, parsed.value.status);
        try testing.expectEqual(@as(?i32, 4242), parsed.value.pid);
        try testing.expectEqual(@as(?i32, null), parsed.value.exit_code);
    }

    try transition(testing.io, testing.allocator, root, c.id[0..], .{
        .status = .exited,
        .exit_code = 0,
        .signal = 0,
    });

    {
        var parsed = try read(testing.io, testing.allocator, root, c.id[0..]);
        defer parsed.deinit();
        try testing.expectEqual(Status.exited, parsed.value.status);
        try testing.expectEqual(@as(?i32, 4242), parsed.value.pid);
        try testing.expectEqual(@as(?i32, 0), parsed.value.exit_code);
        try testing.expectEqual(@as(?i32, 0), parsed.value.signal);
        try testing.expectEqualStrings("/bin/sh", parsed.value.command.?);
    }
}

test "transition: missing state file surfaces StateFileNotFound" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try root.createDirPath(testing.io, containers_subpath);

    try testing.expectError(StateError.StateFileNotFound, transition(
        testing.io,
        testing.allocator,
        root,
        "ffffffffffff",
        .{ .status = .running, .pid = 1 },
    ));
}

test "read: missing state file surfaces StateFileNotFound" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try testing.expectError(StateError.StateFileNotFound, read(
        testing.io,
        testing.allocator,
        root,
        "ffffffffffff",
    ));
}

const ConcurrentReader = struct {
    root: Io.Dir,
    container_id: [id_short_length]u8,
    iterations: u32,
    stop: *std.atomic.Value(bool),
    saw_corrupt: std.atomic.Value(bool) = .init(false),

    fn run(self: *ConcurrentReader) void {
        var i: u32 = 0;
        while (i < self.iterations and !self.stop.load(.acquire)) : (i += 1) {
            var parsed = read(testing.io, testing.allocator, self.root, self.container_id[0..]) catch |err| switch (err) {
                StateError.StateFileCorrupt => {
                    self.saw_corrupt.store(true, .release);
                    return;
                },
                else => continue,
            };
            parsed.deinit();
        }
    }
};

test "transition is atomic under concurrent readers" {
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
        "sha256:11",
        null,
        null,
    );
    defer c.deinit(testing.allocator);

    var stop: std.atomic.Value(bool) = .init(false);

    const reader_count = 4;
    const reader_iters: u32 = 200;
    var readers: [reader_count]ConcurrentReader = undefined;
    var threads: [reader_count]std.Thread = undefined;
    for (&readers, &threads) |*r, *t| {
        r.* = .{
            .root = root,
            .container_id = c.id,
            .iterations = reader_iters,
            .stop = &stop,
        };
        t.* = try std.Thread.spawn(.{}, ConcurrentReader.run, .{r});
    }

    var w: u32 = 0;
    while (w < 200) : (w += 1) {
        const fields: TransitionFields = if (w % 2 == 0)
            .{ .status = .running, .pid = @as(i32, @intCast(w + 1)) }
        else
            .{ .status = .exited, .exit_code = @as(i32, @intCast(w & 0xFF)) };
        try transition(testing.io, testing.allocator, root, c.id[0..], fields);
    }

    stop.store(true, .release);
    for (&threads) |t| t.join();

    for (&readers) |*r| {
        try testing.expect(!r.saw_corrupt.load(.acquire));
    }
}

test "liveness: self pid is alive" {
    const self_pid: i32 = @intCast(std.os.linux.getpid());
    try testing.expectEqual(Liveness.alive, liveness(testing.io, self_pid));
}

test "liveness: invalid pids report exited" {
    try testing.expectEqual(Liveness.exited, liveness(testing.io, 0));
    try testing.expectEqual(Liveness.exited, liveness(testing.io, -1));
    try testing.expectEqual(Liveness.exited, liveness(testing.io, std.math.maxInt(i32)));
}

test "liveness: zombie process reports zombie" {
    const fork_ret = std.os.linux.fork();
    const fork_signed: isize = @bitCast(fork_ret);
    if (fork_signed < 0) return error.ForkFailed;

    if (fork_ret == 0) {
        std.os.linux.exit(0);
    }

    const child_pid: i32 = @intCast(fork_ret);
    defer {
        var status: u32 = 0;
        _ = std.os.linux.waitpid(child_pid, &status, 0);
    }

    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        const result = liveness(testing.io, child_pid);
        if (result == .zombie) return;
        const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.ZombieNotObserved;
}

fn allocFixedId(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    full_id: [id_full_length]u8,
    image_ref: []const u8,
    image_digest: []const u8,
    name: ?[]const u8,
) !Container {
    var seq = RetrySeq{ .ids = &[_][id_full_length]u8{full_id} };
    return allocateWithIdSource(io, gpa, root, image_ref, image_digest, name, null, .{
        .fill_fn = RetrySeq.fill,
        .ctx = &seq,
    });
}

test "resolveTarget: missing containers/ returns ContainerNotFound" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try testing.expectError(
        ResolveError.ContainerNotFound,
        resolveTarget(testing.io, testing.allocator, root, "abcd"),
    );
}

test "resolveTarget: empty needle is ContainerNotFound" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try testing.expectError(
        ResolveError.ContainerNotFound,
        resolveTarget(testing.io, testing.allocator, root, ""),
    );
}

test "resolveTarget: exact name match returns id" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try allocFixedId(
        testing.io,
        gpa,
        root,
        ("a" ** id_full_length).*,
        "alpine:3.19",
        "sha256:aa",
        "web",
    );
    defer c.deinit(gpa);

    const got = try resolveTarget(testing.io, gpa, root, "web");
    try testing.expectEqualStrings(c.id[0..], got[0..]);
}

test "resolveTarget: full short id resolves" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try allocFixedId(
        testing.io,
        gpa,
        root,
        ("b" ** id_full_length).*,
        "alpine:3.19",
        "sha256:bb",
        null,
    );
    defer c.deinit(gpa);

    const got = try resolveTarget(testing.io, gpa, root, c.id[0..]);
    try testing.expectEqualStrings(c.id[0..], got[0..]);
}

test "resolveTarget: 4-char prefix unambiguous" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try allocFixedId(
        testing.io,
        gpa,
        root,
        ("c" ** id_full_length).*,
        "alpine:3.19",
        "sha256:cc",
        null,
    );
    defer c.deinit(gpa);

    const got = try resolveTarget(testing.io, gpa, root, "cccc");
    try testing.expectEqualStrings(c.id[0..], got[0..]);
}

test "resolveTarget: 3-char prefix is too short when no name match" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try allocFixedId(
        testing.io,
        gpa,
        root,
        ("d" ** id_full_length).*,
        "alpine:3.19",
        "sha256:dd",
        null,
    );
    defer c.deinit(gpa);

    try testing.expectError(
        ResolveError.PrefixTooShort,
        resolveTarget(testing.io, gpa, root, "ddd"),
    );
}

test "resolveTarget: ambiguous prefix returns AmbiguousId" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var id1: [id_full_length]u8 = undefined;
    var id2: [id_full_length]u8 = undefined;
    @memcpy(id1[0..6], "ababab");
    @memset(id1[6..], 'a');
    @memcpy(id2[0..6], "ababab");
    @memset(id2[6..], 'b');

    var c1 = try allocFixedId(testing.io, gpa, root, id1, "alpine:3.19", "sha256:01", null);
    defer c1.deinit(gpa);
    var c2 = try allocFixedId(testing.io, gpa, root, id2, "alpine:3.19", "sha256:02", null);
    defer c2.deinit(gpa);

    try testing.expectError(
        ResolveError.AmbiguousId,
        resolveTarget(testing.io, gpa, root, "abab"),
    );
}

test "resolveTarget: name match wins over conflicting id-prefix" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var named = try allocFixedId(
        testing.io,
        gpa,
        root,
        ("e" ** id_full_length).*,
        "alpine:3.19",
        "sha256:e1",
        "feed",
    );
    defer named.deinit(gpa);

    var prefix_owner = try allocFixedId(
        testing.io,
        gpa,
        root,
        ("f" ** 4 ++ "e" ** (id_full_length - 4)).*,
        "alpine:3.19",
        "sha256:e2",
        null,
    );
    defer prefix_owner.deinit(gpa);

    const got = try resolveTarget(testing.io, gpa, root, "feed");
    try testing.expectEqualStrings(named.id[0..], got[0..]);
}

test "resolveTarget: no match returns ContainerNotFound" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try allocFixedId(
        testing.io,
        gpa,
        root,
        ("9" ** id_full_length).*,
        "alpine:3.19",
        "sha256:99",
        "live",
    );
    defer c.deinit(gpa);

    try testing.expectError(
        ResolveError.ContainerNotFound,
        resolveTarget(testing.io, gpa, root, "ghostly"),
    );
}

test "collectPrefixMatches: returns up to two ambiguous ids" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var id1: [id_full_length]u8 = undefined;
    var id2: [id_full_length]u8 = undefined;
    @memcpy(id1[0..6], "cdcdcd");
    @memset(id1[6..], '1');
    @memcpy(id2[0..6], "cdcdcd");
    @memset(id2[6..], '2');

    var c1 = try allocFixedId(testing.io, gpa, root, id1, "alpine:3.19", "sha256:01", null);
    defer c1.deinit(gpa);
    var c2 = try allocFixedId(testing.io, gpa, root, id2, "alpine:3.19", "sha256:02", null);
    defer c2.deinit(gpa);

    var out: [2][id_short_length]u8 = undefined;
    const n = try collectPrefixMatches(testing.io, root, "cdcd", out[0..]);
    try testing.expectEqual(@as(usize, 2), n);
    const got1 = out[0][0..];
    const got2 = out[1][0..];
    const both = std.mem.eql(u8, got1, c1.id[0..]) or std.mem.eql(u8, got1, c2.id[0..]);
    try testing.expect(both);
    try testing.expect(!std.mem.eql(u8, got1, got2));
}
