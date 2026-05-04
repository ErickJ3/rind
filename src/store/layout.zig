//! OCI image layout v1.0.0 on disk.
//!
//! Implements the read/write side of the spec at
//! <https://github.com/opencontainers/image-spec/blob/main/image-layout.md>:
//! an `oci-layout` marker file, an `index.json` describing the locally
//! tagged manifests, and a content-addressable `blobs/sha256/<hex>`
//! tree. The layout is portable to `skopeo` / `crane` / any other
//! OCI-compliant tool reading from the same root.
//!
//! All blob writes are streaming and digest-verified on the fly via
//! the `Hasher` wrapper from `image/digest.zig`: a layer that fails its
//! sha256 check is dropped before it lands in `blobs/sha256/`. All
//! mutating writes (blobs *and* `index.json`) go through
//! `std.Io.Dir.createFileAtomic`, so a crashed `rind pull` cannot leave
//! a half-written file visible at its final path.
//!
//! Single-writer assumption: the rind process is the only writer to a
//! given store at a time. `createFileAtomic` is crash-safe but not
//! linearizable for read-modify-write; two concurrent `tag` calls will
//! both read index v1 and last-write-wins. Cross-process locking is
//! a future enhancement (not yet implemented).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const digest_mod = @import("../image/digest.zig");

/// Sha256 content digest. Re-exported for caller convenience.
pub const Digest = digest_mod.Digest;
/// Streaming sha256 hasher. Re-exported for caller convenience.
pub const Hasher = digest_mod.Hasher;

/// Subpath, relative to the store root, where every blob lives.
/// Hard-coded to sha256 because that is the only OCI-mandatory digest
/// algorithm in MVP (see `image/digest.zig`).
pub const blobs_subpath: []const u8 = "blobs/sha256";

/// Subpath, relative to the store root, under which extracted layer
/// trees live (one subdirectory per layer digest). The store itself
/// does not create or manage this path — `Store.init` leaves it to
/// the pull orchestrator to materialize on demand.
pub const extracted_subpath: []const u8 = "extracted";

/// `imageLayoutVersion` value the store writes and the only one it
/// accepts on open.
pub const oci_layout_version: []const u8 = "1.0.0";

/// OCI-standard annotation key used to attach a human reference name
/// (e.g. `alpine:3.19`) to a manifest entry in `index.json`.
pub const ref_name_annotation: []const u8 = "org.opencontainers.image.ref.name";

const oci_layout_filename: []const u8 = "oci-layout";
const index_filename: []const u8 = "index.json";

/// Cap on the size of `index.json` we will read into memory. Eight
/// megabytes is several orders of magnitude past anything a real local
/// store should ever produce; a larger file means corruption or abuse.
const index_max_bytes: usize = 8 * 1024 * 1024;

const oci_layout_marker_bytes: []const u8 =
    "{\"imageLayoutVersion\":\"1.0.0\"}";

/// Semantic errors returned by the store. Per-method error sets union
/// these with the relevant `Io.Dir.*Error` / `Io.File.*Error` /
/// `Allocator.Error` so transport failures pass through unchanged.
pub const StoreError = error{
    /// A `putBlob` call's streamed bytes did not hash to the expected
    /// digest. The temp file is discarded; the store is unchanged.
    DigestMismatch,
    /// A `getBlob` / `openBlob` call asked for a digest not present.
    BlobNotFound,
    /// `index.json` exists but did not parse as a valid OCI image
    /// index, or `oci-layout` exists but is not valid JSON.
    IndexCorrupt,
    /// The target directory exists but is missing required layout
    /// files (used by `open`, which never creates).
    InvalidLayout,
    /// `oci-layout` exists but its `imageLayoutVersion` is something
    /// other than `oci_layout_version`.
    UnsupportedLayoutVersion,
};

/// OCI image-spec `Platform` object, as embedded in a Descriptor.
pub const Platform = struct {
    architecture: []const u8,
    os: []const u8,
    @"os.version": ?[]const u8 = null,
    @"os.features": ?[]const []const u8 = null,
    variant: ?[]const u8 = null,
};

