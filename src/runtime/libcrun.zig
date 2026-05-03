//! Typed Zig surface over libcrun's container_run / load / kill / delete.
//! Owns the `libcrun_error_t` release discipline; never leaks.
//!
//! T18 deliverable. Downstream tasks (T22 runtime core, T23 `rind run`
//! orchestrator) consume this module — no other Zig code should `@cImport`
//! libcrun headers directly.
//!
//! Header layout deviation: the spec text in docs/tasks.md references
//! `libcrun/container.h` but vendor reality is `vendor/crun-1.23/src/
//! {container,error}.h`. This wrapper imports the headers under their real
//! names and the build wires the include path. See plan file for details.
//!
//! Memory discipline:
//!   - Every libcrun call that may set `libcrun_error_t` runs through `mapErr`
//!     or `classifyAndRelease`, which call `libcrun_error_release` exactly
//!     once.
//!   - C strings handed to libcrun_context_t are owned by the wrapper and
//!     freed before the calling function returns regardless of outcome.
//!   - `Container.deinit` calls `libcrun_container_free`; `Context.deinit`
//!     frees the optional last-error message.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("container.h");
    @cInclude("error.h");
});

/// Closed error set covering every failure path through the wrapper.
pub const RuntimeError = error{
    /// `EINVAL` from libcrun — config.json malformed or option-validation rejected.
    InvalidConfig,
    /// `ENOENT` — bundle directory or config.json missing.
    BundleNotFound,
    /// `EACCES` / `EPERM` — typically rootless without userns or cgroup denial.
    PermissionDenied,
    /// `EEXIST` from `libcrun_status_check_directories` — id already running.
    AlreadyExists,
    /// Anything else libcrun reports — message stashed on `Context.last_error`.
    LibcrunFailure,
    /// Allocator failure while building C strings or duping diagnostics.
    OutOfMemory,
};

/// Decoded outcome of a synchronous container run. libcrun reports its result
/// as a single `int` per `get_process_exit_status` (utils.h) — `WEXITSTATUS`
/// for normal exits and `128 + WTERMSIG` for signal kills. The wrapper splits
/// those back into a typed union so callers don't have to undo the encoding.
pub const ExitStatus = union(enum) {
    /// Process exited normally. Carries `WEXITSTATUS(status)` (0..255).
    exit: u8,
    /// Process killed by signal. Carries the raw signal number (e.g. 9 for SIGKILL).
    signal: u8,
};

/// Maps to libcrun's `LIBCRUN_RUN_OPTIONS_*` enum on `libcrun_container_run`.
pub const CreateOptions = struct {
    /// `LIBCRUN_RUN_OPTIONS_PREFORK`. Default false (foreground sync run).
    prefork: bool = false,
    /// `LIBCRUN_RUN_OPTIONS_KEEP`. Default false (cleanup state on exit).
    keep: bool = false,

    fn toBits(self: CreateOptions) c_uint {
        var bits: c_uint = 0;
        if (self.prefork) bits |= @as(c_uint, c.LIBCRUN_RUN_OPTIONS_PREFORK);
        if (self.keep) bits |= @as(c_uint, c.LIBCRUN_RUN_OPTIONS_KEEP);
        return bits;
    }
};

/// Diagnostics from the most recent failed libcrun call on a `Context`.
/// `message` is owned by `Context.allocator`.
pub const LastError = struct {
    /// errno value libcrun reported (positive — libcrun stores `-errno` then
    /// negates on the way out).
    errno: c_int,
    /// Human-readable message duped from `libcrun_error_s.msg`. Empty if
    /// libcrun didn't supply one.
    message: []const u8,
};

/// Call-site state passed to `runSync`/`kill`/`delete`. Mirrors the subset
/// of `libcrun_context_t` rind populates. All string fields are caller-owned;
/// the wrapper makes NUL-terminated copies for each call.
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// Container id (e.g. 12-char hex from T19's state.zig).
    id: []const u8,
    /// Directory rooting per-container state (e.g. ~/.rind/containers).
    state_root: []const u8,
    /// Bundle directory containing config.json + rootfs/.
    bundle: []const u8,
    /// Optional console socket path for `--console-socket` (T25).
    console_socket: ?[]const u8 = null,
    /// Detached (background) run; foreground sync is the default for T18.
    detach: bool = false,
    /// File descriptors to keep open in the container; default 0.
    preserve_fds: c_int = 0,
    /// Optional sd_notify socket path.
    notify_socket: ?[]const u8 = null,
    /// Disables cgroup setup. Useful for rootless test bundles.
    force_no_cgroup: bool = false,
    /// Most-recent libcrun failure diagnostic. Cleared on success of any
    /// wrapper call. `message` owned by `allocator`.
    last_error: ?LastError = null,

    /// Frees `last_error.message` if any. The string fields above stay
    /// caller-owned.
    pub fn deinit(self: *Context) void {
        if (self.last_error) |le| self.allocator.free(le.message);
        self.last_error = null;
    }
};

