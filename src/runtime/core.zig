//! Foreground container run loop with signal forwarding.
//!
//! Wraps `libcrun.runSync` and forwards SIGINT/SIGTERM/SIGQUIT/SIGHUP
//! to the container while it runs, restoring the prior handlers on
//! return. When `req.tty` is set, a `Pty` instance opens an AF_UNIX
//! console socket libcrun connects to, receives the master pty fd via
//! `SCM_RIGHTS`, and proxies rind's stdin↔master in a worker thread.
//! Otherwise stdio is inherited verbatim — no proxying.
//!
//! Scope:
//!   - One synchronous foreground call; `-d` / detached supervision
//!     is not yet implemented.
//!   - No state-file lifecycle writes.
//!
//! Signal-handler discipline:
//!   - libcrun's container_kill API takes the container id via a
//!     `libcrun_context_t`; there is no user-data pointer. We therefore
//!     keep a single static slot pointing at a heap-allocated `State`,
//!     accessed atomically (`sig_atomic_t`-equivalent `usize`).
//!   - The handler builds a stack-local `libcrun_context_t` from
//!     pre-NUL-terminated z-strings on the `State`, then calls the raw
//!     `libcrun_container_kill` directly. It does not go through
//!     `libcrun.kill`: that wrapper allocates via `dupeZ` on every call,
//!     which is unsafe inside an async-signal context.
//!   - Install / uninstall are serialized by a single atomic `cmpxchg`
//!     on the slot itself: a winning install transitions the slot from
//!     0 to its `*State`, blocking concurrent runs. The handler reads
//!     the slot lock-free.
//!   - `runForeground` must be called from a single thread for the
//!     duration of the call. Concurrent callers from different threads
//!     receive `error.AlreadyRunning`.
//!
//! Why a separate `@cImport` here: `libcrun.zig` is the canonical wrapper
//! over libcrun's C API. We reluctantly mirror its `@cImport` block for
//! the in-handler raw kill call to avoid making `libcrun.zig` export an
//! alloc-free kill helper that no other call site needs.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const libcrun = @import("libcrun.zig");
const Pty = @import("Pty.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("container.h");
    @cInclude("error.h");
});

/// Decoded outcome of `runForeground`. Re-export of `libcrun.ExitStatus`
/// so callers can avoid importing `libcrun` directly.
pub const ExitStatus = libcrun.ExitStatus;

/// Closed error set returned by `runForeground`. Composes
/// `libcrun.RuntimeError` with `AlreadyRunning`, which fires when a
/// second `runForeground` overlaps a first one in the same process.
pub const RuntimeError = libcrun.RuntimeError || error{AlreadyRunning};

/// Inputs required to drive a single foreground container run.
///
/// All slice fields are caller-owned; `runForeground` keeps internal
/// NUL-terminated copies for the duration of the call.
pub const RunRequest = struct {
    /// Container id (e.g. 12-char short id from `runtime/state.zig`).
    id: []const u8,
    /// Per-container state-root parent — typically `<root>/containers/`.
    /// Mirrors libcrun's `--state-root`.
    state_root: []const u8,
    /// Bundle directory containing `config.json`. Typically
    /// `<root>/bundles/<id>/`.
    bundle: []const u8,
    /// Disable libcrun's cgroup setup. Default `true` so rootless dev
    /// runs work without configuring a delegated user.slice.
    force_no_cgroup: bool = true,
    /// `-t/--tty`. When true, `console_socket_path` must also be set;
    /// `runForeground` opens an AF_UNIX listener at that path, hands
    /// it to libcrun, and proxies stdio through the master pty.
    tty: bool = false,
    /// AF_UNIX path for the pty console socket. Required when `tty`
    /// is true; ignored otherwise.
    console_socket_path: ?[]const u8 = null,
};

/// Runs the bundle at `req.bundle` to completion, forwarding
/// SIGINT/SIGTERM/SIGQUIT/SIGHUP to the container while it runs.
///
/// Returns the decoded exit status. On a libcrun-level failure returns
/// the typed `RuntimeError`; diagnostics for failed runs are internal
/// to the wrapper (no surface yet — state-file plumbing is not yet
/// implemented).
///
/// `io` is currently unused; reserved so the signature stays stable
/// once Io-mediated state transitions land here.
pub fn runForeground(
    io: std.Io,
    gpa: Allocator,
    req: RunRequest,
) RuntimeError!ExitStatus {
    _ = io;

    var container = try libcrun.Container.loadFromFile(gpa, req.bundle);
    defer container.deinit();

    var ctx: libcrun.Context = .{
        .allocator = gpa,
        .id = req.id,
        .state_root = req.state_root,
        .bundle = req.bundle,
        .force_no_cgroup = req.force_no_cgroup,
    };
    defer ctx.deinit();

    var pty_storage: ?Pty = null;
    defer if (pty_storage) |*p| {
        p.restore();
        p.deinit();
    };
    if (req.tty) {
        const path = req.console_socket_path orelse return libcrun.RuntimeError.PtySetupFailed;
        pty_storage = Pty.open(gpa, path) catch return libcrun.RuntimeError.ConsoleSocketFailed;
        const pty_ref = &pty_storage.?;
        pty_ref.enterRawMode() catch return libcrun.RuntimeError.PtySetupFailed;
        pty_ref.start() catch return libcrun.RuntimeError.PtySetupFailed;
        ctx.console_socket = path;
    }

    try Forwarder.install(gpa, &ctx);
    defer Forwarder.uninstall(gpa);

    const status = libcrun.runSync(&ctx, container, .{}) catch |err| {
        if (ctx.last_error) |le| {
            std.log.err("libcrun: {s} (status={d})", .{ le.message, le.errno });
        }
        return err;
    };
    if (pty_storage) |*p| {
        p.join();
        if (p.recvFailed()) return libcrun.RuntimeError.PtySetupFailed;
    }
    return status;
}

