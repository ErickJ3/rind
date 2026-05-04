//! `rind rm` subcommand.
//!
//! Resolves each target argument (exact `name` first, then short-ID
//! prefix `>= state_mod.id_prefix_min`) via `state_mod.resolveTarget`
//! and hands the resolved short ID to `runtime/teardown.zig`.
//! Per-target failures print to stderr and don't abort the rest of
//! the loop (Docker convention); the dispatcher returns
//! `error.RmAggregate` when any target failed so `cli/exit.zig` can
//! map it to a non-zero exit code.
//!
//! The teardown step is injected via `RmDeps.teardown_fn` so unit
//! tests don't need a live container.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const clap = @import("clap");

const state_mod = @import("../runtime/state.zig");
const teardown_mod = @import("../runtime/teardown.zig");

/// Validated argv for `rind rm`.
pub const RmArgs = struct {
    /// `-f/--force`: SIGKILL the init pid and remove anyway.
    force: bool = false,
    /// One or more container ids/names. Always at least one — argparse
    /// surfaces `error.Usage` on an empty positional list.
    targets: []const []const u8,
};

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\-f, --force             Force removal of running containers (SIGKILL + 10s wait).
    \\<str>...                Container id or name (repeatable).
    \\
);

const value_parsers = .{
    .str = clap.parsers.string,
};

/// One-line usage banner.
pub const usage_line: []const u8 = "Usage: rind rm [-f|--force] <container>...";

/// Parse argv (after `rm` has been peeled off) into a validated
/// `RmArgs`. `iter` is consumed; `gpa` backs the dupes that survive
/// after `clap`'s arena is freed.
pub fn parseArgs(
    gpa: Allocator,
    iter: anytype,
    err_writer: *Io.Writer,
) !RmArgs {
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

    const positionals = res.positionals[0];
    if (positionals.len == 0) {
        try err_writer.print("rind rm: requires at least one container\n{s}\n", .{usage_line});
        return error.Usage;
    }

    var owned = try gpa.alloc([]const u8, positionals.len);
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |s| gpa.free(s);
        gpa.free(owned);
    }
    for (positionals) |s| {
        owned[filled] = try gpa.dupe(u8, s);
        filled += 1;
    }

    return .{
        .force = res.args.force != 0,
        .targets = owned,
    };
}

/// Free heap copies kept by `parseArgs`.
pub fn freeArgs(gpa: Allocator, args: RmArgs) void {
    for (args.targets) |s| gpa.free(s);
    gpa.free(args.targets);
}

/// Test seam wrapping the cold-start teardown so unit tests can
/// substitute a stub that doesn't open `state.json` or touch `/proc`.
pub const RmDeps = struct {
    teardown_fn: *const fn (
        io: Io,
        gpa: Allocator,
        root_dir: Io.Dir,
        id_short: []const u8,
        opts: teardown_mod.TeardownOptions,
        deps: teardown_mod.TeardownDeps,
    ) teardown_mod.FullTeardownError!void = teardown_mod.teardown,
};

/// Sentinel returned from `run` when at least one target failed; the
/// dispatcher maps this to a non-zero exit code via `cli/exit.zig`.
/// Per-target diagnostics have already been written to `stderr`.
pub const Aggregate = error{RmAggregate};

/// Iterate `args.targets`, resolving each via `state.resolveTarget` and
/// handing the resolved id to `deps.teardown_fn`. Per-target errors are
/// rendered to `stderr` and don't abort the loop. Returns
/// `error.RmAggregate` when any target failed.
pub fn run(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    root_abspath: []const u8,
    args: RmArgs,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    deps: RmDeps,
) !void {
    var any_failed = false;

    for (args.targets) |target| {
        rmOne(io, gpa, root_dir, root_abspath, target, args.force, stdout, stderr, deps) catch |err| {
            any_failed = true;
            renderError(io, root_dir, target, err, stderr) catch {};
            continue;
        };
    }

    if (any_failed) return Aggregate.RmAggregate;
}

fn rmOne(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    root_abspath: []const u8,
    target: []const u8,
    force: bool,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    deps: RmDeps,
) !void {
    _ = stderr;
    const id = try state_mod.resolveTarget(io, gpa, root_dir, target);
    try deps.teardown_fn(io, gpa, root_dir, id[0..], .{
        .root_abspath = root_abspath,
        .force = force,
    }, .{});
    try stdout.print("{s}\n", .{id[0..]});
}

