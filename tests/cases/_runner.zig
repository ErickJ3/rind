//! Regression scenario runner.
//!
//! Walks `tests/cases/<scenario>/`, executes each scenario through the
//! built `rind` binary, and diffs the captured stdout/stderr/exit and
//! any produced files against `expected_*` goldens.
//!
//! Discovery rule: dir entries only (files at the cases-root are
//! skipped, including this `_runner.zig` after it is built into the
//! harness binary). The literal name `_runner` is also rejected as a
//! defensive guard against an accidental harness-output dir. Other
//! `_<name>/` dirs are treated as ordinary scenarios, the bootstrap
//! `_smoke/` fixture is the canonical example.
//!
//! Diff modes per `expected_files[].kind`:
//!   - `bytes`: `std.mem.eql`.
//!   - `json` : both sides canonicalised (sorted object keys, no
//!     insignificant whitespace) then byte-compared. `std.json.Stringify`
//!     does not sort keys (see `src/cli/output.zig`'s comment), so the
//!     canonicaliser below is rolled by hand.
//!
//! Sequential by design. Parallel exec is deferred to a future polish
//! task; readable transcripts win at this milestone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Errors a scenario run may surface to the caller. Composed at use
/// sites with `std.fs`/`std.process`/`std.json` error sets; only this
/// narrow set is exposed publicly so the harness's exit reasons stay
/// stable.
pub const RegressionError = error{
    ScenarioMalformed,
    ScenarioMissingFile,
    ExitMismatch,
    OutputMismatch,
};

/// Environment override entry inside `scenario.json`'s `env` array.
pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// One produced-file assertion. `path` is read from the scenario dir
/// after the run; `golden` is the expected-content file in the same
/// dir; `kind` selects byte-equal vs canonical-JSON compare.
pub const ExpectedFile = struct {
    path: []const u8,
    golden: []const u8,
    kind: Kind,

    pub const Kind = enum { bytes, json };
};

/// Parsed contents of a scenario's `scenario.json`.
pub const ScenarioConfig = struct {
    name: []const u8,
    argv: []const []const u8,
    env: ?[]const KV = null,
    expected_exit: u8 = 0,
    expected_stdout: ?[]const u8 = null,
    expected_stderr: ?[]const u8 = null,
    expected_files: ?[]const ExpectedFile = null,
};

/// Live scenario handle. Owns the arena that backs every slice
/// reachable from `config`. Caller must call `deinit` to release it.
pub const Scenario = struct {
    name: []const u8,
    dir: Io.Dir,
    config: ScenarioConfig,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Scenario, io: Io) void {
        self.dir.close(io);
        self.arena.deinit();
    }
};

/// Result of a single diff. `byte_mismatch` and `json_mismatch` carry
/// owned slices the caller must free (golden updates write the
/// `actual` side; canonical forms are emitted on the JSON branch).
pub const DiffResult = union(enum) {
    equal,
    byte_mismatch: ByteMismatch,
    json_mismatch: JsonMismatch,

    pub const ByteMismatch = struct {
        expected: []const u8,
        actual: []const u8,
    };

    pub const JsonMismatch = struct {
        expected_canonical: []u8,
        actual_canonical: []u8,
    };

    pub fn deinit(self: DiffResult, gpa: Allocator) void {
        switch (self) {
            .equal, .byte_mismatch => {},
            .json_mismatch => |m| {
                gpa.free(m.expected_canonical);
                gpa.free(m.actual_canonical);
            },
        }
    }
};

/// Captured output of one `runScenario` invocation. Caller owns
/// `stdout`/`stderr`; release via `deinit`.
pub const RunOutcome = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *RunOutcome, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

const stdout_byte_limit: Io.Limit = .limited(8 * 1024 * 1024);
const stderr_byte_limit: Io.Limit = .limited(8 * 1024 * 1024);
const golden_byte_limit: Io.Limit = .limited(8 * 1024 * 1024);
const scenario_json_byte_limit: Io.Limit = .limited(256 * 1024);

