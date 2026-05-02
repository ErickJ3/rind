//! Layer extraction: tar+gzip → directory tree.
//!
//! Implements T07 of the M1 plan: pipe a registry blob's bytes through
//! `std.compress.flate` (gzip container) and a custom tar walker into
//! `dest_dir`. Two non-negotiable hardening rules from the OCI image-spec
//! layer doc are enforced inline:
//!
//!   1. **Path traversal** — every entry path is sanitized with a
//!      depth-counter walk. Absolute paths and `..` components that would
//!      escape `dest_dir` are rejected with `error.UnsafePath`. Symlink
//!      targets are validated lexically *before* the link is created
//!      (rather than canonicalizing post-create) to avoid TOCTOU and to
//!      keep the check correct when the target file does not yet exist.
//!
//!   2. **Whiteouts** — `.wh.<name>` removes a sibling and `.wh..wh..opq`
//!      clears its parent directory's contents (preserving the directory
//!      itself). Markers themselves are never written to disk. This
//!      mutates `dest_dir`; the orchestrator (T09) chooses whether
//!      `dest_dir` is per-digest or per-image.
//!
//! Why a custom tar walker instead of `std.tar.Iterator`? The stdlib
//! iterator filters hardlinks (typeflag `'1'`) into a diagnostics
//! channel and discards their headers, which strips the `link_name` we
//! need to materialize the link. This module's `Walker` keeps every
//! interesting kind in one stream.
//!
//! Ownership and modes follow user-namespace rules: uid/gid in the tar
//! header are ignored (`rind` runs as the user, not as root). The mode
//! bits are preserved verbatim via `Io.File.Permissions.fromMode`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Semantic errors returned by the extractor. Per-method error sets
/// union these with the relevant `flate.Decompress.Error`,
/// `Io.Dir.*Error`, `Io.File.*Error`, and `Allocator.Error` so transport
/// failures pass through unchanged.
pub const ExtractError = error{
    /// A tar entry's path was absolute, contained a `..` that escaped
    /// the extraction root, or was a symlink whose target resolved
    /// outside `dest_dir`. The entry was rejected before any
    /// filesystem mutation.
    UnsafePath,
    /// A tar entry kind is not supported by rind (character or block
    /// special file, fifo, sparse). Layer must be re-rolled without
    /// it; rind will not pretend to extract devices.
    UnsupportedEntryKind,
    /// A whiteout marker pointed at something outside `dest_dir`, or
    /// its name was malformed (`.wh.` with no suffix, etc.).
    InvalidWhiteout,
    /// The tar header is malformed (bad magic, bad checksum, bad
    /// octal, truncated stream).
    CorruptStream,
};

/// Errors returned by `extractGzip`. Combines the semantic
/// `ExtractError` set with every transport / filesystem / allocation
/// error a streaming extraction might surface.
pub const ExtractGzipError = ExtractError ||
    flate.Decompress.Error ||
    Io.Reader.Error ||
    Io.Dir.OpenError ||
    Io.Dir.CreateDirPathError ||
    Io.Dir.DeleteTreeError ||
    Io.Dir.SymLinkError ||
    Io.Dir.HardLinkError ||
    Io.Dir.Reader.Error ||
    Io.File.OpenError ||
    Io.File.Writer.Error ||
    Allocator.Error;

/// Extract a `tar+gzip` layer blob into `dest_dir`.
///
/// Streams `blob_reader` through gzip decompression, then a tar walker.
/// Applies OCI whiteout semantics (`.wh.<name>` deletes,
/// `.wh..wh..opq` clears the parent directory's contents) and rejects
/// any path that would escape `dest_dir`. `dest_dir` must already exist
/// and must be opened with iteration capability (needed for opaque
/// whiteouts).
///
/// `dest_dir` is borrowed; the caller retains ownership and is
/// responsible for closing it. Allocations are short-lived: only the
/// gzip window (64 KiB), two path buffers (8 KiB total), and the tar
/// walker's scratch state.
pub fn extractGzip(
    io: Io,
    gpa: Allocator,
    blob_reader: *Io.Reader,
    dest_dir: Io.Dir,
) ExtractGzipError!void {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    var dec: flate.Decompress = .init(blob_reader, .gzip, window);

    extractTar(io, gpa, &dec.reader, dest_dir) catch |err| switch (err) {
        // Decompress.Reader returns ReadFailed and stashes the real
        // diagnostic in `dec.err`. Surface that so callers see, e.g.,
        // `error.BadGzipHeader` rather than a generic `ReadFailed`.
        error.ReadFailed => return dec.err orelse error.ReadFailed,
        else => |e| return e,
    };
}