fn renderError(
    io: Io,
    root_dir: Io.Dir,
    target: []const u8,
    err: anyerror,
    stderr: *Io.Writer,
) !void {
    switch (err) {
        error.ContainerNotFound => try stderr.print(
            "Error: no such container: {s}\n",
            .{target},
        ),
        error.PrefixTooShort => try stderr.print(
            "Error: id prefix \"{s}\" too short (need >= {d} chars)\n",
            .{ target, state_mod.id_prefix_min },
        ),
        error.AmbiguousId => {
            var matches: [2][state_mod.id_short_length]u8 = undefined;
            const n = state_mod.collectPrefixMatches(io, root_dir, target, matches[0..]) catch 0;
            if (n >= 2) {
                try stderr.print(
                    "Error: id \"{s}\" is ambiguous: matches {s} and {s}\n",
                    .{ target, matches[0][0..], matches[1][0..] },
                );
            } else {
                try stderr.print(
                    "Error: id \"{s}\" is ambiguous\n",
                    .{target},
                );
            }
        },
        error.ContainerRunning => try stderr.print(
            "Error: cannot remove \"{s}\": container is running (use -f)\n",
            .{target},
        ),
        error.KillTimeout => try stderr.print(
            "Error: timed out waiting for \"{s}\" to exit after SIGKILL\n",
            .{target},
        ),
        else => try stderr.print(
            "Error: {s}: {s}\n",
            .{ target, @errorName(err) },
        ),
    }
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

fn parseFromSlice(gpa: Allocator, sub: []const []const u8, err_w: *Io.Writer) !RmArgs {
    var iter: SliceIter = .{ .items = sub };
    return parseArgs(gpa, &iter, err_w);
}

test "parseArgs: defaults, single positional, force off" {
    const gpa = testing.allocator;
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();
    const args = try parseFromSlice(gpa, &.{"web"}, &ew.writer);
    defer freeArgs(gpa, args);
    try testing.expect(!args.force);
    try testing.expectEqual(@as(usize, 1), args.targets.len);
    try testing.expectEqualStrings("web", args.targets[0]);
}

test "parseArgs: --force and multiple positionals" {
    const gpa = testing.allocator;
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();
    const args = try parseFromSlice(gpa, &.{ "-f", "a", "b", "c" }, &ew.writer);
    defer freeArgs(gpa, args);
    try testing.expect(args.force);
    try testing.expectEqual(@as(usize, 3), args.targets.len);
    try testing.expectEqualStrings("a", args.targets[0]);
    try testing.expectEqualStrings("c", args.targets[2]);
}

test "parseArgs: --help returns Usage" {
    const gpa = testing.allocator;
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{"--help"}, &ew.writer));
    try testing.expect(std.mem.indexOf(u8, ew.written(), "Usage:") != null);
}

test "parseArgs: empty positionals returns Usage" {
    const gpa = testing.allocator;
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{}, &ew.writer));
}

const StubTeardown = struct {
    fail_with: ?anyerror = null,
    seen_force: bool = false,
    calls: u32 = 0,
};

threadlocal var g_stub: ?*StubTeardown = null;

fn stubTeardownFn(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    id_short: []const u8,
    opts: teardown_mod.TeardownOptions,
    deps: teardown_mod.TeardownDeps,
) teardown_mod.FullTeardownError!void {
    _ = io;
    _ = gpa;
    _ = root_dir;
    _ = id_short;
    _ = deps;
    if (g_stub) |s| {
        s.calls += 1;
        s.seen_force = opts.force;
        if (s.fail_with) |e| return @errorCast(e);
    }
}

fn seedExited(
    gpa: Allocator,
    root: Io.Dir,
    name: ?[]const u8,
) !state_mod.Container {
    var c = try state_mod.allocate(testing.io, gpa, root, "alpine:3.19", "sha256:aa", name, null);
    errdefer c.deinit(gpa);
    try state_mod.transition(testing.io, gpa, root, c.id[0..], .{ .status = .exited, .exit_code = 0 });
    return c;
}

test "run: happy path emits id on stdout" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try seedExited(gpa, root, "web");
    defer c.deinit(gpa);

    var stub: StubTeardown = .{};
    g_stub = &stub;
    defer g_stub = null;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();

    const args = RmArgs{ .force = false, .targets = &[_][]const u8{"web"} };
    try run(testing.io, gpa, root, "/tmp/rind-test", args, &out.writer, &ew.writer, .{
        .teardown_fn = stubTeardownFn,
    });

    try testing.expectEqual(@as(u32, 1), stub.calls);
    try testing.expect(std.mem.indexOf(u8, out.written(), c.id[0..]) != null);
    try testing.expectEqualStrings("", ew.written());
}

