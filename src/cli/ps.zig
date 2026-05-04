//! `rind ps` subcommand.
//!
//! Walks `<root>/containers/*/state.json`, refreshes liveness from
//! `/proc` for `.running` rows, and renders either a fixed-width table
//! (CONTAINER ID, IMAGE, COMMAND, CREATED, STATUS, NAMES), a stable
//! JSON array, or under `-q` one short id per line. The default
//! mirrors Docker: only `.running` rows are shown; `-a/--all` adds
//! `.created` and `.exited`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const clap = @import("clap");

const state_mod = @import("../runtime/state.zig");
const output = @import("output.zig");

/// Output format. `human` is the TTY default; `json` is the stable
/// machine-readable array consumed by tooling.
pub const OutputKind = enum { human, json };

/// Validated argv for `rind ps`.
pub const PsArgs = struct {
    /// `--output {human,json}`. Defaults to human. Ignored when `quiet`
    /// is set `-q` always emits one short id per line.
    output: OutputKind = .human,
    /// `-a/--all`. When false, only `.running` rows are shown
    /// (`.created` and `.exited` are filtered out, mirroring Docker).
    all: bool = false,
    /// `-q/--quiet`. Emit one short container id per line, nothing
    /// else. Wins over `--output`; intended for `rind ps -q | xargs`.
    quiet: bool = false,
};

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\-a, --all               Show all containers (default shows running only).
    \\-q, --quiet             Only display container IDs.
    \\    --output <kind>     Output format: human (default) or json.
    \\
);

const value_parsers = .{
    .kind = clap.parsers.enumeration(OutputKind),
};

/// One-line usage banner. Stable enough that scripts can grep it.
pub const usage_line: []const u8 = "Usage: rind ps [-a|--all] [-q|--quiet] [--output human|json]";

/// Parse argv (after `ps` has been peeled off) into a validated
/// `PsArgs`. `iter` is consumed; `gpa` backs clap's working arena.
/// Returns `error.Usage` for any structural problem and writes a
/// one-line diagnostic to `err_writer`.
pub fn parseArgs(
    gpa: Allocator,
    iter: anytype,
    err_writer: *Io.Writer,
) !PsArgs {
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

    return .{
        .output = res.args.output orelse .human,
        .all = res.args.all != 0,
        .quiet = res.args.quiet != 0,
    };
}

/// No-op kept for symmetry with sibling subcommands. `PsArgs` owns no
/// allocations to free.
pub fn freeArgs(gpa: Allocator, args: PsArgs) void {
    _ = gpa;
    _ = args;
}

/// One row of the `ps` listing. All slices borrow from caller storage
/// (the parsed `state.json` documents pinned by the arena in `run`).
pub const PsRow = struct {
    /// 12-char short container id.
    id: []const u8,
    /// Image ref the container was allocated for.
    image: []const u8,
    /// Resolved `process.args` (single-space joined). Empty when the
    /// state doc predates the `command` field.
    command: []const u8,
    /// RFC 3339 / ISO 8601 UTC timestamp, verbatim from `state.json`.
    started_at: []const u8,
    /// Effective lifecycle status — already reconciled against
    /// `/proc` liveness, so a stale `.running` row reads `.exited`.
    status: state_mod.Status,
    /// Recorded process id when status is `.running`. Null otherwise.
    pid: ?i32,
    /// Normal-exit code on `.exited`. Null otherwise.
    exit_code: ?i32,
    /// Terminating signal on `.exited`. Null otherwise.
    signal: ?i32,
    /// Optional human name (`--name`). Empty rendering when null.
    name: ?[]const u8,
};

fn lessByStartedDesc(_: void, a: PsRow, b: PsRow) bool {
    return std.mem.order(u8, a.started_at, b.started_at) == .gt;
}

/// Cap on a single state.json blob read. State documents are tiny in
/// practice (under a kilobyte); this just bounds an attacker-supplied
/// pathological file.
const state_doc_max_bytes: usize = 64 * 1024;

