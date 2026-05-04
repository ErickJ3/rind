//! Cold-start container teardown.
//!
//! Used by `rind rm` to remove a stopped (or, with `-f`, running)
//! container that the current process did not start. The original
//! orchestrator is gone, so the in-memory `MountedOverlay` and libcrun
//! `Container` handles are unavailable; everything is recovered from
//! `state.json` and the on-disk paths.
//!
//! Two entry points:
//!
//! * `removeTriplet`: idempotent recursive delete of the four
//!   directories rind keeps per container (`containers/<id>`,
//!   `bundles/<id>`, `overlays/<id>`, `runtime/<id_full>`). Also called
//!   by `run.zig`'s `--rm` success path so the warm and cold cleanup
//!   modes share one implementation.
//!
//! * `teardown`: full sequence: reconcile `state.json` against
//!   `/proc`, optionally `kill -9` + wait, unmount any leftover
//!   overlay, then `removeTriplet`.
//!
//! libcrun's per-container state directory under `runtime/<id_full>`
//! is a plain set of files (status.json, lockfile, notify socket).
//! Once the init pid is dead there is no kernel resource to release;
//! `deleteTree` is enough. We therefore do not call `libcrun.delete`
//! reconstructing a libcrun `Container` handle would require re-loading
//! the bundle config, which has often already been torn down.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const overlay_mod = @import("overlay.zig");
const state_mod = @import("state.zig");

/// Closed semantic error set for `teardown`. Callers compose this with
/// the underlying filesystem and state-read errors.
pub const TeardownError = error{
    /// Container is `running` and `force` was not set. Caller must
    /// pass `-f` to proceed.
    ContainerRunning,
    /// `force` was set, SIGKILL was delivered, but the init pid was
    /// still alive after the configured timeout. Likely a process
    /// stuck in uninterruptible (`D`) state.
    KillTimeout,
};

/// Test seam injecting the side-effecting parts of `teardown` so unit
/// tests don't have to spawn real processes or touch the kernel.
pub const TeardownDeps = struct {
    /// Defaults to `defaultKill`, which wraps `std.posix.kill` and
    /// swallows `ProcessNotFound` (race with the kernel reaping the
    /// process between our liveness check and the kill).
    kill_fn: *const fn (pid: i32) void = defaultKill,
    /// Defaults to `state_mod.liveness`. Tests inject a programmable
    /// stub.
    liveness_fn: *const fn (io: Io, pid: i32) state_mod.Liveness = state_mod.liveness,
    /// Defaults to `overlay_mod.unmountPath`. Tests stub it out so they
    /// don't poke the kernel mount table.
    unmount_path_fn: *const fn (merged_abspath: []const u8) overlay_mod.OverlayError!void = overlay_mod.unmountPath,
    /// Defaults to `Io.sleep` for the kill-poll loop. Tests inject a
    /// no-op so the timeout case finishes in microseconds.
    sleep_fn: *const fn (io: Io, ns: u64) void = defaultSleep,
};

/// Caller-tunable knobs.
pub const TeardownOptions = struct {
    /// `-f`: SIGKILL the init pid and wait. When false, a still-running
    /// container surfaces `ContainerRunning`.
    force: bool = false,
    /// Absolute path of the rind state root. Needed to construct the
    /// overlay merged path for `unmount_path_fn`.
    root_abspath: []const u8,
    /// Wall-clock cap on the post-SIGKILL liveness poll. Defaults to
    /// 10 s (the spec figure). Tests shrink it to keep the suite fast.
    kill_timeout_ms: u64 = 10_000,
    /// Polling cadence inside the kill-wait loop. Defaults to 100 ms;
    /// 100 iterations × 100 ms = 10 s.
    kill_poll_interval_ms: u64 = 100,
};

fn defaultKill(pid: i32) void {
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
}

fn defaultSleep(io: Io, ns: u64) void {
    Io.sleep(io, .{ .nanoseconds = @intCast(ns) }, .awake) catch {};
}

