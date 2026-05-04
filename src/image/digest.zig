//! sha256 content digests for the OCI image store.
//!
//! Owns every interaction with `std.crypto.hash.sha2.Sha256` so the rest
//! of the codebase deals only with `Digest` values and a streaming
//! `Hasher` wrapper. Sha256 is the only OCI-mandatory algorithm in MVP;
//! anything else is rejected at parse time.
//!
//! Pure library: no I/O, no allocations. `Digest` holds the raw 32-byte
//! output; the `sha256:<hex>` view is materialized on demand.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// OCI digest algorithm name. Only `sha256` is supported in MVP.
pub const algorithm: []const u8 = "sha256";

/// Length of a sha256 digest in raw bytes.
pub const byte_length: usize = Sha256.digest_length;

/// Length of a sha256 digest rendered as lowercase hex.
pub const hex_length: usize = byte_length * 2;

/// Canonical `algorithm:` prefix, including the trailing colon.
pub const prefix: []const u8 = algorithm ++ ":";

/// Total length of the canonical `sha256:<hex>` string form (71).
pub const string_length: usize = prefix.len + hex_length;

/// Errors returned by `Digest.parse`.
pub const DigestError = error{
    /// The input was not in the canonical `<algorithm>:<hex>` shape, or
    /// the prefix was malformed (missing colon).
    InvalidPrefix,
    /// The input length did not match `string_length`, or the hex
    /// portion was not exactly `hex_length` characters.
    InvalidLength,
    /// The hex portion contained a non-hex character or an uppercase
    /// hex digit (OCI mandates lowercase).
    InvalidHex,
    /// The algorithm prefix was well-formed but is not `sha256`.
    UnsupportedAlgorithm,
};

/// A parsed sha256 content digest. Stored as the raw 32-byte hash; the
/// `sha256:<hex>` view is rendered on demand via `format` / `toString`.
pub const Digest = struct {
    /// Raw 32-byte sha256 output.
    bytes: [byte_length]u8,

    /// Wrap a precomputed 32-byte sha256 hash in a `Digest`.
    pub fn fromBytes(b: [byte_length]u8) Digest {
        return .{ .bytes = b };
    }

    /// Parse a canonical `sha256:<lowercase-hex>` string into a `Digest`.
    /// Rejects uppercase hex so that `parse` round-trips with `format`.
    pub fn parse(s: []const u8) DigestError!Digest {
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse
            return DigestError.InvalidPrefix;
        const algo = s[0..colon];
        const hex = s[colon + 1 ..];
        if (!std.mem.eql(u8, algo, algorithm)) {
            return DigestError.UnsupportedAlgorithm;
        }
        if (hex.len != hex_length) return DigestError.InvalidLength;
        for (hex) |c| {
            const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
            if (!ok) return DigestError.InvalidHex;
        }
        var out: [byte_length]u8 = undefined;
        const decoded = std.fmt.hexToBytes(&out, hex) catch
            return DigestError.InvalidHex;
        std.debug.assert(decoded.len == byte_length);
        return .{ .bytes = out };
    }

    /// Constant-time equality over the raw 32 bytes.
    pub fn eql(a: Digest, b: Digest) bool {
        return std.crypto.timing_safe.eql([byte_length]u8, a.bytes, b.bytes);
    }

    /// `std.fmt` hook (invoked by the `{f}` placeholder in 0.16).
    /// Always renders `sha256:<lowercase-hex>` regardless of fmt spec.
    pub fn format(self: Digest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        try writer.writeAll(prefix);
        try writer.writeAll(&hex);
    }

    /// Render into a stack buffer of exactly `string_length` bytes and
    /// return a slice over the populated region (which aliases `buf`).
    pub fn toString(self: Digest, buf: *[string_length]u8) []const u8 {
        @memcpy(buf[0..prefix.len], prefix);
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        @memcpy(buf[prefix.len..], &hex);
        return buf[0..];
    }

    /// Render the bare lowercase hex (no `sha256:` prefix) into `buf`.
    /// This is the form used as the on-disk filename in an OCI image
    /// layout (`blobs/sha256/<encodedHex>`).
    pub fn encodedHex(self: Digest, buf: *[hex_length]u8) []const u8 {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        @memcpy(buf, &hex);
        return buf[0..];
    }
};