/// OCI image-spec `Descriptor`. Field names are spelled to match the
/// JSON schema directly so `std.json` round-trips them without rename
/// hooks. Optional fields are omitted from the encoded form when null
/// (see `stringify_options`).
pub const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    urls: ?[]const []const u8 = null,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
    platform: ?Platform = null,
    artifactType: ?[]const u8 = null,
};

/// OCI image-spec `ImageIndex`. The `manifests` slice and any nested
/// allocations are owned by the `std.json.Parsed` returned by
/// `Store.readIndex`; do not mutate it without a fresh allocation.
pub const Index = struct {
    schemaVersion: u32 = 2,
    mediaType: []const u8 = "application/vnd.oci.image.index.v1+json",
    manifests: []Descriptor,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
};

/// Compact, human-friendly form of the descriptor data callers need to
/// hand to `Store.tag`. The full `Descriptor` is reserved for
/// pass-through round-trips of externally-written indexes.
pub const ManifestRef = struct {
    /// Manifest media type (e.g. `application/vnd.oci.image.manifest.v1+json`).
    media_type: []const u8,
    /// Digest of the manifest blob. Must already exist via `putBlob`
    /// — the store does not check on tag, but downstream tools will.
    digest: Digest,
    /// Size of the manifest blob in bytes.
    size: u64,
    /// Optional platform descriptor for image-index entries.
    platform: ?Platform = null,
};

const OciLayoutMarker = struct { imageLayoutVersion: []const u8 };

const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