/// Walk `cases_root` for scenario subdirectories. Returns lex-sorted
/// basenames. Files are ignored; the literal name `_runner` is
/// rejected. Caller owns the outer slice and every inner string
/// (allocated through `gpa`).
pub fn discover(io: Io, gpa: Allocator, cases_root: Io.Dir) ![][]const u8 {
    var names: std.array_list.Managed([]const u8) = .init(gpa);
    errdefer {
        for (names.items) |s| gpa.free(s);
        names.deinit();
    }

    var it = cases_root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "_runner")) continue;
        try names.append(try gpa.dupe(u8, entry.name));
    }

    const owned = try names.toOwnedSlice();
    std.mem.sort([]const u8, owned, {}, lessThanSlice);
    return owned;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Open `<cases_root>/<name>/`, parse `scenario.json`. Maps missing
/// files to `error.ScenarioMissingFile` and JSON errors (parse,
/// unknown-field) to `error.ScenarioMalformed`.
pub fn loadScenario(
    io: Io,
    gpa: Allocator,
    cases_root: Io.Dir,
    name: []const u8,
) !Scenario {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var dir = cases_root.openDir(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ScenarioMissingFile,
        else => |e| return e,
    };
    errdefer dir.close(io);

    const aa = arena.allocator();
    const json_bytes = dir.readFileAlloc(io, "scenario.json", aa, scenario_json_byte_limit) catch |err| switch (err) {
        error.FileNotFound => return error.ScenarioMissingFile,
        else => |e| return e,
    };

    const config = std.json.parseFromSliceLeaky(
        ScenarioConfig,
        aa,
        json_bytes,
        .{ .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" },
    ) catch return error.ScenarioMalformed;

    return .{
        .name = try aa.dupe(u8, name),
        .dir = dir,
        .config = config,
        .arena = arena,
    };
}

/// Optional knobs for `runScenario`. Currently only the spawn
/// timeout; expanded as future tasks need it.
pub const RunOpts = struct {
    timeout: Io.Timeout = .none,
};

/// Spawn `rind_bin_path` with the scenario's argv, in the scenario
/// dir, capture stdout/stderr/exit. The harness binary must own
/// `rind_bin_path` long enough for the child to exec it.
pub fn runScenario(
    io: Io,
    gpa: Allocator,
    scenario: *const Scenario,
    rind_bin_path: []const u8,
    opts: RunOpts,
) !RunOutcome {
    var argv: std.array_list.Managed([]const u8) = .init(gpa);
    defer argv.deinit();
    try argv.append(rind_bin_path);
    try argv.appendSlice(scenario.config.argv);

    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = scenario.dir },
        .stdout_limit = stdout_byte_limit,
        .stderr_limit = stderr_byte_limit,
        .timeout = opts.timeout,
    });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal => |sig| @intCast(@as(u32, 128) +% @intFromEnum(sig)),
        .stopped => |sig| @intCast(@as(u32, 128) +% @intFromEnum(sig)),
        .unknown => 255,
    };

    return .{
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Byte-equal compare. Cheap; used for stdout/stderr/`bytes` files.
pub fn diffBytes(expected: []const u8, actual: []const u8) DiffResult {
    if (std.mem.eql(u8, expected, actual)) return .equal;
    return .{ .byte_mismatch = .{ .expected = expected, .actual = actual } };
}

/// Canonicalise both sides then byte-compare. `expected`/`actual`
/// must parse as JSON; otherwise the underlying parser error is
/// returned. On `.json_mismatch`, both canonical forms are owned by
/// the caller (free with `DiffResult.deinit`).
pub fn diffJson(gpa: Allocator, expected: []const u8, actual: []const u8) !DiffResult {
    const expected_canon = try canonicalizeJson(gpa, expected);
    errdefer gpa.free(expected_canon);
    const actual_canon = try canonicalizeJson(gpa, actual);
    errdefer gpa.free(actual_canon);

    if (std.mem.eql(u8, expected_canon, actual_canon)) {
        gpa.free(expected_canon);
        gpa.free(actual_canon);
        return .equal;
    }
    return .{ .json_mismatch = .{
        .expected_canonical = expected_canon,
        .actual_canonical = actual_canon,
    } };
}

/// Re-emit `bytes` as canonical JSON: keys sorted lexically, no
/// insignificant whitespace, integers as decimal, strings escaped
/// per `std.json.Stringify.encodeJsonString`. Non-finite floats are
/// rejected (canonical JSON forbids `NaN`/`Inf`). Caller owns the
/// returned slice.
pub fn canonicalizeJson(gpa: Allocator, bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();

    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    try emitCanonical(gpa, parsed.value, &aw.writer);
    return aw.toOwnedSlice();
}

fn emitCanonical(gpa: Allocator, value: std.json.Value, w: *Io.Writer) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (!std.math.isFinite(f)) return error.NonFiniteFloat;
            try w.print("{d}", .{f});
        },
        .number_string => |s| try w.writeAll(s),
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i != 0) try w.writeByte(',');
                try emitCanonical(gpa, item, w);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            const keys = try sortedKeys(gpa, obj);
            defer gpa.free(keys);

            try w.writeByte('{');
            for (keys, 0..) |k, i| {
                if (i != 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(k, .{}, w);
                try w.writeByte(':');
                try emitCanonical(gpa, obj.get(k).?, w);
            }
            try w.writeByte('}');
        },
    }
}