/// Extract a raw (uncompressed) tar stream. Exposed mostly for tests
/// and for layers whose container has already been peeled off; the
/// gzip variant is the production entry point.
pub fn extractTar(
    io: Io,
    gpa: Allocator,
    tar_reader: *Io.Reader,
    dest_dir: Io.Dir,
) ExtractGzipError!void {
    const file_name_buf = try gpa.alloc(u8, max_path_bytes);
    defer gpa.free(file_name_buf);
    const link_name_buf = try gpa.alloc(u8, max_path_bytes);
    defer gpa.free(link_name_buf);

    var walker: Walker = .init(tar_reader, file_name_buf, link_name_buf);
    var write_buf: [16 * 1024]u8 = undefined;

    while (try walker.next()) |entry| {
        try handleEntry(io, dest_dir, &walker, entry, &write_buf);
    }
}

/// Buffer length we reserve for any single path (header + GNU long
/// name + PAX). 4 KiB comfortably exceeds anything a real layer
/// produces and matches `std.fs.max_path_bytes` on Linux.
const max_path_bytes = std.fs.max_path_bytes;

/// Per-entry handler. Splits whiteout markers off from regular entries,
/// validates paths, and dispatches to the appropriate filesystem op.
fn handleEntry(
    io: Io,
    dest_dir: Io.Dir,
    walker: *Walker,
    entry: TarEntry,
    write_buf: []u8,
) ExtractGzipError!void {
    const basename = std.fs.path.basenamePosix(entry.name);

    if (std.mem.eql(u8, basename, opaque_whiteout_marker)) {
        const parent = std.fs.path.dirnamePosix(entry.name) orelse "";
        try clearOpaqueWhiteout(io, dest_dir, parent);
        try walker.discardRemaining();
        return;
    }
    if (std.mem.startsWith(u8, basename, whiteout_prefix)) {
        const target = basename[whiteout_prefix.len..];
        if (target.len == 0) return ExtractError.InvalidWhiteout;
        const parent = std.fs.path.dirnamePosix(entry.name);
        try applyWhiteout(io, dest_dir, parent, target);
        try walker.discardRemaining();
        return;
    }

    var sanitized_buf: [max_path_bytes]u8 = undefined;
    const sanitized_len = sanitizeLogical(&sanitized_buf, entry.name) catch
        return ExtractError.UnsafePath;
    const file_name = sanitized_buf[0..sanitized_len];
    if (file_name.len == 0) {
        // A bare `./` directory entry — no-op.
        try walker.discardRemaining();
        return;
    }

    switch (entry.kind) {
        .directory => {
            try ensureDir(io, dest_dir, file_name, entry.mode);
            try walker.discardRemaining();
        },
        .file => {
            if (std.fs.path.dirnamePosix(file_name)) |parent| {
                if (parent.len > 0) try dest_dir.createDirPath(io, parent);
            }
            var file = try dest_dir.createFile(io, file_name, .{
                .truncate = true,
                .permissions = permissionsFromMode(entry.mode),
            });
            defer file.close(io);
            var fw = file.writer(io, write_buf);
            walker.streamRemaining(&fw.interface, entry.size) catch |err| switch (err) {
                error.WriteFailed => return fw.err.?,
                else => |e| return e,
            };
            fw.interface.flush() catch return fw.err.?;
        },
        .sym_link => {
            try validateSymlinkTarget(file_name, entry.link_name);
            if (std.fs.path.dirnamePosix(file_name)) |parent| {
                if (parent.len > 0) try dest_dir.createDirPath(io, parent);
            }
            dest_dir.symLink(io, entry.link_name, file_name, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    // OCI layers may overwrite a previous-layer entry. Replace.
                    try dest_dir.deleteTree(io, file_name);
                    try dest_dir.symLink(io, entry.link_name, file_name, .{});
                },
                else => |e| return e,
            };
            try walker.discardRemaining();
        },
        .hard_link => {
            // Validate both ends. The link target is interpreted as a
            // path relative to the tar root (i.e. relative to dest_dir),
            // not relative to the link's own parent directory.
            var link_buf: [max_path_bytes]u8 = undefined;
            const link_len = sanitizeLogical(&link_buf, entry.link_name) catch
                return ExtractError.UnsafePath;
            const link_target = link_buf[0..link_len];
            if (std.fs.path.dirnamePosix(file_name)) |parent| {
                if (parent.len > 0) try dest_dir.createDirPath(io, parent);
            }
            try Io.Dir.hardLink(dest_dir, link_target, dest_dir, file_name, io, .{});
            try walker.discardRemaining();
        },
        .unsupported => {
            return ExtractError.UnsupportedEntryKind;
        },
    }
}

fn ensureDir(io: Io, dest_dir: Io.Dir, sub_path: []const u8, mode: u32) !void {
    _ = mode; // Dir mode preservation deferred — std.Io.Dir on 0.16 has no setPermissions.
    try dest_dir.createDirPath(io, sub_path);
}

fn permissionsFromMode(mode: u32) Io.File.Permissions {
    if (!Io.File.Permissions.has_executable_bit) return .default_file;
    return Io.File.Permissions.fromMode(@intCast(mode & 0o7777));
}

