//! `rind run <image> [cmd...]` subcommand.
//!
//! Argparse, validation, and orchestration glue for the run verb. The
//! actual end-to-end run is delegated to `run_mod.runImage` via
//! `RunDeps.run_fn` so tests can swap in a stub that returns synthetic
//! results without standing up the kernel overlay code path or
//! libcrun.
//!
//! The orchestrator's signature in `src/run.zig` carries `Env` and
//! `RunDeps` parameters that the spec text simplifies away. The
//! `runImageDefault` shim threads default `run_mod.RunDeps{}` through
//! on production calls so the CLI's test seam stays narrow — stubs
//! replace the entire orchestrator body, never just one of its inner
//! deps.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const clap = @import("clap");

const run_mod = @import("../run.zig");
const bundle_mod = @import("../runtime/bundle.zig");
const mount_spec = @import("../runtime/mount_spec.zig");
const layout = @import("../store/layout.zig");

const exit = @import("exit.zig");
const output = @import("output.zig");
const pull_cli = @import("pull.zig");

/// Output format. `human` is the TTY default; `json` is the
/// schema-versioned NDJSON contract shared with `pull`.
pub const OutputKind = enum { human, json };

/// Validated argv for `rind run`. All slices are owned by `gpa` and
/// must be released via `freeArgs` once the caller is done with the
/// result.
pub const RunArgs = struct {
    /// Positional image reference (`alpine:3.19`, `…@sha256:…`).
    image: []const u8,
    /// Trailing positional command + args (`echo hi`). Empty when no
    /// command was supplied; the orchestrator falls back to the image
    /// config defaults in that case.
    cmd: []const []const u8 = &.{},
    /// Output format. `--output {human,json}`. Defaults to human.
    output: OutputKind = .human,
    /// `--name <str>`. Optional human-readable container name; passed
    /// straight through to `state.allocate`.
    name: ?[]const u8 = null,
    /// `--rm`. Removes the container/bundle/overlay triplet on exit.
    rm: bool = false,
    /// `-e KEY=VAL` (repeatable). Raw entries; the bundle composer
    /// validates `KEY=VAL` shape via `error.InvalidEnv` so we don't
    /// double-validate in argparse.
    env: []const []const u8 = &.{},
    /// `--env-file <path>`. Read once in `run()` (I/O stays out of
    /// argparse) and merged with `env` before being handed to the
    /// orchestrator.
    env_file: ?[]const u8 = null,
    /// `-w/--workdir <dir>`. Working directory inside the container.
    workdir: ?[]const u8 = null,
    /// `-u/--user <spec>`. UID, UID:GID, or username (numeric only;
    /// see `bundle.parseUser`).
    user: ?[]const u8 = null,
    /// `--entrypoint <prog>`. Single-string override (matches Docker).
    /// Multi-arg entrypoints stay expressible by shifting args after
    /// `--` into `cmd`. Empty string drops the image's entrypoint
    /// entirely (per `bundle.RunOverrides`).
    entrypoint: ?[]const u8 = null,
    /// `--platform <plat>`. Host-only in MVP; rejected unless equal
    /// to `pull_cli.expected_platform`.
    platform: ?[]const u8 = null,
    /// `-v/--volume host:container[:ro]` (repeatable). Raw specs;
    /// `mount_spec.parseAll` turns them into `UserMount`s in `run()`.
    volumes: []const []const u8 = &.{},
    /// `-t/--tty`. Allocates a pty and switches stdin to raw mode.
    tty: bool = false,
};

/// Run-handler dependency injection. The CLI test seam wraps the
/// entire orchestrator (mirroring `pull_cli.PullDeps`) — it does NOT
/// pass through to `run_mod.RunDeps`. Production calls flow through
/// `runImageDefault`, which threads default `run_mod.RunDeps{}`. Test
/// stubs replace the whole body and never see the inner deps.
pub const RunDeps = struct {
    /// Defaults to `runImageDefault`. Stub returns a synthetic
    /// `RunResult` (or a `RunError`) and emits the event sequence
    /// directly via the supplied `progress_fn`.
    run_fn: *const fn (
        Io,
        Allocator,
        *layout.Store,
        run_mod.Env,
        []const u8,
        run_mod.RunOptions,
    ) run_mod.RunError!run_mod.RunResult = runImageDefault,
};

