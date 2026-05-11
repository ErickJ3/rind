//! Build context loader.
//!
//! Walks a host directory passed as the build context, applies a flat
//! `.containerignore` (or `.dockerignore`) at the root, deterministically
//! sorts the surviving entries, and computes per-entry sha256 digests so
//! the cache-key layer can hash any subset of the listing without
//! re-walking the tree.
//!
//! Scope decisions baked in here:
//!   * The ignore file is flat — Docker semantics. Only the root file is
//!     read; nested ignore files are not honored. We follow Docker, not
//!     git.
//!   * `.containerignore` wins when both names exist. `.dockerignore` is
//!     accepted as a fallback for users coming from a Docker workflow.
//!   * Per-entry digest is the sha256 of the file body for regular files,
//!     the sha256 of the symlink target string for symlinks, and `null`
//!     for directories. Symlinks are NOT followed during the walk so the
//!     digest captures the link itself rather than the pointed-at file.
//!   * Non-regular, non-symlink, non-directory entries (fifo, socket,
//!     block device, char device) emit a warn-level diagnostic and are
//!     omitted from the listing. Build still succeeds.
//!   * Entries are byte-sorted by their forward-slash relative path so
//!     the same context tree always produces the same listing regardless
//!     of insertion order on disk.
//!   * Glob syntax (used by both ignore patterns and `digestSubset`):
//!       - `*`  matches any run of non-`/` bytes.
//!       - `**` matches any run of bytes including `/` (zero or more
//!         path components).
//!       - `?`  matches exactly one non-`/` byte.
//!       - `[abc]` / `[a-z]` / `[!abc]` are character classes.
//!       - `\<x>` escapes a single metacharacter.
//!     Ignore patterns containing a `/` (other than a trailing one) are
//!     anchored at the context root; patterns without `/` match against
//!     each path component's basename at any depth, gitignore-style.
//!   * `digestSubset` patterns are always anchored — they originate from
//!     a `COPY <patterns> <dest>` directive whose source paths are
//!     relative to the context root.
//!
//! Pure library: no global state, no logging. Output is owned by the
//! `Context.arena`; `Context.deinit` releases everything.

const std = @import("std");
const ascii = std.ascii;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const digest_mod = @import("../image/digest.zig");

/// Filenames recognised as the build-context ignore list, in priority
/// order. The first one that exists is consumed.
pub const ignore_filenames = [_][]const u8{
    ".containerignore",
    ".dockerignore",
};

/// Upper bound on the size of the ignore file we will read, in bytes.
/// Anything larger is almost certainly a misuse.
const ignore_file_byte_limit: Io.Limit = .limited(1 << 20);

/// Read buffer used for streaming a regular file through the hasher.
const file_hash_chunk: usize = 64 * 1024;

/// Maximum supported symlink target length. Linux's PATH_MAX is 4096;
/// keeping it on the stack avoids an allocation for every symlink.
const symlink_target_max: usize = 4096;

pub const EntryKind = enum {
    file,
    dir,
    symlink,
};

/// One entry in a loaded build context. Paths are forward-slash
/// relative paths from the context root. The root itself is not
/// represented as an entry.
pub const ContextEntry = struct {
    path: []const u8,
    kind: EntryKind,
    /// POSIX mode bits (lower 12). 0 on Windows where the concept does
    /// not apply directly.
    mode: u32,
    /// Byte size of the file body. 0 for directories and symlinks.
    size: u64,
    /// Content hash. `null` for directories. For symlinks this is the
    /// sha256 of the target-string bytes, not the pointed-at file.
    digest: ?[digest_mod.byte_length]u8,
};

pub const Severity = enum { warn };

/// Non-fatal observation made during `load`.
pub const Diagnostic = struct {
    severity: Severity,
    path: []const u8,
    message: []const u8,
};

pub const Iterator = struct {
    entries: []const ContextEntry,
    pos: usize,

    pub fn next(self: *Iterator) ?ContextEntry {
        if (self.pos >= self.entries.len) return null;
        const e = self.entries[self.pos];
        self.pos += 1;
        return e;
    }

    pub fn reset(self: *Iterator) void {
        self.pos = 0;
    }
};

pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const ContextEntry,
    diagnostics: []const Diagnostic,
    /// Name of the ignore file that was consumed, or null if neither
    /// `.containerignore` nor `.dockerignore` existed.
    ignore_file: ?[]const u8,

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
    }

    pub fn iter(self: *const Context) Iterator {
        return .{ .entries = self.entries, .pos = 0 };
    }

    /// Hashes the canonical (path, mode, digest) tuple of every entry
    /// whose path matches at least one of `patterns`. Determinism comes
    /// from the entries already being lex-sorted at load time and the
    /// canonical record format being byte-stable.
    pub fn digestSubset(
        self: *const Context,
        gpa: Allocator,
        patterns: []const []const u8,
    ) ![digest_mod.byte_length]u8 {
        for (patterns) |p| {
            try validateGlob(p);
        }

        var hasher = digest_mod.Hasher.init();
        const zero32: [digest_mod.byte_length]u8 = @splat(0);

        for (self.entries) |e| {
            var matched = false;
            for (patterns) |p| {
                if (matchGlob(p, e.path)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;

            hasher.update(e.path);
            hasher.update(&[_]u8{0});
            const mode_le = std.mem.toBytes(std.mem.nativeToLittle(u32, e.mode));
            hasher.update(&mode_le);
            if (e.digest) |d| {
                hasher.update(&d);
            } else {
                hasher.update(&zero32);
            }
            hasher.update(&[_]u8{'\n'});
        }

        _ = gpa;
        return hasher.final().bytes;
    }
};

/// Walks `root` and returns a populated `Context`. `root` must be
/// opened with `.{ .iterate = true }` so that the recursive walker can
/// descend into it.
pub fn load(io: Io, gpa: Allocator, root: Io.Dir) !Context {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const ignore_pick = try readIgnoreFile(io, root, aa);

    var program: IgnoreProgram = .{ .rules = &.{} };
    if (ignore_pick.bytes.len != 0) {
        program = try IgnoreProgram.parse(aa, ignore_pick.bytes);
    }

    var entries: std.ArrayList(ContextEntry) = .empty;
    var diags: std.ArrayList(Diagnostic) = .empty;

    try walkAndHash(io, aa, root, program, &entries, &diags, ignore_pick.name);

    const entries_slice = try entries.toOwnedSlice(aa);
    std.sort.block(ContextEntry, entries_slice, {}, lessByPath);

    return .{
        .arena = arena,
        .entries = entries_slice,
        .diagnostics = try diags.toOwnedSlice(aa),
        .ignore_file = ignore_pick.name,
    };
}

fn lessByPath(_: void, a: ContextEntry, b: ContextEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const IgnorePick = struct {
    name: ?[]const u8,
    bytes: []const u8,
};

fn readIgnoreFile(io: Io, root: Io.Dir, aa: Allocator) !IgnorePick {
    for (ignore_filenames) |name| {
        const bytes = root.readFileAlloc(io, name, aa, ignore_file_byte_limit) catch |err| switch (err) {
            error.FileNotFound, error.IsDir, error.NotDir => continue,
            else => |e| return e,
        };
        return .{ .name = name, .bytes = bytes };
    }
    return .{ .name = null, .bytes = "" };
}

const IgnoreRule = struct {
    negate: bool,
    dir_only: bool,
    anchored: bool,
    /// Glob pattern, with the leading `!`, leading `/`, and trailing
    /// `/` stripped. Owned by the same arena as `IgnoreProgram`.
    pattern: []const u8,
};

const IgnoreProgram = struct {
    rules: []const IgnoreRule,

    fn parse(aa: Allocator, source: []const u8) !IgnoreProgram {
        var rules: std.ArrayList(IgnoreRule) = .empty;
        var line_iter = std.mem.splitScalar(u8, source, '\n');
        while (line_iter.next()) |raw| {
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            line = std.mem.trimEnd(u8, line, " \t");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            const rule = try parseRule(aa, line) orelse continue;
            try rules.append(aa, rule);
        }
        return .{ .rules = try rules.toOwnedSlice(aa) };
    }

    /// Returns true when `path` is excluded by the current rule list.
    /// Last-match-wins: scan all rules, the last matching rule decides.
    /// A rule that matches an ancestor directory of `path` propagates to
    /// `path` itself, with negation rules able to override that
    /// inheritance (Docker `.dockerignore` semantics, not gitignore).
    fn isExcluded(self: IgnoreProgram, path: []const u8, is_dir: bool) bool {
        var excluded = false;
        for (self.rules) |r| {
            if ((!r.dir_only or is_dir) and matchRule(r, path)) {
                excluded = !r.negate;
                continue;
            }
            if (anyAncestorMatches(r, path)) {
                excluded = !r.negate;
            }
        }
        return excluded;
    }
};

fn anyAncestorMatches(rule: IgnoreRule, path: []const u8) bool {
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, idx, '/')) |slash| {
        const ancestor = path[0..slash];
        if (matchRule(rule, ancestor)) return true;
        idx = slash + 1;
    }
    return false;
}