/// Idempotent removal of the four per-container directories. Each
/// `deleteTree` swallows `FileNotFound` so re-running cleanup after a
/// partial prior attempt is a no-op. Pass `id_full = null` when the
/// caller doesn't have it (`state.json` was missing); the libcrun
/// runtime dir lives under the full ID so the cleanup is skipped.
pub fn removeTriplet(
    io: Io,
    root_dir: Io.Dir,
    id_short: []const u8,
    id_full: ?[]const u8,
) Io.Dir.DeleteTreeError!void {
    try deleteIfExists(io, root_dir, state_mod.containers_subpath, id_short);
    try deleteIfExists(io, root_dir, state_mod.bundles_subpath, id_short);
    try deleteIfExists(io, root_dir, state_mod.overlays_subpath, id_short);
    if (id_full) |full| {
        try deleteIfExists(io, root_dir, state_mod.runtime_subpath, full);
    }
}

fn deleteIfExists(
    io: Io,
    root_dir: Io.Dir,
    parent_subpath: []const u8,
    id: []const u8,
) Io.Dir.DeleteTreeError!void {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ parent_subpath, id }) catch unreachable;
    try root_dir.deleteTree(io, path);
}

/// Composed error set returned by `teardown`. Folds in `state.read`
/// failures and the filesystem error sets touched by the cleanup
/// stages so callers see one uniform set.
pub const FullTeardownError =
    TeardownError ||
    state_mod.ReadError ||
    overlay_mod.OverlayError ||
    Io.Dir.DeleteTreeError ||
    Allocator.Error;

/// Cold-start teardown for `<root_dir>/containers/<id_short>/`.
///
/// Sequence:
/// 1. Read `state.json`. Missing → idempotent no-op (after running the
///    triplet cleanup so partial removals can be retried).
/// 2. If `status == .running`, consult `/proc/<pid>` via `liveness_fn`.
///    Stale running (state says `.running`, `/proc` says gone) is
///    reconciled silently and treated as exited.
/// 3. If actually running and `!force` → `ContainerRunning`.
/// 4. If actually running and `force` → `kill_fn(pid)` once, then poll
///    `liveness_fn` until it reports `.exited` or `kill_timeout_ms`
///    elapses (`KillTimeout`).
/// 5. Best-effort overlay unmount-by-path.
/// 6. `removeTriplet`.
pub fn teardown(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    id_short: []const u8,
    opts: TeardownOptions,
    deps: TeardownDeps,
) FullTeardownError!void {
    var parsed_opt: ?std.json.Parsed(state_mod.StatePersisted) = state_mod.read(io, gpa, root_dir, id_short) catch |err| switch (err) {
        state_mod.StateError.StateFileNotFound => null,
        else => |e| return e,
    };
    defer if (parsed_opt) |*p| p.deinit();

    var id_full_opt: ?[]const u8 = null;
    if (parsed_opt) |p| {
        id_full_opt = p.value.id_full;

        if (p.value.status == .running) {
            const pid = p.value.pid orelse 0;
            const live = deps.liveness_fn(io, pid);
            const really_alive = live == .alive or live == .zombie;
            if (really_alive) {
                if (!opts.force) return TeardownError.ContainerRunning;
                deps.kill_fn(pid);
                try waitForExit(io, deps, pid, opts);
            }
        }
    }

    var merged_buf: [4096]u8 = undefined;
    const merged_path = std.fmt.bufPrint(&merged_buf, "{s}/{s}/{s}/merged", .{
        opts.root_abspath, state_mod.overlays_subpath, id_short,
    }) catch return TeardownError.KillTimeout;
    deps.unmount_path_fn(merged_path) catch {};

    try removeTriplet(io, root_dir, id_short, id_full_opt);
}