/// Production shim that supplies default inner `run_mod.RunDeps`. The
/// CLI test seam in `RunDeps.run_fn` stops here on production paths;
/// stubs never reach this function.
fn runImageDefault(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    env: run_mod.Env,
    ref_text: []const u8,
    opts: run_mod.RunOptions,
) run_mod.RunError!run_mod.RunResult {
    return run_mod.runImage(io, gpa, store, env, ref_text, opts, .{});
}

const params = clap.parseParamsComptime(
    \\-h, --help                  Display this help and exit.
    \\    --output <kind>         Output format: human (default) or json.
    \\    --name <str>            Assign a name to the container.
    \\    --rm                    Remove the container after it exits.
    \\-e, --env <str>...          Set an environment variable (KEY=VAL). Repeatable.
    \\    --env-file <str>        Read env vars from a file (KEY=VAL per line).
    \\-w, --workdir <str>         Working directory inside the container.
    \\-u, --user <str>            UID, UID:GID, or username.
    \\    --entrypoint <str>      Override the image entrypoint.
    \\    --platform <str>        Target platform (host-only in MVP).
    \\-v, --volume <str>...       Bind-mount host:container[:ro]. Repeatable.
    \\-i, --interactive           Keep stdin open (no-op today; stdin already inherits).
    \\-t, --tty                   Allocate a pseudo-terminal.
    \\<str>                       Image reference (e.g. alpine:3.19).
    \\<str>...                    Optional command + args to run.
    \\
);

const value_parsers = .{
    .str = clap.parsers.string,
    .kind = clap.parsers.enumeration(OutputKind),
};

/// One-line usage banner. Stable enough that scripts can grep it.
pub const usage_line: []const u8 = "Usage: rind run [--output human|json] [--name <n>] [--rm] [-e|--env KEY=VAL]... [--env-file <path>] [-w|--workdir <dir>] [-u|--user <spec>] [--entrypoint <prog>] [--platform <plat>] <image> [--] [cmd...]";

/// Parse argv (after the `run` subcommand has been peeled off) into a
/// validated `RunArgs`. `iter` is consumed; `gpa` backs clap's
/// internal arena and the dupes the result keeps after `res.deinit()`.
/// Returns `error.Usage` for any structural problem and writes a
/// one-line diagnostic to `err_writer`.
pub fn parseArgs(
    gpa: Allocator,
    iter: anytype,
    err_writer: *Io.Writer,
) !RunArgs {
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

    const image = res.positionals[0] orelse {
        try err_writer.print("{s}\n", .{usage_line});
        return error.Usage;
    };

    // Owned-by-arena strings would dangle once `res.deinit()` runs;
    // dupe out everything we want to keep on `gpa` so the caller can
    // call `freeArgs` symmetrically.
    const image_owned = try gpa.dupe(u8, image);
    errdefer gpa.free(image_owned);

    const cmd_src = res.positionals[1];
    var cmd_owned = try gpa.alloc([]const u8, cmd_src.len);
    var cmd_filled: usize = 0;
    errdefer {
        for (cmd_owned[0..cmd_filled]) |s| gpa.free(s);
        gpa.free(cmd_owned);
    }
    for (cmd_src) |s| {
        cmd_owned[cmd_filled] = try gpa.dupe(u8, s);
        cmd_filled += 1;
    }

    const env_src = res.args.env;
    var env_owned = try gpa.alloc([]const u8, env_src.len);
    var env_filled: usize = 0;
    errdefer {
        for (env_owned[0..env_filled]) |s| gpa.free(s);
        gpa.free(env_owned);
    }
    for (env_src) |s| {
        env_owned[env_filled] = try gpa.dupe(u8, s);
        env_filled += 1;
    }

    const env_file_owned: ?[]const u8 = if (res.args.@"env-file") |p|
        try gpa.dupe(u8, p)
    else
        null;
    errdefer if (env_file_owned) |p| gpa.free(p);

    const name_owned: ?[]const u8 = if (res.args.name) |n|
        try gpa.dupe(u8, n)
    else
        null;
    errdefer if (name_owned) |n| gpa.free(n);

    const workdir_owned: ?[]const u8 = if (res.args.workdir) |w|
        try gpa.dupe(u8, w)
    else
        null;
    errdefer if (workdir_owned) |w| gpa.free(w);

    const user_owned: ?[]const u8 = if (res.args.user) |u|
        try gpa.dupe(u8, u)
    else
        null;
    errdefer if (user_owned) |u| gpa.free(u);

    const entrypoint_owned: ?[]const u8 = if (res.args.entrypoint) |e|
        try gpa.dupe(u8, e)
    else
        null;
    errdefer if (entrypoint_owned) |e| gpa.free(e);

    const platform_owned: ?[]const u8 = if (res.args.platform) |p|
        try gpa.dupe(u8, p)
    else
        null;
    errdefer if (platform_owned) |p| gpa.free(p);

    const vol_src = res.args.volume;
    var volumes_owned = try gpa.alloc([]const u8, vol_src.len);
    var volumes_filled: usize = 0;
    errdefer {
        for (volumes_owned[0..volumes_filled]) |s| gpa.free(s);
        gpa.free(volumes_owned);
    }
    for (vol_src) |s| {
        volumes_owned[volumes_filled] = try gpa.dupe(u8, s);
        volumes_filled += 1;
    }

    return .{
        .image = image_owned,
        .cmd = cmd_owned,
        .output = res.args.output orelse .human,
        .name = name_owned,
        .rm = res.args.rm != 0,
        .env = env_owned,
        .env_file = env_file_owned,
        .workdir = workdir_owned,
        .user = user_owned,
        .entrypoint = entrypoint_owned,
        .platform = platform_owned,
        .volumes = volumes_owned,
        .tty = res.args.tty != 0,
    };
}

