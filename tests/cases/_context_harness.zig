//! Build-context-loader regression harness.
//!
//! Opens `<cases-dir>/context/` as a build-context root, runs
//! `rind.Builder.context.load`, then probes a fixed set of
//! `digestSubset` pattern groups. Emits canonical JSON
//! (object keys alphabetised, no insignificant whitespace) and either:
//!   * writes `expected_listing.json` next to the cases dir when
//!     `--update` is passed; or
//!   * byte-compares against the committed golden and exits 1 on drift,
//!     printing both forms to stderr.
//!
//! Field order is hand-coded; the producer of new fields must update
//! this file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rind = @import("rind");
const context = rind.Builder.context;

const usage_text =
    "Usage: context-harness --cases-dir <path> [--update]\n";

const golden_byte_limit: Io.Limit = .limited(1 << 20);

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

const subset_groups: []const []const []const u8 = &.{
    &.{},
    &.{"*.zig"},
    &.{"**/*.zig"},
    &.{"src/**"},
    &.{ "src/**", "Containerfile" },
};

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
            "context-harness: cannot open cases dir '{s}': {s}\n",
            .{ args.cases_dir, @errorName(err) },
        );
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer cases_dir.close(io);

    var ctx_dir = cases_dir.openDir(io, "context", .{ .iterate = true }) catch |err| {
        try stderr.print(
            "context-harness: cannot open context dir '{s}/context': {s}\n",
            .{ args.cases_dir, @errorName(err) },
        );
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer ctx_dir.close(io);

    var ctx = context.load(io, gpa, ctx_dir) catch |err| {
        try stderr.print("context-harness: load failed: {s}\n", .{@errorName(err)});
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer ctx.deinit();

    var subset_results = try gpa.alloc([digest_byte_length]u8, subset_groups.len);
    defer gpa.free(subset_results);
    for (subset_groups, 0..) |group, gi| {
        subset_results[gi] = try ctx.digestSubset(gpa, group);
    }

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try emitCanonical(&aw.writer, &ctx, subset_results);
    const actual = aw.written();

    if (args.update) {
        try writeAtomic(io, cases_dir, "expected_listing.json", actual);
        try stdout.print("UPD  {s}/expected_listing.json\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    const expected = cases_dir.readFileAlloc(io, "expected_listing.json", gpa, golden_byte_limit) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print(
                "context-harness: golden 'expected_listing.json' missing in '{s}' (rerun with -Dupdate-goldens=true)\n",
                .{args.cases_dir},
            );
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer gpa.free(expected);

    if (std.mem.eql(u8, expected, actual)) {
        try stdout.print("OK   context_smoke ({s})\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    try stderr.print("FAIL context_smoke: expected_listing.json drift in '{s}'\n", .{args.cases_dir});
    try stderr.writeAll("--- expected ---\n");
    try stderr.writeAll(expected);
    try stderr.writeAll("\n--- actual ---\n");
    try stderr.writeAll(actual);
    try stderr.writeAll("\n");
    stderr.flush() catch {};
    std.process.exit(1);
}

const digest_byte_length: usize = 32;

fn writeAtomic(io: Io, dir: Io.Dir, rel_path: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, rel_path, .{ .replace = true });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    fw.interface.writeAll(bytes) catch return fw.err.?;
    fw.interface.flush() catch return fw.err.?;
    try atomic.replace(io);
}

fn emitCanonical(
    w: *Io.Writer,
    ctx: *const context.Context,
    subset_results: []const [digest_byte_length]u8,
) !void {
    try w.writeByte('{');
    try w.writeAll("\"diagnostics\":");
    try emitDiagnostics(w, ctx.diagnostics);
    try w.writeAll(",\"entries\":");
    try emitEntries(w, ctx.entries);
    try w.writeAll(",\"ignore_file\":");
    try emitOptString(w, ctx.ignore_file);
    try w.writeAll(",\"subsets\":");
    try emitSubsets(w, subset_results);
    try w.writeByte('}');
}

fn emitDiagnostics(w: *Io.Writer, diags: []const context.Diagnostic) !void {
    try w.writeByte('[');
    for (diags, 0..) |d, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"message\":");
        try std.json.Stringify.encodeJsonString(d.message, .{}, w);
        try w.writeAll(",\"path\":");
        try std.json.Stringify.encodeJsonString(d.path, .{}, w);
        try w.writeAll(",\"severity\":");
        try std.json.Stringify.encodeJsonString(@tagName(d.severity), .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn emitEntries(w: *Io.Writer, entries: []const context.ContextEntry) !void {
    try w.writeByte('[');
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('{');
        try w.writeAll("\"digest\":");
        try emitOptDigest(w, e.digest);
        try w.writeAll(",\"kind\":");
        try std.json.Stringify.encodeJsonString(@tagName(e.kind), .{}, w);
        try w.print(",\"mode\":\"{o:0>4}\"", .{e.mode});
        try w.writeAll(",\"path\":");
        try std.json.Stringify.encodeJsonString(e.path, .{}, w);
        try w.print(",\"size\":{d}", .{e.size});
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn emitSubsets(w: *Io.Writer, results: []const [digest_byte_length]u8) !void {
    try w.writeByte('[');
    for (subset_groups, 0..) |group, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('{');
        try w.writeAll("\"digest\":");
        try emitDigestHex(w, results[i]);
        try w.writeAll(",\"patterns\":");
        try emitStringArray(w, group);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn emitOptDigest(w: *Io.Writer, d: ?[digest_byte_length]u8) !void {
    if (d) |bytes| {
        try emitDigestHex(w, bytes);
    } else {
        try w.writeAll("null");
    }
}

fn emitDigestHex(w: *Io.Writer, bytes: [digest_byte_length]u8) !void {
    const hex = std.fmt.bytesToHex(bytes, .lower);
    try w.writeByte('"');
    try w.writeAll(&hex);
    try w.writeByte('"');
}

fn emitStringArray(w: *Io.Writer, arr: []const []const u8) !void {
    try w.writeByte('[');
    for (arr, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        try std.json.Stringify.encodeJsonString(s, .{}, w);
    }
    try w.writeByte(']');
}

fn emitOptString(w: *Io.Writer, v: ?[]const u8) !void {
    if (v) |s| {
        try std.json.Stringify.encodeJsonString(s, .{}, w);
    } else {
        try w.writeAll("null");
    }
}

const testing = std.testing;

test "parseArgs: --cases-dir + --update" {
    const argv = [_][]const u8{ "context-harness", "--cases-dir", "tests/context_cases/context_smoke", "--update" };
    const a = try parseArgs(argv[0..]);
    try testing.expectEqualStrings("tests/context_cases/context_smoke", a.cases_dir);
    try testing.expect(a.update);
}

test "parseArgs: missing cases-dir errors" {
    const argv = [_][]const u8{"context-harness"};
    try testing.expectError(error.MissingCasesDir, parseArgs(argv[0..]));
}