const whiteout_prefix: []const u8 = ".wh.";
const opaque_whiteout_marker: []const u8 = ".wh..wh..opq";

fn applyWhiteout(io: Io, dest_dir: Io.Dir, parent: ?[]const u8, target: []const u8) !void {
    if (target.len == 0) return ExtractError.InvalidWhiteout;
    if (parent) |p| {
        if (p.len > 0) {
            var sanitized: [max_path_bytes]u8 = undefined;
            const n = sanitizeLogical(&sanitized, p) catch return ExtractError.InvalidWhiteout;
            if (n + 1 + target.len > sanitized.len) return ExtractError.InvalidWhiteout;
            sanitized[n] = '/';
            @memcpy(sanitized[n + 1 ..][0..target.len], target);
            const full = sanitized[0 .. n + 1 + target.len];
            try dest_dir.deleteTree(io, full);
            return;
        }
    }
    try dest_dir.deleteTree(io, target);
}

fn clearOpaqueWhiteout(io: Io, dest_dir: Io.Dir, parent: []const u8) !void {
    var clear_dir: Io.Dir = blk: {
        if (parent.len == 0) {
            // Marker at root. Iterate dest_dir directly without dup'ing
            // the handle — dest_dir is borrowed from the caller and
            // cannot be closed here. Use openDir(".") to get an
            // iterable, owned handle.
            break :blk dest_dir.openDir(io, ".", .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return ExtractError.InvalidWhiteout,
                else => |e| return e,
            };
        }
        var sanitized: [max_path_bytes]u8 = undefined;
        const n = sanitizeLogical(&sanitized, parent) catch return ExtractError.InvalidWhiteout;
        break :blk dest_dir.openDir(io, sanitized[0..n], .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
    };
    defer clear_dir.close(io);

    // Iterate by name and deleteTree each child via the parent handle.
    // We collect names into a small heap-free buffer first because
    // `Iterator.next` invalidates the previous entry's name on each
    // call and `deleteTree` may itself iterate.
    var names_storage: [max_path_bytes * 32]u8 = undefined;
    var names_offsets: [256]usize = undefined;
    var names_len: usize = 0;
    var bytes_used: usize = 0;

    var it = clear_dir.iterate();
    while (try it.next(io)) |child| {
        if (names_len >= names_offsets.len) return ExtractError.InvalidWhiteout;
        if (bytes_used + child.name.len > names_storage.len) return ExtractError.InvalidWhiteout;
        @memcpy(names_storage[bytes_used..][0..child.name.len], child.name);
        names_offsets[names_len] = bytes_used;
        bytes_used += child.name.len;
        names_len += 1;
    }
    var i: usize = 0;
    while (i < names_len) : (i += 1) {
        const start = names_offsets[i];
        const end = if (i + 1 < names_len) names_offsets[i + 1] else bytes_used;
        const name = names_storage[start..end];
        try clear_dir.deleteTree(io, name);
    }
}

/// Lexically sanitize a tar entry path. Rejects absolute paths and any
/// `..` component that would pop above the extraction root. Collapses
/// `.` components silently and removes any trailing `/`. Returns the
/// number of bytes written into `buffer`.
///
/// SECURITY: this is the only barrier between a malicious tar and the
/// filesystem outside `dest_dir`. The check is purely lexical (no
/// `realPath` calls) so it remains correct when target files do not
/// yet exist and is immune to TOCTOU between sanitize and create.
fn sanitizeLogical(buffer: []u8, path: []const u8) error{Invalid}!usize {
    if (path.len == 0) return error.Invalid;
    if (path[0] == '/') return error.Invalid;
    var i: usize = 0;
    var depth: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue;
        for (component) |c| if (c == 0) return error.Invalid;
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return error.Invalid;
            depth -= 1;
            // Pop the trailing component from `buffer`.
            if (i == 0) return error.Invalid;
            i -= 1; // drop the trailing 0 we don't have; back up to the slash boundary
            while (i > 0 and buffer[i] != '/') : (i -= 1) {}
            // i now points at a '/' (or stays at 0 if no '/').
            continue;
        }
        if (depth > 0) {
            if (i + 1 + component.len > buffer.len) return error.Invalid;
            buffer[i] = '/';
            i += 1;
        } else {
            if (i + component.len > buffer.len) return error.Invalid;
        }
        @memcpy(buffer[i..][0..component.len], component);
        i += component.len;
        depth += 1;
    }
    return i;
}