/// Free strings owned by `args`. Mirrors the dupes done in
/// `parseArgs`; `gpa` must be the same allocator.
pub fn freeArgs(gpa: Allocator, args: RunArgs) void {
    gpa.free(args.image);
    for (args.cmd) |s| gpa.free(s);
    gpa.free(args.cmd);
    for (args.env) |s| gpa.free(s);
    gpa.free(args.env);
    if (args.env_file) |p| gpa.free(p);
    if (args.name) |n| gpa.free(n);
    if (args.workdir) |w| gpa.free(w);
    if (args.user) |u| gpa.free(u);
    if (args.entrypoint) |e| gpa.free(e);
    if (args.platform) |p| gpa.free(p);
    for (args.volumes) |v| gpa.free(v);
    gpa.free(args.volumes);
}

/// Cap on an `--env-file` read. 1 MiB is generous; Docker's docs
/// don't specify a limit, but env files in the wild are KB.
const env_file_max_bytes: usize = 1 << 20;

/// Read `path` as a Docker-style env file: `KEY=VAL` per line, lines
/// starting with `#` (after whitespace trim) are comments, blank
/// lines are skipped. No `\` continuations, no quoting. Each
/// surviving line is duped onto `gpa`; on error the partial set is
/// freed. The bundle composer revalidates each entry's `KEY=VAL`
/// shape — this loader is only structural.
fn loadEnvFile(io: Io, gpa: Allocator, path: []const u8) ![]const []const u8 {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(env_file_max_bytes));
    defer gpa.free(text);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |it| gpa.free(it);
        list.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        try list.append(gpa, try gpa.dupe(u8, line));
    }
    return try list.toOwnedSlice(gpa);
}

