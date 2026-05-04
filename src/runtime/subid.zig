//! `/etc/subuid` / `/etc/subgid` / `/etc/passwd` lookups.
//!
//! Shared by `runtime/overlay.zig` (which feeds the lookup results to
//! `newuidmap` / `newgidmap` when joining a fresh user namespace) and
//! `runtime/bundle.zig` (which encodes the same ranges as multi-line
//! OCI `linux.uidMappings` / `gidMappings` so libcrun can map
//! container-side uids > 0 against the calling user's subuid range).
//!
//! The parsers are pure — they take a byte slice and return the parsed
//! result. The `*Alloc` wrappers add the I/O layer (1 MiB cap on each
//! file; subuid/passwd files in the wild are KB).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

/// Closed error set returned by every public function in this module.
/// Composed into `runtime/overlay.zig:OverlayError` and
/// `runtime/bundle.zig:BundleError` so callers can `try` without
/// re-spelling the union.
pub const SubidError = error{
    /// `/etc/sub{u,g}id` exists but has no line whose first column
    /// matches either the username or the numeric id of the calling
    /// user. Configure with `usermod --add-subuids` (or distro-specific
    /// equivalent) or run as root.
    SubidNotConfigured,
    /// A `/etc/sub{u,g}id` line for the calling user is present but
    /// malformed (missing `:` separators or non-numeric range fields).
    SubidMalformed,
    /// `/etc/passwd` has no line whose `uid` field matches the supplied
    /// numeric uid. Indicates a hostile or stripped passwd database.
    UserLookupFailed,
} || Allocator.Error;

/// Cap on a single passwd / subuid / subgid read into memory. 1 MiB
/// is generous; these files are KB in practice.
pub const file_max_bytes: usize = 1 << 20;

/// Parsed range from a single `/etc/sub{u,g}id` line.
pub const Range = struct {
    /// First host id in the contiguous range.
    start: u32,
    /// Number of consecutive ids (size of the range).
    count: u32,
};

/// Read `/etc/passwd` (or any path with the same shape) and return the
/// username whose `uid` field equals `target_uid`. Caller owns the
/// returned slice.
pub fn lookupUsernameAlloc(
    io: Io,
    gpa: Allocator,
    passwd_path: []const u8,
    target_uid: linux.uid_t,
) SubidError![]u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, passwd_path, gpa, .limited(file_max_bytes)) catch
        return SubidError.UserLookupFailed;
    defer gpa.free(bytes);

    return parsePasswd(gpa, bytes, target_uid);
}

/// Read `/etc/subuid` or `/etc/subgid` and return the range matching
/// either `username` or the textual form of `numeric_id`. Both forms
/// are accepted per `subuid(5)`.
pub fn lookupSubidAlloc(
    io: Io,
    gpa: Allocator,
    path: []const u8,
    username: []const u8,
    numeric_id: u32,
) SubidError!Range {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_max_bytes)) catch
        return SubidError.SubidNotConfigured;
    defer gpa.free(bytes);
    return parseSubid(bytes, username, numeric_id);
}

/// Pure parser used by `lookupUsernameAlloc` and the test block.
/// Caller owns the returned slice.
pub fn parsePasswd(
    gpa: Allocator,
    passwd: []const u8,
    target_uid: linux.uid_t,
) SubidError![]u8 {
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        // Format: name:passwd:uid:gid:gecos:home:shell
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue; // passwd
        const uid_str = fields.next() orelse continue;

        const uid = std.fmt.parseInt(u32, uid_str, 10) catch continue;
        if (uid == target_uid) {
            return gpa.dupe(u8, name);
        }
    }
    return SubidError.UserLookupFailed;
}

/// Pure parser used by `lookupSubidAlloc` and the test block.
pub fn parseSubid(
    subid: []const u8,
    username: []const u8,
    numeric_id: u32,
) SubidError!Range {
    var lines = std.mem.splitScalar(u8, subid, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        // Format: <name-or-uid>:<start>:<count>
        var fields = std.mem.splitScalar(u8, line, ':');
        const owner = fields.next() orelse continue;
        const start_str = fields.next() orelse return SubidError.SubidMalformed;
        const count_str = fields.next() orelse return SubidError.SubidMalformed;

        const matches_name = std.mem.eql(u8, owner, username);
        const matches_id = blk: {
            const parsed = std.fmt.parseInt(u32, owner, 10) catch break :blk false;
            break :blk parsed == numeric_id;
        };
        if (!(matches_name or matches_id)) continue;

        const start = std.fmt.parseInt(u32, start_str, 10) catch
            return SubidError.SubidMalformed;
        const count = std.fmt.parseInt(u32, count_str, 10) catch
            return SubidError.SubidMalformed;
        return .{ .start = start, .count = count };
    }
    return SubidError.SubidNotConfigured;
}

const testing = std.testing;

test "parsePasswd: first match wins, returns owned slice" {
    const passwd =
        \\root:x:0:0:root:/root:/bin/sh
        \\alice:x:1000:1000::/home/alice:/bin/sh
        \\bob:x:1001:1001::/home/bob:/bin/sh
    ;
    const name = try parsePasswd(testing.allocator, passwd, 1000);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("alice", name);
}

test "parsePasswd: missing uid surfaces UserLookupFailed" {
    const passwd =
        \\root:x:0:0:root:/root:/bin/sh
        \\alice:x:1000:1000::/home/alice:/bin/sh
    ;
    try testing.expectError(SubidError.UserLookupFailed, parsePasswd(testing.allocator, passwd, 9999));
}

test "parseSubid: matches by username" {
    const text =
        \\alice:100000:65536
        \\bob:200000:65536
    ;
    const r = try parseSubid(text, "alice", 1000);
    try testing.expectEqual(@as(u32, 100000), r.start);
    try testing.expectEqual(@as(u32, 65536), r.count);
}

test "parseSubid: matches by numeric uid form" {
    const text = "1000:300000:65536\n";
    const r = try parseSubid(text, "alice", 1000);
    try testing.expectEqual(@as(u32, 300000), r.start);
}

test "parseSubid: no match → SubidNotConfigured" {
    const text = "alice:100000:65536\n";
    try testing.expectError(SubidError.SubidNotConfigured, parseSubid(text, "carol", 1234));
}

test "parseSubid: malformed line → SubidMalformed" {
    const text = "alice:100000\n";
    try testing.expectError(SubidError.SubidMalformed, parseSubid(text, "alice", 1000));
}

test "parseSubid: comments and blanks are skipped" {
    const text =
        \\# comment
        \\
        \\alice:100000:65536
    ;
    const r = try parseSubid(text, "alice", 1000);
    try testing.expectEqual(@as(u32, 100000), r.start);
}