fn waitForExit(
    io: Io,
    deps: TeardownDeps,
    pid: i32,
    opts: TeardownOptions,
) TeardownError!void {
    const interval_ns: u64 = opts.kill_poll_interval_ms * std.time.ns_per_ms;
    const interval_ms = if (opts.kill_poll_interval_ms == 0) 1 else opts.kill_poll_interval_ms;
    const max_attempts: u64 = (opts.kill_timeout_ms + interval_ms - 1) / interval_ms;

    var attempts: u64 = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        const live = deps.liveness_fn(io, pid);
        if (live == .exited) return;
        deps.sleep_fn(io, interval_ns);
    }
    if (deps.liveness_fn(io, pid) == .exited) return;
    return TeardownError.KillTimeout;
}

const testing = std.testing;

const StubState = struct {
    flips_at: u32 = 0,
    counter: u32 = 0,
    initial: state_mod.Liveness = .alive,
    after: state_mod.Liveness = .exited,
    kill_calls: u32 = 0,
    sleep_calls: u32 = 0,
    unmount_calls: u32 = 0,
};

threadlocal var g_stub: ?*StubState = null;

fn stubLiveness(io: Io, pid: i32) state_mod.Liveness {
    _ = io;
    _ = pid;
    if (g_stub) |s| {
        defer s.counter += 1;
        if (s.counter >= s.flips_at) return s.after;
        return s.initial;
    }
    return .exited;
}

fn stubKill(pid: i32) void {
    _ = pid;
    if (g_stub) |s| s.kill_calls += 1;
}

fn stubSleep(io: Io, ns: u64) void {
    _ = io;
    _ = ns;
    if (g_stub) |s| s.sleep_calls += 1;
}

fn stubUnmount(path: []const u8) overlay_mod.OverlayError!void {
    _ = path;
    if (g_stub) |s| s.unmount_calls += 1;
}

fn makeDeps(stub: *StubState) TeardownDeps {
    g_stub = stub;
    return .{
        .kill_fn = stubKill,
        .liveness_fn = stubLiveness,
        .unmount_path_fn = stubUnmount,
        .sleep_fn = stubSleep,
    };
}

const fast_opts: TeardownOptions = .{
    .root_abspath = "/tmp",
    .kill_timeout_ms = 10,
    .kill_poll_interval_ms = 1,
};

fn seedExited(
    gpa: Allocator,
    root: Io.Dir,
    name: ?[]const u8,
) !state_mod.Container {
    var c = try state_mod.allocate(testing.io, gpa, root, "alpine:3.19", "sha256:aa", name, null);
    errdefer c.deinit(gpa);
    try state_mod.transition(testing.io, gpa, root, c.id[0..], .{
        .status = .exited,
        .exit_code = 0,
    });
    return c;
}

test "removeTriplet: deletes all four dirs and is idempotent" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try seedExited(gpa, root, null);
    defer c.deinit(gpa);

    var rt_buf: [128]u8 = undefined;
    const rt_path = try std.fmt.bufPrint(&rt_buf, "{s}/{s}", .{ state_mod.runtime_subpath, c.id_full[0..] });
    try root.createDirPath(testing.io, rt_path);

    try removeTriplet(testing.io, root, c.id[0..], c.id_full[0..]);

    inline for (&[_][]const u8{
        state_mod.containers_subpath,
        state_mod.bundles_subpath,
        state_mod.overlays_subpath,
    }) |sub| {
        var path_buf: [128]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sub, c.id[0..] });
        try testing.expectError(error.FileNotFound, root.statFile(testing.io, p, .{}));
    }
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, rt_path, .{}));

    try removeTriplet(testing.io, root, c.id[0..], c.id_full[0..]);
}

test "removeTriplet: skips runtime when id_full is null" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try seedExited(gpa, root, null);
    defer c.deinit(gpa);

    try removeTriplet(testing.io, root, c.id[0..], null);

    var path_buf: [128]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ state_mod.containers_subpath, c.id[0..] });
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, p, .{}));
}

test "teardown: exited container removes triplet without invoking kill" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try seedExited(gpa, root, null);
    defer c.deinit(gpa);

    var stub: StubState = .{};
    try teardown(testing.io, gpa, root, c.id[0..], fast_opts, makeDeps(&stub));
    try testing.expectEqual(@as(u32, 0), stub.kill_calls);
    try testing.expectEqual(@as(u32, 1), stub.unmount_calls);
}