/// Run the container. The renderer is invoked for each progress event,
/// once for the success summary, and once for an error message on
/// failure. Errors propagate; `main.zig` maps them to exit codes.
///
/// Returns the `u8` exit code the rind binary should exit with on the
/// success path. Convention follows POSIX/bash/Docker/runc:
/// `result.exit_code` when the container exited normally, or
/// `128 + result.signal` when it was terminated by a signal. Errors are
/// signalled the usual way (typed return); `main.zig` maps those
/// through `cli_exit.mapErrorToExitCode`.
pub fn run(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    env: run_mod.Env,
    args: RunArgs,
    out: *output.Renderer,
    deps: RunDeps,
) !u8 {
    if (args.platform) |p| {
        if (!std.mem.eql(u8, p, pull_cli.expected_platform)) {
            try out.on_error(out.ctx, "unsupported --platform (host-only in MVP)");
            return error.UnsupportedPlatform;
        }
    }

    // Build the merged env slice: `--env-file` lines first, then
    // `-e` flags. Docker's last-write-wins semantics for KEY
    // collisions are enforced inside `bundle.mergeEnv`, so order
    // here just decides which side wins on duplicates (CLI flags
    // win, mirroring Docker).
    var env_from_file: []const []const u8 = &.{};
    defer {
        for (env_from_file) |s| gpa.free(s);
        if (env_from_file.len != 0) gpa.free(env_from_file);
    }
    if (args.env_file) |path| {
        env_from_file = loadEnvFile(io, gpa, path) catch |err| {
            try out.on_error(out.ctx, @errorName(err));
            return err;
        };
    }

    const merged_env = try gpa.alloc([]const u8, env_from_file.len + args.env.len);
    defer gpa.free(merged_env);
    @memcpy(merged_env[0..env_from_file.len], env_from_file);
    @memcpy(merged_env[env_from_file.len..], args.env);

    const entrypoint_override: ?[]const []const u8 = if (args.entrypoint) |e|
        if (e.len == 0) &.{} else &[_][]const u8{e}
    else
        null;

    const cmd_override: ?[]const []const u8 = if (args.cmd.len == 0) null else args.cmd;

    const user_mounts = mount_spec.parseAll(io, gpa, args.volumes) catch |err| {
        try out.on_error(out.ctx, @errorName(err));
        return err;
    };
    defer mount_spec.freeAll(gpa, user_mounts);

    const overrides: bundle_mod.RunOverrides = .{
        .entrypoint = entrypoint_override,
        .cmd = cmd_override,
        .env = merged_env,
        .workdir = args.workdir,
        .user = args.user,
        .mounts = user_mounts,
        .tty = args.tty,
    };

    var trampoline_ctx: TrampolineCtx = .{ .renderer = out };
    const opts: run_mod.RunOptions = .{
        .rm = args.rm,
        .name = args.name,
        .overrides = overrides,
        .progress_ctx = @ptrCast(&trampoline_ctx),
        .progress_fn = trampoline,
    };

    const result = deps.run_fn(io, gpa, store, env, args.image, opts) catch |err| {
        try out.on_error(out.ctx, @errorName(err));
        return err;
    };

    try out.on_run_summary(out.ctx, .{ .ref = args.image, .result = &result });

    return if (result.signal != 0) 128 +% result.signal else result.exit_code;
}

/// Trampoline state. `runImage` is single-threaded so no mutex is
/// needed (in contrast to `pull_cli.TrampolineCtx`, which serialises
/// against worker pools).
const TrampolineCtx = struct {
    renderer: *output.Renderer,
};

fn trampoline(ctx: ?*anyopaque, ev: run_mod.RunEvent) void {
    const self: *TrampolineCtx = @ptrCast(@alignCast(ctx.?));
    self.renderer.on_run_event(self.renderer.ctx, ev) catch {};
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

fn parseFromSlice(gpa: Allocator, argv: []const []const u8, err_writer: *Io.Writer) !RunArgs {
    var iter: SliceIter = .{ .items = argv };
    return parseArgs(gpa, &iter, err_writer);
}

test "parseArgs accepts bare image" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(gpa, &.{"alpine:3.19"}, &err_buf.writer);
    defer freeArgs(gpa, a);

    try testing.expectEqualStrings("alpine:3.19", a.image);
    try testing.expectEqual(@as(usize, 0), a.cmd.len);
    try testing.expectEqual(OutputKind.human, a.output);
    try testing.expect(!a.rm);
    try testing.expectEqual(@as(?[]const u8, null), a.name);
}

test "parseArgs accepts image plus cmd args" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(gpa, &.{ "alpine", "echo", "hi" }, &err_buf.writer);
    defer freeArgs(gpa, a);

    try testing.expectEqualStrings("alpine", a.image);
    try testing.expectEqual(@as(usize, 2), a.cmd.len);
    try testing.expectEqualStrings("echo", a.cmd[0]);
    try testing.expectEqualStrings("hi", a.cmd[1]);
}

test "parseArgs accepts image + -- + dash-prefixed cmd args" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(
        gpa,
        &.{ "alpine", "--", "echo", "-n", "hi" },
        &err_buf.writer,
    );
    defer freeArgs(gpa, a);

    try testing.expectEqual(@as(usize, 3), a.cmd.len);
    try testing.expectEqualStrings("echo", a.cmd[0]);
    try testing.expectEqualStrings("-n", a.cmd[1]);
    try testing.expectEqualStrings("hi", a.cmd[2]);
}

