//! Pseudo-terminal subsystem for `rind run -it`.
//!
//! Lifecycle (driven by `runtime/core.zig`):
//!   1. Main thread calls `Pty.open` — binds and listens on the
//!      `console_socket` AF_UNIX path libcrun will connect to.
//!   2. Main thread calls `enterRawMode`, saves stdin's termios and
//!      switches it to a `cfmakeraw`-equivalent state.
//!   3. Main thread calls `start`, then invokes `libcrun.runSync`. The
//!      worker thread spawned by `start` accepts libcrun's connection,
//!      receives the pty master fd via `SCM_RIGHTS`, and runs a
//!      `poll(2)` loop proxying rind's stdin↔master plus a SIGWINCH
//!      self-pipe.
//!   4. When the container exits, the master returns EOF and the worker
//!      thread joins. Main thread calls `restore` (idempotent) and
//!      `deinit`.
//!
//! Termios restore must run on every exit path:
//!   - Clean exit / typed error: `defer pty.restore()` in
//!     `core.runForeground`.
//!   - SIGINT/SIGTERM/SIGQUIT/SIGHUP: the existing signal forwarder in
//!     `runtime/core.zig` calls `restoreAsyncSignalSafe` before
//!     forwarding.
//!   - Fatal signals (SIGSEGV/SIGABRT/SIGFPE/SIGBUS): a one-shot
//!     handler installed by `enterRawMode` calls
//!     `restoreAsyncSignalSafe` and re-raises.
//!
//! The async-signal-safe path reads from a file-static atomic slot
//! (`raw_state`) that mirrors the `Pty` instance's saved termios. The
//! restore is one `tcsetattr` syscall POSIX-listed
//! async-signal-safe, guarded by an idempotency flag so concurrent
//! handler + `defer restore` calls collapse to a single `tcsetattr`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;

const Pty = @This();

/// Closed semantic error set returned by every public method.
pub const Error = error{
    /// `tcgetattr` returned `ENOTTY` — rind's stdin is not a terminal.
    /// `-t/--tty` cannot be honoured. Matches Docker's hard-error.
    NotATerminal,
    /// `tcsetattr`, `pipe2`, or thread spawn failed — anything outside
    /// the console-socket dance that nevertheless makes the pty path
    /// unusable.
    PtySetupFailed,
    /// AF_UNIX listener could not be created, bound, or accepted on,
    /// or `recvmsg` failed to surface a master fd.
    ConsoleSocketFailed,
};

/// Per-instance state. All fds are owned by the `Pty` and closed by
/// `deinit`. Strings (`socket_path_z`) are owned by `gpa`.
gpa: Allocator,
socket_path_z: [:0]u8,
listener_fd: i32 = -1,
master_fd: std.atomic.Value(i32) = .init(-1),
recv_failed: std.atomic.Value(bool) = .init(false),
/// Self-pipe written by the SIGWINCH handler. The proxy loop polls
/// the read end and translates each pending byte into an
/// ioctl(TIOCGWINSZ)/ioctl(TIOCSWINSZ) pair.
sigwinch_pipe: [2]i32 = .{ -1, -1 },
/// Pipe used by the main thread to wake the worker out of `accept`
/// or `poll` when libcrun returns before the container produced any
/// output (e.g. config validation rejected the bundle).
wake_pipe: [2]i32 = .{ -1, -1 },
worker: ?std.Thread = null,
saved_termios: ?posix.termios = null,
/// Snapshot of stdin used during raw-mode entry. Only the saved fd
/// gets restored even if rind's stdin is later swapped out.
saved_stdin_fd: i32 = posix.STDIN_FILENO,
/// Pre-snapshot of host stdin's winsize taken in `enterRawMode`,
/// before libcrun forks the container. Lets the worker push
/// winsize on the master with one syscall instead of two,
/// shrinking the race in which busybox queries `\033[6n` for the
/// terminal width before our SIGWINCH path has armed.
saved_winsize: ?posix.winsize = null,