/// Reject symlink targets that resolve outside the extraction root.
/// Absolute targets are rejected unconditionally. For relative targets,
/// we walk `parent_components(link_path) ++ split(target)` with a depth
/// counter; if depth ever drops below zero, the link escapes.
///
/// SECURITY: lexical check, mirroring `sanitizeLogical`. See its doc
/// comment for the TOCTOU rationale.
fn validateSymlinkTarget(link_path: []const u8, target: []const u8) ExtractError!void {
    if (target.len == 0) return ExtractError.UnsafePath;
    if (target[0] == '/') return ExtractError.UnsafePath;

    // Starting depth = number of components in link_path's parent dir.
    // E.g. `bin/sh` has parent `bin/` with depth 1; the symlink lives
    // *at* depth 1 and `..` from it lands back at depth 0.
    var depth: i64 = 0;
    var parent_iter = std.mem.tokenizeScalar(u8, link_path, '/');
    var components: usize = 0;
    while (parent_iter.next()) |_| components += 1;
    if (components > 0) depth = @intCast(components - 1); // drop the link's own basename

    var target_iter = std.mem.tokenizeScalar(u8, target, '/');
    while (target_iter.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        for (component) |c| if (c == 0) return ExtractError.UnsafePath;
        if (std.mem.eql(u8, component, "..")) {
            depth -= 1;
            if (depth < 0) return ExtractError.UnsafePath;
        } else {
            depth += 1;
        }
    }
}

/// Kinds the walker surfaces to the caller. Sparse / device / fifo all
/// collapse to `unsupported` so the caller can decide policy.
const TarKind = enum {
    file,
    directory,
    sym_link,
    hard_link,
    unsupported,
};

const TarEntry = struct {
    name: []const u8,
    link_name: []const u8,
    size: u64,
    mode: u32,
    kind: TarKind,
};

const block_size: usize = 512;

const Walker = struct {
    reader: *Io.Reader,
    file_name_buf: []u8,
    link_name_buf: []u8,

    /// Pending data bytes the caller has not yet consumed (file
    /// content). Drained lazily on the next `next` call.
    unread: u64 = 0,
    /// Padding bytes after the current entry's data, to round up to
    /// the next 512-byte block boundary. Range [0, 511].
    padding: u16 = 0,
    /// Pending name override from a GNU long-name or PAX path record.
    pending_name_len: ?usize = null,
    pending_link_len: ?usize = null,
    /// Pending size override from a PAX size record (rare; entries
    /// > 8 GiB).
    pending_size: ?u64 = null,

    fn init(reader: *Io.Reader, file_name_buf: []u8, link_name_buf: []u8) Walker {
        return .{
            .reader = reader,
            .file_name_buf = file_name_buf,
            .link_name_buf = link_name_buf,
        };
    }

    /// Discard any data + padding the caller did not consume from the
    /// previous entry. Safe to call multiple times.
    fn discardRemaining(self: *Walker) ExtractGzipError!void {
        if (self.unread > 0) {
            try self.reader.discardAll64(self.unread);
            self.unread = 0;
        }
        if (self.padding > 0) {
            try self.reader.discardAll(self.padding);
            self.padding = 0;
        }
    }

    /// Stream `n` bytes of the current entry's data into `dest`.
    /// Updates `unread` so a subsequent `discardRemaining` is a no-op
    /// for the data portion.
    fn streamRemaining(self: *Walker, dest: *Io.Writer, n: u64) Io.Reader.StreamError!void {
        try self.reader.streamExact64(dest, n);
        self.unread = 0;
    }

    /// Yield the next entry, or `null` at EOF. Transparently consumes
    /// GNU long-name / long-link / PAX prefix headers so the caller
    /// only sees real entries.
    fn next(self: *Walker) ExtractGzipError!?TarEntry {
        try self.discardRemaining();

        var name_len: ?usize = self.pending_name_len;
        var link_len: ?usize = self.pending_link_len;
        var size_override: ?u64 = self.pending_size;
        self.pending_name_len = null;
        self.pending_link_len = null;
        self.pending_size = null;

        while (true) {
            var header_bytes: [block_size]u8 = undefined;
            const got = try self.reader.readSliceShort(&header_bytes);
            if (got == 0) return null;
            if (got < block_size) return ExtractError.CorruptStream;
            const hdr: Header = .{ .bytes = &header_bytes };
            if (try hdr.isZeroBlock()) return null;
            try hdr.verifyChecksum();

            const typeflag = hdr.typeflag();
            const raw_size = try hdr.size();
            self.padding = blockPadding(raw_size);

            switch (typeflag) {
                .gnu_long_name => {
                    name_len = try self.readPrefix(raw_size, self.file_name_buf);
                    continue;
                },
                .gnu_long_link => {
                    link_len = try self.readPrefix(raw_size, self.link_name_buf);
                    continue;
                },
                .pax_extended => {
                    var pax = PaxParser{
                        .reader = self.reader,
                        .remaining = @intCast(raw_size),
                    };
                    while (try pax.next()) |attr| switch (attr.key) {
                        .path => name_len = try pax.copyValue(attr, self.file_name_buf),
                        .linkpath => link_len = try pax.copyValue(attr, self.link_name_buf),
                        .size => {
                            var buf: [32]u8 = undefined;
                            const v = try pax.copyValue(attr, &buf);
                            size_override = std.fmt.parseInt(u64, buf[0..v], 10) catch
                                return ExtractError.CorruptStream;
                        },
                        .skip => try pax.skipValue(attr),
                    };
                    self.padding = blockPadding(raw_size);
                    if (self.padding > 0) {
                        try self.reader.discardAll(self.padding);
                        self.padding = 0;
                    }
                    continue;
                },
                .pax_global => {
                    try self.reader.discardAll64(raw_size);
                    if (self.padding > 0) {
                        try self.reader.discardAll(self.padding);
                        self.padding = 0;
                    }
                    continue;
                },
                else => {},
            }

            // Real entry. Resolve name/link from prefix overrides or the header itself.
            const name = if (name_len) |n|
                self.file_name_buf[0..n]
            else
                try hdr.fullName(self.file_name_buf);
            const link_name = if (link_len) |n|
                self.link_name_buf[0..n]
            else
                hdr.linkName(self.link_name_buf) catch return ExtractError.CorruptStream;
            const mode = try hdr.mode();
            const size = size_override orelse raw_size;

            const kind: TarKind = switch (typeflag) {
                .normal_alias, .normal, .contiguous => .file,
                .directory => .directory,
                .symbolic_link => .sym_link,
                .hard_link => .hard_link,
                else => .unsupported,
            };

            // Hardlinks have no data payload; force unread = 0.
            self.unread = if (kind == .file) size else 0;
            if (kind != .file) self.padding = 0;

            return .{
                .name = name,
                .link_name = link_name,
                .size = size,
                .mode = mode,
                .kind = kind,
            };
        }
    }

    fn readPrefix(self: *Walker, size: u64, buf: []u8) ExtractGzipError!usize {
        if (size > buf.len) return ExtractError.CorruptStream;
        const n: usize = @intCast(size);
        // GNU long-name records are null-terminated; readSliceAll only
        // returns success if it gets exactly `n` bytes.
        try self.reader.readSliceAll(buf[0..n]);
        const padding = blockPadding(size);
        if (padding > 0) try self.reader.discardAll(padding);
        self.padding = 0;
        // Strip trailing NUL if present.
        return if (n > 0 and buf[n - 1] == 0) n - 1 else n;
    }
};