/// Lookup table mapping each forwarded signal to the libcrun-accepted
/// symbolic name. Order is fixed: handlers are saved/restored by index.
const SignalEntry = struct {
    sig: std.posix.SIG,
    name: [:0]const u8,
};

const forwarded: [4]SignalEntry = .{
    .{ .sig = .INT, .name = "SIGINT" },
    .{ .sig = .TERM, .name = "SIGTERM" },
    .{ .sig = .QUIT, .name = "SIGQUIT" },
    .{ .sig = .HUP, .name = "SIGHUP" },
};

fn signalNameZ(sig: std.posix.SIG) ?[:0]const u8 {
    for (forwarded) |entry| {
        if (entry.sig == sig) return entry.name;
    }
    return null;
}

/// File-private singleton holding the cross-handler state.
const Forwarder = struct {
    /// Bitcast `*State` (or 0 when no run is active). Doubles as the
    /// install gate: `cmpxchgStrong(0, ptr, ...)` succeeds for at most
    /// one caller, the rest see `error.AlreadyRunning`.
    var slot: std.atomic.Value(usize) = .init(0);
    /// Active-handler counter. Incremented on handler entry, decremented
    /// on exit. `uninstall` spin-waits until this drops to zero before
    /// freeing `State`, defending against the handler firing on a
    /// different thread mid-restore.
    var in_handler: std.atomic.Value(u32) = .init(0);
    var saved: [forwarded.len]std.posix.Sigaction = undefined;

    /// Pre-built data the signal handler needs. NUL-terminated string
    /// fields are owned by the heap allocator passed to `install` and
    /// freed by `uninstall`.
    const State = struct {
        id_z: [:0]u8,
        state_root_z: [:0]u8,
        bundle_z: [:0]u8,
        force_no_cgroup: bool,
        preserve_fds: c_int,
        detach: bool,

        fn deinit(self: *State, gpa: Allocator) void {
            gpa.free(self.id_z);
            gpa.free(self.state_root_z);
            gpa.free(self.bundle_z);
        }
    };

    fn install(gpa: Allocator, ctx: *const libcrun.Context) (Allocator.Error || error{AlreadyRunning})!void {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);

        state.id_z = try gpa.dupeZ(u8, ctx.id);
        errdefer gpa.free(state.id_z);

        state.state_root_z = try gpa.dupeZ(u8, ctx.state_root);
        errdefer gpa.free(state.state_root_z);

        state.bundle_z = try gpa.dupeZ(u8, ctx.bundle);
        errdefer gpa.free(state.bundle_z);

        state.force_no_cgroup = ctx.force_no_cgroup;
        state.preserve_fds = ctx.preserve_fds;
        state.detach = ctx.detach;

        // Atomic install gate: at most one caller wins the cmpxchg.
        // Publish State before registering handlers so any handler that
        // fires after sigaction below sees a valid pointer. On failure
        // the errdefers above unwind state + duped strings.
        if (slot.cmpxchgStrong(0, @intFromPtr(state), .acq_rel, .acquire) != null) {
            return error.AlreadyRunning;
        }

        const new_act: std.posix.Sigaction = .{
            .handler = .{ .handler = &handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        for (forwarded, 0..) |entry, i| {
            std.posix.sigaction(entry.sig, &new_act, &saved[i]);
        }
    }

    fn uninstall(gpa: Allocator) void {
        // Restore prior handlers first: after this returns the kernel
        // will no longer dispatch to our handler. New deliveries take
        // the saved disposition.
        var i: usize = forwarded.len;
        while (i > 0) {
            i -= 1;
            std.posix.sigaction(forwarded[i].sig, &saved[i], null);
        }

        // Wait for any in-flight handler invocation to finish before
        // freeing State. The window is tiny (handler does one syscall
        // pair) and `in_handler` is bounded by the number of signals
        // already queued at restore time.
        while (in_handler.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }

        const raw = slot.swap(0, .acq_rel);
        if (raw == 0) return;
        const state: *State = @ptrFromInt(raw);
        state.deinit(gpa);
        gpa.destroy(state);
    }

    /// SIGINT/SIGTERM/SIGQUIT/SIGHUP entry point. Async-signal-safe:
    ///   - No allocation (z-strings pre-built at install time).
    ///   - No locking (slot is atomic).
    ///   - Restores stdin termios via `Pty.restoreAsyncSignalSafe` so a
    ///     hung libcrun call never strands the user's terminal in raw
    ///     mode. The call is idempotent and a no-op when no pty is
    ///     active.
    ///   - One libcrun call (`libcrun_container_kill`); errors silenced
    ///     because handlers can't propagate.
    fn handler(sig: std.posix.SIG) callconv(.c) void {
        _ = in_handler.fetchAdd(1, .acq_rel);
        defer _ = in_handler.fetchSub(1, .acq_rel);

        Pty.restoreAsyncSignalSafe();

        const raw = slot.load(.acquire);
        if (raw == 0) return;
        const state: *const State = @ptrFromInt(raw);

        const name = signalNameZ(sig) orelse return;

        var lc_ctx: c.libcrun_context_t = std.mem.zeroes(c.libcrun_context_t);
        lc_ctx.id = state.id_z.ptr;
        lc_ctx.state_root = state.state_root_z.ptr;
        lc_ctx.bundle = state.bundle_z.ptr;
        lc_ctx.detach = state.detach;
        lc_ctx.preserve_fds = state.preserve_fds;
        lc_ctx.force_no_cgroup = state.force_no_cgroup;
        lc_ctx.fifo_exec_wait_fd = -1;

        var err: c.libcrun_error_t = null;
        _ = c.libcrun_container_kill(&lc_ctx, state.id_z.ptr, name.ptr, &err);
        if (err != null) _ = c.libcrun_error_release(&err);
    }
};

const testing = std.testing;

test "signalNameZ: forwarded signals map to symbolic names" {
    try testing.expectEqualStrings("SIGINT", signalNameZ(.INT).?);
    try testing.expectEqualStrings("SIGTERM", signalNameZ(.TERM).?);
    try testing.expectEqualStrings("SIGQUIT", signalNameZ(.QUIT).?);
    try testing.expectEqualStrings("SIGHUP", signalNameZ(.HUP).?);
}

test "signalNameZ: non-forwarded signal returns null" {
    try testing.expectEqual(@as(?[:0]const u8, null), signalNameZ(.USR1));
    try testing.expectEqual(@as(?[:0]const u8, null), signalNameZ(.PIPE));
}

test "Forwarder.install: stores non-zero slot then uninstall clears it" {
    const ctx: libcrun.Context = .{
        .allocator = testing.allocator,
        .id = "abcdef012345",
        .state_root = "/tmp/rind-state",
        .bundle = "/tmp/rind-bundle",
    };

    try testing.expectEqual(@as(usize, 0), Forwarder.slot.load(.acquire));

    try Forwarder.install(testing.allocator, &ctx);
    try testing.expect(Forwarder.slot.load(.acquire) != 0);

    Forwarder.uninstall(testing.allocator);
    try testing.expectEqual(@as(usize, 0), Forwarder.slot.load(.acquire));
}

test "Forwarder.install: double install returns AlreadyRunning" {
    const ctx: libcrun.Context = .{
        .allocator = testing.allocator,
        .id = "abcdef012345",
        .state_root = "/tmp/rind-state",
        .bundle = "/tmp/rind-bundle",
    };

    try Forwarder.install(testing.allocator, &ctx);
    defer Forwarder.uninstall(testing.allocator);

    try testing.expectError(error.AlreadyRunning, Forwarder.install(testing.allocator, &ctx));
}

test "Forwarder: prior SIGINT disposition is restored after uninstall" {
    // Snapshot the SIGINT disposition before our install; assert install
    // changes it to our handler; assert uninstall restores it to the
    // original. We never raise the signal.
    var pre: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &pre);

    const ctx: libcrun.Context = .{
        .allocator = testing.allocator,
        .id = "abcdef012345",
        .state_root = "/tmp/rind-state",
        .bundle = "/tmp/rind-bundle",
    };

    try Forwarder.install(testing.allocator, &ctx);

    var during: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &during);
    try testing.expect(during.handler.handler != pre.handler.handler);

    Forwarder.uninstall(testing.allocator);

    var post: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &post);
    try testing.expectEqual(pre.handler.handler, post.handler.handler);
}

test "runForeground: missing bundle returns BundleNotFound" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const abs = try std.fs.path.join(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "no-such-bundle" });
    defer testing.allocator.free(abs);

    const result = runForeground(testing.io, testing.allocator, .{
        .id = "abcdef012345",
        .state_root = abs,
        .bundle = abs,
    });
    try testing.expectError(libcrun.RuntimeError.BundleNotFound, result);
}
