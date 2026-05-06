//! Manifest cache: skip the network on warm pull.
//!
//! Stores one sidecar JSON file per `(registry, repository, reference)`
//! tuple under `<store>/cache/manifests/v1/<sha256(key)>.json`. The
//! manifest body itself is not duplicated — it already lives in the
//! content-addressed `blobs/sha256/` tree, keyed by `manifest_digest`.
//! The cache only records the indirection from a human ref to that
//! digest plus the `ETag` and `expires_at_unix` needed for conditional
//! revalidation.
//!
//! TTL semantics: tag-style references (`alpine:3.19`) expire after
//! `defaultTtlSeconds()` (default 300, override `RIND_MANIFEST_TTL`).
//! Digest pins (`...@sha256:...`) never expire — the digest IS the
//! identity, so the registry can never serve a different body.
//!
//! Concurrency: the OCI store is single-writer (see `layout.zig` doc).
//! Cache writes go through `createFileAtomic` so a partial write is
//! never visible at the final path; concurrent writers of the same
//! ref produce a last-writer-wins outcome with no torn files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const digest_mod = @import("../image/digest.zig");
const layout = @import("layout.zig");

/// Subpath under the store root where cache sidecars live.
pub const cache_subpath: []const u8 = "cache/manifests/v1";

/// Default TTL (seconds) for tag-style references. Five minutes is
/// the same value Docker uses for its image-pull staleness check.
pub const default_tag_ttl_seconds: i64 = 300;

/// Per-ref cache record. Strings are JSON-owned (arena-backed when
/// returned via `lookup`).
pub const Entry = struct {
    /// Schema version. Bumped if the on-disk shape changes; older
    /// records become a cache miss after a version mismatch.
    schema: u32 = 1,
    /// `sha256:...` form of the manifest blob already stored under
    /// `<store>/blobs/sha256/`.
    manifest_digest: []const u8,
    /// `Content-Type` of the manifest (e.g. OCI v1 vs Docker schema-2).
    media_type: []const u8,
    /// Last-seen `ETag` header value, or null if the registry omitted
    /// one. Used to send `If-None-Match` on the next refresh.
    etag: ?[]const u8 = null,
    /// Unix timestamp (seconds) after which the entry is stale and
    /// must be revalidated. `std.math.maxInt(i64)` for digest pins.
    expires_at_unix: i64,
    /// Size of the manifest body in bytes. Used for tagging
    /// `index.json` after a 304 (we re-tag with the same descriptor).
    size: u64,
    /// Original registry host (denormalized for debugging — `cat
    /// cache/manifests/v1/*.json` is meant to be human-readable).
    registry: []const u8,
    /// Original repository.
    repository: []const u8,
    /// Original reference (tag or `sha256:...`).
    reference: []const u8,
};

/// Parsed cache record. Wraps `std.json.Parsed(Entry)` so callers can
/// keep the same `.value` / `.deinit()` ergonomics as the rest of the
/// codebase (see `layout.Store.readIndex`).
pub const Parsed = std.json.Parsed(Entry);

/// Errors returned by `lookup`. A missing or unreadable file is not
/// surfaced — the orchestrator just falls through to a network fetch.
pub const LookupError = Allocator.Error;

/// Errors returned by `store`.
pub const StoreError =
    Io.Dir.CreateDirPathOpenError ||
    Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.ReplaceError ||
    Io.File.Writer.Error ||
    std.json.Stringify.Error ||
    Allocator.Error;

/// True iff `entry` is still valid for the wall-clock instant `now_unix`.
pub fn isFresh(entry: Entry, now_unix: i64) bool {
    return now_unix < entry.expires_at_unix;
}

/// Compute `expires_at_unix` for a freshly fetched manifest. Digest
/// pins are immortal; tags pick up `tag_ttl_seconds` from the caller
/// (CLI threads `default_tag_ttl_seconds` by default; an env-var
/// override is applied at the entry point so no transitive env-read
/// happens here).
pub fn computeExpiry(reference: []const u8, now_unix: i64, tag_ttl_seconds: i64) i64 {
    if (isDigestRef(reference)) return std.math.maxInt(i64);
    return now_unix +| tag_ttl_seconds;
}