/// Open handle to an OCI image-layout root. Holds two long-lived
/// `Io.Dir` handles: the layout root and the `blobs/sha256/`
/// subdirectory. Use `init` to open-or-create, `open` to require an
/// existing layout, `close` to release the handles.
pub const Store = struct {
    /// Root of the layout (the directory containing `oci-layout`).
    dir: Io.Dir,
    /// `blobs/sha256/` opened with iteration capability.
    blobs_dir: Io.Dir,

    /// Errors returned by `init`. Unions `StoreError` with the fs
    /// errors that can surface while creating directories and files.
    pub const InitError = StoreError ||
        Io.Dir.CreateDirPathOpenError ||
        Io.Dir.WriteFileError ||
        Io.Dir.ReadFileAllocError ||
        Io.Dir.AccessError ||
        Allocator.Error;

    /// Errors returned by `open`.
    pub const OpenError = StoreError ||
        Io.Dir.OpenError ||
        Io.Dir.AccessError ||
        Io.Dir.ReadFileAllocError ||
        Allocator.Error;

    /// Open the layout under `parent / sub_path`, creating it (and any
    /// missing layout files) if it does not yet exist. Idempotent on a
    /// valid existing layout. Returns `UnsupportedLayoutVersion` if
    /// `oci-layout` exists but pins a non-1.0.0 version.
    pub fn init(io: Io, parent: Io.Dir, sub_path: []const u8) InitError!Store {
        var root = try parent.createDirPathOpen(io, sub_path, .{
            .open_options = .{ .iterate = true },
        });
        errdefer root.close(io);

        try ensureLayoutMarker(io, root);
        try ensureEmptyIndex(io, root);

        var blobs = try root.createDirPathOpen(io, blobs_subpath, .{
            .open_options = .{ .iterate = true },
        });
        errdefer blobs.close(io);

        return .{ .dir = root, .blobs_dir = blobs };
    }

    /// Open an already-initialized layout. Fails with `InvalidLayout`
    /// if the marker, `index.json`, or `blobs/sha256/` are missing.
    pub fn open(io: Io, parent: Io.Dir, sub_path: []const u8) OpenError!Store {
        var root = parent.openDir(io, sub_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return StoreError.InvalidLayout,
            else => |e| return e,
        };
        errdefer root.close(io);

        root.access(io, oci_layout_filename, .{}) catch |err| switch (err) {
            error.FileNotFound => return StoreError.InvalidLayout,
            else => |e| return e,
        };
        try validateLayoutMarker(io, root);

        root.access(io, index_filename, .{}) catch |err| switch (err) {
            error.FileNotFound => return StoreError.InvalidLayout,
            else => |e| return e,
        };

        var blobs = root.openDir(io, blobs_subpath, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return StoreError.InvalidLayout,
            else => |e| return e,
        };
        errdefer blobs.close(io);

        return .{ .dir = root, .blobs_dir = blobs };
    }

    /// Release both directory handles. Safe to call exactly once.
    pub fn close(self: *Store, io: Io) void {
        self.blobs_dir.close(io);
        self.dir.close(io);
        self.* = undefined;
    }

    /// True iff `blobs/sha256/<hex>` exists. Cheap; one syscall.
    pub fn hasBlob(self: *const Store, io: Io, digest: Digest) bool {
        var hex_buf: [digest_mod.hex_length]u8 = undefined;
        const hex = digest.encodedHex(&hex_buf);
        self.blobs_dir.access(io, hex, .{}) catch return false;
        return true;
    }

    /// Errors returned by `putBlob`.
    pub const PutBlobError = StoreError ||
        error{ReadFailed} ||
        Io.Dir.CreateFileAtomicError ||
        Io.File.Atomic.LinkError ||
        Io.File.Writer.Error;

    /// Stream `reader` into `blobs/sha256/<hex>`, hashing on the fly,
    /// verifying the final hash equals `expected`. The bytes never
    /// land at the final path until verification succeeds; on
    /// `DigestMismatch` the temp is discarded and the store is
    /// unchanged. Idempotent: a second call with a digest already
    /// present is a no-op fast path.
    pub fn putBlob(
        self: *Store,
        io: Io,
        expected: Digest,
        reader: *Io.Reader,
    ) PutBlobError!void {
        var hex_buf: [digest_mod.hex_length]u8 = undefined;
        const hex = expected.encodedHex(&hex_buf);

        if (self.hasBlob(io, expected)) return;

        var atomic = try self.blobs_dir.createFileAtomic(io, hex, .{ .replace = false });
        defer atomic.deinit(io);

        var write_buf: [64 * 1024]u8 = undefined;
        var fw = atomic.file.writer(io, &write_buf);

        var read_buf: [64 * 1024]u8 = undefined;
        var hashed = reader.hashed(Hasher.init(), &read_buf);

        _ = hashed.reader.streamRemaining(&fw.interface) catch |err| switch (err) {
            error.WriteFailed => return fw.err.?,
            error.ReadFailed => return error.ReadFailed,
        };
        fw.interface.flush() catch return fw.err.?;

        const got = hashed.hasher.final();
        if (!got.eql(expected)) return StoreError.DigestMismatch;

        try atomic.link(io);
    }

    /// Errors returned by `openBlob`.
    pub const OpenBlobError = StoreError || Io.File.OpenError;

    /// Open the blob file for streaming reads. The returned `Io.File`
    /// must be closed by the caller via `file.close(io)`.
    pub fn openBlob(self: *const Store, io: Io, digest: Digest) OpenBlobError!Io.File {
        var hex_buf: [digest_mod.hex_length]u8 = undefined;
        const hex = digest.encodedHex(&hex_buf);
        return self.blobs_dir.openFile(io, hex, .{}) catch |err| switch (err) {
            error.FileNotFound => return StoreError.BlobNotFound,
            else => |e| return e,
        };
    }

    /// Errors returned by `readBlobAlloc`.
    pub const ReadBlobError = StoreError || Io.Dir.ReadFileAllocError;

    /// Read a blob into a freshly allocated, caller-owned buffer.
    /// Bounded by `max` bytes; returns `error.StreamTooLong` if the
    /// blob exceeds it. Suitable for small blobs (configs, manifests);
    /// stream via `openBlob` for layers.
    pub fn readBlobAlloc(
        self: *const Store,
        io: Io,
        gpa: Allocator,
        digest: Digest,
        max: usize,
    ) ReadBlobError![]u8 {
        var hex_buf: [digest_mod.hex_length]u8 = undefined;
        const hex = digest.encodedHex(&hex_buf);
        return self.blobs_dir.readFileAlloc(io, hex, gpa, .limited(max)) catch |err| switch (err) {
            error.FileNotFound => return StoreError.BlobNotFound,
            else => |e| return e,
        };
    }

    /// Errors returned by `readIndex`.
    pub const ReadIndexError = StoreError ||
        Io.Dir.ReadFileAllocError ||
        Allocator.Error;

    /// Parse `index.json` into an arena-owned `Index`. Caller must
    /// call `.deinit()` on the returned `Parsed` value.
    pub fn readIndex(
        self: *const Store,
        io: Io,
        gpa: Allocator,
    ) ReadIndexError!std.json.Parsed(Index) {
        const bytes = try self.dir.readFileAlloc(io, index_filename, gpa, .limited(index_max_bytes));
        defer gpa.free(bytes);
        return std.json.parseFromSlice(Index, gpa, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return StoreError.IndexCorrupt;
    }

    /// Errors returned by `writeIndex`.
    pub const WriteIndexError = StoreError ||
        Io.Dir.CreateFileAtomicError ||
        Io.File.Atomic.ReplaceError ||
        Io.File.Writer.Error ||
        std.json.Stringify.Error;

    /// Atomically replace `index.json` with the JSON encoding of
    /// `index`. Crash-safe (temp file + rename); not concurrency-safe
    /// across writers (see module doc).
    pub fn writeIndex(self: *const Store, io: Io, index: Index) WriteIndexError!void {
        var atomic = try self.dir.createFileAtomic(io, index_filename, .{ .replace = true });
        defer atomic.deinit(io);

        var buf: [4096]u8 = undefined;
        var fw = atomic.file.writer(io, &buf);
        std.json.Stringify.value(index, stringify_options, &fw.interface) catch |err| switch (err) {
            error.WriteFailed => return fw.err.?,
        };
        fw.interface.flush() catch return fw.err.?;

        try atomic.replace(io);
    }

    /// Errors returned by `tag`.
    pub const TagError = ReadIndexError || WriteIndexError;

    /// Upsert a manifest entry in `index.json` keyed by
    /// `org.opencontainers.image.ref.name = ref_name`. Replaces any
    /// existing entry with the same ref name. Two ref names pointing
    /// at the same digest produce two distinct entries (per spec —
    /// one annotation value per descriptor).
    pub fn tag(
        self: *Store,
        io: Io,
        gpa: Allocator,
        ref_name: []const u8,
        manifest: ManifestRef,
    ) TagError!void {
        var parsed = try self.readIndex(io, gpa);
        defer parsed.deinit();

        var digest_buf: [digest_mod.string_length]u8 = undefined;
        const digest_str = manifest.digest.toString(&digest_buf);

        var annotations: std.json.ArrayHashMap([]const u8) = .{};
        defer annotations.map.deinit(gpa);
        try annotations.map.put(gpa, ref_name_annotation, ref_name);

        const new_descriptor: Descriptor = .{
            .mediaType = manifest.media_type,
            .digest = digest_str,
            .size = manifest.size,
            .platform = manifest.platform,
            .annotations = annotations,
        };

        const old = parsed.value.manifests;
        var match: ?usize = null;
        for (old, 0..) |d, i| {
            if (descriptorRefName(d)) |existing| {
                if (std.mem.eql(u8, existing, ref_name)) {
                    match = i;
                    break;
                }
            }
        }

        if (match) |i| {
            const buf = try gpa.alloc(Descriptor, old.len);
            defer gpa.free(buf);
            @memcpy(buf, old);
            buf[i] = new_descriptor;
            try self.writeIndex(io, .{
                .schemaVersion = parsed.value.schemaVersion,
                .mediaType = parsed.value.mediaType,
                .manifests = buf,
                .annotations = parsed.value.annotations,
            });
        } else {
            const buf = try gpa.alloc(Descriptor, old.len + 1);
            defer gpa.free(buf);
            @memcpy(buf[0..old.len], old);
            buf[old.len] = new_descriptor;
            try self.writeIndex(io, .{
                .schemaVersion = parsed.value.schemaVersion,
                .mediaType = parsed.value.mediaType,
                .manifests = buf,
                .annotations = parsed.value.annotations,
            });
        }
    }

    /// Errors returned by `untag`.
    pub const UntagError = ReadIndexError || WriteIndexError;

    /// Remove the manifest entry whose
    /// `org.opencontainers.image.ref.name` matches `ref_name`. The
    /// underlying blob is *not* deleted (garbage collection is not
    /// yet implemented).
    /// A missing ref is not an error.
    pub fn untag(
        self: *Store,
        io: Io,
        gpa: Allocator,
        ref_name: []const u8,
    ) UntagError!void {
        var parsed = try self.readIndex(io, gpa);
        defer parsed.deinit();

        const old = parsed.value.manifests;
        var match: ?usize = null;
        for (old, 0..) |d, i| {
            if (descriptorRefName(d)) |existing| {
                if (std.mem.eql(u8, existing, ref_name)) {
                    match = i;
                    break;
                }
            }
        }
        if (match == null) return;

        const buf = try gpa.alloc(Descriptor, old.len - 1);
        defer gpa.free(buf);
        @memcpy(buf[0..match.?], old[0..match.?]);
        @memcpy(buf[match.?..], old[match.? + 1 ..]);

        try self.writeIndex(io, .{
            .schemaVersion = parsed.value.schemaVersion,
            .mediaType = parsed.value.mediaType,
            .manifests = buf,
            .annotations = parsed.value.annotations,
        });
    }
};

fn descriptorRefName(d: Descriptor) ?[]const u8 {
    const ann = d.annotations orelse return null;
    return ann.map.get(ref_name_annotation);
}

fn ensureLayoutMarker(io: Io, root: Io.Dir) (Io.Dir.WriteFileError || Io.Dir.ReadFileAllocError || Io.Dir.AccessError || StoreError)!void {
    root.access(io, oci_layout_filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try root.writeFile(io, .{
                .sub_path = oci_layout_filename,
                .data = oci_layout_marker_bytes,
            });
            return;
        },
        else => |e| return e,
    };
    try validateLayoutMarker(io, root);
}

