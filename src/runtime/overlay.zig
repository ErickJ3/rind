//! Overlayfs mount/unmount for rind container rootfs.
//!
//! `mount` lays the OCI image's extracted layers (oldest-first) as
//! `lowerdir`s under a single overlay mount whose upper/work/merged
//! trees live under `<container_dir>/{upper,work,merged}`. The bundle
//! composer takes `MountedOverlay.merged_path` and writes it into
//! `config.json` as `rootfs.path`; the run orchestrator closes the
//! lifecycle by calling `unmount` after libcrun returns.
//!
//! Privilege model
//! - Root (`geteuid() == 0`): mount in the existing namespaces directly.
//! - Rootless (`geteuid() != 0`): the calling process forks a helper child
//!   that `unshare(CLONE_NEWUSER|CLONE_NEWNS)`s itself, the parent then
//!   spawns the suid `newuidmap`/`newgidmap` helpers (shadow-utils) to
//!   write the full `/etc/sub{u,g}id` range into the helper's namespaces,
//!   the helper performs the mount, and the parent `setns`'s into the
//!   helper's user + mount namespaces before SIGTERM-reaping the helper.
//!   The mount NS survives because the parent is now its only inhabitant.
//!
//! Kernel floor
//! Rootless overlayfs needs Linux ≥ 5.11. Older kernels surface
//! `OverlayError.UnsupportedKernel` from the proc-osrelease check before
//! any namespace work happens. Privileged callers skip the floor check;
//! kernel rootless-overlay support is irrelevant when you already have
//! `CAP_SYS_ADMIN` in the init userns.
//!
//! Memory discipline
//! - The options string and absolute paths are heap-allocated on `gpa`
//!   *before* the fork so the child sees them via copy-on-write and never
//!   touches `gpa` itself (post-fork allocator state is unsafe).
//! - `MountedOverlay` owns three slices freed by `deinit`.
//! - Child path uses raw `linux.read`/`linux.write` for sync messaging;
//!   any failure inside the child terminates with `exit_group` so the
//!   parent's `waitpid` reaps a clean status.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;

const subid_mod = @import("subid.zig");
/// Re-export so `runtime/bundle.zig` and the overlay code path agree on
/// the same type without each importing `subid.zig` separately.
pub const SubidRange = subid_mod.Range;

/// Maximum length of the overlay options string the kernel will accept
/// in a single `mount(2)` call. The kernel page-bounds the `data`
/// argument; 4096 is the conservative documented limit and the value
/// `man overlay` cites. With deep image trees (Debian-derived images
/// can carry 30+ layers) we may approach it; the typed
/// `LowerdirsTooLong` makes the breakage actionable.
pub const max_options_bytes: usize = 4096;

/// Inter-process sync messages exchanged on the parent/child socketpair
/// during the rootless mount dance. Fixed 8-byte frames keep the wire
/// format trivial and child-safe (no allocator, no formatter).
const Frame = packed struct(u64) {
    tag: u32,
    /// Errno carried alongside `err` frames; zero otherwise.
    payload: u32,

    const tag_ready: u32 = std.mem.readInt(u32, "RDY\x00", .little);
    const tag_go: u32 = std.mem.readInt(u32, "GO\x00\x00", .little);
    const tag_ok: u32 = std.mem.readInt(u32, "OK\x00\x00", .little);
    const tag_err: u32 = std.mem.readInt(u32, "ERR\x00", .little);
};