/// `true` if `reference` is a digest pin (starts with `sha256:`).
pub fn isDigestRef(reference: []const u8) bool {
    return std.mem.startsWith(u8, reference, "sha256:");
}

/// Look up the cache entry for `(registry, repository, reference)`.
/// Returns `null` if no entry exists or the file is unreadable /
/// unparseable (corrupt cache files are treated as misses, never as
/// hard failures — the orchestrator just falls through to a network
/// fetch).
pub fn lookup(
    io: Io,
    gpa: Allocator,
    store_handle: *const layout.Store,
    registry: []const u8,
    repository: []const u8,
    reference: []const u8,
) LookupError!?Parsed {
    var path_buf: [cache_subpath.len + 1 + 64 + ".json".len]u8 = undefined;
    const rel_path = formatPath(&path_buf, registry, repository, reference);

    const bytes = store_handle.dir.readFileAlloc(
        io,
        rel_path,
        gpa,
        .limited(64 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return null,
        else => return null,
    };
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(Entry, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;

    if (parsed.value.schema != 1) {
        parsed.deinit();
        return null;
    }

    return parsed;
}

/// Persist `entry` into the cache, creating `cache/manifests/v1/` on
/// demand. Atomic — a crash mid-write leaves no half-file at the
/// final path.
pub fn store(
    io: Io,
    store_handle: *layout.Store,
    entry: Entry,
) StoreError!void {
    var dir = try store_handle.dir.createDirPathOpen(io, cache_subpath, .{
        .open_options = .{},
    });
    defer dir.close(io);

    var key_buf: [digest_mod.hex_length]u8 = undefined;
    keyHexFor(&key_buf, entry.registry, entry.repository, entry.reference);
    var name_buf: [digest_mod.hex_length + ".json".len]u8 = undefined;
    const file_name = std.fmt.bufPrint(&name_buf, "{s}.json", .{key_buf[0..]}) catch unreachable;

    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &write_buf);
    std.json.Stringify.value(entry, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, &fw.interface) catch |err| switch (err) {
        error.WriteFailed => return fw.err.?,
    };
    fw.interface.flush() catch return fw.err.?;

    try atomic.replace(io);
}

/// Drop the cache entry for `(registry, repository, reference)` if
/// one exists. Missing files are silently ignored — eviction must be
/// idempotent because the orchestrator calls it eagerly on a digest
/// mismatch.
pub fn evict(
    io: Io,
    store_handle: *layout.Store,
    registry: []const u8,
    repository: []const u8,
    reference: []const u8,
) void {
    var path_buf: [cache_subpath.len + 1 + 64 + ".json".len]u8 = undefined;
    const rel_path = formatPath(&path_buf, registry, repository, reference);
    store_handle.dir.deleteFile(io, rel_path) catch {};
}

fn keyHexFor(out: *[digest_mod.hex_length]u8, registry: []const u8, repository: []const u8, reference: []const u8) void {
    var hasher = digest_mod.Hasher.init();
    hasher.update(registry);
    hasher.update("|");
    hasher.update(repository);
    hasher.update("|");
    hasher.update(reference);
    const dig = hasher.final();
    _ = dig.encodedHex(out);
}

fn formatPath(
    buf: *[cache_subpath.len + 1 + 64 + ".json".len]u8,
    registry: []const u8,
    repository: []const u8,
    reference: []const u8,
) []const u8 {
    var key_hex: [digest_mod.hex_length]u8 = undefined;
    keyHexFor(&key_hex, registry, repository, reference);
    return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ cache_subpath, key_hex[0..] }) catch unreachable;
}

const testing = std.testing;

test "isDigestRef and computeExpiry" {
    try testing.expect(isDigestRef("sha256:" ++ ("0" ** 64)));
    try testing.expect(!isDigestRef("3.19"));
    try testing.expect(!isDigestRef("latest"));

    const now: i64 = 1_000_000;
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), computeExpiry("sha256:" ++ ("0" ** 64), now, 60));
    const tag_exp = computeExpiry("3.19", now, 60);
    try testing.expectEqual(now + 60, tag_exp);
}