fn validateLayoutMarker(io: Io, root: Io.Dir) (Io.Dir.ReadFileAllocError || StoreError)!void {
    var buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const bytes = root.readFileAlloc(io, oci_layout_filename, fba.allocator(), .limited(buf.len)) catch |err| switch (err) {
        error.OutOfMemory, error.StreamTooLong => return StoreError.IndexCorrupt,
        else => |e| return e,
    };
    var marker_fba_buf: [1024]u8 = undefined;
    var marker_fba: std.heap.FixedBufferAllocator = .init(&marker_fba_buf);
    const parsed = std.json.parseFromSlice(OciLayoutMarker, marker_fba.allocator(), bytes, .{
        .ignore_unknown_fields = true,
    }) catch return StoreError.IndexCorrupt;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.imageLayoutVersion, oci_layout_version)) {
        return StoreError.UnsupportedLayoutVersion;
    }
}

fn ensureEmptyIndex(io: Io, root: Io.Dir) (Io.Dir.WriteFileError || Io.Dir.AccessError)!void {
    root.access(io, index_filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try root.writeFile(io, .{
                .sub_path = index_filename,
                .data =
                \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}
                ,
            });
            return;
        },
        else => |e| return e,
    };
}

const testing = std.testing;

const empty_sha256_hex: *const [digest_mod.hex_length:0]u8 =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const abc_sha256_hex: *const [digest_mod.hex_length:0]u8 =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const hello_sha256_hex: *const [digest_mod.hex_length:0]u8 =
    "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