/// Opaque handle around `libcrun_container_t`. Use `loadFromFile` to obtain.
pub const Container = struct {
    raw: *c.libcrun_container_t,

    /// Reads `<bundle_dir>/config.json` via `libcrun_container_load_from_file`.
    ///
    /// libcrun's load_from_file always reports failures with `status=0`,
    /// embedding the cause (ENOENT vs yajl parse) in the message string. The
    /// wrapper pre-opens the file to surface typed `BundleNotFound` /
    /// `PermissionDenied`; anything that survives the open and still fails
    /// inside libcrun is treated as `InvalidConfig` (parse-level). The
    /// libcrun_error_t is always released exactly once on failure.
    pub fn loadFromFile(
        allocator: std.mem.Allocator,
        bundle_dir: []const u8,
    ) RuntimeError!Container {
        const config_path = std.fs.path.joinZ(allocator, &.{ bundle_dir, "config.json" }) catch
            return error.OutOfMemory;
        defer allocator.free(config_path);

        const fd = std.posix.openatZ(
            std.posix.AT.FDCWD,
            config_path.ptr,
            .{ .ACCMODE = .RDONLY },
            0,
        ) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.BundleNotFound,
            error.AccessDenied, error.PermissionDenied => return error.PermissionDenied,
            error.IsDir => return error.InvalidConfig,
            else => return error.LibcrunFailure,
        };
        _ = std.os.linux.close(fd);

        var err: c.libcrun_error_t = null;
        const handle = c.libcrun_container_load_from_file(config_path.ptr, &err);
        if (handle == null) {
            // File opened cleanly above; any failure here is parse-level.
            if (err != null) _ = c.libcrun_error_release(&err);
            return error.InvalidConfig;
        }
        return Container{ .raw = handle.? };
    }

    /// Frees the underlying `libcrun_container_t`. Single-use: poisons `raw`
    /// (`undefined` is filled with 0xaa in debug builds) so a double-deinit
    /// traps loudly.
    pub fn deinit(self: *Container) void {
        c.libcrun_container_free(self.raw);
        self.raw = undefined;
    }
};

/// Runs `container` synchronously to completion. Returns the decoded exit
/// status; on a libcrun-level failure, returns a typed RuntimeError and
/// stashes diagnostics on `ctx.last_error`.
pub fn runSync(
    ctx: *Context,
    container: Container,
    opts: CreateOptions,
) RuntimeError!ExitStatus {
    var lc_ctx: c.libcrun_context_t = std.mem.zeroes(c.libcrun_context_t);
    var owned = try CContextStrings.build(ctx, &lc_ctx);
    defer owned.deinit(ctx.allocator);
    lc_ctx.detach = ctx.detach;
    lc_ctx.preserve_fds = ctx.preserve_fds;
    lc_ctx.force_no_cgroup = ctx.force_no_cgroup;
    lc_ctx.fifo_exec_wait_fd = -1;

    var err: c.libcrun_error_t = null;
    const ret = c.libcrun_container_run(&lc_ctx, container.raw, opts.toBits(), &err);
    if (ret < 0) return mapErr(ctx, &err);
    clearLastError(ctx);
    return decodeExitStatus(ret);
}

/// Sends `signal_name` to the running container via `libcrun_container_kill`.
/// libcrun accepts both symbolic ("SIGTERM") and numeric ("9") strings.
pub fn kill(
    ctx: *Context,
    container: Container,
    signal_name: [:0]const u8,
) RuntimeError!void {
    _ = container; // libcrun resolves by id from ctx; param kept for API symmetry.
    var lc_ctx: c.libcrun_context_t = std.mem.zeroes(c.libcrun_context_t);
    var owned = try CContextStrings.build(ctx, &lc_ctx);
    defer owned.deinit(ctx.allocator);
    lc_ctx.fifo_exec_wait_fd = -1;

    var err: c.libcrun_error_t = null;
    const ret = c.libcrun_container_kill(&lc_ctx, owned.id_z.ptr, signal_name.ptr, &err);
    if (ret < 0) return mapErr(ctx, &err);
    clearLastError(ctx);
}