/// Closed semantic error set covering every failure path through
/// `mount`/`unmount`. Callers should propagate or re-classify these;
/// the runtime orchestrator maps them to user-facing diagnostics.
pub const OverlayError = error{
    /// Linux < 5.11 detected and the caller is rootless. Native
    /// overlayfs in an unprivileged user namespace was added in 5.11;
    /// older kernels can't satisfy this contract without fuse-overlayfs
    /// (which rind explicitly does not depend on).
    UnsupportedKernel,
    /// Generated options string would exceed `max_options_bytes`. Use a
    /// flatter image or compose the rootfs out-of-band.
    LowerdirsTooLong,
    /// `mount(2)` returned an errno that doesn't classify into any of
    /// the more specific variants here. The numeric errno is logged by
    /// the rootless child via the `err` frame; root-path failures
    /// surface the errno through stderr.
    OverlayMountFailed,
    /// `umount2` reported `EBUSY` on both attempts (immediate +
    /// `MNT_DETACH` after a 50ms sleep).
    OverlayBusy,
    /// `unshare(2)` failed inside the rootless helper child.
    UnshareFailed,
    /// `fork(2)` failed.
    ForkFailed,
    /// `socketpair(2)` failed setting up the parent/child sync channel.
    SocketpairFailed,
    /// Parent process could not `setns(2)` into the helper's user or
    /// mount namespace (typically `EPERM` if the helper exited early).
    SetnsFailed,
    /// `newuidmap` / `newgidmap` not on `PATH` (or unreadable). On most
    /// distros these ship with the `shadow-utils` / `uidmap` package
    /// and need to be suid root.
    NewuidmapMissing,
    /// `newuidmap` / `newgidmap` exited non-zero. Common causes:
    /// suid bit missing, `/etc/sub{u,g}id` range smaller than what we
    /// asked to map, or a mismatched username argument.
    NewuidmapFailed,
    /// Sync read/write between parent and helper child failed (the
    /// socketpair was closed unexpectedly, child died, etc.).
    ChildSyncFailed,
} || subid_mod.SubidError;

/// Live overlay handle returned by `mount`. The mount is held in the
/// process's mount namespace (which, in the rootless flow, is a fresh
/// namespace this process now belongs to). `merged_path` is the kernel
/// view of the mount; the bundle composer hands it to libcrun as
/// `rootfs.path`.
pub const MountedOverlay = struct {
    allocator: Allocator,
    /// NUL-terminated absolute path to the merged tree. Freed by
    /// `deinit`.
    merged_path: [:0]u8,
    /// Absolute path to the upper tree (writable layer). Freed by
    /// `deinit`. Useful for diagnostic + the cleanup path which
    /// recursively deletes upper to reclaim disk space.
    upper_path: []u8,
    /// Absolute path to the workdir. Freed by `deinit`.
    work_path: []u8,
    /// `true` when `mount` joined a fresh user+mount namespace as part
    /// of the rootless flow. Bundle composer keys mapping shape off
    /// this — joined_userns means we view the host id space through
    /// `newuidmap`'s mapping, so OCI `linux.uidMappings.hostID` values
    /// are joined-userns ids (0 + 1..1+sub_uid.count), not the
    /// original host ids.
    joined_userns: bool,
    /// Subuid range from `/etc/subuid` matched against the calling
    /// user, captured before the namespace dance. `null` on the
    /// privileged path. Bundle uses `.count` to emit a second
    /// `linux.uidMappings` entry whose `hostID` is `1` (the offset
    /// inside the joined userns where `newuidmap` mapped it).
    host_sub_uid: ?subid_mod.Range,
    /// Subgid range from `/etc/subgid`. Same conventions as
    /// `host_sub_uid`; `null` on the privileged path.
    host_sub_gid: ?subid_mod.Range,

    /// Frees the owned path slices. Safe to call exactly once.
    pub fn deinit(self: *MountedOverlay) void {
        self.allocator.free(self.merged_path);
        self.allocator.free(self.upper_path);
        self.allocator.free(self.work_path);
        self.* = undefined;
    }
};

/// Mount overlayfs combining `lowerdirs` (oldest-first OCI order) with
/// `<container_dir>/{upper,work}` onto `<container_dir>/merged`.
///
/// `container_dir` and every entry in `lowerdirs` must be absolute
/// paths. The three subdirs are created idempotently. On rootless
/// invocations the calling process transitions into a fresh
/// user+mount namespace; subsequent code in the same process sees the
/// mount and inherits the new namespaces.
pub fn mount(
    io: Io,
    gpa: Allocator,
    container_dir: []const u8,
    lowerdirs: []const []const u8,
) OverlayError!MountedOverlay {
    const euid = linux.geteuid();
    if (euid != 0 and !try kernelSupportsRootlessOverlay(io, gpa)) {
        return OverlayError.UnsupportedKernel;
    }

    try ensureSubdirs(io, container_dir);

    const merged_path = try joinAbsZ(gpa, container_dir, "merged");
    errdefer gpa.free(merged_path);
    const upper_path = try joinAbs(gpa, container_dir, "upper");
    errdefer gpa.free(upper_path);
    const work_path = try joinAbs(gpa, container_dir, "work");
    errdefer gpa.free(work_path);

    const opts = try buildOptions(gpa, lowerdirs, upper_path, work_path);
    defer gpa.free(opts);

    if (euid == 0) {
        try mountPrivileged(merged_path, opts);
        return .{
            .allocator = gpa,
            .merged_path = merged_path,
            .upper_path = upper_path,
            .work_path = work_path,
            .joined_userns = false,
            .host_sub_uid = null,
            .host_sub_gid = null,
        };
    }

    const captured = try mountRootless(gpa, io, merged_path, opts);
    return .{
        .allocator = gpa,
        .merged_path = merged_path,
        .upper_path = upper_path,
        .work_path = work_path,
        .joined_userns = true,
        .host_sub_uid = captured.sub_uid,
        .host_sub_gid = captured.sub_gid,
    };
}