test "parseArgs accepts repeatable -e" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(
        gpa,
        &.{ "-e", "FOO=1", "-e", "BAR=2", "alpine" },
        &err_buf.writer,
    );
    defer freeArgs(gpa, a);

    try testing.expectEqual(@as(usize, 2), a.env.len);
    try testing.expectEqualStrings("FOO=1", a.env[0]);
    try testing.expectEqualStrings("BAR=2", a.env[1]);
}

test "parseArgs accepts --rm with --name" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(
        gpa,
        &.{ "--rm", "--name", "tinker", "alpine" },
        &err_buf.writer,
    );
    defer freeArgs(gpa, a);

    try testing.expect(a.rm);
    try testing.expectEqualStrings("tinker", a.name.?);
}

test "parseArgs accepts --output json" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(
        gpa,
        &.{ "--output", "json", "alpine" },
        &err_buf.writer,
    );
    defer freeArgs(gpa, a);
    try testing.expectEqual(OutputKind.json, a.output);
}

test "parseArgs accepts --platform that matches host" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(
        gpa,
        &.{ "--platform", pull_cli.expected_platform, "alpine" },
        &err_buf.writer,
    );
    defer freeArgs(gpa, a);
    try testing.expect(a.platform != null);
}

test "parseArgs accepts all flags together" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(gpa, &.{
        "--output",                 "json",
        "--name",                   "foo",
        "--rm",                     "-e",
        "FOO=1",                    "--env-file",
        "/tmp/x.env",               "-w",
        "/srv",                     "-u",
        "1000:1000",                "--entrypoint",
        "sh",                       "--platform",
        pull_cli.expected_platform, "alpine:3.19",
        "echo",                     "hi",
    }, &err_buf.writer);
    defer freeArgs(gpa, a);

    try testing.expectEqual(OutputKind.json, a.output);
    try testing.expectEqualStrings("foo", a.name.?);
    try testing.expect(a.rm);
    try testing.expectEqual(@as(usize, 1), a.env.len);
    try testing.expectEqualStrings("/tmp/x.env", a.env_file.?);
    try testing.expectEqualStrings("/srv", a.workdir.?);
    try testing.expectEqualStrings("1000:1000", a.user.?);
    try testing.expectEqualStrings("sh", a.entrypoint.?);
    try testing.expectEqualStrings("alpine:3.19", a.image);
    try testing.expectEqual(@as(usize, 2), a.cmd.len);
}

test "parseArgs accepts --entrypoint sh" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{ "--entrypoint", "sh", "alpine" }, &err_buf.writer);
    defer freeArgs(gpa, a);
    try testing.expectEqualStrings("sh", a.entrypoint.?);
}

test "parseArgs accepts --env-file <path> without I/O" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    // Path doesn't have to exist — argparse never opens it.
    const a = try parseFromSlice(gpa, &.{ "--env-file", "/does/not/exist", "alpine" }, &err_buf.writer);
    defer freeArgs(gpa, a);
    try testing.expectEqualStrings("/does/not/exist", a.env_file.?);
}

test "parseArgs rejects missing positional" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{}, &err_buf.writer));
}

test "parseArgs rejects unknown flag" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(
        error.Usage,
        parseFromSlice(gpa, &.{ "--bogus", "alpine" }, &err_buf.writer),
    );
}

test "parseArgs rejects unknown --output value" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(
        error.Usage,
        parseFromSlice(gpa, &.{ "--output", "bogus", "alpine" }, &err_buf.writer),
    );
}

test "parseArgs --help is treated as a usage exit" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(
        error.Usage,
        parseFromSlice(gpa, &.{"--help"}, &err_buf.writer),
    );
}

