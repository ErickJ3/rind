//! CLI entry-point dispatch.
//!
//! `main.zig` hands raw argv here. We peel off the subcommand and
//! route to the matching handler. Subcommand-level argparse lives
//! in the per-verb file (`pull.zig`, eventually `run.zig`, etc.).
//!
//! Top-level argparse is hand-rolled rather than going through
//! `clap.parseEx`. With one verb today the dispatch is two `eql`
//! checks; layering clap's subcommand machinery on top would obscure
//! more than it helps. When a third verb lands, swap in clap.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const layout = @import("../store/layout.zig");
const client_mod = @import("../registry/client.zig");
const auth_mod = @import("../registry/auth.zig");
const run_mod = @import("../run.zig");
const Environ = std.process.Environ;

const exit = @import("exit.zig");
const output = @import("output.zig");
const pull_cli = @import("pull.zig");
const run_cli = @import("run.zig");
const images_cli = @import("images.zig");
const inspect_cli = @import("inspect.zig");
const ps_cli = @import("ps.zig");
const IoV4 = @import("../IoV4.zig");

/// Default storage root suffix appended to `$HOME` when `RIND_ROOT`
/// is unset. Matches the layout described in `docs/rind.md`.
pub const default_root_suffix: []const u8 = ".rind";
/// Sub-path inside the root that holds the OCI image-layout store.
pub const store_subpath: []const u8 = "store";

/// One-line usage banner for the top-level CLI.
pub const usage_line: []const u8 = "Usage: rind <command> [args...]\nCommands:\n  pull     Pull an image into the local store\n  run      Run a command in a new container\n  ps       List containers\n  images   List images in the local store\n  inspect  Dump the image config JSON for a local image\n  help     Show this message";

/// Resolve the rind state-root directory. Precedence:
/// 1. `RIND_ROOT` env var (used as-is).
/// 2. `$HOME/.rind`.
/// Returns `error.HomeNotFound` if neither is set. Caller owns the
/// returned slice.
pub fn resolveRoot(gpa: Allocator, env_map: *const Environ.Map) ![]u8 {
    if (env_map.get("RIND_ROOT")) |v| return gpa.dupe(u8, v);
    const home = env_map.get("HOME") orelse return error.HomeNotFound;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, default_root_suffix });
}

/// Top-level dispatch. `argv` includes `argv[0]` (program name), so
/// the subcommand is at `argv[1]`. `stdout` / `stderr` are used for
/// human renderers, JSON output, and usage diagnostics. Returns an
/// error on bad input or subcommand failure; `main.zig` maps it to an
/// exit code via `cli_exit.mapErrorToExitCode`.
///
/// Returns the `u8` exit code the rind binary should propagate on the
/// success path. Most subcommands return `0`; `run` returns the
/// container's exit code (`128 + signal` on signal exit, per POSIX).
pub fn dispatch(
    io: Io,
    gpa: Allocator,
    argv: []const []const u8,
    env_map: *const Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !u8 {
    if (argv.len < 2) {
        try stderr.print("{s}\n", .{usage_line});
        return error.Usage;
    }
    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        try stdout.print("{s}\n", .{usage_line});
        try stdout.flush();
        return 0;
    }
    if (std.mem.eql(u8, cmd, "pull")) {
        return runPull(io, gpa, argv[2..], env_map, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "run")) {
        return runRun(io, gpa, argv[2..], env_map, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "images")) {
        return runImages(io, gpa, argv[2..], env_map, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "inspect")) {
        return runInspect(io, gpa, argv[2..], env_map, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "ps")) {
        return runPs(io, gpa, argv[2..], env_map, stdout, stderr);
    }
    try stderr.print("rind: unknown command '{s}'\n{s}\n", .{ cmd, usage_line });
    return error.Usage;
}