/// Unmount the overlay. Tries `umount2(0)` first; on `EBUSY` sleeps 50ms
/// and retries with `MNT_DETACH`. Frees `mounted` on success; the struct
/// is poisoned on return regardless of success path.
///
/// Recursive cleanup of `upper`/`work`/`merged` is the caller's job
/// (run orchestrator's cleanup path) — keeping that here would
/// conflate concerns when `--rm` is off.
pub fn unmount(io: Io, mounted: *MountedOverlay) OverlayError!void {
    const rc1 = linux.umount2(mounted.merged_path.ptr, 0);
    switch (linux.errno(rc1)) {
        .SUCCESS => {
            mounted.deinit();
            return;
        },
        .BUSY => {
            Io.sleep(io, Io.Duration.fromMilliseconds(50), .awake) catch {};
            const rc2 = linux.umount2(mounted.merged_path.ptr, linux.MNT.DETACH);
            switch (linux.errno(rc2)) {
                .SUCCESS => {
                    mounted.deinit();
                    return;
                },
                else => return OverlayError.OverlayBusy,
            }
        },
        else => return OverlayError.OverlayBusy,
    }
}

fn ensureSubdirs(io: Io, container_dir: []const u8) OverlayError!void {
    var dir = Io.Dir.openDirAbsolute(io, container_dir, .{}) catch
        return OverlayError.OverlayMountFailed;
    defer dir.close(io);

    inline for (&[_][]const u8{ "upper", "work", "merged" }) |sub| {
        dir.createDir(io, sub, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return OverlayError.OverlayMountFailed,
        };
    }
}

fn joinAbs(gpa: Allocator, base: []const u8, sub: []const u8) OverlayError![]u8 {
    return std.fs.path.join(gpa, &.{ base, sub }) catch return OverlayError.OutOfMemory;
}

fn joinAbsZ(gpa: Allocator, base: []const u8, sub: []const u8) OverlayError![:0]u8 {
    return std.fs.path.joinZ(gpa, &.{ base, sub }) catch return OverlayError.OutOfMemory;
}

/// Build the overlay options string `lowerdir=A:B:C,upperdir=U,workdir=W\x00`.
/// Length-checked against `max_options_bytes`. Caller frees.
fn buildOptions(
    gpa: Allocator,
    lowerdirs: []const []const u8,
    upper_path: []const u8,
    work_path: []const u8,
) OverlayError![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    buf.appendSlice(gpa, "lowerdir=") catch return OverlayError.OutOfMemory;
    for (lowerdirs, 0..) |dir, i| {
        if (i != 0) buf.append(gpa, ':') catch return OverlayError.OutOfMemory;
        buf.appendSlice(gpa, dir) catch return OverlayError.OutOfMemory;
    }
    buf.appendSlice(gpa, ",upperdir=") catch return OverlayError.OutOfMemory;
    buf.appendSlice(gpa, upper_path) catch return OverlayError.OutOfMemory;
    buf.appendSlice(gpa, ",workdir=") catch return OverlayError.OutOfMemory;
    buf.appendSlice(gpa, work_path) catch return OverlayError.OutOfMemory;

    if (buf.items.len + 1 > max_options_bytes) return OverlayError.LowerdirsTooLong;

    return buf.toOwnedSliceSentinel(gpa, 0) catch return OverlayError.OutOfMemory;
}

fn mountPrivileged(merged_path: [:0]const u8, opts: [:0]const u8) OverlayError!void {
    const fstype: [:0]const u8 = "overlay";
    const rc = linux.mount(fstype.ptr, merged_path.ptr, fstype.ptr, 0, @intFromPtr(opts.ptr));
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .NOSYS, .NODEV => return OverlayError.UnsupportedKernel,
        else => return OverlayError.OverlayMountFailed,
    }
}