/// List containers under `root_dir`. Reads each `containers/<id>/state.json`,
/// reconciles `.running` rows against `/proc`, filters by `--all`, and
/// renders the result per `args.output`.
///
/// `now_unix_secs` is the wall-clock seconds-since-epoch used to render
/// relative times; production callers fill it from `Io.Clock.now(.real, io)`,
/// tests pin it to a fixture value.
pub fn run(
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    args: PsArgs,
    now_unix_secs: i64,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    _ = stderr;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var rows: std.ArrayList(PsRow) = .empty;
    defer rows.deinit(gpa);

    var containers_dir = root_dir.openDir(io, state_mod.containers_subpath, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try renderOutput(stdout, args, rows.items, now_unix_secs);
            return;
        },
        else => |e| return e,
    };
    defer containers_dir.close(io);

    var it = containers_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != state_mod.id_short_length) continue;

        const file_path = try std.fmt.allocPrint(aa, "{s}/{s}/{s}", .{
            state_mod.containers_subpath,
            entry.name,
            state_mod.state_filename,
        });

        const bytes = root_dir.readFileAlloc(io, file_path, aa, .limited(state_doc_max_bytes)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };

        const parsed = std.json.parseFromSliceLeaky(state_mod.StatePersisted, aa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch continue;

        var status: state_mod.Status = parsed.status;
        if (status == .running) {
            const pid = parsed.pid orelse 0;
            const live = state_mod.liveness(io, pid);
            if (live != .alive) status = .exited;
        }

        if (!args.all and status != .running) continue;

        try rows.append(gpa, .{
            .id = parsed.id,
            .image = parsed.image_ref,
            .command = parsed.command orelse "",
            .started_at = parsed.started_at,
            .status = status,
            .pid = parsed.pid,
            .exit_code = parsed.exit_code,
            .signal = parsed.signal,
            .name = parsed.name,
        });
    }

    std.mem.sort(PsRow, rows.items, {}, lessByStartedDesc);

    try renderOutput(stdout, args, rows.items, now_unix_secs);
}

fn renderOutput(
    stdout: *Io.Writer,
    args: PsArgs,
    rows: []const PsRow,
    now_unix_secs: i64,
) !void {
    if (args.quiet) {
        try renderQuiet(stdout, rows);
    } else switch (args.output) {
        .human => try renderHuman(stdout, rows, now_unix_secs),
        .json => try renderJson(stdout, rows),
    }
    try stdout.flush();
}

fn renderQuiet(w: *Io.Writer, rows: []const PsRow) Io.Writer.Error!void {
    for (rows) |row| {
        try w.writeAll(row.id);
        try w.writeByte('\n');
    }
}

const col_id_w: usize = 14;
const col_image_w: usize = 30;
const col_command_w: usize = 25;
const col_created_w: usize = 17;
const col_status_w: usize = 18;

const command_max_chars: usize = 20;

fn writePadded(w: *Io.Writer, s: []const u8, width: usize) Io.Writer.Error!void {
    try w.writeAll(s);
    if (s.len < width) {
        var n: usize = width - s.len;
        while (n > 0) : (n -= 1) try w.writeByte(' ');
    } else {
        try w.writeByte(' ');
        try w.writeByte(' ');
    }
}

