//! OCI image config decoder for `rind images` (T11).
//!
//! Parses the JSON document referenced by a manifest's `config`
//! descriptor. The decoder is narrow: it surfaces only the fields T11
//! consumes (`created`, plus the OCI-mandatory `architecture` / `os` /
//! `rootfs` so torn or wrong-shape bodies still fail loudly) and lets
//! `std.json` skip everything else.
//!
//! Pure library: no I/O, no allocations beyond what `std.json` does
//! into the caller-supplied arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors returned by `parse`. JSON-shape problems roll up to
/// `BadConfigJson`; everything else is the caller's responsibility.
pub const ConfigError = error{
    /// `std.json` rejected the input or a required field was missing.
    BadConfigJson,
};

/// Subset of an OCI image config that T11 cares about. Field names
/// mirror the OCI JSON schema so `std.json` parses without rename
/// hooks. `created` is optional because the spec marks it RECOMMENDED,
/// not REQUIRED — older images may omit it.
pub const ImageConfig = struct {
    /// e.g. `"amd64"`. OCI-required.
    architecture: []const u8,
    /// e.g. `"linux"`. OCI-required.
    os: []const u8,
    /// ISO 8601 timestamp, kept verbatim. Null when the key is absent.
    created: ?[]const u8 = null,
    /// Rootfs descriptor. Required by OCI; demanding the field means a
    /// torn or wrong-shape config is rejected at parse time.
    rootfs: RootFs,

    /// Inner shape of the `rootfs` field.
    pub const RootFs = struct {
        /// Always `"layers"` for OCI image configs.
        type: []const u8,
        /// Uncompressed layer digests (`sha256:<hex>`). Caller-borrowed.
        diff_ids: [][]const u8,
    };
};

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .duplicate_field_behavior = .@"error",
};

/// Decode `bytes` into an `ImageConfig`. Allocations land in
/// `arena_alloc`; the returned value aliases that arena and is invalid
/// once the arena is reset or deinitialized.
pub fn parse(arena_alloc: Allocator, bytes: []const u8) ConfigError!ImageConfig {
    return std.json.parseFromSliceLeaky(ImageConfig, arena_alloc, bytes, parse_options) catch
        return ConfigError.BadConfigJson;
}

const testing = std.testing;

const minimal_config =
    \\{
    \\  "architecture": "amd64",
    \\  "os": "linux",
    \\  "created": "2024-01-27T00:30:48.6Z",
    \\  "rootfs": {
    \\    "type": "layers",
    \\    "diff_ids": [
    \\      "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    \\    ]
    \\  }
    \\}
;

const config_no_created =
    \\{
    \\  "architecture": "arm64",
    \\  "os": "linux",
    \\  "rootfs": { "type": "layers", "diff_ids": [] }
    \\}
;

test "parse extracts architecture, os, created, and rootfs.diff_ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), minimal_config);
    try testing.expectEqualStrings("amd64", c.architecture);
    try testing.expectEqualStrings("linux", c.os);
    try testing.expectEqualStrings("2024-01-27T00:30:48.6Z", c.created.?);
    try testing.expectEqualStrings("layers", c.rootfs.type);
    try testing.expectEqual(@as(usize, 1), c.rootfs.diff_ids.len);
}

test "parse tolerates missing created" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), config_no_created);
    try testing.expectEqual(@as(?[]const u8, null), c.created);
    try testing.expectEqualStrings("arm64", c.architecture);
}

test "parse ignores unknown extension fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fixture =
        \\{
        \\  "architecture": "amd64",
        \\  "os": "linux",
        \\  "rootfs": {"type":"layers","diff_ids":[]},
        \\  "history": [{"created":"x"}],
        \\  "config": {"User":"root"}
        \\}
    ;
    const c = try parse(arena.allocator(), fixture);
    try testing.expectEqualStrings("amd64", c.architecture);
}

test "parse rejects malformed JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ConfigError.BadConfigJson, parse(arena.allocator(), "{not json"));
}

test "parse rejects missing required field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const missing_arch =
        \\{"os":"linux","rootfs":{"type":"layers","diff_ids":[]}}
    ;
    try testing.expectError(ConfigError.BadConfigJson, parse(arena.allocator(), missing_arch));
}