fn mountRootless(
    gpa: Allocator,
    io: Io,
    merged_path: [:0]const u8,
    opts: [:0]const u8,
) OverlayError!struct { sub_uid: SubidRange, sub_gid: SubidRange } {
    // Resolve the calling user's name and subuid/subgid ranges before
    // forking. Failure modes here are pure user-config errors.
    const euid = linux.geteuid();
    const egid = linux.getegid();

    const username = try lookupUsernameAlloc(io, gpa, "/etc/passwd", euid);
    defer gpa.free(username);

    const sub_uid = try lookupSubidAlloc(io, gpa, "/etc/subuid", username, euid);
    const sub_gid = try lookupSubidAlloc(io, gpa, "/etc/subgid", username, egid);

    var sv: [2]i32 = undefined;
    const sp_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv);
    if (linux.errno(sp_rc) != .SUCCESS) return OverlayError.SocketpairFailed;

    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        else => {
            _ = linux.close(sv[0]);
            _ = linux.close(sv[1]);
            return OverlayError.ForkFailed;
        },
    }

    const child_pid: linux.pid_t = @bitCast(@as(u32, @truncate(fork_rc)));
    if (child_pid == 0) {
        // Inside child. Anything that returns from this branch leaks
        // back into the test runner with a duplicated allocator state;
        // every exit path goes through `linux.exit_group`.
        _ = linux.close(sv[0]);
        childEntry(sv[1], merged_path, opts);
        // childEntry never returns.
        unreachable;
    }

    // Parent path.
    _ = linux.close(sv[1]);
    defer _ = linux.close(sv[0]);

    parentDance(gpa, io, sv[0], child_pid, euid, egid, username, sub_uid, sub_gid) catch |err| {
        // Best-effort cleanup: kill the helper if it's still around.
        _ = linux.kill(child_pid, .TERM);
        var status: u32 = 0;
        _ = linux.waitpid(child_pid, &status, 0);
        return err;
    };

    return .{ .sub_uid = sub_uid, .sub_gid = sub_gid };
}

fn parentDance(
    gpa: Allocator,
    io: Io,
    sock: i32,
    child_pid: linux.pid_t,
    euid: linux.uid_t,
    egid: linux.gid_t,
    username: []const u8,
    sub_uid: SubidRange,
    sub_gid: SubidRange,
) OverlayError!void {
    // Wait for child to confirm it has unshared.
    const ready = try recvFrame(sock);
    switch (ready.tag) {
        Frame.tag_ready => {},
        Frame.tag_err => return OverlayError.UnshareFailed,
        else => return OverlayError.ChildSyncFailed,
    }

    // Hand the child's namespaces over to newuidmap / newgidmap. The
    // helpers consult /etc/sub{u,g}id themselves; we just have to point
    // them at the right pid and the per-uid range we already parsed.
    try runIdMapHelper(gpa, io, "newuidmap", child_pid, 0, euid, 1, sub_uid, username);
    try runIdMapHelper(gpa, io, "newgidmap", child_pid, 0, egid, 1, sub_gid, username);

    // Tell the child the maps are in place.
    try sendFrame(sock, .{ .tag = Frame.tag_go, .payload = 0 });

    // Child performs the mount and reports back.
    const done = try recvFrame(sock);
    switch (done.tag) {
        Frame.tag_ok => {},
        Frame.tag_err => {
            const e: linux.E = @enumFromInt(done.payload);
            return switch (e) {
                .NOSYS, .NODEV => OverlayError.UnsupportedKernel,
                else => OverlayError.OverlayMountFailed,
            };
        },
        else => return OverlayError.ChildSyncFailed,
    }

    // Join the child's namespaces so the mount survives it.
    try setnsFromChild(child_pid);

    // Reap the helper.
    _ = linux.kill(child_pid, .TERM);
    var status: u32 = 0;
    _ = linux.waitpid(child_pid, &status, 0);
}