fn countFiles(io: Io, dir: Io.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

test "init creates oci-layout, empty index.json, and blobs/sha256/" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    var marker_buf: [128]u8 = undefined;
    const marker = try tmp.dir.readFile(testing.io, "store/oci-layout", &marker_buf);
    try testing.expectEqualStrings(oci_layout_marker_bytes, marker);

    var index_buf: [256]u8 = undefined;
    const index_bytes = try tmp.dir.readFile(testing.io, "store/index.json", &index_buf);
    try testing.expect(std.mem.indexOf(u8, index_bytes, "\"manifests\":[]") != null);

    const blobs_stat = try tmp.dir.statFile(testing.io, "store/blobs/sha256", .{});
    try testing.expectEqual(Io.File.Kind.directory, blobs_stat.kind);
}

test "init is idempotent on an already-initialized layout" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var s1 = try Store.init(testing.io, tmp.dir, "store");
    s1.close(testing.io);
    var s2 = try Store.init(testing.io, tmp.dir, "store");
    defer s2.close(testing.io);

    var marker_buf: [128]u8 = undefined;
    const marker = try tmp.dir.readFile(testing.io, "store/oci-layout", &marker_buf);
    try testing.expectEqualStrings(oci_layout_marker_bytes, marker);
}

test "init rejects an existing layout pinning a non-1.0.0 version" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "store", .{});
    defer root.close(testing.io);
    try root.writeFile(testing.io, .{
        .sub_path = oci_layout_filename,
        .data = "{\"imageLayoutVersion\":\"1.1.0\"}",
    });

    try testing.expectError(StoreError.UnsupportedLayoutVersion, Store.init(testing.io, tmp.dir, "store"));
}