/// Bind + listen on `console_socket_path`. Path must already have its
/// parent directory in place; it must also fit in `sun_path` (108
/// bytes including the trailing NUL).
pub fn open(gpa: Allocator, console_socket_path: []const u8) Error!Pty {
    var addr: linux.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    if (console_socket_path.len >= addr.path.len) return Error.ConsoleSocketFailed;
    @memcpy(addr.path[0..console_socket_path.len], console_socket_path);

    const path_z = gpa.dupeZ(u8, console_socket_path) catch return Error.PtySetupFailed;
    errdefer gpa.free(path_z);

    // Stale socket from a crashed prior run trips bind with EADDRINUSE.
    // Best-effort unlink — if the path is still missing the bind below
    // surfaces the real error.
    _ = linux.unlink(path_z.ptr);

    const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(sock_rc) != .SUCCESS) return Error.ConsoleSocketFailed;
    const listener: i32 = @intCast(sock_rc);
    errdefer _ = linux.close(listener);

    const addr_len: linux.socklen_t = @intCast(@sizeOf(linux.sockaddr.un));
    if (linux.errno(linux.bind(listener, @ptrCast(&addr), addr_len)) != .SUCCESS) {
        return Error.ConsoleSocketFailed;
    }
    if (linux.errno(linux.listen(listener, 1)) != .SUCCESS) {
        return Error.ConsoleSocketFailed;
    }

    var sigwinch: [2]i32 = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&sigwinch, .{
        .NONBLOCK = true,
        .CLOEXEC = true,
    })) != .SUCCESS) return Error.PtySetupFailed;
    errdefer {
        _ = linux.close(sigwinch[0]);
        _ = linux.close(sigwinch[1]);
    }

    var wake: [2]i32 = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&wake, .{
        .NONBLOCK = true,
        .CLOEXEC = true,
    })) != .SUCCESS) return Error.PtySetupFailed;

    return .{
        .gpa = gpa,
        .socket_path_z = path_z,
        .listener_fd = listener,
        .sigwinch_pipe = sigwinch,
        .wake_pipe = wake,
    };
}

/// Save stdin's termios and switch to a `cfmakeraw`-equivalent
/// configuration. Caller must pair with `restore` (idempotent).
pub fn enterRawMode(self: *Pty) Error!void {
    const fd = self.saved_stdin_fd;
    const saved = posix.tcgetattr(fd) catch |err| switch (err) {
        error.NotATerminal => return Error.NotATerminal,
        else => return Error.PtySetupFailed,
    };
    self.saved_termios = saved;

    var raw = saved;
    // `cfmakeraw` per Linux man page: clear input/output post-processing
    // and line-discipline cooking; force 8-bit chars; one byte minimum
    // read with no inter-character timeout.
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(linux.V.MIN)] = 1;
    raw.cc[@intFromEnum(linux.V.TIME)] = 0;

    posix.tcsetattr(fd, .NOW, raw) catch return Error.PtySetupFailed;

    // Best-effort: capture the host winsize now so the worker can
    // push it onto the master in one syscall on receipt. Failure
    // (e.g. fd is not a tty in tests) leaves the snapshot null and
    // the worker falls back to the live ioctl pair.
    var ws: posix.winsize = undefined;
    if (linux.errno(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws))) == .SUCCESS) {
        self.saved_winsize = ws;
    }

    // Publish the saved state for the async-signal-safe restore path
    // before installing the fatal-signal handler so any signal that
    // fires immediately can find it.
    raw_state.publish(fd, saved);
    installFatalHandler();
}

/// Spawn the worker thread. Caller invokes `libcrun.runSync` after
/// `start` returns; the worker handles accept + recvmsg + proxy.
pub fn start(self: *Pty) Error!void {
    if (self.worker != null) return Error.PtySetupFailed;
    self.worker = std.Thread.spawn(.{}, workerEntry, .{self}) catch
        return Error.PtySetupFailed;
}

/// Wake the worker out of `accept` or `poll` and join. Safe to call
/// multiple times; subsequent calls are no-ops.
pub fn join(self: *Pty) void {
    if (self.worker) |w| {
        // Wake any in-flight `poll` by writing a byte to the wake
        // pipe; close the listener so a blocking `accept` errors out.
        const one: [1]u8 = .{0};
        _ = linux.write(self.wake_pipe[1], &one, 1);
        if (self.listener_fd >= 0) {
            _ = linux.close(self.listener_fd);
            self.listener_fd = -1;
        }
        w.join();
        self.worker = null;
    }
}

/// True if the worker thread reported it could not receive the master
/// fd from libcrun. Read after `join`.
pub fn recvFailed(self: *const Pty) bool {
    return self.recv_failed.load(.acquire);
}