test "loadEnvFile parses KEY=VAL lines, skips comments and blanks" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\# leading comment
        \\
        \\FOO=1
        \\BAR=two
        \\   # indented comment
        \\
        \\BAZ=val#with#hash
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "env.list", .data = body });

    var path_buf: [256]u8 = undefined;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const full = try std.fmt.bufPrint(&path_buf, "{s}/.zig-cache/tmp/{s}/env.list", .{ cwd, tmp.sub_path });

    const lines = try loadEnvFile(io, gpa, full);
    defer {
        for (lines) |l| gpa.free(l);
        gpa.free(lines);
    }

    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("FOO=1", lines[0]);
    try testing.expectEqualStrings("BAR=two", lines[1]);
    try testing.expectEqualStrings("BAZ=val#with#hash", lines[2]);
}

test "loadEnvFile handles missing trailing newline" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "env.list", .data = "FOO=1\nBAR=2" });

    var path_buf: [256]u8 = undefined;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const full = try std.fmt.bufPrint(&path_buf, "{s}/.zig-cache/tmp/{s}/env.list", .{ cwd, tmp.sub_path });

    const lines = try loadEnvFile(io, gpa, full);
    defer {
        for (lines) |l| gpa.free(l);
        gpa.free(lines);
    }
    try testing.expectEqual(@as(usize, 2), lines.len);
}

test "loadEnvFile surfaces FileNotFound for missing path" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testing.expectError(error.FileNotFound, loadEnvFile(io, gpa, "/does/not/exist.env"));
}

const StubState = struct {
    return_err: ?run_mod.RunError = null,
    exit_code: u8 = 0,
    signal: u8 = 0,
};

threadlocal var stub_state: StubState = .{};

fn stubRunSuccess(
    _: Io,
    _: Allocator,
    _: *layout.Store,
    _: run_mod.Env,
    ref_text: []const u8,
    opts: run_mod.RunOptions,
) run_mod.RunError!run_mod.RunResult {
    if (stub_state.return_err) |e| return e;

    const id = [12]u8{ 'a', 'b', 'c', '1', '2', '3', 'd', 'e', 'f', '4', '5', '6' };
    if (opts.progress_fn) |f| {
        f(opts.progress_ctx, .{ .run_started = .{ .ref = ref_text, .id = id } });
        f(opts.progress_ctx, .overlay_mounted);
        f(opts.progress_ctx, .bundle_ready);
        f(opts.progress_ctx, .{ .started = .{ .pid = 0 } });
        f(opts.progress_ctx, .{ .exited = .{ .code = stub_state.exit_code, .signal = stub_state.signal } });
        if (opts.rm) f(opts.progress_ctx, .removed);
    }
    return .{
        .container_id = id,
        .exit_code = stub_state.exit_code,
        .signal = stub_state.signal,
        .removed = opts.rm,
    };
}

fn dummyStore(io: Io, tmp: *std.testing.TmpDir) !layout.Store {
    return try layout.Store.init(io, tmp.dir, "store");
}

test "run drives renderer and reports success — human" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try dummyStore(io, &tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    stub_state = .{};
    const args: RunArgs = .{ .image = "alpine:3.19" };
    const code = try run(
        io,
        gpa,
        &store,
        .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
        args,
        &r,
        .{ .run_fn = stubRunSuccess },
    );

    try testing.expectEqual(@as(u8, 0), code);
    // Default human renderer is silent — container stdout is the only
    // thing rind itself writes (none here, the stub doesn't simulate
    // it). Run progress lives behind `RIND_LOG=rind=debug`.
    try testing.expectEqual(@as(usize, 0), out_buf.written().len);
}

test "run drives renderer and reports success — JSON snapshot" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try dummyStore(io, &tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var json_renderer: output.Json = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
    };
    var r = json_renderer.renderer();

    stub_state = .{};
    const args: RunArgs = .{ .image = "alpine:3.19", .rm = true };
    _ = try run(
        io,
        gpa,
        &store,
        .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
        args,
        &r,
        .{ .run_fn = stubRunSuccess },
    );

    const expected_events = @embedFile("testdata/run_events.ndjson");
    try testing.expect(std.mem.startsWith(u8, out_buf.written(), expected_events));
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"event\":\"run_summary\"") != null);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"container_id\":\"abc123def456\"") != null);
}

