//! Streaming gzip / zlib decompression backed by zlib-ng (linked statically;
//! see build.zig `cZlibNg`). Drop-in replacement for the gzip path of
//! `std.compress.flate.Decompress` — same `init(upstream, container, window)`
//! shape and same `reader` field so callers in `src/image/extract.zig` swap
//! one identifier.
//!
//! Why: pure-zig flate is single-threaded and ~5–10× slower than zlib-ng's
//! runtime-dispatched SIMD inflate on x86_64. The bottleneck on `rind pull
//! tensorflow/tensorflow` was a single 355 MB layer that took ~45 s to inflate;
//! zlib-ng cuts that to a handful of seconds, which is the only way to close
//! the gap to docker's wall time without rolling assembly.
//!
//! The wrapper feeds bytes from `upstream` into `zng_inflate` zero-copy via the
//! upstream Reader's own buffered slice and writes decompressed output directly
//! into the caller's `window` (used as the Reader buffer). zlib-ng has its own
//! 32 KiB internal sliding window, so `window` is just an output staging area.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;

const c = @cImport({
    @cInclude("zlib-ng.h");
});

pub const max_window_len: usize = 64 * 1024;

pub const Container = enum {
    /// gzip wrapper (RFC 1952). Matches what registry layers use.
    gzip,
    /// zlib wrapper (RFC 1950). Not used by OCI but keeping the parity.
    zlib,
    /// Raw deflate stream (RFC 1951). No header/checksum.
    raw,

    fn windowBits(c_kind: Container) c_int {
        return switch (c_kind) {
            .gzip => 15 + 16,
            .zlib => 15,
            .raw => -15,
        };
    }
};

pub const Error = error{
    /// `zng_inflateInit2` rejected the parameters or ran out of memory.
    InitFailed,
    /// Stream contained malformed deflate / gzip / zlib data.
    CorruptStream,
    /// Stream needs a preset dictionary (we never set one — registry layers don't).
    NeedDict,
    /// Inflate failed to allocate its internal state.
    OutOfMemory,
    /// Compressed stream was truncated before `Z_STREAM_END`.
    UnexpectedEndOfStream,
    /// Surface from upstream / output writer; details stashed on `err`.
    ReadFailed,
};