fn childEntry(sock: i32, merged_path: [:0]const u8, opts: [:0]const u8) noreturn {
    const unshare_flags: usize = linux.CLONE.NEWUSER | linux.CLONE.NEWNS;
    const ush = linux.unshare(unshare_flags);
    if (linux.errno(ush) != .SUCCESS) {
        sendFrameNoFail(sock, .{ .tag = Frame.tag_err, .payload = @intFromEnum(linux.errno(ush)) });
        linux.exit_group(1);
    }

    sendFrameNoFail(sock, .{ .tag = Frame.tag_ready, .payload = 0 });

    const go = recvFrameNoFail(sock);
    if (go.tag != Frame.tag_go) linux.exit_group(2);

    const fstype: [:0]const u8 = "overlay";
    const rc = linux.mount(fstype.ptr, merged_path.ptr, fstype.ptr, 0, @intFromPtr(opts.ptr));
    if (linux.errno(rc) != .SUCCESS) {
        sendFrameNoFail(sock, .{ .tag = Frame.tag_err, .payload = @intFromEnum(linux.errno(rc)) });
        linux.exit_group(3);
    }

    sendFrameNoFail(sock, .{ .tag = Frame.tag_ok, .payload = 0 });

    // Hold the mount namespace alive until the parent has setns'd into
    // it and SIGTERMs us.
    while (true) _ = linux.pause();
}

fn setnsFromChild(child_pid: linux.pid_t) OverlayError!void {
    var path_buf: [64]u8 = undefined;

    const user_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/ns/user", .{child_pid}) catch
        return OverlayError.SetnsFailed;
    const user_fd = openProcNs(user_path) orelse return OverlayError.SetnsFailed;
    defer _ = linux.close(user_fd);
    if (linux.errno(linux.setns(user_fd, linux.CLONE.NEWUSER)) != .SUCCESS)
        return OverlayError.SetnsFailed;

    const mnt_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/ns/mnt", .{child_pid}) catch
        return OverlayError.SetnsFailed;
    const mnt_fd = openProcNs(mnt_path) orelse return OverlayError.SetnsFailed;
    defer _ = linux.close(mnt_fd);
    if (linux.errno(linux.setns(mnt_fd, linux.CLONE.NEWNS)) != .SUCCESS)
        return OverlayError.SetnsFailed;
}

fn openProcNs(path_z: [:0]const u8) ?i32 {
    const O = linux.O{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const rc = linux.openat(linux.AT.FDCWD, path_z.ptr, O, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @as(i32, @bitCast(@as(u32, @truncate(rc)))),
        else => null,
    };
}

// `SubidRange`, `parsePasswd`, `parseSubid`, `lookupUsernameAlloc`, and
// `lookupSubidAlloc` live in `subid.zig` so the bundle composer can
// reuse them when emitting multi-line OCI `linux.uidMappings`. Local
// aliases keep the call sites below short.
const lookupUsernameAlloc = subid_mod.lookupUsernameAlloc;
const lookupSubidAlloc = subid_mod.lookupSubidAlloc;

// Helper-existence pre-flight: cheaper to defer to `std.process.run`,
// which surfaces `error.FileNotFound` from the OS exec when the binary
// isn't on PATH. `runIdMapHelper` reclassifies that into the typed
// `NewuidmapMissing`.

fn sendFrame(fd: i32, frame: Frame) OverlayError!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], frame.tag, .little);
    std.mem.writeInt(u32, bytes[4..8], frame.payload, .little);
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => written += rc,
            .INTR => continue,
            else => return OverlayError.ChildSyncFailed,
        }
    }
}

fn recvFrame(fd: i32) OverlayError!Frame {
    var bytes: [8]u8 = undefined;
    var read_total: usize = 0;
    while (read_total < bytes.len) {
        const rc = linux.read(fd, bytes[read_total..].ptr, bytes.len - read_total);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return OverlayError.ChildSyncFailed;
                read_total += rc;
            },
            .INTR => continue,
            else => return OverlayError.ChildSyncFailed,
        }
    }
    return .{
        .tag = std.mem.readInt(u32, bytes[0..4], .little),
        .payload = std.mem.readInt(u32, bytes[4..8], .little),
    };
}

fn sendFrameNoFail(fd: i32, frame: Frame) void {
    sendFrame(fd, frame) catch {};
}

fn recvFrameNoFail(fd: i32) Frame {
    return recvFrame(fd) catch .{ .tag = 0, .payload = 0 };
}