test "isFresh" {
    const e: Entry = .{
        .manifest_digest = "sha256:" ++ ("a" ** 64),
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .expires_at_unix = 100,
        .size = 0,
        .registry = "r",
        .repository = "x/y",
        .reference = "latest",
    };
    try testing.expect(isFresh(e, 50));
    try testing.expect(!isFresh(e, 100));
    try testing.expect(!isFresh(e, 200));
}

test "store + lookup round-trips an entry" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var s = try layout.Store.init(io, tmp.dir, "store");
    defer s.close(io);

    const e: Entry = .{
        .manifest_digest = "sha256:" ++ ("a" ** 64),
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .etag = "\"deadbeef\"",
        .expires_at_unix = 9_999_999_999,
        .size = 1234,
        .registry = "ghcr.io",
        .repository = "x/y",
        .reference = "latest",
    };
    try store(io, &s, e);

    var got = (try lookup(io, gpa, &s, "ghcr.io", "x/y", "latest")).?;
    defer got.deinit();
    try testing.expectEqualStrings(e.manifest_digest, got.value.manifest_digest);
    try testing.expectEqualStrings(e.media_type, got.value.media_type);
    try testing.expectEqualStrings(e.etag.?, got.value.etag.?);
    try testing.expectEqual(e.expires_at_unix, got.value.expires_at_unix);
    try testing.expectEqual(e.size, got.value.size);
}

test "lookup returns null on a missing entry" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var s = try layout.Store.init(io, tmp.dir, "store");
    defer s.close(io);

    try testing.expect((try lookup(io, gpa, &s, "ghcr.io", "x/y", "latest")) == null);
}

test "lookup returns null on a corrupt entry without erroring" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var s = try layout.Store.init(io, tmp.dir, "store");
    defer s.close(io);

    var dir = try s.dir.createDirPathOpen(io, cache_subpath, .{ .open_options = .{} });
    defer dir.close(io);

    var key_hex: [digest_mod.hex_length]u8 = undefined;
    keyHexFor(&key_hex, "ghcr.io", "x/y", "latest");
    var name_buf: [digest_mod.hex_length + ".json".len]u8 = undefined;
    const fname = try std.fmt.bufPrint(&name_buf, "{s}.json", .{key_hex[0..]});
    try dir.writeFile(io, .{ .sub_path = fname, .data = "{not json" });

    try testing.expect((try lookup(io, gpa, &s, "ghcr.io", "x/y", "latest")) == null);
}

test "evict removes an existing entry, no-op on missing" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var s = try layout.Store.init(io, tmp.dir, "store");
    defer s.close(io);

    const e: Entry = .{
        .manifest_digest = "sha256:" ++ ("a" ** 64),
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .expires_at_unix = 9_999_999_999,
        .size = 0,
        .registry = "ghcr.io",
        .repository = "x/y",
        .reference = "latest",
    };
    try store(io, &s, e);
    evict(io, &s, "ghcr.io", "x/y", "latest");
    try testing.expect((try lookup(io, gpa, &s, "ghcr.io", "x/y", "latest")) == null);

    evict(io, &s, "ghcr.io", "x/y", "missing");
}

test "schema version mismatch is treated as a cache miss" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var s = try layout.Store.init(io, tmp.dir, "store");
    defer s.close(io);

    var dir = try s.dir.createDirPathOpen(io, cache_subpath, .{ .open_options = .{} });
    defer dir.close(io);

    var key_hex: [digest_mod.hex_length]u8 = undefined;
    keyHexFor(&key_hex, "ghcr.io", "x/y", "latest");
    var name_buf: [digest_mod.hex_length + ".json".len]u8 = undefined;
    const fname = try std.fmt.bufPrint(&name_buf, "{s}.json", .{key_hex[0..]});

    const malformed =
        \\{"schema":99,"manifest_digest":"sha256:0000","media_type":"x","expires_at_unix":0,"size":0,"registry":"r","repository":"x/y","reference":"latest"}
    ;
    try dir.writeFile(io, .{ .sub_path = fname, .data = malformed });

    try testing.expect((try lookup(io, gpa, &s, "ghcr.io", "x/y", "latest")) == null);
}