fn parseRule(aa: Allocator, line: []const u8) !?IgnoreRule {
    var p = line;
    var negate = false;
    if (p.len > 0 and p[0] == '!') {
        negate = true;
        p = p[1..];
    }
    var dir_only = false;
    if (p.len > 0 and p[p.len - 1] == '/') {
        dir_only = true;
        p = p[0 .. p.len - 1];
    }
    if (p.len == 0) return null;

    const slash_index = std.mem.indexOfScalar(u8, p, '/');
    const anchored = slash_index != null;
    if (anchored and p[0] == '/') p = p[1..];
    if (p.len == 0) return null;

    const owned = try aa.dupe(u8, p);
    return IgnoreRule{
        .negate = negate,
        .dir_only = dir_only,
        .anchored = anchored,
        .pattern = owned,
    };
}

fn matchRule(rule: IgnoreRule, path: []const u8) bool {
    if (rule.anchored) return matchGlob(rule.pattern, path);
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const basename = if (slash) |s| path[s + 1 ..] else path;
    return matchGlob(rule.pattern, basename);
}

fn validateGlob(pattern: []const u8) !void {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => {
                if (i + 1 >= pattern.len) return error.BadPattern;
                i += 1;
            },
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, pattern, i + 1, ']') orelse
                    return error.BadPattern;
                if (close == i + 1) return error.BadPattern;
                i = close;
            },
            else => {},
        }
    }
}

fn matchGlob(pattern: []const u8, text: []const u8) bool {
    return matchGlobAt(pattern, 0, text, 0);
}

fn matchGlobAt(pat: []const u8, p_in: usize, txt: []const u8, t_in: usize) bool {
    var p = p_in;
    var t = t_in;
    while (p < pat.len) {
        const c = pat[p];
        switch (c) {
            '*' => {
                if (p + 1 < pat.len and pat[p + 1] == '*') {
                    var p_next = p + 2;
                    if (p_next < pat.len and pat[p_next] == '/') p_next += 1;
                    while (true) {
                        if (matchGlobAt(pat, p_next, txt, t)) return true;
                        if (t >= txt.len) return false;
                        t += 1;
                    }
                } else {
                    const p_next = p + 1;
                    while (true) {
                        if (matchGlobAt(pat, p_next, txt, t)) return true;
                        if (t >= txt.len) return false;
                        if (txt[t] == '/') return false;
                        t += 1;
                    }
                }
            },
            '?' => {
                if (t >= txt.len or txt[t] == '/') return false;
                t += 1;
                p += 1;
            },
            '[' => {
                if (t >= txt.len or txt[t] == '/') return false;
                const close = std.mem.indexOfScalarPos(u8, pat, p + 1, ']') orelse return false;
                if (!matchClass(pat[p + 1 .. close], txt[t])) return false;
                t += 1;
                p = close + 1;
            },
            '\\' => {
                if (p + 1 >= pat.len) return false;
                const lit = pat[p + 1];
                if (t >= txt.len or txt[t] != lit) return false;
                t += 1;
                p += 2;
            },
            else => {
                if (t >= txt.len or txt[t] != c) return false;
                t += 1;
                p += 1;
            },
        }
    }
    return t == txt.len;
}

