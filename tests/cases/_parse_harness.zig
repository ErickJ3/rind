//! Containerfile-parser regression harness.
//!
//! Reads `<cases-dir>/Containerfile`, runs `rind.Builder.parse.parse`,
//! emits canonical JSON (object keys alphabetised, no insignificant
//! whitespace), and either:
//!   * writes `expected_ast.json` next to the input when `--update` is
//!     passed (used for first-time golden authoring and refreshes);
//!   * byte-compares against `expected_ast.json` and exits 1 on drift,
//!     printing both canonical forms to stderr.
//!
//! The canonical form is emitted directly, no parse-then-re-emit pass.
//! Field order is hand-coded; the producer of new fields must update
//! this file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rind = @import("rind");
const lex = rind.Builder.lex;
const parse = rind.Builder.parse;

const usage_text =
    "Usage: parse-harness --cases-dir <path> [--update]\n";

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
        try stderr.print("parse-harness: cannot open cases dir '{s}': {s}\n", .{ args.cases_dir, @errorName(err) });
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer cases_dir.close(io);

    const src = cases_dir.readFileAlloc(io, "Containerfile", gpa, containerfile_byte_limit) catch |err| {
        try stderr.print("parse-harness: cannot read Containerfile: {s}\n", .{@errorName(err)});
        stderr.flush() catch {};
        std.process.exit(2);
    };
    defer gpa.free(src);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const result = parse.parse(arena.allocator(), src) catch |err| {
        try stderr.print("parse-harness: parse failed: {s}\n", .{@errorName(err)});
        stderr.flush() catch {};
        std.process.exit(1);
    };

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try emitCanonical(&aw.writer, &result);
    const actual = aw.written();

    if (args.update) {
        try writeAtomic(io, cases_dir, "expected_ast.json", actual);
        try stdout.print("UPD  {s}/expected_ast.json\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    const expected = cases_dir.readFileAlloc(io, "expected_ast.json", gpa, golden_byte_limit) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print(
                "parse-harness: golden 'expected_ast.json' missing in '{s}' (rerun with -Dupdate-goldens=true)\n",
                .{args.cases_dir},
            );
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer gpa.free(expected);

    if (std.mem.eql(u8, expected, actual)) {
        try stdout.print("OK   parse_smoke ({s})\n", .{args.cases_dir});
        stdout.flush() catch {};
        return;
    }

    try stderr.print("FAIL parse_smoke: expected_ast.json drift in '{s}'\n", .{args.cases_dir});
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

fn emitCanonical(w: *Io.Writer, result: *const parse.ParseResult) !void {
    try w.writeByte('{');
    try w.writeAll("\"diagnostics\":");
    try emitDiagnostics(w, result.diagnostics);
    try w.writeAll(",\"header\":");
    try emitHeader(w, result.header);
    try w.writeAll(",\"instructions\":");
    try emitInstructions(w, result.instructions);
    try w.writeByte('}');
}

fn emitHeader(w: *Io.Writer, h: lex.Header) !void {
    try w.writeAll("{\"escape\":");
    var buf: [1]u8 = .{h.escape};
    try std.json.Stringify.encodeJsonString(buf[0..], .{}, w);
    try w.writeAll(",\"syntax\":");
    try emitOptString(w, h.syntax);
    try w.writeByte('}');
}

fn emitDiagnostics(w: *Io.Writer, diags: []const parse.Diagnostic) !void {
    try w.writeByte('[');
    for (diags, 0..) |d, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"message\":");
        try std.json.Stringify.encodeJsonString(d.message, .{}, w);
        try w.writeAll(",\"severity\":");
        try std.json.Stringify.encodeJsonString(@tagName(d.severity), .{}, w);
        try w.writeAll(",\"span\":");
        try emitSpan(w, d.span);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn emitInstructions(w: *Io.Writer, instrs: []const parse.Instruction) !void {
    try w.writeByte('[');
    for (instrs, 0..) |ins, i| {
        if (i != 0) try w.writeByte(',');
        try emitInstruction(w, ins);
    }
    try w.writeByte(']');
}

fn emitInstruction(w: *Io.Writer, ins: parse.Instruction) !void {
    try w.writeByte('{');
    try w.writeAll("\"kind\":");
    try std.json.Stringify.encodeJsonString(@tagName(ins), .{}, w);
    switch (ins) {
        .from => |v| {
            try w.writeAll(",\"alias\":");
            try emitOptString(w, v.alias);
            try w.writeAll(",\"image\":");
            try emitOptImageRef(w, v.image);
            try w.writeAll(",\"is_scratch\":");
            try w.writeAll(if (v.is_scratch) "true" else "false");
            try w.writeAll(",\"platform\":");
            try emitOptString(w, v.platform);
            try w.writeAll(",\"raw\":");
            try std.json.Stringify.encodeJsonString(v.raw, .{}, w);
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
            try w.writeAll(",\"stage_ref\":");
            try emitOptString(w, v.stage_ref);
        },
        .run, .cmd, .entrypoint => |v| {
            try w.writeAll(",\"args\":");
            try emitStringArray(w, v.args);
            try w.writeAll(",\"form\":");
            try std.json.Stringify.encodeJsonString(@tagName(v.form), .{}, w);
            try w.writeAll(",\"heredocs\":");
            try emitHeredocs(w, v.heredocs);
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
        },
        .copy, .add => |v| {
            try w.writeAll(",\"chmod\":");
            try emitOptString(w, v.chmod);
            try w.writeAll(",\"chown\":");
            try emitOptString(w, v.chown);
            try w.writeAll(",\"dest\":");
            try std.json.Stringify.encodeJsonString(v.dest, .{}, w);
            try w.writeAll(",\"from\":");
            try emitOptString(w, v.from);
            try w.writeAll(",\"is_add\":");
            try w.writeAll(if (v.is_add) "true" else "false");
            try w.writeAll(",\"sources\":");
            try emitStringArray(w, v.sources);
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
        },
        .env, .label => |v| {
            try w.writeAll(",\"entries\":");
            try emitEntries(w, v.entries);
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
        },
        .workdir, .user, .stopsignal, .maintainer => |v| {
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
            try w.writeAll(",\"value\":");
            try std.json.Stringify.encodeJsonString(v.value, .{}, w);
        },
        .expose, .volume, .shell => |v| {
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
            try w.writeAll(",\"values\":");
            try emitStringArray(w, v.values);
        },
        .arg => |v| {
            try w.writeAll(",\"default\":");
            try emitOptString(w, v.default);
            try w.writeAll(",\"is_global\":");
            try w.writeAll(if (v.is_global) "true" else "false");
            try w.writeAll(",\"name\":");
            try std.json.Stringify.encodeJsonString(v.name, .{}, w);
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
        },
        .healthcheck => |v| {
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
            try w.writeAll(",\"value\":");
            try emitHealthcheckValue(w, v.value);
        },
        .onbuild => |v| {
            try w.writeAll(",\"inner_directive\":");
            try std.json.Stringify.encodeJsonString(@tagName(v.inner_directive), .{}, w);
            try w.writeAll(",\"raw_args\":");
            try emitStringArray(w, v.raw_args);
            try w.writeAll(",\"span\":");
            try emitSpan(w, v.span);
        },
    }
    try w.writeByte('}');
}

fn emitHealthcheckValue(w: *Io.Writer, hc: parse.Healthcheck) !void {
    switch (hc) {
        .none => try w.writeAll("{\"kind\":\"none\"}"),
        .cmd => |c| {
            try w.writeByte('{');
            try w.writeAll("\"args\":");
            try emitStringArray(w, c.args);
            try w.writeAll(",\"form\":");
            try std.json.Stringify.encodeJsonString(@tagName(c.form), .{}, w);
            try w.writeAll(",\"interval\":");
            try emitOptString(w, c.interval);
            try w.writeAll(",\"kind\":\"cmd\"");
            try w.writeAll(",\"retries\":");
            try emitOptString(w, c.retries);
            try w.writeAll(",\"start_period\":");
            try emitOptString(w, c.start_period);
            try w.writeAll(",\"timeout\":");
            try emitOptString(w, c.timeout);
            try w.writeByte('}');
        },
    }
}

fn emitEntries(w: *Io.Writer, entries: []const parse.KeyValue) !void {
    try w.writeByte('[');
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"key\":");
        try std.json.Stringify.encodeJsonString(e.key, .{}, w);
        try w.writeAll(",\"value\":");
        try std.json.Stringify.encodeJsonString(e.value, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn emitHeredocs(w: *Io.Writer, hds: []const parse.Heredoc) !void {
    try w.writeByte('[');
    for (hds, 0..) |h, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"body\":");
        try std.json.Stringify.encodeJsonString(h.body, .{}, w);
        try w.writeAll(",\"strip_tabs\":");
        try w.writeAll(if (h.strip_tabs) "true" else "false");
        try w.writeAll(",\"tag\":");
        try std.json.Stringify.encodeJsonString(h.tag, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
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

fn emitOptImageRef(w: *Io.Writer, ref: ?@import("rind").Image.ref.ImageRef) !void {
    if (ref) |r| {
        try w.writeByte('{');
        try w.writeAll("\"digest\":");
        try emitOptString(w, r.digest);
        try w.writeAll(",\"registry\":");
        try std.json.Stringify.encodeJsonString(r.registry, .{}, w);
        try w.writeAll(",\"repository\":");
        try std.json.Stringify.encodeJsonString(r.repository, .{}, w);
        try w.writeAll(",\"tag\":");
        try emitOptString(w, r.tag);
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }
}

fn emitSpan(w: *Io.Writer, s: lex.Span) !void {
    try w.print(
        "{{\"col\":{d},\"len\":{d},\"line\":{d},\"offset\":{d}}}",
        .{ s.col, s.len, s.line, s.offset },
    );
}

const testing = std.testing;

test "emitCanonical: empty result" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var instrs = [_]parse.Instruction{};
    var diags = [_]parse.Diagnostic{};
    const r: parse.ParseResult = .{
        .header = .{},
        .instructions = instrs[0..],
        .diagnostics = diags[0..],
    };
    try emitCanonical(&aw.writer, &r);
    try testing.expectEqualStrings(
        "{\"diagnostics\":[],\"header\":{\"escape\":\"\\\\\",\"syntax\":null},\"instructions\":[]}",
        aw.written(),
    );
}

test "parseArgs: --cases-dir + --update" {
    const argv = [_][]const u8{ "parse-harness", "--cases-dir", "tests/parse_cases/parse_smoke", "--update" };
    const a = try parseArgs(argv[0..]);
    try testing.expectEqualStrings("tests/parse_cases/parse_smoke", a.cases_dir);
    try testing.expect(a.update);
}

test "parseArgs: missing cases-dir errors" {
    const argv = [_][]const u8{"parse-harness"};
    try testing.expectError(error.MissingCasesDir, parseArgs(argv[0..]));
}