fn formatRelative(buf: []u8, secs: i64) []u8 {
    if (secs <= 0) {
        return std.fmt.bufPrint(buf, "Less than a second ago", .{}) catch unreachable;
    }
    if (secs < 60) {
        return std.fmt.bufPrint(buf, "{d} seconds ago", .{secs}) catch unreachable;
    }
    if (secs < 60 * 60) {
        return std.fmt.bufPrint(buf, "{d} minutes ago", .{@divTrunc(secs, 60)}) catch unreachable;
    }
    if (secs < 24 * 60 * 60) {
        return std.fmt.bufPrint(buf, "{d} hours ago", .{@divTrunc(secs, 60 * 60)}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d} days ago", .{@divTrunc(secs, 24 * 60 * 60)}) catch unreachable;
}

fn formatUptime(buf: []u8, secs: i64) []u8 {
    if (secs <= 0) {
        return std.fmt.bufPrint(buf, "Up Less than a second", .{}) catch unreachable;
    }
    if (secs < 60) {
        return std.fmt.bufPrint(buf, "Up {d} seconds", .{secs}) catch unreachable;
    }
    if (secs < 60 * 60) {
        return std.fmt.bufPrint(buf, "Up {d} minutes", .{@divTrunc(secs, 60)}) catch unreachable;
    }
    if (secs < 24 * 60 * 60) {
        return std.fmt.bufPrint(buf, "Up {d} hours", .{@divTrunc(secs, 60 * 60)}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "Up {d} days", .{@divTrunc(secs, 24 * 60 * 60)}) catch unreachable;
}

/// Parse an RFC 3339 timestamp like `2026-05-04T12:34:56Z` into Unix
/// seconds. Returns null on any structural problem; callers fall back
/// to a literal echo of the source string in that case.
pub fn parseRfc3339Z(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T') return null;
    if (s[13] != ':' or s[16] != ':') return null;
    if (s[19] != 'Z') return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    const days_since_epoch = daysFromCivil(year, month, day);
    return @as(i64, days_since_epoch) * 86400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second);
}

fn daysFromCivil(y_in: i32, m_in: u8, d_in: u8) i64 {
    var y: i64 = y_in;
    if (m_in <= 2) y -= 1;
    const era: i64 = @divFloor(if (y >= 0) y else (y - 399), 400);
    const yoe: u64 = @intCast(y - era * 400);
    const m: i64 = m_in;
    const m_off: i64 = if (m_in > 2) m - 3 else m + 9;
    const doy: u64 = @intCast(@divTrunc(153 * m_off + 2, 5) + @as(i64, d_in) - 1);
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

fn statusString(buf: []u8, row: PsRow, now_unix_secs: i64) []u8 {
    return switch (row.status) {
        .created => std.fmt.bufPrint(buf, "Created", .{}) catch unreachable,
        .running => blk: {
            const start = parseRfc3339Z(row.started_at) orelse break :blk std.fmt.bufPrint(buf, "Up", .{}) catch unreachable;
            break :blk formatUptime(buf, now_unix_secs - start);
        },
        .exited => blk: {
            const code = row.exit_code orelse 0;
            const start = parseRfc3339Z(row.started_at);
            if (start) |s_unix| {
                const ago_buf_len: usize = 32;
                var ago_buf: [ago_buf_len]u8 = undefined;
                const ago = formatRelative(&ago_buf, now_unix_secs - s_unix);
                break :blk std.fmt.bufPrint(buf, "Exited ({d}) {s}", .{ code, ago }) catch unreachable;
            }
            break :blk std.fmt.bufPrint(buf, "Exited ({d})", .{code}) catch unreachable;
        },
    };
}

fn renderHuman(w: *Io.Writer, rows: []const PsRow, now_unix_secs: i64) Io.Writer.Error!void {
    try writePadded(w, "CONTAINER ID", col_id_w);
    try writePadded(w, "IMAGE", col_image_w);
    try writePadded(w, "COMMAND", col_command_w);
    try writePadded(w, "CREATED", col_created_w);
    try writePadded(w, "STATUS", col_status_w);
    try w.writeAll("NAMES\n");

    for (rows) |row| {
        try writePadded(w, row.id, col_id_w);
        try writePadded(w, row.image, col_image_w);

        var quoted_buf: [command_max_chars + 8]u8 = undefined;
        const quoted = formatQuotedCommand(&quoted_buf, row.command);

        var trunc_buf: [command_max_chars + 8]u8 = undefined;
        const cmd_trunc = output.truncateEllipsis(&trunc_buf, quoted, command_max_chars);
        try writePadded(w, cmd_trunc, col_command_w);

        var created_buf: [32]u8 = undefined;
        const created: []const u8 = if (parseRfc3339Z(row.started_at)) |unix|
            formatRelative(&created_buf, now_unix_secs - unix)
        else
            row.started_at;
        try writePadded(w, created, col_created_w);

        var status_buf: [64]u8 = undefined;
        const status_str = statusString(&status_buf, row, now_unix_secs);
        try writePadded(w, status_str, col_status_w);

        const name = row.name orelse "";
        try w.writeAll(name);
        try w.writeByte('\n');
    }
}

fn formatQuotedCommand(buf: []u8, command: []const u8) []u8 {
    if (command.len == 0) return buf[0..0];
    if (command.len + 2 > buf.len) {
        buf[0] = '"';
        const room = buf.len - 2;
        @memcpy(buf[1 .. 1 + room], command[0..room]);
        buf[1 + room] = '"';
        return buf[0 .. 2 + room];
    }
    buf[0] = '"';
    @memcpy(buf[1 .. 1 + command.len], command);
    buf[1 + command.len] = '"';
    return buf[0 .. command.len + 2];
}

fn renderJson(w: *Io.Writer, rows: []const PsRow) Io.Writer.Error!void {
    if (rows.len == 0) {
        try w.writeAll("[]\n");
        return;
    }
    try w.writeAll("[\n");
    for (rows, 0..) |row, i| {
        try w.writeAll("  {\n");

        try w.writeAll("    \"id\": ");
        try writeJsonString(w, row.id);
        try w.writeAll(",\n");

        try w.writeAll("    \"image\": ");
        try writeJsonString(w, row.image);
        try w.writeAll(",\n");

        try w.writeAll("    \"command\": ");
        try writeJsonString(w, row.command);
        try w.writeAll(",\n");

        try w.writeAll("    \"created_at\": ");
        try writeJsonString(w, row.started_at);
        try w.writeAll(",\n");

        try w.writeAll("    \"status\": ");
        try writeJsonString(w, statusName(row.status));
        try w.writeAll(",\n");

        try w.writeAll("    \"pid\": ");
        if (row.pid) |p| {
            try w.print("{d}", .{p});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n");

        try w.writeAll("    \"exit_code\": ");
        if (row.exit_code) |c| {
            try w.print("{d}", .{c});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n");

        try w.writeAll("    \"signal\": ");
        if (row.signal) |sig| {
            try w.print("{d}", .{sig});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n");

        try w.writeAll("    \"name\": ");
        if (row.name) |n| {
            try writeJsonString(w, n);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("\n  }");
        if (i + 1 < rows.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("]\n");
}

fn statusName(s: state_mod.Status) []const u8 {
    return switch (s) {
        .created => "created",
        .running => "running",
        .exited => "exited",
    };
}

fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
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

fn parseFromSlice(gpa: Allocator, argv: []const []const u8, err_writer: *Io.Writer) !PsArgs {
    var iter: SliceIter = .{ .items = argv };
    return parseArgs(gpa, &iter, err_writer);
}

test "parseArgs default is human, all=false, quiet=false" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{}, &err_buf.writer);
    try testing.expectEqual(OutputKind.human, a.output);
    try testing.expect(!a.all);
    try testing.expect(!a.quiet);
}

test "parseArgs accepts -a and --output json" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(gpa, &.{ "-a", "--output", "json" }, &err_buf.writer);
    try testing.expect(a.all);
    try testing.expectEqual(OutputKind.json, a.output);
}

test "parseArgs accepts -q and combined -aq" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const q_only = try parseFromSlice(gpa, &.{"-q"}, &err_buf.writer);
    try testing.expect(q_only.quiet);
    try testing.expect(!q_only.all);

    const aq = try parseFromSlice(gpa, &.{ "-a", "-q" }, &err_buf.writer);
    try testing.expect(aq.quiet);
    try testing.expect(aq.all);

    const long = try parseFromSlice(gpa, &.{"--quiet"}, &err_buf.writer);
    try testing.expect(long.quiet);
}

test "parseArgs rejects unknown flag" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{"--bogus"}, &err_buf.writer));
}

test "parseArgs --help is treated as a usage exit" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{"--help"}, &err_buf.writer));
}

