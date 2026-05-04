//! Bind-mount spec parsing for `rind run -v host:container[:ro]`.
//!
//! Docker-compatible subset:
//!   - Two- or three-field `host:container[:ro|:rw]` form only.
//!   - `source` and `destination` must be absolute paths.
//!   - `:ro` / `:rw` are the only third-field tokens accepted; everything
//!     else (`:Z`, `:U`, `:create`, `:cached`, propagation modes) is
//!     rejected so the surface stays small and predictable.
//!
//! Readability is checked as the real euid via `Io.Dir.accessAbsolute`.
//! rind is not setuid, so this is the same authority the caller already
//! has — there's no path by which a privileged bind-mount could be
//! arranged through this validator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One parsed `-v host:container[:ro]` spec. Source and destination are
/// borrowed slices into the input strings; the slice itself returned by
/// `parseAll` is owned by the caller's allocator.
pub const UserMount = struct {
    /// Absolute host path. Borrowed from the input spec.
    source: []const u8,
    /// Absolute container path. Borrowed from the input spec.
    destination: []const u8,
    /// `:ro` was supplied (or `:rw` rejected). Defaults to false.
    read_only: bool,
};

/// Closed semantic error set returned by `parseAll`.
pub const SpecError = error{
    /// Spec didn't match `<src>:<dst>` or `<src>:<dst>:<ro|rw>`, had
    /// empty fields, or used an unsupported third-field token.
    InvalidVolumeSpec,
    /// `source` couldn't be opened for read by the calling user. Covers
    /// `EACCES`, `EPERM`, and `ENOENT` — collapsed because the user
    /// can't disambiguate from the spec text.
    VolumeSourceUnreadable,
    /// `source` was not an absolute path. `destination` falling foul of
    /// the same rule reports `InvalidVolumeSpec` (caller-supplied dest
    /// is treated as a structural problem, not an authority one).
    VolumeSourceNotAbsolute,
} || Allocator.Error;

/// Parse every `-v` spec in `raws`. Returns a freshly-allocated slice
/// of `UserMount`s; release with `freeAll`. The first failing spec
/// stops the parse — partial results are freed before returning.
pub fn parseAll(io: Io, gpa: Allocator, raws: []const []const u8) SpecError![]UserMount {
    var out = try gpa.alloc(UserMount, raws.len);
    errdefer gpa.free(out);
    for (raws, 0..) |raw, i| {
        out[i] = try parseOne(io, raw);
    }
    return out;
}

/// Mirror of `parseAll`'s allocation. Safe to call on the return value
/// of `parseAll`; no per-`UserMount` cleanup is needed because the
/// strings borrow from caller-owned input.
pub fn freeAll(gpa: Allocator, mounts: []UserMount) void {
    gpa.free(mounts);
}

/// Parse a single `host:container[:ro|:rw]` spec. Exposed for tests;
/// production code calls `parseAll`.
pub fn parseOne(io: Io, raw: []const u8) SpecError!UserMount {
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;

    var iter = std.mem.splitScalar(u8, raw, ':');
    while (iter.next()) |p| {
        if (part_count >= 3) return SpecError.InvalidVolumeSpec;
        parts[part_count] = p;
        part_count += 1;
    }
    if (part_count < 2) return SpecError.InvalidVolumeSpec;
    if (parts[0].len == 0 or parts[1].len == 0) return SpecError.InvalidVolumeSpec;

    var read_only = false;
    if (part_count == 3) {
        if (std.mem.eql(u8, parts[2], "ro")) {
            read_only = true;
        } else if (std.mem.eql(u8, parts[2], "rw")) {
            read_only = false;
        } else {
            return SpecError.InvalidVolumeSpec;
        }
    }

    if (parts[0][0] != '/') return SpecError.VolumeSourceNotAbsolute;
    if (parts[1][0] != '/') return SpecError.InvalidVolumeSpec;

    Io.Dir.accessAbsolute(io, parts[0], .{ .read = true }) catch |err| switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.FileNotFound,
        => return SpecError.VolumeSourceUnreadable,
        else => return SpecError.VolumeSourceUnreadable,
    };

    return .{
        .source = parts[0],
        .destination = parts[1],
        .read_only = read_only,
    };
}