test "teardown: running + alive without force returns ContainerRunning" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try state_mod.allocate(testing.io, gpa, root, "alpine:3.19", "sha256:aa", null, null);
    defer c.deinit(gpa);
    try state_mod.transition(testing.io, gpa, root, c.id[0..], .{ .status = .running, .pid = 12345 });

    var stub: StubState = .{ .initial = .alive, .after = .alive };
    try testing.expectError(
        TeardownError.ContainerRunning,
        teardown(testing.io, gpa, root, c.id[0..], fast_opts, makeDeps(&stub)),
    );
    try testing.expectEqual(@as(u32, 0), stub.kill_calls);
}

test "teardown: stale running (state=running, liveness=exited) succeeds without force" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try state_mod.allocate(testing.io, gpa, root, "alpine:3.19", "sha256:aa", null, null);
    defer c.deinit(gpa);
    try state_mod.transition(testing.io, gpa, root, c.id[0..], .{ .status = .running, .pid = 99999999 });

    var stub: StubState = .{ .initial = .exited, .after = .exited };
    try teardown(testing.io, gpa, root, c.id[0..], fast_opts, makeDeps(&stub));
    try testing.expectEqual(@as(u32, 0), stub.kill_calls);
}

test "teardown: running + force kills, waits, removes" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try state_mod.allocate(testing.io, gpa, root, "alpine:3.19", "sha256:aa", null, null);
    defer c.deinit(gpa);
    try state_mod.transition(testing.io, gpa, root, c.id[0..], .{ .status = .running, .pid = 12345 });

    var stub: StubState = .{ .flips_at = 2, .initial = .alive, .after = .exited };
    var opts = fast_opts;
    opts.force = true;

    try teardown(testing.io, gpa, root, c.id[0..], opts, makeDeps(&stub));
    try testing.expectEqual(@as(u32, 1), stub.kill_calls);

    var path_buf: [128]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ state_mod.containers_subpath, c.id[0..] });
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, p, .{}));
}

test "teardown: running + force + liveness never flips returns KillTimeout" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try state_mod.allocate(testing.io, gpa, root, "alpine:3.19", "sha256:aa", null, null);
    defer c.deinit(gpa);
    try state_mod.transition(testing.io, gpa, root, c.id[0..], .{ .status = .running, .pid = 12345 });

    var stub: StubState = .{ .initial = .alive, .after = .alive };
    var opts = fast_opts;
    opts.force = true;

    try testing.expectError(
        TeardownError.KillTimeout,
        teardown(testing.io, gpa, root, c.id[0..], opts, makeDeps(&stub)),
    );
    try testing.expectEqual(@as(u32, 1), stub.kill_calls);
}

test "teardown: missing state.json is an idempotent no-op" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    try root.createDirPath(testing.io, state_mod.containers_subpath);

    var stub: StubState = .{};
    try teardown(testing.io, gpa, root, "abcdef123456", fast_opts, makeDeps(&stub));
    try testing.expectEqual(@as(u32, 0), stub.kill_calls);
}

test "teardown: partial prior cleanup (containers/<id> already gone) succeeds" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try seedExited(gpa, root, null);
    defer c.deinit(gpa);

    var rm_buf: [128]u8 = undefined;
    const cont_path = try std.fmt.bufPrint(&rm_buf, "{s}/{s}", .{ state_mod.containers_subpath, c.id[0..] });
    try root.deleteTree(testing.io, cont_path);

    var stub: StubState = .{};
    try teardown(testing.io, gpa, root, c.id[0..], fast_opts, makeDeps(&stub));

    var bun_buf: [128]u8 = undefined;
    const bun_path = try std.fmt.bufPrint(&bun_buf, "{s}/{s}", .{ state_mod.bundles_subpath, c.id[0..] });
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, bun_path, .{}));
}