fn matchClass(body: []const u8, c: u8) bool {
    if (body.len == 0) return false;
    var i: usize = 0;
    var negate = false;
    if (body[0] == '!' or body[0] == '^') {
        negate = true;
        i = 1;
    }
    var found = false;
    while (i < body.len) {
        if (i + 2 < body.len and body[i + 1] == '-') {
            if (c >= body[i] and c <= body[i + 2]) found = true;
            i += 3;
        } else {
            if (c == body[i]) found = true;
            i += 1;
        }
    }
    return found != negate;
}

fn walkAndHash(
    io: Io,
    aa: Allocator,
    root: Io.Dir,
    program: IgnoreProgram,
    entries: *std.ArrayList(ContextEntry),
    diags: *std.ArrayList(Diagnostic),
    ignore_name: ?[]const u8,
) !void {
    var walker = try root.walk(aa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const norm_path = try normalisePath(aa, entry.path);

        const kind: EntryKind = switch (entry.kind) {
            .file => .file,
            .directory => .dir,
            .sym_link => .symlink,
            .block_device, .character_device, .named_pipe, .unix_domain_socket, .door, .event_port, .whiteout, .unknown => {
                try diags.append(aa, .{
                    .severity = .warn,
                    .path = norm_path,
                    .message = try std.fmt.allocPrint(
                        aa,
                        "skipping unsupported file kind: {s}",
                        .{@tagName(entry.kind)},
                    ),
                });
                continue;
            },
        };

        const is_dir = kind == .dir;
        if (program.isExcluded(norm_path, is_dir)) continue;

        if (ignore_name) |name| {
            if (std.mem.eql(u8, norm_path, name)) continue;
        }

        const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
        const mode_bits: u32 = @intCast(stat.permissions.toMode() & 0o7777);

        var size: u64 = 0;
        var maybe_digest: ?[digest_mod.byte_length]u8 = null;

        switch (kind) {
            .file => {
                size = stat.size;
                maybe_digest = try hashRegularFile(io, entry.dir, entry.basename);
            },
            .symlink => {
                var target_buf: [symlink_target_max]u8 = undefined;
                const n = try entry.dir.readLink(io, entry.basename, &target_buf);
                const target = target_buf[0..n];
                maybe_digest = digest_mod.Hasher.hash(target).bytes;
                size = 0;
            },
            .dir => {},
        }

        try entries.append(aa, .{
            .path = norm_path,
            .kind = kind,
            .mode = mode_bits,
            .size = size,
            .digest = maybe_digest,
        });
    }
}

fn hashRegularFile(io: Io, dir: Io.Dir, sub_path: []const u8) ![digest_mod.byte_length]u8 {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);

    var buf: [file_hash_chunk]u8 = undefined;
    var fr = file.reader(io, &.{});
    var hasher = digest_mod.Hasher.init();

    while (true) {
        const n = fr.interface.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => return fr.err.?,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.final().bytes;
}

fn normalisePath(aa: Allocator, raw: []const u8) ![]const u8 {
    const out = try aa.alloc(u8, raw.len);
    for (raw, 0..) |c, i| {
        out[i] = if (c == std.fs.path.sep) '/' else c;
    }
    return out;
}

const testing = std.testing;

test "parseRule: trailing slash means dir-only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try parseRule(arena.allocator(), "build/")).?;
    try testing.expect(r.dir_only);
    try testing.expect(!r.negate);
    try testing.expect(!r.anchored);
    try testing.expectEqualStrings("build", r.pattern);
}

test "parseRule: leading bang sets negate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try parseRule(arena.allocator(), "!keep.log")).?;
    try testing.expect(r.negate);
    try testing.expectEqualStrings("keep.log", r.pattern);
}

test "parseRule: pattern with internal slash is anchored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try parseRule(arena.allocator(), "src/secret.txt")).?;
    try testing.expect(r.anchored);
    try testing.expectEqualStrings("src/secret.txt", r.pattern);
}

test "parseRule: leading slash is stripped, still anchored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try parseRule(arena.allocator(), "/build")).?;
    try testing.expect(r.anchored);
    try testing.expectEqualStrings("build", r.pattern);
}