test "open fails with InvalidLayout when oci-layout is missing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = try tmp.dir.createDirPathOpen(testing.io, "store", .{});
    root.close(testing.io);

    try testing.expectError(StoreError.InvalidLayout, Store.open(testing.io, tmp.dir, "store"));
}

test "putBlob writes content to blobs/sha256/<hex> and hasBlob is true" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const expected = Hasher.hash("abc");
    var src: Io.Reader = .fixed("abc");
    try store.putBlob(testing.io, expected, &src);

    try testing.expect(store.hasBlob(testing.io, expected));

    var on_disk_buf: [16]u8 = undefined;
    const on_disk = try store.blobs_dir.readFile(testing.io, abc_sha256_hex, &on_disk_buf);
    try testing.expectEqualStrings("abc", on_disk);
}

test "putBlob rejects digest mismatch and leaves blobs/sha256/ empty" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const wrong_expected = Hasher.hash("xyz");
    var src: Io.Reader = .fixed("abc");
    try testing.expectError(StoreError.DigestMismatch, store.putBlob(testing.io, wrong_expected, &src));

    try testing.expect(!store.hasBlob(testing.io, wrong_expected));
    try testing.expectEqual(@as(usize, 0), try countFiles(testing.io, store.blobs_dir));
}

test "putBlob accepts an empty blob" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const expected = Hasher.hash("");
    var src: Io.Reader = .fixed("");
    try store.putBlob(testing.io, expected, &src);

    var sink: [4]u8 = undefined;
    const got = try store.blobs_dir.readFile(testing.io, empty_sha256_hex, &sink);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "putBlob is a no-op when the blob already exists" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const expected = Hasher.hash("hello");
    var first: Io.Reader = .fixed("hello");
    try store.putBlob(testing.io, expected, &first);

    // Pass an empty reader the second time — if the fast path doesn't
    // trip, the digest check would fail. That it doesn't proves the
    // hot path is hit.
    var second: Io.Reader = .fixed("");
    try store.putBlob(testing.io, expected, &second);
    try testing.expectEqual(@as(usize, 1), try countFiles(testing.io, store.blobs_dir));
}

test "openBlob and readBlobAlloc return the stored bytes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const expected = Hasher.hash("hello");
    var src: Io.Reader = .fixed("hello");
    try store.putBlob(testing.io, expected, &src);

    var f = try store.openBlob(testing.io, expected);
    defer f.close(testing.io);
    var rbuf: [16]u8 = undefined;
    var fr = f.reader(testing.io, &.{});
    const n = fr.interface.readSliceShort(&rbuf) catch |err| switch (err) {
        error.ReadFailed => return fr.err.?,
    };
    try testing.expectEqualStrings("hello", rbuf[0..n]);

    const slurped = try store.readBlobAlloc(testing.io, testing.allocator, expected, 64);
    defer testing.allocator.free(slurped);
    try testing.expectEqualStrings("hello", slurped);
}

test "openBlob and readBlobAlloc return BlobNotFound for unknown digest" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const missing = Hasher.hash("never written");
    try testing.expectError(StoreError.BlobNotFound, store.openBlob(testing.io, missing));
    try testing.expectError(StoreError.BlobNotFound, store.readBlobAlloc(testing.io, testing.allocator, missing, 64));
}