fn sortedKeys(gpa: Allocator, obj: std.json.ObjectMap) ![][]const u8 {
    const keys = try gpa.alloc([]const u8, obj.count());
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, lessThanSlice);
    return keys;
}

/// Atomically write `new_bytes` to `<dir>/<rel_path>`, creating the
/// file if absent. Mirrors the `createFileAtomic` pattern at
/// `src/store/layout.zig:342`.
pub fn updateGolden(io: Io, dir: Io.Dir, rel_path: []const u8, new_bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, rel_path, .{ .replace = true });
    defer atomic.deinit(io);

    var buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    fw.interface.writeAll(new_bytes) catch return fw.err.?;
    fw.interface.flush() catch return fw.err.?;

    try atomic.replace(io);
}

const Args = struct {
    rind_bin_path: []const u8,
    cases_dir: []const u8,
    update_goldens: bool,
};

const usage =
    "Usage: regression-runner <rind_bin_path> --cases-dir <path> [--update-goldens]\n";

fn parseArgs(argv: []const []const u8) !Args {
    var rind_bin_path: ?[]const u8 = null;
    var cases_dir: ?[]const u8 = null;
    var update_goldens = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--update-goldens")) {
            update_goldens = true;
        } else if (std.mem.eql(u8, a, "--cases-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgValue;
            cases_dir = argv[i];
        } else if (rind_bin_path == null) {
            rind_bin_path = a;
        } else {
            return error.UnexpectedArg;
        }
    }

    return .{
        .rind_bin_path = rind_bin_path orelse return error.MissingRindBinPath,
        .cases_dir = cases_dir orelse return error.MissingCasesDir,
        .update_goldens = update_goldens,
    };
}

const FailReason = union(enum) {
    exit_mismatch: struct { expected: u8, actual: u8 },
    stdout_mismatch: DiffResult,
    stderr_mismatch: DiffResult,
    file_mismatch: struct { path: []const u8, diff: DiffResult },
    file_missing: []const u8,
    golden_missing: []const u8,
    json_parse_failed: []const u8,
};

const Outcome = enum { pass, fail, updated };

fn runOne(
    io: Io,
    gpa: Allocator,
    cases_root: Io.Dir,
    name: []const u8,
    rind_bin: []const u8,
    update_goldens: bool,
    err_out: *Io.Writer,
) !Outcome {
    var scenario = try loadScenario(io, gpa, cases_root, name);
    defer scenario.deinit(io);

    var run = try runScenario(io, gpa, &scenario, rind_bin, .{});
    defer run.deinit(gpa);

    var any_diff = false;
    var any_update = false;

    if (scenario.config.expected_exit != run.exit_code) {
        try err_out.print(
            "  exit: expected={d} actual={d}\n",
            .{ scenario.config.expected_exit, run.exit_code },
        );
        if (run.stderr.len != 0) try err_out.print("  stderr:\n{s}\n", .{run.stderr});
        any_diff = true;
    }

    if (scenario.config.expected_stdout) |golden| {
        const acted = try diffOrUpdateBytes(io, gpa, scenario.dir, golden, run.stdout, update_goldens, err_out, "stdout");
        switch (acted) {
            .pass => {},
            .fail => any_diff = true,
            .updated => any_update = true,
        }
    }
    if (scenario.config.expected_stderr) |golden| {
        const acted = try diffOrUpdateBytes(io, gpa, scenario.dir, golden, run.stderr, update_goldens, err_out, "stderr");
        switch (acted) {
            .pass => {},
            .fail => any_diff = true,
            .updated => any_update = true,
        }
    }

    if (scenario.config.expected_files) |files| {
        for (files) |ef| {
            const produced = scenario.dir.readFileAlloc(io, ef.path, gpa, golden_byte_limit) catch |err| switch (err) {
                error.FileNotFound => {
                    try err_out.print("  produced file missing: {s}\n", .{ef.path});
                    any_diff = true;
                    continue;
                },
                else => |e| return e,
            };
            defer gpa.free(produced);

            const acted = switch (ef.kind) {
                .bytes => try diffOrUpdateBytes(io, gpa, scenario.dir, ef.golden, produced, update_goldens, err_out, ef.path),
                .json => try diffOrUpdateJson(io, gpa, scenario.dir, ef.golden, produced, update_goldens, err_out, ef.path),
            };
            switch (acted) {
                .pass => {},
                .fail => any_diff = true,
                .updated => any_update = true,
            }
        }
    }

    if (update_goldens) return if (any_update or any_diff) .updated else .pass;
    return if (any_diff) .fail else .pass;
}