/// Restore stdin's termios. Idempotent; the async-signal-safe variant
/// also defers to the same `raw_state` slot.
pub fn restore(self: *Pty) void {
    if (self.saved_termios) |saved| {
        posix.tcsetattr(self.saved_stdin_fd, .NOW, saved) catch {};
        self.saved_termios = null;
        raw_state.markRestored();
    }
}

/// Variant safe to call from an async signal handler. Looks up the
/// saved termios from `raw_state` and issues the single `tcsetattr`
/// syscall (POSIX-listed async-signal-safe). No-ops if already
/// restored.
pub fn restoreAsyncSignalSafe() void {
    raw_state.restoreOnce();
}

/// Close every fd, free the duped path, and unlink the socket file.
/// Safe even if `start`/`enterRawMode` were never called.
pub fn deinit(self: *Pty) void {
    self.join();
    if (self.listener_fd >= 0) _ = linux.close(self.listener_fd);
    const m = self.master_fd.swap(-1, .acq_rel);
    if (m >= 0) _ = linux.close(m);
    if (self.sigwinch_pipe[0] >= 0) _ = linux.close(self.sigwinch_pipe[0]);
    if (self.sigwinch_pipe[1] >= 0) _ = linux.close(self.sigwinch_pipe[1]);
    if (self.wake_pipe[0] >= 0) _ = linux.close(self.wake_pipe[0]);
    if (self.wake_pipe[1] >= 0) _ = linux.close(self.wake_pipe[1]);
    _ = linux.unlink(self.socket_path_z.ptr);
    self.gpa.free(self.socket_path_z);
    self.* = undefined;
}

/// Worker thread: accept + recvmsg + proxy. Never panics; failures
/// flip `recv_failed` and return.
fn workerEntry(self: *Pty) void {
    const conn_fd = acceptConnection(self) catch {
        self.recv_failed.store(true, .release);
        return;
    };
    defer _ = linux.close(conn_fd);

    const master = recvMasterFd(conn_fd) catch {
        self.recv_failed.store(true, .release);
        return;
    };
    self.master_fd.store(master, .release);

    // Push the initial winsize once so the container's terminal size
    // matches rind's before the first prompt renders. Prefer the
    // pre-snapshot taken in `enterRawMode` (one syscall, narrower
    // race window) and fall back to the live read on hosts where
    // the snapshot was unavailable.
    if (self.saved_winsize) |ws| {
        _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
    } else {
        forwardWinsize(self.saved_stdin_fd, master);
    }

    install_sigwinch_self_pipe.publish(self.sigwinch_pipe[1]);
    installSigwinchHandler();

    proxyLoop(self, master);
}

fn acceptConnection(self: *Pty) !i32 {
    // Use poll so a wake_pipe write can break us out before libcrun
    // ever connects (e.g. libcrun rejected the bundle and returned
    // immediately).
    var fds = [_]posix.pollfd{
        .{ .fd = self.listener_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = self.wake_pipe[0], .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        _ = posix.poll(&fds, -1) catch return error.PollFailed;
        if (fds[1].revents != 0) return error.Cancelled;
        if (fds[0].revents == 0) continue;
        const rc = linux.accept(self.listener_fd, null, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR, .AGAIN => continue,
            else => return error.AcceptFailed,
        }
    }
}

fn recvMasterFd(conn_fd: i32) !i32 {
    var data_buf: [1]u8 = .{0};
    var iov: [1]posix.iovec = .{.{ .base = &data_buf, .len = 1 }};
    var ctrl_buf: [cmsg_space_one_fd]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    @memset(&ctrl_buf, 0);

    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &ctrl_buf,
        .controllen = ctrl_buf.len,
        .flags = 0,
    };
    while (true) {
        const rc = linux.recvmsg(conn_fd, &msg, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.PeerClosed;
                break;
            },
            .INTR => continue,
            else => return error.RecvFailed,
        }
    }

    const cmsg: *linux.cmsghdr = @ptrCast(@alignCast(&ctrl_buf));
    if (cmsg.level != linux.SOL.SOCKET or cmsg.type != linux.SCM.RIGHTS) {
        return error.RecvFailed;
    }
    var fd: i32 = -1;
    const data_offset = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @alignOf(i32));
    @memcpy(std.mem.asBytes(&fd), ctrl_buf[data_offset..][0..@sizeOf(i32)]);
    if (fd < 0) return error.RecvFailed;
    return fd;
}