test "tag adds an entry and a second tag with the same name replaces it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const d1 = Hasher.hash("manifest-v1");
    const d2 = Hasher.hash("manifest-v2");

    try store.tag(testing.io, testing.allocator, "alpine:3.19", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = d1,
        .size = 11,
    });
    try store.tag(testing.io, testing.allocator, "alpine:3.19", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = d2,
        .size = 11,
    });

    var parsed = try store.readIndex(testing.io, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.manifests.len);

    var d2_buf: [digest_mod.string_length]u8 = undefined;
    try testing.expectEqualStrings(d2.toString(&d2_buf), parsed.value.manifests[0].digest);
    try testing.expectEqualStrings("alpine:3.19", parsed.value.manifests[0].annotations.?.map.get(ref_name_annotation).?);
}

test "tag allows multiple entries with the same digest under different ref names" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const d = Hasher.hash("shared");
    try store.tag(testing.io, testing.allocator, "alpine:3.19", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = d,
        .size = 6,
    });
    try store.tag(testing.io, testing.allocator, "alpine:latest", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = d,
        .size = 6,
    });

    var parsed = try store.readIndex(testing.io, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.manifests.len);
}

test "untag removes only the named entry and preserves the underlying blob" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const d = Hasher.hash("shared");
    var src: Io.Reader = .fixed("shared");
    try store.putBlob(testing.io, d, &src);

    try store.tag(testing.io, testing.allocator, "alpine:3.19", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = d,
        .size = 6,
    });
    try store.tag(testing.io, testing.allocator, "alpine:latest", .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = d,
        .size = 6,
    });

    try store.untag(testing.io, testing.allocator, "alpine:3.19");

    var parsed = try store.readIndex(testing.io, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.manifests.len);
    try testing.expectEqualStrings("alpine:latest", parsed.value.manifests[0].annotations.?.map.get(ref_name_annotation).?);
    try testing.expect(store.hasBlob(testing.io, d)); // blob retained.
}

test "untag is a no-op when the ref name is unknown" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    try store.untag(testing.io, testing.allocator, "nothing:here");

    var parsed = try store.readIndex(testing.io, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.manifests.len);
}

test "readIndex round-trips externally-written annotations, urls, and platform" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var store = try Store.init(testing.io, tmp.dir, "store");
    defer store.close(testing.io);

    const fixture =
        \\{
        \\  "schemaVersion": 2,
        \\  "mediaType": "application/vnd.oci.image.index.v1+json",
        \\  "manifests": [
        \\    {
        \\      "mediaType": "application/vnd.oci.image.manifest.v1+json",
        \\      "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        \\      "size": 1234,
        \\      "urls": ["https://example.com/manifest"],
        \\      "annotations": {"org.opencontainers.image.ref.name": "alpine:3.19", "extra": "preserved"},
        \\      "platform": {"architecture": "amd64", "os": "linux", "os.version": "5.15", "variant": "v1"},
        \\      "artifactType": "application/example"
        \\    }
        \\  ],
        \\  "annotations": {"top.level": "kept"}
        \\}
    ;
    try store.dir.writeFile(testing.io, .{ .sub_path = index_filename, .data = fixture });

    var parsed = try store.readIndex(testing.io, testing.allocator);
    {
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 1), parsed.value.manifests.len);
        const d = parsed.value.manifests[0];
        try testing.expectEqualStrings("application/example", d.artifactType.?);
        try testing.expectEqualStrings("https://example.com/manifest", d.urls.?[0]);
        try testing.expectEqualStrings("preserved", d.annotations.?.map.get("extra").?);
        try testing.expectEqualStrings("5.15", d.platform.?.@"os.version".?);
        try testing.expectEqualStrings("kept", parsed.value.annotations.?.map.get("top.level").?);

        try store.writeIndex(testing.io, parsed.value);
    }

    // Re-read and re-check that nothing was dropped on the way to disk.
    var parsed2 = try store.readIndex(testing.io, testing.allocator);
    defer parsed2.deinit();
    try testing.expectEqual(@as(usize, 1), parsed2.value.manifests.len);
    const d2 = parsed2.value.manifests[0];
    try testing.expectEqualStrings("application/example", d2.artifactType.?);
    try testing.expectEqualStrings("https://example.com/manifest", d2.urls.?[0]);
    try testing.expectEqualStrings("preserved", d2.annotations.?.map.get("extra").?);
    try testing.expectEqualStrings("5.15", d2.platform.?.@"os.version".?);
    try testing.expectEqualStrings("kept", parsed2.value.annotations.?.map.get("top.level").?);
}