fn blockPadding(size: u64) u16 {
    const rem: u16 = @intCast(size % block_size);
    if (rem == 0) return 0;
    return @intCast(block_size - rem);
}

const TypeFlag = enum(u8) {
    normal_alias = 0,
    normal = '0',
    hard_link = '1',
    symbolic_link = '2',
    character_special = '3',
    block_special = '4',
    directory = '5',
    fifo = '6',
    contiguous = '7',
    pax_global = 'g',
    pax_extended = 'x',
    gnu_long_name = 'L',
    gnu_long_link = 'K',
    gnu_sparse = 'S',
    _,
};

const Header = struct {
    bytes: *const [block_size]u8,

    fn typeflag(self: Header) TypeFlag {
        return @enumFromInt(self.bytes[156]);
    }

    fn name(self: Header) []const u8 {
        return nullStr(self.bytes[0..100]);
    }

    fn prefix(self: Header) []const u8 {
        if (!self.is_ustar()) return &.{};
        return nullStr(self.bytes[345..500]);
    }

    fn is_ustar(self: Header) bool {
        const magic = self.bytes[257..263];
        return std.mem.eql(u8, magic[0..5], "ustar");
    }

    fn fullName(self: Header, buf: []u8) ExtractGzipError![]const u8 {
        const n = self.name();
        const p = self.prefix();
        const total = if (p.len == 0) n.len else p.len + 1 + n.len;
        if (buf.len < total) return ExtractError.CorruptStream;
        if (p.len == 0) {
            @memcpy(buf[0..n.len], n);
            return buf[0..n.len];
        }
        @memcpy(buf[0..p.len], p);
        buf[p.len] = '/';
        @memcpy(buf[p.len + 1 ..][0..n.len], n);
        return buf[0..total];
    }

    fn linkName(self: Header, buf: []u8) ExtractGzipError![]const u8 {
        const link = nullStr(self.bytes[157..257]);
        if (buf.len < link.len) return ExtractError.CorruptStream;
        @memcpy(buf[0..link.len], link);
        return buf[0..link.len];
    }

    fn mode(self: Header) ExtractGzipError!u32 {
        const v = octal(self.bytes[100..108]) catch return ExtractError.CorruptStream;
        return @intCast(v);
    }

    fn size(self: Header) ExtractGzipError!u64 {
        const raw = self.bytes[124..136];
        // GNU base-256 binary encoding for sizes that don't fit in 11 octal digits.
        if (raw[0] == 0x80) {
            // Top 4 bytes must be zero for a 64-bit value.
            if (raw[1] != 0 or raw[2] != 0 or raw[3] != 0) return ExtractError.CorruptStream;
            return std.mem.readInt(u64, raw[4..12], .big);
        }
        if (raw[0] == 0xff) return ExtractError.CorruptStream;
        return octal(raw) catch return ExtractError.CorruptStream;
    }

    fn checksum(self: Header) ExtractGzipError!u64 {
        return octal(self.bytes[148..156]) catch ExtractError.CorruptStream;
    }

    fn computedChecksum(self: Header) struct { unsigned: u64, signed: i64 } {
        var u: u64 = 0;
        var s: i64 = 0;
        for (self.bytes, 0..) |b, i| {
            const v: u8 = if (i >= 148 and i < 156) ' ' else b;
            u += v;
            s += @as(i8, @bitCast(v));
        }
        return .{ .unsigned = u, .signed = s };
    }

    fn verifyChecksum(self: Header) ExtractGzipError!void {
        const field = try self.checksum();
        const c = self.computedChecksum();
        if (field != c.unsigned and field != @as(u64, @bitCast(c.signed))) {
            return ExtractError.CorruptStream;
        }
    }

    fn isZeroBlock(self: Header) ExtractGzipError!bool {
        const field = try self.checksum();
        if (field != 0) return false;
        const c = self.computedChecksum();
        // A header of all zeros has unsigned sum == 256 (eight ' '
        // bytes treated as the chksum field).
        return c.unsigned == 256;
    }
};