/// `CMSG_SPACE(sizeof(int))` for one fd. Linux aligns ancillary data
/// on `usize` boundaries; the cmsghdr is followed by the fd payload.
const cmsg_space_one_fd: usize = blk: {
    const data = @sizeOf(i32);
    const aligned_hdr = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @alignOf(usize));
    const aligned = std.mem.alignForward(usize, aligned_hdr + data, @alignOf(usize));
    break :blk aligned;
};

fn proxyLoop(self: *Pty, master: i32) void {
    var stdin_open = true;
    var fds = [_]posix.pollfd{
        .{ .fd = master, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = self.saved_stdin_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = self.sigwinch_pipe[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = self.wake_pipe[0], .events = linux.POLL.IN, .revents = 0 },
    };
    var buf: [4096]u8 = undefined;
    while (true) {
        fds[0].revents = 0;
        fds[1].revents = 0;
        fds[2].revents = 0;
        fds[3].revents = 0;
        if (!stdin_open) fds[1].fd = -1;

        _ = posix.poll(&fds, -1) catch return;

        if (fds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n = readSome(master, &buf) orelse return;
            if (n == 0) return; // master EOF — container exited
            writeAll(posix.STDOUT_FILENO, buf[0..n]);
        }
        if (stdin_open and fds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n = readSome(self.saved_stdin_fd, &buf) orelse return;
            if (n == 0) {
                stdin_open = false;
            } else {
                writeAll(master, buf[0..n]);
            }
        }
        if (fds[2].revents != 0) {
            // Drain the self-pipe; one ioctl pair covers all queued
            // SIGWINCHes since we always read the *current* size.
            var drain: [16]u8 = undefined;
            _ = linux.read(self.sigwinch_pipe[0], &drain, drain.len);
            forwardWinsize(self.saved_stdin_fd, master);
        }
        if (fds[3].revents != 0) return;
    }
}

fn readSome(fd: i32, buf: []u8) ?usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return 0,
            else => return null,
        }
    }
}

fn writeAll(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            else => return,
        }
    }
}

/// Read rind's window size and push it onto the master pty.
fn forwardWinsize(stdin_fd: i32, master_fd: i32) void {
    var ws: posix.winsize = undefined;
    if (linux.errno(linux.ioctl(
        stdin_fd,
        linux.T.IOCGWINSZ,
        @intFromPtr(&ws),
    )) != .SUCCESS) return;
    _ = linux.ioctl(master_fd, linux.T.IOCSWINSZ, @intFromPtr(&ws));
}

const RawState = struct {
    fd: std.atomic.Value(i32) = .init(-1),
    has_saved: std.atomic.Value(bool) = .init(false),
    restored: std.atomic.Value(bool) = .init(true),
    saved: posix.termios = undefined,

    fn publish(self: *RawState, fd: i32, saved: posix.termios) void {
        self.saved = saved;
        self.fd.store(fd, .release);
        self.restored.store(false, .release);
        self.has_saved.store(true, .release);
    }

    fn markRestored(self: *RawState) void {
        self.restored.store(true, .release);
    }

    fn restoreOnce(self: *RawState) void {
        if (!self.has_saved.load(.acquire)) return;
        if (self.restored.swap(true, .acq_rel)) return;
        const fd = self.fd.load(.acquire);
        if (fd < 0) return;
        // tcsetattr is async-signal-safe per POSIX; no allocator,
        // no stdio, no locks.
        _ = std.c.tcsetattr(fd, posix.TCSA.NOW, &self.saved);
    }
};

var raw_state: RawState = .{};

const SelfPipe = struct {
    write_fd: std.atomic.Value(i32) = .init(-1),
    installed: std.atomic.Value(bool) = .init(false),

    fn publish(self: *SelfPipe, write_fd: i32) void {
        self.write_fd.store(write_fd, .release);
    }
};

var install_sigwinch_self_pipe: SelfPipe = .{};

fn sigwinchHandler(_: posix.SIG) callconv(.c) void {
    const fd = install_sigwinch_self_pipe.write_fd.load(.acquire);
    if (fd < 0) return;
    const byte: [1]u8 = .{0};
    _ = linux.write(fd, &byte, 1);
}