/// Streaming sha256 hasher. Construct with `init`, feed bytes through
/// `update`, finalize with `final` to get a `Digest`. The store and
/// the blob pool use this to hash blobs on the fly while writing them
/// to disk, avoiding a double pass.
pub const Hasher = struct {
    inner: Sha256,

    /// Start a fresh sha256 stream.
    pub fn init() Hasher {
        return .{ .inner = Sha256.init(.{}) };
    }

    /// Absorb `bytes` into the running hash.
    pub fn update(self: *Hasher, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    /// Finalize the stream and return the resulting digest. The hasher
    /// is left in an undefined state; do not call `update`/`final`
    /// again.
    pub fn final(self: *Hasher) Digest {
        return Digest.fromBytes(self.inner.finalResult());
    }

    /// One-shot convenience: hash a single buffer end-to-end.
    pub fn hash(bytes: []const u8) Digest {
        var out: [byte_length]u8 = undefined;
        Sha256.hash(bytes, &out, .{});
        return Digest.fromBytes(out);
    }
};

const testing = std.testing;

// NIST FIPS 180-4 vectors.
const empty_hex: *const [hex_length:0]u8 =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const abc_hex: *const [hex_length:0]u8 =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

test "parse roundtrip via toString" {
    const input = prefix ++ empty_hex.*;
    const d = try Digest.parse(input);
    var buf: [string_length]u8 = undefined;
    const rendered = d.toString(&buf);
    try testing.expectEqualStrings(input, rendered);
}

test "parse rejects wrong total length" {
    // 70 chars: prefix + 63 hex.
    const short = prefix ++ ("0" ** (hex_length - 1));
    try testing.expectError(DigestError.InvalidLength, Digest.parse(short));
    // 72 chars: prefix + 65 hex.
    const long = prefix ++ ("0" ** (hex_length + 1));
    try testing.expectError(DigestError.InvalidLength, Digest.parse(long));
}

test "parse rejects missing colon" {
    // 71 chars total, no `:` anywhere.
    const bad = "sha256" ++ ("0" ** (string_length - algorithm.len));
    try testing.expectError(DigestError.InvalidPrefix, Digest.parse(bad));
}

test "parse rejects unsupported algorithm" {
    const bad = "md5:" ++ ("0" ** hex_length);
    try testing.expectError(DigestError.UnsupportedAlgorithm, Digest.parse(bad));
}

test "parse rejects non-hex character" {
    const bad = prefix ++ "g" ++ ("0" ** (hex_length - 1));
    try testing.expectError(DigestError.InvalidHex, Digest.parse(bad));
}

test "parse rejects uppercase hex" {
    const bad = prefix ++ "AAAA" ++ ("0" ** (hex_length - 4));
    try testing.expectError(DigestError.InvalidHex, Digest.parse(bad));
}

test "Hasher matches one-shot for empty input" {
    var h = Hasher.init();
    const got = h.final();
    var buf: [string_length]u8 = undefined;
    try testing.expectEqualStrings(prefix ++ empty_hex.*, got.toString(&buf));
    try testing.expect(got.eql(Hasher.hash("")));
}

test "Hasher matches one-shot for abc" {
    var h = Hasher.init();
    h.update("abc");
    const got = h.final();
    var buf: [string_length]u8 = undefined;
    try testing.expectEqualStrings(prefix ++ abc_hex.*, got.toString(&buf));
    try testing.expect(got.eql(Hasher.hash("abc")));
}

test "Hasher chunked update equals one-shot over 1 KiB" {
    var data: [1024]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xff);

    var h = Hasher.init();
    h.update(data[0..400]);
    h.update(data[400..]);
    const streamed = h.final();

    const oneshot = Hasher.hash(&data);
    try testing.expect(streamed.eql(oneshot));
}

test "eql true for identical, false for one-bit-different" {
    const a = try Digest.parse(prefix ++ empty_hex.*);
    const b = try Digest.parse(prefix ++ empty_hex.*);
    try testing.expect(a.eql(b));

    var flipped = a;
    flipped.bytes[0] ^= 0x01;
    try testing.expect(!a.eql(flipped));
}

test "format writer hook produces canonical string" {
    const d = Hasher.hash("abc");
    var sink_buf: [string_length]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buf);
    try d.format(&sink);
    try testing.expectEqualStrings(prefix ++ abc_hex.*, sink.buffered());
}

test "encodedHex strips the algorithm prefix" {
    const d = try Digest.parse(prefix ++ abc_hex.*);
    var buf: [hex_length]u8 = undefined;
    const hex = d.encodedHex(&buf);
    try testing.expectEqualStrings(abc_hex.*[0..], hex);
    try testing.expectEqual(hex_length, hex.len);
}

test "fromBytes wraps raw hash" {
    var raw: [byte_length]u8 = undefined;
    Sha256.hash("abc", &raw, .{});
    const d = Digest.fromBytes(raw);
    try testing.expect(d.eql(Hasher.hash("abc")));
}