test "matchGlob: single * does not cross slash" {
    try testing.expect(matchGlob("*.tmp", "foo.tmp"));
    try testing.expect(!matchGlob("*.tmp", "dir/foo.tmp"));
    try testing.expect(matchGlob("a*c", "abc"));
    try testing.expect(matchGlob("a*c", "axxxc"));
    try testing.expect(!matchGlob("a*c", "ab/c"));
}

test "matchGlob: ** matches across slashes" {
    try testing.expect(matchGlob("**/foo", "foo"));
    try testing.expect(matchGlob("**/foo", "a/foo"));
    try testing.expect(matchGlob("**/foo", "a/b/c/foo"));
    try testing.expect(matchGlob("a/**/b", "a/b"));
    try testing.expect(matchGlob("a/**/b", "a/x/b"));
    try testing.expect(matchGlob("a/**/b", "a/x/y/b"));
    try testing.expect(matchGlob("foo/**", "foo/bar"));
    try testing.expect(matchGlob("foo/**", "foo/bar/baz"));
}

test "matchGlob: ? matches one non-slash byte" {
    try testing.expect(matchGlob("a?c", "abc"));
    try testing.expect(!matchGlob("a?c", "ac"));
    try testing.expect(!matchGlob("a?c", "a/c"));
}

test "matchGlob: character class" {
    try testing.expect(matchGlob("[abc].txt", "a.txt"));
    try testing.expect(matchGlob("[abc].txt", "b.txt"));
    try testing.expect(!matchGlob("[abc].txt", "d.txt"));
    try testing.expect(matchGlob("[a-z].txt", "m.txt"));
    try testing.expect(!matchGlob("[a-z].txt", "M.txt"));
    try testing.expect(matchGlob("[!a].txt", "b.txt"));
    try testing.expect(!matchGlob("[!a].txt", "a.txt"));
}

test "IgnoreProgram: blank lines and comments are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "# a comment\n\n\nbuild/\n# trailing\n";
    const program = try IgnoreProgram.parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 1), program.rules.len);
    try testing.expectEqualStrings("build", program.rules[0].pattern);
}

test "IgnoreProgram: last-match-wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "build/\n!build/keep.bin\n";
    const program = try IgnoreProgram.parse(arena.allocator(), src);

    try testing.expect(program.isExcluded("build", true));
    try testing.expect(program.isExcluded("build/temp.bin", false));
    try testing.expect(!program.isExcluded("build/keep.bin", false));
}

test "IgnoreProgram: anchored pattern matches root only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "/secret.txt\n";
    const program = try IgnoreProgram.parse(arena.allocator(), src);

    try testing.expect(program.isExcluded("secret.txt", false));
    try testing.expect(!program.isExcluded("nested/secret.txt", false));
}

test "IgnoreProgram: unanchored pattern matches any depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "node_modules\n";
    const program = try IgnoreProgram.parse(arena.allocator(), src);

    try testing.expect(program.isExcluded("node_modules", true));
    try testing.expect(program.isExcluded("a/node_modules", true));
    try testing.expect(program.isExcluded("a/b/node_modules", true));
}

test "IgnoreProgram: dir-only does not match files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "log/\n";
    const program = try IgnoreProgram.parse(arena.allocator(), src);

    try testing.expect(program.isExcluded("log", true));
    try testing.expect(!program.isExcluded("log", false));
}

test "validateGlob: rejects unterminated escape and class" {
    try testing.expectError(error.BadPattern, validateGlob("foo\\"));
    try testing.expectError(error.BadPattern, validateGlob("foo[abc"));
    try testing.expectError(error.BadPattern, validateGlob("foo[]"));
    try validateGlob("foo*.tmp");
    try validateGlob("**/*.zig");
    try validateGlob("[a-z]");
    try validateGlob("\\*literal");
}

test "load: simple tree with file and subdir" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hello" });
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/b.txt", .data = "world" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    try testing.expectEqual(@as(usize, 3), ctx.entries.len);
    try testing.expectEqualStrings("a.txt", ctx.entries[0].path);
    try testing.expectEqualStrings("sub", ctx.entries[1].path);
    try testing.expectEqualStrings("sub/b.txt", ctx.entries[2].path);
    try testing.expectEqual(EntryKind.file, ctx.entries[0].kind);
    try testing.expectEqual(EntryKind.dir, ctx.entries[1].kind);
    try testing.expectEqual(EntryKind.file, ctx.entries[2].kind);
    try testing.expect(ctx.entries[0].digest != null);
    try testing.expect(ctx.entries[1].digest == null);
}