fn diffOrUpdateBytes(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    golden_path: []const u8,
    actual: []const u8,
    update_goldens: bool,
    err_out: *Io.Writer,
    label: []const u8,
) !Outcome {
    const expected = dir.readFileAlloc(io, golden_path, gpa, golden_byte_limit) catch |err| switch (err) {
        error.FileNotFound => {
            if (update_goldens) {
                try updateGolden(io, dir, golden_path, actual);
                try err_out.print("  {s}: golden created at {s}\n", .{ label, golden_path });
                return .updated;
            }
            try err_out.print("  {s}: golden missing at {s}\n", .{ label, golden_path });
            return .fail;
        },
        else => |e| return e,
    };
    defer gpa.free(expected);

    switch (diffBytes(expected, actual)) {
        .equal => return .pass,
        .byte_mismatch => {
            if (update_goldens) {
                try updateGolden(io, dir, golden_path, actual);
                try err_out.print("  {s}: golden rewritten at {s}\n", .{ label, golden_path });
                return .updated;
            }
            try err_out.print("  {s}: byte-equal diff at {s}\n", .{ label, golden_path });
            try err_out.print("    expected ({d} bytes):\n{s}\n", .{ expected.len, expected });
            try err_out.print("    actual   ({d} bytes):\n{s}\n", .{ actual.len, actual });
            return .fail;
        },
        .json_mismatch => unreachable,
    }
}

fn diffOrUpdateJson(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    golden_path: []const u8,
    actual: []const u8,
    update_goldens: bool,
    err_out: *Io.Writer,
    label: []const u8,
) !Outcome {
    const expected = dir.readFileAlloc(io, golden_path, gpa, golden_byte_limit) catch |err| switch (err) {
        error.FileNotFound => {
            if (update_goldens) {
                const canon = try canonicalizeJson(gpa, actual);
                defer gpa.free(canon);
                try updateGolden(io, dir, golden_path, canon);
                try err_out.print("  {s}: golden created at {s}\n", .{ label, golden_path });
                return .updated;
            }
            try err_out.print("  {s}: golden missing at {s}\n", .{ label, golden_path });
            return .fail;
        },
        else => |e| return e,
    };
    defer gpa.free(expected);

    var diff = try diffJson(gpa, expected, actual);
    defer diff.deinit(gpa);

    switch (diff) {
        .equal => return .pass,
        .json_mismatch => |m| {
            if (update_goldens) {
                try updateGolden(io, dir, golden_path, m.actual_canonical);
                try err_out.print("  {s}: golden rewritten at {s}\n", .{ label, golden_path });
                return .updated;
            }
            try err_out.print("  {s}: canonical-JSON diff at {s}\n", .{ label, golden_path });
            try err_out.print("    expected_canonical:\n{s}\n", .{m.expected_canonical});
            try err_out.print("    actual_canonical:\n{s}\n", .{m.actual_canonical});
            return .fail;
        },
        .byte_mismatch => unreachable,
    }
}