/// Deletes container state via `libcrun_container_delete`. Pass `force=true`
/// to skip the running-state check.
pub fn delete(
    ctx: *Context,
    container: Container,
    force: bool,
) RuntimeError!void {
    var lc_ctx: c.libcrun_context_t = std.mem.zeroes(c.libcrun_context_t);
    var owned = try CContextStrings.build(ctx, &lc_ctx);
    defer owned.deinit(ctx.allocator);
    lc_ctx.fifo_exec_wait_fd = -1;

    var err: c.libcrun_error_t = null;
    const ret = c.libcrun_container_delete(
        &lc_ctx,
        container.raw.container_def,
        owned.id_z.ptr,
        force,
        &err,
    );
    if (ret < 0) return mapErr(ctx, &err);
    clearLastError(ctx);
}

/// Decodes libcrun's `get_process_exit_status` convention back into a typed
/// union. See utils.h:424.
fn decodeExitStatus(ret: c_int) ExitStatus {
    if (ret >= 128 and ret <= 128 + 64) {
        return .{ .signal = @intCast(ret - 128) };
    }
    const clamped: c_int = if (ret < 0) 0 else if (ret > 255) 255 else ret;
    return .{ .exit = @intCast(clamped) };
}

const CContextStrings = struct {
    id_z: [:0]u8,
    state_root_z: [:0]u8,
    bundle_z: [:0]u8,
    console_socket_z: ?[:0]u8,
    notify_socket_z: ?[:0]u8,

    fn build(ctx: *const Context, out: *c.libcrun_context_t) RuntimeError!CContextStrings {
        const a = ctx.allocator;
        const id_z = a.dupeZ(u8, ctx.id) catch return error.OutOfMemory;
        errdefer a.free(id_z);
        const state_root_z = a.dupeZ(u8, ctx.state_root) catch return error.OutOfMemory;
        errdefer a.free(state_root_z);
        const bundle_z = a.dupeZ(u8, ctx.bundle) catch return error.OutOfMemory;
        errdefer a.free(bundle_z);

        var console_z: ?[:0]u8 = null;
        if (ctx.console_socket) |s| {
            console_z = a.dupeZ(u8, s) catch return error.OutOfMemory;
        }
        errdefer if (console_z) |s| a.free(s);

        var notify_z: ?[:0]u8 = null;
        if (ctx.notify_socket) |s| {
            notify_z = a.dupeZ(u8, s) catch return error.OutOfMemory;
        }
        errdefer if (notify_z) |s| a.free(s);

        out.id = id_z.ptr;
        out.state_root = state_root_z.ptr;
        out.bundle = bundle_z.ptr;
        out.console_socket = if (console_z) |s| s.ptr else null;
        out.notify_socket = if (notify_z) |s| s.ptr else null;

        return .{
            .id_z = id_z,
            .state_root_z = state_root_z,
            .bundle_z = bundle_z,
            .console_socket_z = console_z,
            .notify_socket_z = notify_z,
        };
    }

    fn deinit(self: *CContextStrings, a: std.mem.Allocator) void {
        a.free(self.id_z);
        a.free(self.state_root_z);
        a.free(self.bundle_z);
        if (self.console_socket_z) |s| a.free(s);
        if (self.notify_socket_z) |s| a.free(s);
    }
};

/// Translates a libcrun_error_t to a typed RuntimeError, stashes message on
/// `ctx.last_error`, and releases the C-side error exactly once.
fn mapErr(ctx: *Context, err: *c.libcrun_error_t) RuntimeError {
    var status: c_int = 0;
    var msg_dup: []u8 = &.{};
    if (err.*) |e| {
        status = e.*.status;
        if (e.*.msg) |raw| {
            const slice = std.mem.sliceTo(raw, 0);
            msg_dup = ctx.allocator.dupe(u8, slice) catch &.{};
        }
    }

    if (ctx.last_error) |prev| ctx.allocator.free(prev.message);
    ctx.last_error = .{ .errno = status, .message = msg_dup };

    _ = c.libcrun_error_release(err);
    return classify(status);
}