test "load: containerignore excludes a subtree" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".containerignore", .data = "build/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.zig", .data = "// keep" });
    try tmp.dir.createDirPath(testing.io, "build");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build/output.bin", .data = "skip" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    for (ctx.entries) |e| {
        try testing.expect(!std.mem.startsWith(u8, e.path, "build"));
        try testing.expect(!std.mem.eql(u8, e.path, ".containerignore"));
    }
    try testing.expectEqualStrings("main.zig", ctx.entries[0].path);
    try testing.expect(ctx.ignore_file != null);
    try testing.expectEqualStrings(".containerignore", ctx.ignore_file.?);
}

test "load: dockerignore is fallback when containerignore is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".dockerignore", .data = "*.tmp\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "keep.zig", .data = "k" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x.tmp", .data = "drop" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    try testing.expect(ctx.ignore_file != null);
    try testing.expectEqualStrings(".dockerignore", ctx.ignore_file.?);
    for (ctx.entries) |e| {
        try testing.expect(!std.mem.endsWith(u8, e.path, ".tmp"));
    }
}

test "load: containerignore wins over dockerignore" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".containerignore", .data = "*.a\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".dockerignore", .data = "*.b\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x.a", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "y.b", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "z.txt", .data = "" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    try testing.expectEqualStrings(".containerignore", ctx.ignore_file.?);
    var saw_yb = false;
    var saw_ztxt = false;
    var saw_xa = false;
    for (ctx.entries) |e| {
        if (std.mem.eql(u8, e.path, "y.b")) saw_yb = true;
        if (std.mem.eql(u8, e.path, "z.txt")) saw_ztxt = true;
        if (std.mem.eql(u8, e.path, "x.a")) saw_xa = true;
    }
    try testing.expect(saw_yb);
    try testing.expect(saw_ztxt);
    try testing.expect(!saw_xa);
}

test "load: entries are sorted lex by path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "z.txt", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m.txt", .data = "" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    try testing.expectEqualStrings("a.txt", ctx.entries[0].path);
    try testing.expectEqualStrings("m.txt", ctx.entries[1].path);
    try testing.expectEqualStrings("z.txt", ctx.entries[2].path);
}

test "digestSubset: stable across pattern order" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "alpha" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "bravo" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "charlie" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const order_one = [_][]const u8{ "a.zig", "b.zig" };
    const order_two = [_][]const u8{ "b.zig", "a.zig" };
    const d1 = try ctx.digestSubset(testing.allocator, order_one[0..]);
    const d2 = try ctx.digestSubset(testing.allocator, order_two[0..]);
    try testing.expectEqualSlices(u8, &d1, &d2);
}

test "digestSubset: subset changes when matched content changes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "in.zig", .data = "first" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out.zig", .data = "stable" });

    var ctx_a = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx_a.deinit();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "in.zig", .data = "second" });

    var ctx_b = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx_b.deinit();

    const patterns = [_][]const u8{"in.zig"};
    const da = try ctx_a.digestSubset(testing.allocator, patterns[0..]);
    const db = try ctx_b.digestSubset(testing.allocator, patterns[0..]);
    try testing.expect(!std.mem.eql(u8, &da, &db));
}

test "digestSubset: rejects unterminated character class" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const bad = [_][]const u8{"foo[abc"};
    try testing.expectError(error.BadPattern, ctx.digestSubset(testing.allocator, bad[0..]));
}

test "digestSubset: ** glob includes nested files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = "m" });
    try tmp.dir.createDirPath(testing.io, "src/util");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/util/helper.zig", .data = "h" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig", .data = "b" });

    var ctx = try load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const all = [_][]const u8{"**/*.zig"};
    const root_only = [_][]const u8{"*.zig"};
    const da = try ctx.digestSubset(testing.allocator, all[0..]);
    const db = try ctx.digestSubset(testing.allocator, root_only[0..]);
    try testing.expect(!std.mem.eql(u8, &da, &db));
}