fn installSigwinchHandler() void {
    if (install_sigwinch_self_pipe.installed.swap(true, .acq_rel)) return;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = &sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    posix.sigaction(.WINCH, &act, null);
}

const fatal_signals = [_]posix.SIG{ .SEGV, .ABRT, .FPE, .BUS };
var fatal_installed: std.atomic.Value(bool) = .init(false);

fn fatalHandler(sig: posix.SIG) callconv(.c) void {
    raw_state.restoreOnce();
    // Restore the default disposition and re-raise so the kernel's
    // default action (core dump) still happens.
    var dfl: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &dfl, null);
    _ = linux.kill(linux.getpid(), sig);
}

fn installFatalHandler() void {
    if (fatal_installed.swap(true, .acq_rel)) return;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = &fatalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (fatal_signals) |sig| {
        posix.sigaction(sig, &act, null);
    }
}

const testing = std.testing;

test "open: creates listener and unlinks socket on deinit" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(testing.io, gpa);
    defer gpa.free(cwd);
    const sock = try std.fs.path.join(gpa, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "console.sock",
    });
    defer gpa.free(sock);

    var pty = try open(gpa, sock);
    defer pty.deinit();
    try testing.expect(pty.listener_fd >= 0);
}

test "open: rejects path that overflows sun_path" {
    const gpa = testing.allocator;
    const long = "/" ++ ("a" ** 200);
    try testing.expectError(Error.ConsoleSocketFailed, open(gpa, long));
}

test "recvMasterFd: extracts fd sent over a socketpair" {
    var sv: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM,
        0,
        &sv,
    )));
    defer _ = linux.close(sv[0]);
    defer _ = linux.close(sv[1]);

    // Make a junk fd to send: a fresh pipe end is convenient.
    var dummy: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&dummy, .{ .CLOEXEC = true })));
    defer _ = linux.close(dummy[1]);

    // Send dummy[0] via SCM_RIGHTS on sv[1].
    var data: [1]u8 = .{' '};
    var iov_const: [1]posix.iovec_const = .{.{ .base = &data, .len = 1 }};
    var ctrl: [cmsg_space_one_fd]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    @memset(&ctrl, 0);
    const cmsg: *linux.cmsghdr = @ptrCast(@alignCast(&ctrl));
    cmsg.len = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @alignOf(usize)) + @sizeOf(i32);
    cmsg.level = linux.SOL.SOCKET;
    cmsg.type = linux.SCM.RIGHTS;
    const data_off = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @alignOf(i32));
    @memcpy(ctrl[data_off..][0..@sizeOf(i32)], std.mem.asBytes(&dummy[0]));

    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov_const),
        .iovlen = 1,
        .control = &ctrl,
        .controllen = ctrl.len,
        .flags = 0,
    };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sendmsg(sv[1], &msg, 0)));

    const recv = try recvMasterFd(sv[0]);
    defer _ = linux.close(recv);
    try testing.expect(recv >= 0);
    try testing.expect(recv != dummy[0]); // recv is a duped fd in our process

    // The duped fd should refer to the same pipe — write to dummy[1] and
    // read it through `recv` to confirm.
    const probe: [3]u8 = .{ 'h', 'i', 0 };
    try testing.expectEqual(@as(usize, 3), linux.write(dummy[1], &probe, 3));
    var rbuf: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), linux.read(recv, &rbuf, 3));
    try testing.expectEqualSlices(u8, &probe, &rbuf);
}

test "restore: idempotent when never entered raw mode" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(testing.io, gpa);
    defer gpa.free(cwd);
    const sock = try std.fs.path.join(gpa, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "console.sock",
    });
    defer gpa.free(sock);

    var pty = try open(gpa, sock);
    defer pty.deinit();
    pty.restore();
    pty.restore(); // double-call must be a no-op
}

test "enterRawMode: returns NotATerminal when stdin is a pipe" {
    // Use a pipe end as the saved stdin so tcgetattr surfaces ENOTTY
    // without actually messing with the test runner's terminal.
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, gpa);
    defer gpa.free(cwd);
    const sock = try std.fs.path.join(gpa, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "console.sock",
    });
    defer gpa.free(sock);

    var pty = try open(gpa, sock);
    defer pty.deinit();

    var pipe_fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    pty.saved_stdin_fd = pipe_fds[0];
    try testing.expectError(Error.NotATerminal, pty.enterRawMode());
}