const testing = std.testing;

fn touch(io: Io, dir: std.testing.TmpDir, sub: []const u8) !void {
    try dir.dir.writeFile(io, .{ .sub_path = sub, .data = "x" });
}

fn absInTmp(gpa: Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, sub });
}

test "parseOne: valid two-field rw spec" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try touch(testing.io, tmp, "src");

    const src = try absInTmp(testing.allocator, &tmp, "src");
    defer testing.allocator.free(src);
    const raw = try std.fmt.allocPrint(testing.allocator, "{s}:/data", .{src});
    defer testing.allocator.free(raw);

    const m = try parseOne(testing.io, raw);
    try testing.expectEqualStrings(src, m.source);
    try testing.expectEqualStrings("/data", m.destination);
    try testing.expectEqual(false, m.read_only);
}

test "parseOne: valid three-field :ro spec" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try touch(testing.io, tmp, "src");

    const src = try absInTmp(testing.allocator, &tmp, "src");
    defer testing.allocator.free(src);
    const raw = try std.fmt.allocPrint(testing.allocator, "{s}:/data:ro", .{src});
    defer testing.allocator.free(raw);

    const m = try parseOne(testing.io, raw);
    try testing.expectEqual(true, m.read_only);
}

test "parseOne: explicit :rw spec resolves to read_only=false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try touch(testing.io, tmp, "src");

    const src = try absInTmp(testing.allocator, &tmp, "src");
    defer testing.allocator.free(src);
    const raw = try std.fmt.allocPrint(testing.allocator, "{s}:/data:rw", .{src});
    defer testing.allocator.free(raw);

    const m = try parseOne(testing.io, raw);
    try testing.expectEqual(false, m.read_only);
}

test "parseOne: rejects four-field spec" {
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, "/a:/b:ro:extra"));
}

test "parseOne: rejects single-field spec" {
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, "/lonely"));
}

test "parseOne: rejects empty source" {
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, ":/dest"));
}

test "parseOne: rejects empty destination" {
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, "/src:"));
}

test "parseOne: rejects unknown third-field token" {
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, "/src:/dst:Z"));
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, "/src:/dst:cached"));
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, "/src:/dst:rprivate"));
}

test "parseOne: rejects relative source" {
    try testing.expectError(SpecError.VolumeSourceNotAbsolute, parseOne(testing.io, "rel/src:/dst"));
}

test "parseOne: rejects relative destination" {
    try testing.expectError(SpecError.InvalidVolumeSpec, parseOne(testing.io, "/abs/src:rel/dst"));
}

test "parseOne: nonexistent source surfaces VolumeSourceUnreadable" {
    try testing.expectError(
        SpecError.VolumeSourceUnreadable,
        parseOne(testing.io, "/does/not/exist/anywhere:/dst"),
    );
}

test "parseAll: parses two specs and frees cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try touch(testing.io, tmp, "a");
    try touch(testing.io, tmp, "b");

    const a = try absInTmp(testing.allocator, &tmp, "a");
    defer testing.allocator.free(a);
    const b = try absInTmp(testing.allocator, &tmp, "b");
    defer testing.allocator.free(b);

    const r0 = try std.fmt.allocPrint(testing.allocator, "{s}:/x", .{a});
    defer testing.allocator.free(r0);
    const r1 = try std.fmt.allocPrint(testing.allocator, "{s}:/y:ro", .{b});
    defer testing.allocator.free(r1);

    const out = try parseAll(testing.io, testing.allocator, &.{ r0, r1 });
    defer freeAll(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("/x", out[0].destination);
    try testing.expectEqualStrings("/y", out[1].destination);
    try testing.expectEqual(true, out[1].read_only);
}
