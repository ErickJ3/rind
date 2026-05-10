//! Layer-cache-key derivation regression harness.
//!
//! Reads `<cases-dir>/Containerfile`, parses it, opens
//! `<cases-dir>/context/` as the build context, threads a synthetic
//! StepEnv state machine across the parsed instructions, calls
//! `cache_key.derive` at each step, and either:
//!   * writes `expected_keys.json` next to the input when `--update` is
//!     passed; or
//!   * byte-compares the produced JSON against the committed golden and
//!     exits 1 on drift, printing both forms to stderr.
//!
//! State machine rules (kept minimal until T35 lands):
//!   * FROM resets env to empty, shell to `/bin/sh -c`.
//!   * ENV merges entries into env (parser already split K=V form).
//!   * ARG with a default value merges as an env entry.
//!   * SHELL replaces the active shell argv.
//!   * Each instruction's derived key becomes the next instruction's
//!     parent so the chain is reproducible end-to-end.
//!   * Build context is forwarded as `ctx_arg` only for COPY/ADD.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rind = @import("rind");
const cache_key = rind.Builder.cache_key;
const context_mod = rind.Builder.context;
const digest_mod = rind.Image.digest;
const parse = rind.Builder.parse;

const usage_text =
    "Usage: cache-key-harness --cases-dir <path> [--update]\n";

const containerfile_byte_limit: Io.Limit = .limited(1 << 20);
const golden_byte_limit: Io.Limit = .limited(1 << 20);
const default_shell_argv: []const []const u8 = &.{ "/bin/sh", "-c" };

const Args = struct {
    cases_dir: []const u8,
    update: bool,
};

fn parseArgs(argv: []const []const u8) !Args {
    var cases_dir: ?[]const u8 = null;
    var update = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--update")) {
            update = true;
        } else if (std.mem.eql(u8, a, "--cases-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgValue;
            cases_dir = argv[i];
        } else {
            return error.UnexpectedArg;
        }
    }
    return .{
        .cases_dir = cases_dir orelse return error.MissingCasesDir,
        .update = update,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4 * 1024]u8 = undefined;
    var stderr_buf: [4 * 1024]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stdout = &stdout_fw.interface;
    const stderr = &stderr_fw.interface;

    const args = parseArgs(argv) catch {
        try stderr.writeAll(usage_text);
        stderr.flush() catch {};
        std.process.exit(2);
    };

    var cases_dir = Io.Dir.cwd().openDir(io, args.cases_dir, .{}) catch |err| {
        try stderr.print(
            "cache-key-harness: cannot open cases dir '{s}': {s}\n",
            .{ args.cases_dir, @errorName(err) },
        );
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer cases_dir.close(io);

    const src = cases_dir.readFileAlloc(io, "Containerfile", gpa, containerfile_byte_limit) catch |err| {
        try stderr.print(
            "cache-key-harness: cannot read Containerfile: {s}\n",
            .{@errorName(err)},
        );
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer gpa.free(src);

    var ctx_dir = cases_dir.openDir(io, "context", .{ .iterate = true }) catch |err| {
        try stderr.print(
            "cache-key-harness: cannot open context dir '{s}/context': {s}\n",
            .{ args.cases_dir, @errorName(err) },
        );
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer ctx_dir.close(io);

    var ctx = context_mod.load(io, gpa, ctx_dir) catch |err| {
        try stderr.print(
            "cache-key-harness: context.load failed: {s}\n",
            .{@errorName(err)},
        );
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const result = parse.parse(arena.allocator(), src) catch |err| {
        try stderr.print(
            "cache-key-harness: parse failed: {s}\n",
            .{@errorName(err)},
        );
        stderr.flush() catch {};
        std.process.exit(1);
    };

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try emitChain(gpa, &aw.writer, result.instructions, &ctx);
    const actual = aw.written();

    if (args.update) {
        try writeAtomic(io, cases_dir, "expected_keys.json", actual);
        try stdout.print("UPD  {s}/expected_keys.json\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    const expected = cases_dir.readFileAlloc(io, "expected_keys.json", gpa, golden_byte_limit) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print(
                "cache-key-harness: golden 'expected_keys.json' missing in '{s}' (rerun with -Dupdate-goldens=true)\n",
                .{args.cases_dir},
            );
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer gpa.free(expected);

    if (std.mem.eql(u8, expected, actual)) {
        try stdout.print("OK   cache_key_smoke ({s})\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    try stderr.print(
        "FAIL cache_key_smoke: expected_keys.json drift in '{s}'\n",
        .{args.cases_dir},
    );
    try stderr.writeAll("--- expected ---\n");
    try stderr.writeAll(expected);
    try stderr.writeAll("\n--- actual ---\n");
    try stderr.writeAll(actual);
    try stderr.writeAll("\n");
    stderr.flush() catch {};
    std.process.exit(1);
}

fn writeAtomic(io: Io, dir: Io.Dir, rel_path: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, rel_path, .{ .replace = true });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    fw.interface.writeAll(bytes) catch return fw.err.?;
    fw.interface.flush() catch return fw.err.?;
    try atomic.replace(io);
}

fn emitChain(
    gpa: Allocator,
    w: *Io.Writer,
    instrs: []const parse.Instruction,
    ctx: *const context_mod.Context,
) !void {
    var env_list: std.ArrayList(parse.KeyValue) = .empty;
    defer env_list.deinit(gpa);
    var shell: []const []const u8 = default_shell_argv;
    var parent: cache_key.Key = digest_mod.Hasher.hash("").bytes;

    try w.writeByte('[');
    for (instrs, 0..) |ins, idx| {
        switch (ins) {
            .from => {
                env_list.clearRetainingCapacity();
                shell = default_shell_argv;
            },
            .env => |v| {
                for (v.entries) |kv| try env_list.append(gpa, kv);
            },
            .arg => |v| {
                if (v.default) |def| {
                    try env_list.append(gpa, .{ .key = v.name, .value = def });
                }
            },
            .shell => |v| {
                shell = v.values;
            },
            else => {},
        }

        const step_env: cache_key.StepEnv = .{
            .vars = env_list.items,
            .shell = shell,
        };
        const ctx_arg: ?*const context_mod.Context = switch (ins) {
            .copy, .add => ctx,
            else => null,
        };
        const key = try cache_key.derive(gpa, parent, ins, step_env, ctx_arg);

        if (idx != 0) try w.writeByte(',');
        try w.writeByte('{');
        try w.writeAll("\"directive\":");
        try std.json.Stringify.encodeJsonString(@tagName(ins), .{}, w);
        try w.print(",\"index\":{d}", .{idx});
        try w.writeAll(",\"key\":\"sha256:");
        const hex = std.fmt.bytesToHex(key, .lower);
        try w.writeAll(&hex);
        try w.writeAll("\"}");

        parent = key;
    }
    try w.writeByte(']');
}

const testing = std.testing;

test "parseArgs: --cases-dir + --update" {
    const argv = [_][]const u8{ "cache-key-harness", "--cases-dir", "tests/cache_key_cases/cache_key_smoke", "--update" };
    const a = try parseArgs(argv[0..]);
    try testing.expectEqualStrings("tests/cache_key_cases/cache_key_smoke", a.cases_dir);
    try testing.expect(a.update);
}

test "parseArgs: missing cases-dir errors" {
    const argv = [_][]const u8{"cache-key-harness"};
    try testing.expectError(error.MissingCasesDir, parseArgs(argv[0..]));
}
