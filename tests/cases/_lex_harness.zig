//! Containerfile-lexer regression harness.
//!
//! Reads `<cases-dir>/Containerfile`, runs `rind.Builder.lex.tokenize`,
//! emits canonical JSON (object keys alphabetised, no insignificant
//! whitespace), and either:
//!   * writes `expected_tokens.json` next to the input when `--update`
//!     is passed (used for first-time golden authoring and refreshes);
//!   * byte-compares against `expected_tokens.json` and exits 1 on
//!     drift, printing both canonical forms to stderr.
//!
//! The canonical form is emitted directly (no parse-then-re-emit pass),
//! so the harness does not depend on `std.json.parseFromSlice`. Field
//! order is hand-coded; the producer of new fields must update this
//! file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lex = @import("rind").Builder.lex;

const usage_text =
    "Usage: lex-harness --cases-dir <path> [--update]\n";

const containerfile_byte_limit: Io.Limit = .limited(1 << 20);
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
        try stderr.print("lex-harness: cannot open cases dir '{s}': {s}\n", .{ args.cases_dir, @errorName(err) });
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer cases_dir.close(io);

    const src = cases_dir.readFileAlloc(io, "Containerfile", gpa, containerfile_byte_limit) catch |err| {
        try stderr.print("lex-harness: cannot read Containerfile: {s}\n", .{@errorName(err)});
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer gpa.free(src);

    var result = lex.tokenize(gpa, src) catch |err| {
        try stderr.print("lex-harness: tokenize failed: {s}\n", .{@errorName(err)});
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer result.deinit(gpa);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try emitCanonical(&aw.writer, &result);
    const actual = aw.written();

    if (args.update) {
        try writeAtomic(io, cases_dir, "expected_tokens.json", actual);
        try stdout.print("UPD  {s}/expected_tokens.json\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    const expected = cases_dir.readFileAlloc(io, "expected_tokens.json", gpa, golden_byte_limit) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print(
                "lex-harness: golden 'expected_tokens.json' missing in '{s}' (rerun with -Dupdate-goldens=true)\n",
                .{args.cases_dir},
            );
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer gpa.free(expected);

    if (std.mem.eql(u8, expected, actual)) {
        try stdout.print("OK   lex_smoke ({s})\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    try stderr.print("FAIL lex_smoke: expected_tokens.json drift in '{s}'\n", .{args.cases_dir});
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

fn emitCanonical(w: *Io.Writer, result: *const lex.Result) !void {
    try w.writeByte('{');
    try w.writeAll("\"header\":");
    try emitHeader(w, result.header);
    try w.writeAll(",\"tokens\":");
    try emitTokens(w, result.tokens);
    try w.writeByte('}');
}

fn emitHeader(w: *Io.Writer, h: lex.Header) !void {
    try w.writeAll("{\"escape\":");
    var buf: [1]u8 = .{h.escape};
    try std.json.Stringify.encodeJsonString(buf[0..], .{}, w);
    try w.writeAll(",\"syntax\":");
    if (h.syntax) |s| {
        try std.json.Stringify.encodeJsonString(s, .{}, w);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');
}

fn emitTokens(w: *Io.Writer, tokens: []const lex.Token) !void {
    try w.writeByte('[');
    for (tokens, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try emitToken(w, t);
    }
    try w.writeByte(']');
}

fn emitToken(w: *Io.Writer, t: lex.Token) !void {
    try w.writeAll("{\"directive_tag\":");
    if (t.directive_tag) |d| {
        try std.json.Stringify.encodeJsonString(@tagName(d), .{}, w);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"kind\":");
    try std.json.Stringify.encodeJsonString(@tagName(t.kind), .{}, w);
    try w.writeAll(",\"span\":");
    try emitSpan(w, t.span);
    try w.writeAll(",\"text\":");
    try std.json.Stringify.encodeJsonString(t.text, .{}, w);
    try w.writeByte('}');
}

fn emitSpan(w: *Io.Writer, s: lex.Span) !void {
    try w.print(
        "{{\"col\":{d},\"len\":{d},\"line\":{d},\"offset\":{d}}}",
        .{ s.col, s.len, s.line, s.offset },
    );
}

const testing = std.testing;

test "emitCanonical: empty result emits sorted keys" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var tokens = [_]lex.Token{};
    const r: lex.Result = .{ .header = .{}, .tokens = tokens[0..] };
    try emitCanonical(&aw.writer, &r);
    try testing.expectEqualStrings("{\"header\":{\"escape\":\"\\\\\",\"syntax\":null},\"tokens\":[]}", aw.written());
}

test "emitToken: span keys alphabetised" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const tok: lex.Token = .{
        .kind = .directive,
        .text = "FROM",
        .span = .{ .offset = 0, .len = 4, .line = 1, .col = 1 },
        .directive_tag = .from,
    };
    try emitToken(&aw.writer, tok);
    try testing.expectEqualStrings(
        "{\"directive_tag\":\"from\",\"kind\":\"directive\",\"span\":{\"col\":1,\"len\":4,\"line\":1,\"offset\":0},\"text\":\"FROM\"}",
        aw.written(),
    );
}

test "parseArgs: --cases-dir + --update" {
    const argv = [_][]const u8{ "lex-harness", "--cases-dir", "tests/cases/lex_smoke", "--update" };
    const a = try parseArgs(argv[0..]);
    try testing.expectEqualStrings("tests/cases/lex_smoke", a.cases_dir);
    try testing.expect(a.update);
}

test "parseArgs: missing cases-dir errors" {
    const argv = [_][]const u8{"lex-harness"};
    try testing.expectError(error.MissingCasesDir, parseArgs(argv[0..]));
}