/// Harness binary entry point. CLI: `<rind_bin_path> --cases-dir <p> [--update-goldens]`.
/// Exits 0 on all-pass or any update; 1 on any FAIL; 2 on usage error.
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
        try stderr.writeAll(usage);
        stderr.flush() catch {};
        std.process.exit(2);
    };

    var cases_root = Io.Dir.cwd().openDir(io, args.cases_dir, .{ .iterate = true }) catch |err| {
        try stderr.print("regression-runner: cannot open cases dir '{s}': {s}\n", .{ args.cases_dir, @errorName(err) });
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer cases_root.close(io);

    const names = try discover(io, gpa, cases_root);
    defer {
        for (names) |s| gpa.free(s);
        gpa.free(names);
    }

    if (names.len == 0) {
        try stdout.print("no scenarios found under {s}\n", .{args.cases_dir});
        stdout.flush() catch {};
        std.process.exit(0);
    }

    var fail_count: usize = 0;
    var update_count: usize = 0;
    for (names) |name| {
        var per_scenario_buf: [16 * 1024]u8 = undefined;
        var per_scenario: Io.Writer = .fixed(&per_scenario_buf);

        const outcome = runOne(io, gpa, cases_root, name, args.rind_bin_path, args.update_goldens, &per_scenario) catch |err| {
            try stdout.print("FAIL {s} (internal: {s})\n", .{ name, @errorName(err) });
            const written = per_scenario.buffered();
            if (written.len != 0) try stdout.writeAll(written);
            fail_count += 1;
            continue;
        };

        switch (outcome) {
            .pass => try stdout.print("OK   {s}\n", .{name}),
            .fail => {
                try stdout.print("FAIL {s}\n", .{name});
                const written = per_scenario.buffered();
                if (written.len != 0) try stdout.writeAll(written);
                fail_count += 1;
            },
            .updated => {
                try stdout.print("UPD  {s}\n", .{name});
                const written = per_scenario.buffered();
                if (written.len != 0) try stdout.writeAll(written);
                update_count += 1;
            },
        }
    }

    try stdout.print("\nsummary: {d} scenario(s), {d} failed, {d} updated\n", .{ names.len, fail_count, update_count });
    stdout.flush() catch {};
    stderr.flush() catch {};

    if (args.update_goldens) std.process.exit(0);
    std.process.exit(if (fail_count == 0) 0 else 1);
}

const testing = std.testing;

test "diffBytes: equal" {
    try testing.expect(diffBytes("abc", "abc") == .equal);
}

test "diffBytes: mismatch" {
    const r = diffBytes("abc", "abd");
    try testing.expect(r == .byte_mismatch);
}

test "canonicalizeJson: object keys sorted" {
    const a = try canonicalizeJson(testing.allocator, "{\"b\":1,\"a\":2}");
    defer testing.allocator.free(a);
    const b = try canonicalizeJson(testing.allocator, "{\"a\":2,\"b\":1}");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expectEqualStrings("{\"a\":2,\"b\":1}", a);
}

test "canonicalizeJson: nested objects sort recursively" {
    const a = try canonicalizeJson(testing.allocator, "{\"z\":{\"y\":1,\"x\":2},\"a\":1}");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("{\"a\":1,\"z\":{\"x\":2,\"y\":1}}", a);
}

test "canonicalizeJson: array preserves order, no whitespace" {
    const a = try canonicalizeJson(testing.allocator, "[1, 2, 3]");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("[1,2,3]", a);
}

test "canonicalizeJson: rejects NaN-like via parser" {
    // Standard JSON rejects bare NaN at parse time, so the parse
    // error surfaces before the float check fires.
    try testing.expectError(error.SyntaxError, canonicalizeJson(testing.allocator, "{\"x\":NaN}"));
}

test "canonicalizeJson: scalars" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "null", .out = "null" },
        .{ .in = "true", .out = "true" },
        .{ .in = "false", .out = "false" },
        .{ .in = "42", .out = "42" },
        .{ .in = "\"hi\"", .out = "\"hi\"" },
    };
    for (cases) |c| {
        const got = try canonicalizeJson(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.out, got);
    }
}

test "diffJson: equal up to whitespace and key order" {
    const r = try diffJson(testing.allocator, "{\"a\":1,\"b\":2}", "{ \"b\":2 , \"a\":1 }");
    try testing.expect(r == .equal);
}