fn nullStr(s: []const u8) []const u8 {
    for (s, 0..) |c, i| {
        if (c == 0) return s[0..i];
    }
    return s;
}

fn octal(field: []const u8) error{Invalid}!u64 {
    const trimmed_left = std.mem.trimStart(u8, field, "0 ");
    const trimmed = std.mem.trimEnd(u8, trimmed_left, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch error.Invalid;
}

const PaxKey = enum { path, linkpath, size, skip };

const PaxAttr = struct {
    key: PaxKey,
    value_len: usize,
};

const PaxParser = struct {
    reader: *Io.Reader,
    remaining: usize,

    fn next(self: *PaxParser) ExtractGzipError!?PaxAttr {
        while (self.remaining > 0) {
            const len_str = self.reader.takeSentinel(' ') catch return ExtractError.CorruptStream;
            const len = std.fmt.parseInt(usize, len_str, 10) catch return ExtractError.CorruptStream;
            const key_bytes = self.reader.takeSentinel('=') catch return ExtractError.CorruptStream;

            // Compute value length. Layout: "LEN KEY=VALUE\n".
            const consumed = len_str.len + 1 + key_bytes.len + 1; // includes the two separators
            if (len < consumed + 1 or self.remaining < len) return ExtractError.CorruptStream;
            const value_len = len - consumed - 1; // minus the trailing '\n'
            self.remaining -= len;

            const key: PaxKey = if (std.mem.eql(u8, key_bytes, "path"))
                .path
            else if (std.mem.eql(u8, key_bytes, "linkpath"))
                .linkpath
            else if (std.mem.eql(u8, key_bytes, "size"))
                .size
            else
                .skip;

            return .{ .key = key, .value_len = value_len };
        }
        return null;
    }

    fn copyValue(self: *PaxParser, attr: PaxAttr, buf: []u8) ExtractGzipError!usize {
        if (attr.value_len > buf.len) return ExtractError.CorruptStream;
        self.reader.readSliceAll(buf[0..attr.value_len]) catch return ExtractError.CorruptStream;
        if ((self.reader.takeByte() catch return ExtractError.CorruptStream) != '\n') {
            return ExtractError.CorruptStream;
        }
        return attr.value_len;
    }

    fn skipValue(self: *PaxParser, attr: PaxAttr) ExtractGzipError!void {
        self.reader.discardAll(attr.value_len) catch return ExtractError.CorruptStream;
        if ((self.reader.takeByte() catch return ExtractError.CorruptStream) != '\n') {
            return ExtractError.CorruptStream;
        }
    }
};

const testing = std.testing;

/// Build a tar+gzip blob in-memory from a list of synthetic entries.
/// Returns a heap-allocated buffer the caller owns.
fn buildTarGz(allocator: Allocator, entries: []const TestEntry) ![]u8 {
    // Phase 1: assemble the raw tar.
    var raw: Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer raw.deinit();

    var tar_writer: std.tar.Writer = .{ .underlying_writer = &raw.writer };
    for (entries) |e| try writeTestEntry(&tar_writer, &raw.writer, e);
    try raw.writer.flush();

    const raw_bytes = try allocator.dupe(u8, raw.written());
    defer allocator.free(raw_bytes);

    // Phase 2: gzip-wrap. Allocating's initial capacity must exceed
    // flate's 8-byte assertion on `output.buffer.len`.
    var gz: Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer gz.deinit();

    var window: [flate.max_window_len]u8 = undefined;
    var compress = try flate.Compress.init(&gz.writer, &window, .gzip, .default);
    try compress.writer.writeAll(raw_bytes);
    try compress.finish();
    try gz.writer.flush();

    return gz.toOwnedSlice();
}

const TestEntry = union(enum) {
    dir: struct { path: []const u8, mode: u32 = 0o755 },
    file: struct { path: []const u8, content: []const u8, mode: u32 = 0o644 },
    symlink: struct { path: []const u8, target: []const u8 },
    hardlink: struct { path: []const u8, target: []const u8 },
    fifo: struct { path: []const u8 },
    raw_path_file: struct { path: []const u8, content: []const u8 },
};

fn writeTestEntry(w: *std.tar.Writer, raw: *Io.Writer, entry: TestEntry) !void {
    switch (entry) {
        .dir => |d| try w.writeDir(d.path, .{ .mode = d.mode }),
        .file => |f| try w.writeFileBytes(f.path, f.content, .{ .mode = f.mode }),
        .symlink => |s| try w.writeLink(s.path, s.target, .{}),
        .hardlink => |h| try writeRawHeader(raw, h.path, h.target, 0, 0o644, '1'),
        .fifo => |f| try writeRawHeader(raw, f.path, "", 0, 0o644, '6'),
        .raw_path_file => |r| {
            try writeRawHeader(raw, r.path, "", r.content.len, 0o644, '0');
            try raw.writeAll(r.content);
            const pad = blockPadding(r.content.len);
            if (pad > 0) {
                var zero: [block_size]u8 = std.mem.zeroes([block_size]u8);
                try raw.writeAll(zero[0..pad]);
            }
        },
    }
}

fn writeRawHeader(raw: *Io.Writer, path: []const u8, link_name: []const u8, size: u64, mode: u32, typeflag: u8) !void {
    var bytes: [block_size]u8 = std.mem.zeroes([block_size]u8);
    if (path.len > 100 or link_name.len > 100) return error.NameTooLong;

    @memcpy(bytes[0..path.len], path);
    writeOctal(bytes[100..107], mode);
    bytes[107] = 0;
    writeOctal(bytes[124..135], size);
    bytes[135] = 0;
    @memcpy(bytes[136..147], "00000000000");
    bytes[147] = 0;
    @memset(bytes[148..156], ' ');
    bytes[156] = typeflag;
    @memcpy(bytes[157..][0..link_name.len], link_name);
    @memcpy(bytes[257..263], "ustar\x00");
    @memcpy(bytes[263..265], "00");

    var checksum: u64 = 0;
    for (bytes) |b| checksum += b;
    writeOctal(bytes[148..154], checksum);
    bytes[154] = 0;
    bytes[155] = ' ';

    try raw.writeAll(&bytes);
}

fn writeOctal(buf: []u8, value: u64) void {
    var v = value;
    var i: usize = buf.len;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v & 0o7));
        v >>= 3;
    }
}