/// Variant of `mapErr` for call sites without a `Context` (i.e.
/// `Container.loadFromFile`). Drops the diagnostic message — caller still
/// gets the typed error.
fn classifyAndRelease(err: *c.libcrun_error_t) RuntimeError {
    var status: c_int = 0;
    if (err.*) |e| status = e.*.status;
    _ = c.libcrun_error_release(err);
    return classify(status);
}

fn clearLastError(ctx: *Context) void {
    if (ctx.last_error) |le| {
        ctx.allocator.free(le.message);
        ctx.last_error = null;
    }
}

fn classify(errno_val: c_int) RuntimeError {
    return switch (errno_val) {
        c.EINVAL => RuntimeError.InvalidConfig,
        c.ENOENT => RuntimeError.BundleNotFound,
        c.EACCES, c.EPERM => RuntimeError.PermissionDenied,
        c.EEXIST => RuntimeError.AlreadyExists,
        else => RuntimeError.LibcrunFailure,
    };
}

const testing = std.testing;

test "decodeExitStatus: WEXITSTATUS path" {
    try testing.expectEqualDeep(ExitStatus{ .exit = 0 }, decodeExitStatus(0));
    try testing.expectEqualDeep(ExitStatus{ .exit = 1 }, decodeExitStatus(1));
    try testing.expectEqualDeep(ExitStatus{ .exit = 127 }, decodeExitStatus(127));
}

test "decodeExitStatus: 128 + WTERMSIG path" {
    try testing.expectEqualDeep(ExitStatus{ .signal = 2 }, decodeExitStatus(130));
    try testing.expectEqualDeep(ExitStatus{ .signal = 9 }, decodeExitStatus(137));
    try testing.expectEqualDeep(ExitStatus{ .signal = 15 }, decodeExitStatus(143));
}

test "CreateOptions.toBits: empty -> 0, prefork -> PREFORK, keep -> KEEP" {
    try testing.expectEqual(@as(c_uint, 0), (CreateOptions{}).toBits());
    try testing.expectEqual(
        @as(c_uint, c.LIBCRUN_RUN_OPTIONS_PREFORK),
        (CreateOptions{ .prefork = true }).toBits(),
    );
    try testing.expectEqual(
        @as(c_uint, c.LIBCRUN_RUN_OPTIONS_KEEP),
        (CreateOptions{ .keep = true }).toBits(),
    );
    try testing.expectEqual(
        @as(c_uint, c.LIBCRUN_RUN_OPTIONS_PREFORK | c.LIBCRUN_RUN_OPTIONS_KEEP),
        (CreateOptions{ .prefork = true, .keep = true }).toBits(),
    );
}

test "classify: errno -> typed error" {
    try testing.expectEqual(RuntimeError.InvalidConfig, classify(c.EINVAL));
    try testing.expectEqual(RuntimeError.BundleNotFound, classify(c.ENOENT));
    try testing.expectEqual(RuntimeError.PermissionDenied, classify(c.EACCES));
    try testing.expectEqual(RuntimeError.PermissionDenied, classify(c.EPERM));
    try testing.expectEqual(RuntimeError.AlreadyExists, classify(c.EEXIST));
    try testing.expectEqual(RuntimeError.LibcrunFailure, classify(0));
    try testing.expectEqual(RuntimeError.LibcrunFailure, classify(c.EIO));
}

/// Returns an absolute path string for a TmpDir's underlying filesystem
/// directory (`<cwd>/.zig-cache/tmp/<sub_path>`). Caller frees.
fn tmpAbsPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path });
}

test "Container.loadFromFile: missing config.json returns BundleNotFound" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const abs = try tmpAbsPath(allocator, &tmp.sub_path);
    defer allocator.free(abs);

    const result = Container.loadFromFile(allocator, abs);
    try testing.expectError(RuntimeError.BundleNotFound, result);
}

test "Container.loadFromFile: malformed config.json returns InvalidConfig" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Truncated JSON object — yajl rejects with an EINVAL via libcrun.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{" });

    const abs = try tmpAbsPath(allocator, &tmp.sub_path);
    defer allocator.free(abs);

    const result = Container.loadFromFile(allocator, abs);
    try testing.expectError(RuntimeError.InvalidConfig, result);
}

// runSync /bin/true integration deferred: building a rootless bundle
// (uid_map, no cgroup, static rootfs) is a fixture that lands with T19
// (state) + T21 (bundle composer). T18 proves the wrapper compiles +
// hits libcrun's error paths cleanly via the unit tests above; T22 will
// add the live `/bin/true` exit-code test against a composed bundle.