test "diffJson: not equal returns canonical forms" {
    var r = try diffJson(testing.allocator, "{\"a\":1}", "{\"a\":2}");
    defer r.deinit(testing.allocator);
    try testing.expect(r == .json_mismatch);
}

test "discover: lex-sorted, dirs only, skips _runner" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const io = testing.io;

    try tmp.dir.createDir(io, "zeta", .default_dir);
    try tmp.dir.createDir(io, "alpha", .default_dir);
    try tmp.dir.createDir(io, "_smoke", .default_dir);
    try tmp.dir.createDir(io, "_runner", .default_dir);
    {
        var f = try tmp.dir.createFile(io, "stray.txt", .{});
        f.close(io);
    }

    const names = try discover(io, testing.allocator, tmp.dir);
    defer {
        for (names) |s| testing.allocator.free(s);
        testing.allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("_smoke", names[0]);
    try testing.expectEqualStrings("alpha", names[1]);
    try testing.expectEqualStrings("zeta", names[2]);
}

test "loadScenario: missing dir yields ScenarioMissingFile" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectError(
        error.ScenarioMissingFile,
        loadScenario(testing.io, testing.allocator, tmp.dir, "ghost"),
    );
}

test "loadScenario: missing scenario.json yields ScenarioMissingFile" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "case", .default_dir);

    try testing.expectError(
        error.ScenarioMissingFile,
        loadScenario(testing.io, testing.allocator, tmp.dir, "case"),
    );
}

test "loadScenario: malformed JSON yields ScenarioMalformed" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "case", .default_dir);
    var dir = try tmp.dir.openDir(io, "case", .{});
    defer dir.close(io);

    var f = try dir.createFile(io, "scenario.json", .{});
    {
        var buf: [128]u8 = undefined;
        var fw = f.writer(io, &buf);
        try fw.interface.writeAll("{ not valid json");
        try fw.interface.flush();
    }
    f.close(io);

    try testing.expectError(
        error.ScenarioMalformed,
        loadScenario(io, testing.allocator, tmp.dir, "case"),
    );
}

test "loadScenario: unknown field rejected" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "case", .default_dir);
    var dir = try tmp.dir.openDir(io, "case", .{});
    defer dir.close(io);

    var f = try dir.createFile(io, "scenario.json", .{});
    {
        var buf: [256]u8 = undefined;
        var fw = f.writer(io, &buf);
        try fw.interface.writeAll(
            "{\"name\":\"x\",\"argv\":[\"help\"],\"weird_extra\":42}",
        );
        try fw.interface.flush();
    }
    f.close(io);

    try testing.expectError(
        error.ScenarioMalformed,
        loadScenario(io, testing.allocator, tmp.dir, "case"),
    );
}

test "loadScenario: well-formed parses" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "case", .default_dir);
    var dir = try tmp.dir.openDir(io, "case", .{});
    defer dir.close(io);

    var f = try dir.createFile(io, "scenario.json", .{});
    {
        var buf: [256]u8 = undefined;
        var fw = f.writer(io, &buf);
        try fw.interface.writeAll(
            "{\"name\":\"case\",\"argv\":[\"help\"],\"expected_exit\":0,\"expected_stdout\":\"out.txt\"}",
        );
        try fw.interface.flush();
    }
    f.close(io);

    var s = try loadScenario(io, testing.allocator, tmp.dir, "case");
    defer s.deinit(io);
    try testing.expectEqualStrings("case", s.config.name);
    try testing.expectEqual(@as(usize, 1), s.config.argv.len);
    try testing.expectEqualStrings("help", s.config.argv[0]);
    try testing.expectEqual(@as(u8, 0), s.config.expected_exit);
    try testing.expect(s.config.expected_stdout != null);
    try testing.expectEqualStrings("out.txt", s.config.expected_stdout.?);
}

test "updateGolden: writes new file atomically" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    try updateGolden(io, tmp.dir, "fresh.txt", "hello\n");

    const got = try tmp.dir.readFileAlloc(io, "fresh.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello\n", got);
}

test "updateGolden: replaces existing file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    try updateGolden(io, tmp.dir, "g.txt", "old");
    try updateGolden(io, tmp.dir, "g.txt", "new");

    const got = try tmp.dir.readFileAlloc(io, "g.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("new", got);
}