test "run surfaces ImageNotPresent" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try dummyStore(io, &tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    stub_state = .{ .return_err = error.ImageNotPresent };
    try testing.expectError(error.ImageNotPresent, run(
        io,
        gpa,
        &store,
        .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
        .{ .image = "alpine:missing" },
        &r,
        .{ .run_fn = stubRunSuccess },
    ));
    try testing.expectEqual(exit.Code.usage, exit.mapErrorToExitCode(error.ImageNotPresent));
    try testing.expect(std.mem.indexOf(u8, err_buf.written(), "ImageNotPresent") != null);
    stub_state = .{};
}

test "run surfaces RuntimeError.LibcrunFailure" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try dummyStore(io, &tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    stub_state = .{ .return_err = error.LibcrunFailure };
    try testing.expectError(error.LibcrunFailure, run(
        io,
        gpa,
        &store,
        .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
        .{ .image = "alpine:3.19" },
        &r,
        .{ .run_fn = stubRunSuccess },
    ));
    try testing.expectEqual(exit.Code.generic, exit.mapErrorToExitCode(error.LibcrunFailure));
    stub_state = .{};
}

test "run surfaces UnsupportedPlatform on non-host platform" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try dummyStore(io, &tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    const args: RunArgs = .{ .image = "alpine:3.19", .platform = "windows/i386" };
    try testing.expectError(error.UnsupportedPlatform, run(
        io,
        gpa,
        &store,
        .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
        args,
        &r,
        .{ .run_fn = stubRunSuccess },
    ));
    try testing.expectEqual(exit.Code.usage, exit.mapErrorToExitCode(error.UnsupportedPlatform));
    try testing.expect(std.mem.indexOf(u8, err_buf.written(), "unsupported --platform") != null);
}

test "run --rm emits removed event and reports removed=true in summary" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try dummyStore(io, &tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    stub_state = .{};
    _ = try run(
        io,
        gpa,
        &store,
        .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
        .{ .image = "alpine:3.19", .rm = true },
        &r,
        .{ .run_fn = stubRunSuccess },
    );
    // Default human is silent. The `removed` event still flows through
    // the JSON renderer (verified in the JSON snapshot test above).
    try testing.expectEqual(@as(usize, 0), out_buf.written().len);
}

test "run forwards orchestrator errors and maps to exit codes" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try dummyStore(io, &tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    const cases = [_]struct {
        err: run_mod.RunError,
        code: exit.Code,
    }{
        .{ .err = error.ImageNotPresent, .code = .usage },
        .{ .err = error.LibcrunFailure, .code = .generic },
        .{ .err = error.BundleNotFound, .code = .generic },
        .{ .err = error.InvalidConfig, .code = .generic },
        .{ .err = error.InvalidEnv, .code = .usage },
    };
    for (cases) |c| {
        stub_state = .{ .return_err = c.err };
        const r_err = run(
            io,
            gpa,
            &store,
            .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
            .{ .image = "alpine:3.19" },
            &r,
            .{ .run_fn = stubRunSuccess },
        );
        try testing.expectError(c.err, r_err);
        try testing.expectEqual(c.code, exit.mapErrorToExitCode(c.err));
    }
    stub_state = .{};
}

fn runOnceAndGetCode(
    io: Io,
    gpa: Allocator,
    tmp: *std.testing.TmpDir,
    exit_code: u8,
    signal: u8,
) !u8 {
    var store = try dummyStore(io, tmp);
    defer store.close(io);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    stub_state = .{ .exit_code = exit_code, .signal = signal };
    defer stub_state = .{};
    return try run(
        io,
        gpa,
        &store,
        .{ .root_dir = tmp.dir, .root_abspath = "/tmp/dummy" },
        .{ .image = "alpine:3.19" },
        &r,
        .{ .run_fn = stubRunSuccess },
    );
}

test "run propagates non-zero exit code verbatim" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectEqual(@as(u8, 42), try runOnceAndGetCode(io, gpa, &tmp, 42, 0));
}

test "run encodes signal exit as 128 + signal (POSIX)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // SIGKILL (9) → 137; matches bash, Docker, runc.
    try testing.expectEqual(@as(u8, 137), try runOnceAndGetCode(io, gpa, &tmp, 0, 9));
    // SIGTERM (15) → 143.
    try testing.expectEqual(@as(u8, 143), try runOnceAndGetCode(io, gpa, &tmp, 0, 15));
}

test "run reports 0 on clean exit" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectEqual(@as(u8, 0), try runOnceAndGetCode(io, gpa, &tmp, 0, 0));
}