test "sanitizeLogical accepts simple paths" {
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try sanitizeLogical(&buf, "a/b/c"));
    try testing.expectEqualStrings("a/b/c", buf[0..5]);
}

test "sanitizeLogical collapses dot components" {
    var buf: [256]u8 = undefined;
    const n = try sanitizeLogical(&buf, "./a/./b/./c");
    try testing.expectEqualStrings("a/b/c", buf[0..n]);
}

test "sanitizeLogical handles internal dotdot that stays in tree" {
    var buf: [256]u8 = undefined;
    const n = try sanitizeLogical(&buf, "a/b/../c");
    try testing.expectEqualStrings("a/c", buf[0..n]);
}

test "sanitizeLogical rejects absolute paths" {
    var buf: [256]u8 = undefined;
    try testing.expectError(error.Invalid, sanitizeLogical(&buf, "/etc/passwd"));
}

test "sanitizeLogical rejects escaping dotdot" {
    var buf: [256]u8 = undefined;
    try testing.expectError(error.Invalid, sanitizeLogical(&buf, "../etc"));
    try testing.expectError(error.Invalid, sanitizeLogical(&buf, "a/../../etc"));
}

test "validateSymlinkTarget accepts in-tree relative target" {
    try validateSymlinkTarget("bin/ash", "sh");
    try validateSymlinkTarget("usr/bin/python3", "../../bin/python3");
    try validateSymlinkTarget("a/b/c", "../../d");
}

test "validateSymlinkTarget rejects absolute target" {
    try testing.expectError(ExtractError.UnsafePath, validateSymlinkTarget("link", "/etc"));
}

test "validateSymlinkTarget rejects target that escapes root" {
    try testing.expectError(ExtractError.UnsafePath, validateSymlinkTarget("link", "../../etc"));
    try testing.expectError(ExtractError.UnsafePath, validateSymlinkTarget("a/b", "../../../etc"));
}