fn runPull(
    io_in: Io,
    gpa: Allocator,
    sub_argv: []const []const u8,
    env_map: *const Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !u8 {
    var iter: SliceIter = .{ .items = sub_argv };
    const args = try pull_cli.parseArgs(gpa, &iter, stderr);
    defer pull_cli.freeArgs(gpa, args);

    var v4_io: IoV4 = undefined;
    const io = if (args.ipv4) blk: {
        v4_io = IoV4.init(io_in);
        break :blk v4_io.io();
    } else io_in;

    const root_path = try resolveRoot(gpa, env_map);
    defer gpa.free(root_path);

    var root_dir = try Io.Dir.cwd().createDirPathOpen(io, root_path, .{
        .open_options = .{ .iterate = true },
    });
    defer root_dir.close(io);

    var store = try layout.Store.init(io, root_dir, store_subpath);
    defer store.close(io);

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    // TODO: swap `Provider.anonymous` for the file-backed provider
    // that reads `~/.rind/auth.json`.
    var client = client_mod.Client.init(gpa, io, &http_client, auth_mod.Provider.anonymous);
    defer client.deinit();

    // Live per-layer progress is delegated to `std.Progress`. The
    // orchestrator already builds byte-metered children for each
    // blob and a row per layer for extract; we just hand it a root
    // node. Skipped for JSON (machine-readable contract; would
    // garble), `--quiet`, and `--no-progress`. `std.Progress`
    // auto-disables on non-TTY too, so this is also safe in CI.
    const want_progress = args.output == .human and !args.quiet and !args.no_progress;

    var progress_root: ?std.Progress.Node = if (want_progress)
        std.Progress.start(io, .{ .root_name = "" })
    else
        null;
    // Fallback teardown for the platform-error early return below.
    // On the success path `pull_cli.run` ends the root before
    // `on_summary` so the summary line lands cleanly below the
    // already-cleared progress region.
    defer if (progress_root) |n| n.end();

    var human: output.Human = .{
        .writer = stdout,
        .err_writer = stderr,
        .quiet = args.quiet,
        .progress_active = want_progress,
    };
    var json_renderer: output.Json = .{
        .writer = stdout,
        .err_writer = stderr,
    };

    var renderer = switch (args.output) {
        .human => human.renderer(),
        .json => json_renderer.renderer(),
    };

    try pull_cli.run(io, gpa, &store, &client, args, &renderer, .{}, &progress_root);
    return 0;
}

fn runRun(
    io: Io,
    gpa: Allocator,
    sub_argv: []const []const u8,
    env_map: *const Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !u8 {
    var iter: SliceIter = .{ .items = sub_argv };
    const args = try run_cli.parseArgs(gpa, &iter, stderr);
    defer run_cli.freeArgs(gpa, args);

    const root_path = try resolveRoot(gpa, env_map);
    defer gpa.free(root_path);

    var root_dir = try Io.Dir.cwd().createDirPathOpen(io, root_path, .{
        .open_options = .{ .iterate = true },
    });
    defer root_dir.close(io);

    var store = layout.Store.open(io, root_dir, store_subpath) catch |err| switch (err) {
        layout.StoreError.InvalidLayout => {
            try stderr.print("rind: no image store at '{s}/{s}' (run `rind pull` first)\n", .{ root_path, store_subpath });
            return err;
        },
        else => |e| return e,
    };
    defer store.close(io);

    var human: output.Human = .{
        .writer = stdout,
        .err_writer = stderr,
        .quiet = false,
    };
    var json_renderer: output.Json = .{
        .writer = stdout,
        .err_writer = stderr,
    };

    var renderer = switch (args.output) {
        .human => human.renderer(),
        .json => json_renderer.renderer(),
    };

    const env: run_mod.Env = .{
        .root_dir = root_dir,
        .root_abspath = root_path,
        .store_subpath = store_subpath,
    };

    return try run_cli.run(io, gpa, &store, env, args, &renderer, .{});
}

fn runImages(
    io: Io,
    gpa: Allocator,
    sub_argv: []const []const u8,
    env_map: *const Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !u8 {
    var iter: SliceIter = .{ .items = sub_argv };
    const args = try images_cli.parseArgs(gpa, &iter, stderr);
    defer images_cli.freeArgs(gpa, args);

    const root_path = try resolveRoot(gpa, env_map);
    defer gpa.free(root_path);

    var root_dir = try Io.Dir.cwd().createDirPathOpen(io, root_path, .{
        .open_options = .{ .iterate = true },
    });
    defer root_dir.close(io);

    var store = layout.Store.open(io, root_dir, store_subpath) catch |err| switch (err) {
        layout.StoreError.InvalidLayout => {
            try stderr.print("rind: no image store at '{s}/{s}' (run `rind pull` first)\n", .{ root_path, store_subpath });
            return err;
        },
        else => |e| return e,
    };
    defer store.close(io);

    try images_cli.run(io, gpa, &store, args, stdout, stderr);
    return 0;
}

fn runInspect(
    io: Io,
    gpa: Allocator,
    sub_argv: []const []const u8,
    env_map: *const Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !u8 {
    var iter: SliceIter = .{ .items = sub_argv };
    const args = try inspect_cli.parseArgs(gpa, &iter, stderr);
    defer inspect_cli.freeArgs(gpa, args);

    const root_path = try resolveRoot(gpa, env_map);
    defer gpa.free(root_path);

    var root_dir = try Io.Dir.cwd().createDirPathOpen(io, root_path, .{
        .open_options = .{ .iterate = true },
    });
    defer root_dir.close(io);

    var store = layout.Store.open(io, root_dir, store_subpath) catch |err| switch (err) {
        layout.StoreError.InvalidLayout => {
            try stderr.print("rind: no image store at '{s}/{s}' (run `rind pull` first)\n", .{ root_path, store_subpath });
            return err;
        },
        else => |e| return e,
    };
    defer store.close(io);

    try inspect_cli.run(io, gpa, &store, args, stdout, stderr);
    return 0;
}

fn runPs(
    io: Io,
    gpa: Allocator,
    sub_argv: []const []const u8,
    env_map: *const Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !u8 {
    var iter: SliceIter = .{ .items = sub_argv };
    const args = try ps_cli.parseArgs(gpa, &iter, stderr);
    defer ps_cli.freeArgs(gpa, args);

    const root_path = try resolveRoot(gpa, env_map);
    defer gpa.free(root_path);

    var root_dir = try Io.Dir.cwd().createDirPathOpen(io, root_path, .{
        .open_options = .{ .iterate = true },
    });
    defer root_dir.close(io);

    const ts = Io.Clock.now(.real, io);
    const ns: i96 = ts.nanoseconds;
    const now_unix: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));

    try ps_cli.run(io, gpa, root_dir, args, now_unix, stdout, stderr);
    return 0;
}

const SliceIter = struct {
    items: []const []const u8,
    idx: usize = 0,
    pub fn next(self: *SliceIter) ?[]const u8 {
        if (self.idx >= self.items.len) return null;
        defer self.idx += 1;
        return self.items[self.idx];
    }
};

const testing = std.testing;

test "dispatch with no args prints usage and returns error.Usage" {
    const gpa = testing.allocator;
    const io = testing.io;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    var env_map = Environ.Map.init(gpa);
    defer env_map.deinit();
    try testing.expectError(
        error.Usage,
        dispatch(io, gpa, &.{"rind"}, &env_map, &out.writer, &err_buf.writer),
    );
    try testing.expect(std.mem.indexOf(u8, err_buf.written(), "Usage:") != null);
}

test "dispatch help prints banner and returns success" {
    const gpa = testing.allocator;
    const io = testing.io;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    var env_map = Environ.Map.init(gpa);
    defer env_map.deinit();
    const code = try dispatch(io, gpa, &.{ "rind", "help" }, &env_map, &out.writer, &err_buf.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Usage:") != null);
}

test "dispatch unknown subcommand returns error.Usage" {
    const gpa = testing.allocator;
    const io = testing.io;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    var env_map = Environ.Map.init(gpa);
    defer env_map.deinit();
    try testing.expectError(
        error.Usage,
        dispatch(io, gpa, &.{ "rind", "weld" }, &env_map, &out.writer, &err_buf.writer),
    );
    try testing.expect(std.mem.indexOf(u8, err_buf.written(), "unknown command") != null);
}

test "resolveRoot prefers RIND_ROOT when set" {
    const gpa = testing.allocator;
    var env_map = Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("RIND_ROOT", "/tmp/rind-test");

    const path = try resolveRoot(gpa, &env_map);
    defer gpa.free(path);
    try testing.expectEqualStrings("/tmp/rind-test", path);
}

test "resolveRoot falls back to HOME/.rind" {
    const gpa = testing.allocator;
    var env_map = Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/alice");

    const path = try resolveRoot(gpa, &env_map);
    defer gpa.free(path);
    try testing.expectEqualStrings("/home/alice/.rind", path);
}

test "resolveRoot returns HomeNotFound when neither is set" {
    const gpa = testing.allocator;
    var env_map = Environ.Map.init(gpa);
    defer env_map.deinit();
    try testing.expectError(error.HomeNotFound, resolveRoot(gpa, &env_map));
}