test "run: -f propagates force to teardown" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try seedExited(gpa, root, "svc");
    defer c.deinit(gpa);

    var stub: StubTeardown = .{};
    g_stub = &stub;
    defer g_stub = null;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();

    const args = RmArgs{ .force = true, .targets = &[_][]const u8{"svc"} };
    try run(testing.io, gpa, root, "/tmp/rind-test", args, &out.writer, &ew.writer, .{
        .teardown_fn = stubTeardownFn,
    });

    try testing.expect(stub.seen_force);
}

test "run: mixed success — bogus name continues, valid removed, RmAggregate" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c1 = try seedExited(gpa, root, "good1");
    defer c1.deinit(gpa);
    var c2 = try seedExited(gpa, root, "good2");
    defer c2.deinit(gpa);

    var stub: StubTeardown = .{};
    g_stub = &stub;
    defer g_stub = null;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();

    const args = RmArgs{
        .force = false,
        .targets = &[_][]const u8{ "good1", "ghostly", "good2" },
    };
    try testing.expectError(
        Aggregate.RmAggregate,
        run(testing.io, gpa, root, "/tmp/rind-test", args, &out.writer, &ew.writer, .{
            .teardown_fn = stubTeardownFn,
        }),
    );

    try testing.expectEqual(@as(u32, 2), stub.calls);
    try testing.expect(std.mem.indexOf(u8, out.written(), c1.id[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), c2.id[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, ew.written(), "no such container: ghostly") != null);
}

test "run: ContainerRunning surfaces stderr line, returns RmAggregate" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var c = try seedExited(gpa, root, "svc");
    defer c.deinit(gpa);

    var stub: StubTeardown = .{ .fail_with = error.ContainerRunning };
    g_stub = &stub;
    defer g_stub = null;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();

    const args = RmArgs{ .force = false, .targets = &[_][]const u8{"svc"} };
    try testing.expectError(
        Aggregate.RmAggregate,
        run(testing.io, gpa, root, "/tmp/rind-test", args, &out.writer, &ew.writer, .{
            .teardown_fn = stubTeardownFn,
        }),
    );
    try testing.expect(std.mem.indexOf(u8, ew.written(), "container is running") != null);
    try testing.expect(std.mem.indexOf(u8, ew.written(), "use -f") != null);
}

const FixedIdSeq = struct {
    ids: []const [state_mod.id_full_length]u8,
    cursor: usize = 0,

    fn fill(io: Io, ctx: ?*anyopaque, out: *[state_mod.id_full_length]u8) void {
        _ = io;
        const self: *FixedIdSeq = @ptrCast(@alignCast(ctx.?));
        const i = if (self.cursor >= self.ids.len) self.ids.len - 1 else self.cursor;
        out.* = self.ids[i];
        self.cursor += 1;
    }
};

test "run: AmbiguousId stderr lists both ids" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(testing.io);

    var id1: [state_mod.id_full_length]u8 = undefined;
    var id2: [state_mod.id_full_length]u8 = undefined;
    @memcpy(id1[0..6], "decade");
    @memset(id1[6..], 'a');
    @memcpy(id2[0..6], "decade");
    @memset(id2[6..], 'b');

    var seq = FixedIdSeq{ .ids = &.{id1} };
    var c1 = try state_mod.allocateWithIdSource(testing.io, gpa, root, "alpine:3.19", "sha256:01", null, null, .{
        .fill_fn = FixedIdSeq.fill,
        .ctx = &seq,
    });
    defer c1.deinit(gpa);
    var seq2 = FixedIdSeq{ .ids = &.{id2} };
    var c2 = try state_mod.allocateWithIdSource(testing.io, gpa, root, "alpine:3.19", "sha256:02", null, null, .{
        .fill_fn = FixedIdSeq.fill,
        .ctx = &seq2,
    });
    defer c2.deinit(gpa);

    var stub: StubTeardown = .{};
    g_stub = &stub;
    defer g_stub = null;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ew: Io.Writer.Allocating = .init(gpa);
    defer ew.deinit();

    const args = RmArgs{ .force = false, .targets = &[_][]const u8{"deca"} };
    try testing.expectError(
        Aggregate.RmAggregate,
        run(testing.io, gpa, root, "/tmp/rind-test", args, &out.writer, &ew.writer, .{
            .teardown_fn = stubTeardownFn,
        }),
    );
    try testing.expect(std.mem.indexOf(u8, ew.written(), "ambiguous") != null);
    try testing.expect(std.mem.indexOf(u8, ew.written(), c1.id[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, ew.written(), c2.id[0..]) != null);
}