test "extractGzip basic round-trip: dir + file + symlink" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .dir = .{ .path = "bin" } },
        .{ .file = .{ .path = "bin/sh", .content = "#!/bin/sh\n", .mode = 0o755 } },
        .{ .symlink = .{ .path = "bin/ash", .target = "sh" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try extractGzip(testing.io, testing.allocator, &reader, tmp.dir);

    var content_buf: [32]u8 = undefined;
    const content = try tmp.dir.readFile(testing.io, "bin/sh", &content_buf);
    try testing.expectEqualStrings("#!/bin/sh\n", content);

    if (Io.File.Permissions.has_executable_bit) {
        const stat = try tmp.dir.statFile(testing.io, "bin/sh", .{});
        const mode = stat.permissions.toMode();
        try testing.expect(mode & 0o100 != 0); // owner-executable
    }

    var link_buf: [32]u8 = undefined;
    const link_n = try tmp.dir.readLink(testing.io, "bin/ash", &link_buf);
    try testing.expectEqualStrings("sh", link_buf[0..link_n]);
}

test "extractGzip whiteout removes a prior-layer file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "etc");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "etc/hostname", .data = "old" });

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .file = .{ .path = "etc/.wh.hostname", .content = "" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try extractGzip(testing.io, testing.allocator, &reader, tmp.dir);

    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "etc/hostname", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "etc/.wh.hostname", .{}));
    const etc_stat = try tmp.dir.statFile(testing.io, "etc", .{});
    try testing.expectEqual(Io.File.Kind.directory, etc_stat.kind);
}

test "extractGzip opaque whiteout clears a directory's contents" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "etc");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "etc/a", .data = "1" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "etc/b", .data = "2" });
    try tmp.dir.createDirPath(testing.io, "etc/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "etc/sub/c", .data = "3" });

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .file = .{ .path = "etc/.wh..wh..opq", .content = "" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try extractGzip(testing.io, testing.allocator, &reader, tmp.dir);

    const etc_stat = try tmp.dir.statFile(testing.io, "etc", .{});
    try testing.expectEqual(Io.File.Kind.directory, etc_stat.kind);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "etc/a", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "etc/b", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "etc/sub", .{}));
}

test "extractGzip rejects path-traversal entry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .raw_path_file = .{ .path = "../../etc/passwd", .content = "pwned" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try testing.expectError(ExtractError.UnsafePath, extractGzip(testing.io, testing.allocator, &reader, tmp.dir));
}

test "extractGzip rejects absolute path entry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .raw_path_file = .{ .path = "/etc/passwd", .content = "pwned" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try testing.expectError(ExtractError.UnsafePath, extractGzip(testing.io, testing.allocator, &reader, tmp.dir));
}

test "extractGzip rejects symlink target that escapes rootfs" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .symlink = .{ .path = "link", .target = "../../etc" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try testing.expectError(ExtractError.UnsafePath, extractGzip(testing.io, testing.allocator, &reader, tmp.dir));
}

test "extractGzip rejects absolute symlink target" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .symlink = .{ .path = "link", .target = "/etc" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try testing.expectError(ExtractError.UnsafePath, extractGzip(testing.io, testing.allocator, &reader, tmp.dir));
}

test "extractGzip materializes a hard link" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .file = .{ .path = "a", .content = "shared" } },
        .{ .hardlink = .{ .path = "b", .target = "a" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try extractGzip(testing.io, testing.allocator, &reader, tmp.dir);

    const stat_a = try tmp.dir.statFile(testing.io, "a", .{});
    const stat_b = try tmp.dir.statFile(testing.io, "b", .{});
    try testing.expectEqual(stat_a.inode, stat_b.inode);

    var content_buf: [16]u8 = undefined;
    const c = try tmp.dir.readFile(testing.io, "b", &content_buf);
    try testing.expectEqualStrings("shared", c);
}

test "extractGzip rejects fifo / unsupported entry kind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .fifo = .{ .path = "myfifo" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try testing.expectError(ExtractError.UnsupportedEntryKind, extractGzip(testing.io, testing.allocator, &reader, tmp.dir));
}

test "extractGzip surfaces typed error for non-gzip blob" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const garbage = "not a gzip stream, not even close" ** 8;
    var reader: Io.Reader = .fixed(garbage);
    try testing.expectError(error.BadGzipHeader, extractGzip(testing.io, testing.allocator, &reader, tmp.dir));
}

test "extractGzip overwrites a previous-layer file with a new symlink" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old", .data = "stale" });

    const blob = try buildTarGz(testing.allocator, &.{
        .{ .symlink = .{ .path = "old", .target = "elsewhere" } },
    });
    defer testing.allocator.free(blob);

    var reader: Io.Reader = .fixed(blob);
    try extractGzip(testing.io, testing.allocator, &reader, tmp.dir);

    var link_buf: [32]u8 = undefined;
    const n = try tmp.dir.readLink(testing.io, "old", &link_buf);
    try testing.expectEqualStrings("elsewhere", link_buf[0..n]);
}
