//! `rind` binary entry point.
//!
//! Responsibilities, in order:
//!
//!   1. Unpack `std.process.Init` (allocator, argv, io).
//!   2. Configure runtime log filtering from `RIND_LOG`.
//!   3. Hand argv to `cli.dispatch` for subcommand routing.
//!   4. Catch every error, map it to the documented exit code via
//!      `cli/exit.zig`, and call `std.process.exit` exactly once.
//!
//! No business logic lives here. Adding flags, subcommands, or
//! handlers means touching `src/cli/`, not this file.

const std = @import("std");
const Io = std.Io;

const cli_root = @import("cli/root.zig");
const cli_exit = @import("cli/exit.zig");

/// Customised `std.Options` so `RIND_LOG=rind=debug` can flip on
/// debug logging without recompiling. The runtime flag is consulted
/// inside `rindLogFn`; the comptime `log_level` stays at `.debug`
/// so that filtering is purely runtime.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = rindLogFn,
};

var debug_logging = std.atomic.Value(bool).init(false);

fn rindLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    switch (level) {
        .err, .warn => std.log.defaultLog(level, scope, fmt, args),
        .info, .debug => {
            if (debug_logging.load(.acquire)) {
                std.log.defaultLog(level, scope, fmt, args);
            }
        },
    }
}

/// Apply `RIND_LOG`. The full filter syntax (`scope=level,scope2=level2`)
/// is overkill for MVP — the only recognised value is the literal
/// substring `rind=debug`, which flips on info+debug logs.
fn applyLogEnv(env_map: *const std.process.Environ.Map) void {
    const v = env_map.get("RIND_LOG") orelse return;
    if (std.mem.indexOf(u8, v, "rind=debug") != null) {
        debug_logging.store(true, .release);
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    applyLogEnv(init.environ_map);

    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4 * 1024]u8 = undefined;
    var stderr_buf: [4 * 1024]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stdout = &stdout_fw.interface;
    const stderr = &stderr_fw.interface;

    cli_root.dispatch(io, arena, argv, init.environ_map, stdout, stderr) catch |err| {
        // Best-effort flush so any in-flight bytes land before exit.
        stdout.flush() catch {};
        stderr.flush() catch {};
        std.process.exit(@intFromEnum(cli_exit.mapErrorToExitCode(err)));
    };

    stdout.flush() catch {};
    stderr.flush() catch {};
}

test {
    // Force the test runner to walk into the CLI subtree. Without
    // these the cli/* tests would not be reached from the exe root.
    _ = @import("cli/exit.zig");
    _ = @import("cli/output.zig");
    _ = @import("cli/pull.zig");
    _ = @import("cli/images.zig");
    _ = @import("cli/root.zig");
}