pub const Decompress = struct {
    upstream: *Reader,
    z: c.zng_stream,
    err: ?Error,
    eof: bool,
    reader: Reader,

    const vtable: Reader.VTable = .{
        .stream = stream,
        .readVec = readVec,
    };

    /// Initializes `self` in-place. zlib-ng's internal state stores a
    /// back-pointer to the `zng_stream` it was initialized with, so
    /// initializing into a local and then returning by value breaks every
    /// subsequent `zng_inflate` call with `Z_STREAM_ERROR`. Caller pattern:
    ///
    ///     var dec: zlib_ng.Decompress = undefined;
    ///     try dec.init(reader, .gzip, window);
    ///     defer dec.deinit();
    ///
    /// Caller owns `window`; must keep it alive until `deinit` returns.
    /// `window.len` must be at least `max_window_len`.
    pub fn init(self: *Decompress, upstream: *Reader, container: Container, window: []u8) Error!void {
        std.debug.assert(window.len >= max_window_len);

        self.* = .{
            .upstream = upstream,
            .z = std.mem.zeroes(c.zng_stream),
            .err = null,
            .eof = false,
            .reader = .{
                .vtable = &vtable,
                .buffer = window,
                .seek = 0,
                .end = 0,
            },
        };

        const rc = c.zng_inflateInit2(&self.z, container.windowBits());
        if (rc != c.Z_OK) return error.InitFailed;
    }

    /// Releases zlib-ng's internal state. Must be called once. The `window`
    /// slice passed to `init` remains the caller's to free.
    pub fn deinit(d: *Decompress) void {
        _ = c.zng_inflateEnd(&d.z);
        d.* = undefined;
    }

    fn stream(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {
        _ = w;
        _ = limit;
        return readIndirect(r);
    }

    fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
        _ = data;
        return readIndirect(r);
    }

    fn readIndirect(r: *Reader) Reader.Error!usize {
        const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));

        if (d.err != null) return error.ReadFailed;
        if (d.eof) return error.EndOfStream;

        // Compact `r.buffer` when free tail space is too small for a
        // productive inflate call. Without this, after a few cycles
        // r.end pins at r.buffer.len (consumer drains via r.seek but
        // we never move data left), inflate keeps returning Z_BUF_ERROR
        // with no output, and the higher-level Reader livelocks
        // calling readVec → readIndirect → 0 forever. Observed on
        // tensorflow/tensorflow's 355 MB layer: ~500% CPU stuck for
        // 8+ minutes with no progress before adding this.
        if (r.buffer.len - r.end < 16 * 1024 and r.seek > 0) {
            const keep = r.end - r.seek;
            std.mem.copyForwards(u8, r.buffer[0..keep], r.buffer[r.seek..r.end]);
            r.end = keep;
            r.seek = 0;
        }

        // Try to ensure upstream has at least one buffered byte.
        // EndOfStream is not fatal here — zlib-ng can sometimes still
        // produce output from internal state, and the truncation check
        // below catches the real case.
        var input = d.upstream.buffered();
        if (input.len == 0) {
            d.upstream.fillMore() catch |e| switch (e) {
                error.EndOfStream => {},
                error.ReadFailed => {
                    d.err = error.ReadFailed;
                    return error.ReadFailed;
                },
            };
            input = d.upstream.buffered();
        }

        const out = r.buffer[r.end..];
        if (out.len == 0) {
            // Caller hasn't drained the buffer yet. Returning 0 lets the
            // higher-level Reader retry after the consumer makes room.
            return 0;
        }

        d.z.next_in = if (input.len == 0) null else input.ptr;
        d.z.avail_in = @intCast(input.len);
        d.z.next_out = out.ptr;
        d.z.avail_out = @intCast(out.len);

        const rc = c.zng_inflate(&d.z, c.Z_NO_FLUSH);

        const consumed = input.len - @as(usize, d.z.avail_in);
        const produced = out.len - @as(usize, d.z.avail_out);
        if (consumed > 0) d.upstream.toss(consumed);
        r.end += produced;

        switch (rc) {
            c.Z_STREAM_END => {
                d.eof = true;
                return 0;
            },
            c.Z_OK => return 0,
            c.Z_BUF_ERROR => {
                // Z_BUF_ERROR = no progress this call. Only a real error
                // when consumed and produced are both zero AND upstream
                // is exhausted — i.e. the stream ended mid-block.
                if (consumed == 0 and produced == 0 and input.len == 0) {
                    d.err = error.UnexpectedEndOfStream;
                    return error.ReadFailed;
                }
                return 0;
            },
            c.Z_DATA_ERROR => {
                d.err = error.CorruptStream;
                return error.ReadFailed;
            },
            c.Z_NEED_DICT => {
                d.err = error.NeedDict;
                return error.ReadFailed;
            },
            c.Z_MEM_ERROR => {
                d.err = error.OutOfMemory;
                return error.ReadFailed;
            },
            else => {
                d.err = error.CorruptStream;
                return error.ReadFailed;
            },
        }
    }
};

test "decompress empty gzip stream" {
    // Smallest valid gzip: 10-byte header, 2-byte empty deflate block,
    // 8-byte trailer (crc32=0, isize=0).
    const empty_gz = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    var upstream: Reader = .fixed(&empty_gz);
    var window: [max_window_len]u8 = undefined;
    var d: Decompress = undefined;
    try d.init(&upstream, .gzip, &window);
    defer d.deinit();

    var out: [16]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, d.reader.readSliceAll(&out));
}

test "decompress gzip 'hello world'" {
    // gzip of "hello world\n" produced by `printf 'hello world\n' | gzip -n`.
    const hello_gz = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca,
        0x49, 0xe1, 0x02, 0x00, 0x2d, 0x3b, 0x08, 0xaf, 0x0c, 0x00,
        0x00, 0x00,
    };

    var upstream: Reader = .fixed(&hello_gz);
    var window: [max_window_len]u8 = undefined;
    var d: Decompress = undefined;
    try d.init(&upstream, .gzip, &window);
    defer d.deinit();

    var aw = Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    _ = try d.reader.streamRemaining(&aw.writer);

    try std.testing.expectEqualStrings("hello world\n", aw.written());
}