fn runIdMapHelper(
    gpa: Allocator,
    io: Io,
    helper: []const u8,
    pid: linux.pid_t,
    inside_id: u32,
    outside_id: u32,
    inside_count: u32,
    sub_range: SubidRange,
    username: []const u8,
) OverlayError!void {
    _ = username;

    var pid_buf: [16]u8 = undefined;
    var inside_buf: [16]u8 = undefined;
    var outside_buf: [16]u8 = undefined;
    var inside_count_buf: [16]u8 = undefined;
    var sub_inside_buf: [16]u8 = undefined;
    var sub_start_buf: [16]u8 = undefined;
    var sub_count_buf: [16]u8 = undefined;

    const pid_s = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch unreachable;
    const inside_s = std.fmt.bufPrint(&inside_buf, "{d}", .{inside_id}) catch unreachable;
    const outside_s = std.fmt.bufPrint(&outside_buf, "{d}", .{outside_id}) catch unreachable;
    const inside_count_s = std.fmt.bufPrint(&inside_count_buf, "{d}", .{inside_count}) catch unreachable;
    const sub_inside_s = std.fmt.bufPrint(&sub_inside_buf, "{d}", .{inside_count}) catch unreachable;
    const sub_start_s = std.fmt.bufPrint(&sub_start_buf, "{d}", .{sub_range.start}) catch unreachable;
    const sub_count_s = std.fmt.bufPrint(&sub_count_buf, "{d}", .{sub_range.count}) catch unreachable;

    const argv = [_][]const u8{
        helper,
        pid_s,
        inside_s,
        outside_s,
        inside_count_s,
        sub_inside_s,
        sub_start_s,
        sub_count_s,
    };

    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| switch (err) {
        error.FileNotFound => return OverlayError.NewuidmapMissing,
        else => return OverlayError.NewuidmapFailed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return OverlayError.NewuidmapFailed,
        else => return OverlayError.NewuidmapFailed,
    }
}

fn kernelSupportsRootlessOverlay(io: Io, gpa: Allocator) OverlayError!bool {
    _ = io;
    _ = gpa;
    // `/proc/sys/kernel/osrelease` is a synthetic procfs file: `statx`
    // reports `size=0`, which trips `readFileAlloc`'s size-aware path
    // and yields an empty buffer (Linux 6.x behaviour). `uname(2)`
    // returns the same string straight from the kernel and is the
    // canonical source.
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return OverlayError.UnsupportedKernel;
    const release = std.mem.sliceTo(&uts.release, 0);
    return parseKernelMinAtLeast(release, 5, 11);
}

fn parseKernelMinAtLeast(release: []const u8, want_major: u32, want_minor: u32) bool {
    var it = std.mem.splitAny(u8, release, ".-+_ \t\n");
    const major_s = it.next() orelse return false;
    const minor_s = it.next() orelse return false;
    const major = std.fmt.parseInt(u32, major_s, 10) catch return false;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return false;
    if (major > want_major) return true;
    if (major < want_major) return false;
    return minor >= want_minor;
}

const testing = std.testing;

test "buildOptions: layout matches kernel-expected form" {
    const lows = [_][]const u8{ "/a", "/b", "/c" };
    const opts = try buildOptions(testing.allocator, &lows, "/u", "/w");
    defer testing.allocator.free(opts);
    try testing.expectEqualStrings("lowerdir=/a:/b:/c,upperdir=/u,workdir=/w", opts);
}

test "buildOptions: single lowerdir has no leading colon" {
    const lows = [_][]const u8{"/only"};
    const opts = try buildOptions(testing.allocator, &lows, "/u", "/w");
    defer testing.allocator.free(opts);
    try testing.expectEqualStrings("lowerdir=/only,upperdir=/u,workdir=/w", opts);
}

test "buildOptions: rejects payloads exceeding max_options_bytes" {
    // Build a synthetic list of 128-char lowerdirs so 35+ entries push past 4096.
    var dir_buf: [128]u8 = undefined;
    @memset(&dir_buf, 'x');
    dir_buf[0] = '/';

    var dirs: [40][]const u8 = undefined;
    for (&dirs) |*d| d.* = dir_buf[0..];

    const result = buildOptions(testing.allocator, &dirs, "/u", "/w");
    try testing.expectError(OverlayError.LowerdirsTooLong, result);
}

// Subid + passwd parser tests live in `runtime/subid.zig` alongside
// the parser definitions. Reach them through that module's test block.

test "parseKernelMinAtLeast: 5.11 trims trailing newline" {
    try testing.expect(parseKernelMinAtLeast("5.11.0-generic\n", 5, 11));
    try testing.expect(parseKernelMinAtLeast("6.6.0-rt\n", 5, 11));
    try testing.expect(!parseKernelMinAtLeast("5.10.999-foo\n", 5, 11));
    try testing.expect(!parseKernelMinAtLeast("4.19.0\n", 5, 11));
    try testing.expect(parseKernelMinAtLeast("5.11\n", 5, 11));
}