test "parseRfc3339Z parses canonical form" {
    const got = parseRfc3339Z("2026-05-04T12:34:56Z").?;
    try testing.expectEqual(@as(i64, 1777898096), got);
}

test "parseRfc3339Z rejects malformed input" {
    try testing.expect(parseRfc3339Z("not-a-date") == null);
    try testing.expect(parseRfc3339Z("2026-05-04 12:34:56Z") == null);
}

const fixture_now_unix: i64 = 1777898400;

const fixture_rows = [_]PsRow{
    .{
        .id = "abc123def456",
        .image = "alpine:3.19",
        .command = "/bin/sh -c echo",
        .started_at = "2026-05-04T12:30:00Z",
        .status = .running,
        .pid = 4242,
        .exit_code = null,
        .signal = null,
        .name = "web",
    },
    .{
        .id = "fed654cba321",
        .image = "ghcr.io/foo/bar:v2",
        .command = "redis /etc/redis.conf",
        .started_at = "2026-05-04T11:30:00Z",
        .status = .exited,
        .pid = 5151,
        .exit_code = 0,
        .signal = 0,
        .name = null,
    },
};

test "renderHuman snapshot" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try renderHuman(&buf.writer, &fixture_rows, fixture_now_unix);
    const expected = @embedFile("testdata/ps_human.txt");
    try testing.expectEqualStrings(expected, buf.written());
}

test "renderJson snapshot" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try renderJson(&buf.writer, &fixture_rows);
    const expected = @embedFile("testdata/ps.json");
    try testing.expectEqualStrings(expected, buf.written());
}

test "renderJson empty container set emits empty array" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try renderJson(&buf.writer, &.{});
    try testing.expectEqualStrings("[]\n", buf.written());
}