// Validates the synthetic three-lowerdir flow end-to-end:
//   l1/file_a + l2/file_b + l3/file_c → merged sees all three; writes
//   to merged land in upper; lowerdirs are byte-unchanged; unmount
//   succeeds; merged is empty after.
//
// Skipped when the running environment can't satisfy the rootless
// preconditions (no newuidmap on PATH, no /etc/subuid entry, kernel
// < 5.11, …). The privileged path runs unconditionally when uid == 0.

test "mount: synthetic three lowerdirs round-trips through merged + upper" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Real-mount round-trip is a process-polluting integration test:
    // when the rootless path succeeds, the parent test process
    // `setns`-es into the child's user+mount namespaces and never
    // returns to the original namespaces. Subsequent tests in the
    // same binary inherit this leak — `tmpDir` then can't create
    // `.zig-cache` because the host uid is unmapped in the new
    // userns. Gate behind an explicit opt-in env var; the unit
    // tests for `parseKernelMinAtLeast` and `buildOptions` cover
    // the pure pieces.
    if (std.c.getenv("RIND_OVERLAY_E2E") == null) return error.SkipZigTest;

    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Build an absolute path to the tmp dir (mount needs absolute paths).
    const cwd = try std.process.currentPathAlloc(testing.io, gpa);
    defer gpa.free(cwd);
    const tmp_abs = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(tmp_abs);

    // Lay out three lowerdirs and one container_dir under the tmp.
    inline for (&[_][]const u8{ "l1", "l2", "l3", "c1" }) |sub| {
        try tmp.dir.createDirPath(testing.io, sub);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "l1/file_a", .data = "a-content\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "l2/file_b", .data = "b-content\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "l3/file_c", .data = "c-content\n" });

    const l1 = try std.fs.path.join(gpa, &.{ tmp_abs, "l1" });
    defer gpa.free(l1);
    const l2 = try std.fs.path.join(gpa, &.{ tmp_abs, "l2" });
    defer gpa.free(l2);
    const l3 = try std.fs.path.join(gpa, &.{ tmp_abs, "l3" });
    defer gpa.free(l3);
    const c1 = try std.fs.path.join(gpa, &.{ tmp_abs, "c1" });
    defer gpa.free(c1);

    // Let mount() itself surface env mismatches; classify them as skip
    // signals rather than re-implementing the prereq probes here.
    var mounted = mount(testing.io, gpa, c1, &.{ l1, l2, l3 }) catch |err| switch (err) {
        OverlayError.OverlayMountFailed,
        OverlayError.UnsupportedKernel,
        OverlayError.NewuidmapMissing,
        OverlayError.NewuidmapFailed,
        OverlayError.SubidNotConfigured,
        OverlayError.UserLookupFailed,
        OverlayError.SetnsFailed,
        OverlayError.UnshareFailed,
        => return error.SkipZigTest,
        else => return err,
    };

    // Read-through: lowerdir file visible via merged.
    const merged_a = try std.fs.path.join(gpa, &.{ mounted.merged_path, "file_a" });
    defer gpa.free(merged_a);
    const file_a_bytes = try Io.Dir.cwd().readFileAlloc(testing.io, merged_a, gpa, .limited(64));
    defer gpa.free(file_a_bytes);
    try testing.expectEqualStrings("a-content\n", file_a_bytes);

    // Write-through: new file lands in upper.
    const merged_new = try std.fs.path.join(gpa, &.{ mounted.merged_path, "new_file" });
    defer gpa.free(merged_new);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = merged_new, .data = "hi" });

    const upper_new = try std.fs.path.join(gpa, &.{ mounted.upper_path, "new_file" });
    defer gpa.free(upper_new);
    const upper_bytes = try Io.Dir.cwd().readFileAlloc(testing.io, upper_new, gpa, .limited(64));
    defer gpa.free(upper_bytes);
    try testing.expectEqualStrings("hi", upper_bytes);

    // Lowerdir untouched.
    const lower_new = try std.fs.path.join(gpa, &.{ l1, "new_file" });
    defer gpa.free(lower_new);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, lower_new, .{}));

    try unmount(testing.io, &mounted);
}