test "run on missing containers/ emits header only / empty array" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var out_buf: Io.Writer.Allocating = .init(gpa);
        defer out_buf.deinit();
        var err_buf: Io.Writer.Allocating = .init(gpa);
        defer err_buf.deinit();
        try run(io, gpa, tmp.dir, .{ .output = .json }, fixture_now_unix, &out_buf.writer, &err_buf.writer);
        try testing.expectEqualStrings("[]\n", out_buf.written());
    }

    {
        var out_buf: Io.Writer.Allocating = .init(gpa);
        defer out_buf.deinit();
        var err_buf: Io.Writer.Allocating = .init(gpa);
        defer err_buf.deinit();
        try run(io, gpa, tmp.dir, .{ .output = .human }, fixture_now_unix, &out_buf.writer, &err_buf.writer);
        try testing.expect(std.mem.startsWith(u8, out_buf.written(), "CONTAINER ID"));
    }
}

test "run hides .created and .exited by default; -a includes both" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(io);

    var c1 = try state_mod.allocate(io, gpa, root, "alpine:3.19", "sha256:aa", "fresh", "/bin/sh");
    defer c1.deinit(gpa);
    var c2 = try state_mod.allocate(io, gpa, root, "busybox:1", "sha256:bb", "gone", "/bin/true");
    defer c2.deinit(gpa);

    try state_mod.transition(io, gpa, root, c2.id[0..], .{ .status = .exited, .exit_code = 0, .signal = 0 });

    {
        var out_buf: Io.Writer.Allocating = .init(gpa);
        defer out_buf.deinit();
        var err_buf: Io.Writer.Allocating = .init(gpa);
        defer err_buf.deinit();
        try run(io, gpa, root, .{ .output = .json, .all = false }, fixture_now_unix, &out_buf.writer, &err_buf.writer);
        try testing.expectEqualStrings("[]\n", out_buf.written());
    }

    {
        var out_buf: Io.Writer.Allocating = .init(gpa);
        defer out_buf.deinit();
        var err_buf: Io.Writer.Allocating = .init(gpa);
        defer err_buf.deinit();
        try run(io, gpa, root, .{ .output = .json, .all = true }, fixture_now_unix, &out_buf.writer, &err_buf.writer);
        try testing.expect(std.mem.indexOf(u8, out_buf.written(), "fresh") != null);
        try testing.expect(std.mem.indexOf(u8, out_buf.written(), "gone") != null);
        try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"status\": \"created\"") != null);
        try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"status\": \"exited\"") != null);
    }
}

test "run quiet emits id-per-line, no header, ignores --output" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(io);

    var c1 = try state_mod.allocate(io, gpa, root, "alpine:3.19", "sha256:aa", "first", "/bin/sh");
    defer c1.deinit(gpa);
    var c2 = try state_mod.allocate(io, gpa, root, "busybox:1", "sha256:bb", "second", "/bin/true");
    defer c2.deinit(gpa);

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    try run(io, gpa, root, .{ .quiet = true, .all = true, .output = .json }, fixture_now_unix, &out_buf.writer, &err_buf.writer);

    const got = out_buf.written();
    try testing.expect(std.mem.indexOf(u8, got, "CONTAINER ID") == null);
    try testing.expect(std.mem.indexOf(u8, got, "{") == null);
    try testing.expect(std.mem.indexOf(u8, got, c1.id[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, got, c2.id[0..]) != null);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |line| if (line.len != 0) {
        try testing.expectEqual(state_mod.id_short_length, line.len);
        lines += 1;
    };
    try testing.expectEqual(@as(usize, 2), lines);
}

test "run reconciles stale .running rows against /proc liveness" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(io, "rind", .{
        .open_options = .{ .iterate = true },
    });
    defer root.close(io);

    var c = try state_mod.allocate(io, gpa, root, "alpine:3.19", "sha256:cc", "ghost", "/bin/sh");
    defer c.deinit(gpa);

    // Mark .running with an obviously dead pid.
    try state_mod.transition(io, gpa, root, c.id[0..], .{
        .status = .running,
        .pid = std.math.maxInt(i32),
    });

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    // Default ps must omit the row because /proc reports the pid is gone.
    try run(io, gpa, root, .{ .output = .json, .all = false }, fixture_now_unix, &out_buf.writer, &err_buf.writer);
    try testing.expectEqualStrings("[]\n", out_buf.written());

    // -a brings it back, with status == exited.
    out_buf.clearRetainingCapacity();
    try run(io, gpa, root, .{ .output = .json, .all = true }, fixture_now_unix, &out_buf.writer, &err_buf.writer);
    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "\"status\": \"exited\"") != null);
}
