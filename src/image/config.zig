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
    /// OCI image-config `config` object — runtime defaults T21 reads
    /// when composing the bundle. Optional because the spec marks the
    /// whole object as not required, and many real configs omit it.
    config: ?Config = null,

    /// Inner shape of the `rootfs` field.
    pub const RootFs = struct {
        /// Always `"layers"` for OCI image configs.
        type: []const u8,
        /// Uncompressed layer digests (`sha256:<hex>`). Caller-borrowed.
        diff_ids: [][]const u8,
    };

    /// OCI image-config `config` object. Field names mirror the JSON
    /// schema's PascalCase so `std.json` maps keys without rename hooks.
    /// Every field is optional — image configs in the wild routinely
    /// omit any subset. T21 (bundle composer) reads these to fill the
    /// runtime spec's `process` defaults; T11/T12 ignore them.
    pub const Config = struct {
        /// `KEY=VAL` strings forwarded into the container's environment.
        Env: ?[][]const u8 = null,
        /// Default command tokens; user CLI args override at run time.
        Cmd: ?[][]const u8 = null,
        /// Entrypoint tokens. Prepended to `Cmd` per OCI runtime defaults.
        Entrypoint: ?[][]const u8 = null,
        /// Initial working directory inside the container.
        WorkingDir: ?[]const u8 = null,
        /// `user`, `uid`, `user:group`, or `uid:gid`. Resolution against
        /// the rootfs's `/etc/passwd` is the runtime's job.
        User: ?[]const u8 = null,
        /// Free-form key/value labels (e.g. `org.opencontainers.image.*`).
        Labels: ?std.json.ArrayHashMap([]const u8) = null,
        /// Set of ports the image advertises. Keys are `port/proto`
        /// (e.g. `"80/tcp"`); values are empty objects per spec.
        ExposedPorts: ?std.json.ArrayHashMap(struct {}) = null,
        /// Set of mount paths that should default to anonymous volumes.
        /// Keys are absolute paths; values are empty objects per spec.
        Volumes: ?std.json.ArrayHashMap(struct {}) = null,
        /// Stop signal name (`"SIGTERM"`) or number (`"15"`) — verbatim.
        StopSignal: ?[]const u8 = null,
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

test "parse extracts config.Env/Cmd/WorkingDir from real alpine 3.19 fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fixture = @embedFile("testdata/alpine_3_19_config.json");
    const c = try parse(arena.allocator(), fixture);
    const cfg = c.config orelse return error.TestExpectedNonNull;
    try testing.expect(cfg.Env != null);
    try testing.expectEqual(@as(usize, 1), cfg.Env.?.len);
    try testing.expect(std.mem.startsWith(u8, cfg.Env.?[0], "PATH="));
    try testing.expect(cfg.Cmd != null);
    try testing.expectEqual(@as(usize, 1), cfg.Cmd.?.len);
    try testing.expectEqualStrings("/bin/sh", cfg.Cmd.?[0]);
    try testing.expectEqualStrings("/", cfg.WorkingDir.?);
    try testing.expectEqual(@as(?[][]const u8, null), cfg.Entrypoint);
    try testing.expectEqual(@as(?[]const u8, null), cfg.User);
    try testing.expect(cfg.Labels == null);
    try testing.expect(cfg.ExposedPorts == null);
    try testing.expect(cfg.Volumes == null);
    try testing.expectEqual(@as(?[]const u8, null), cfg.StopSignal);
}

test "parse leaves config null when the object is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), config_no_created);
    try testing.expectEqual(@as(?ImageConfig.Config, null), c.config);
}

test "parse extracts only Env when other config fields are absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fixture =
        \\{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":[]},"config":{"Env":["A=1"]}}
    ;
    const c = try parse(arena.allocator(), fixture);
    const cfg = c.config orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(usize, 1), cfg.Env.?.len);
    try testing.expectEqualStrings("A=1", cfg.Env.?[0]);
    try testing.expectEqual(@as(?[][]const u8, null), cfg.Cmd);
    try testing.expectEqual(@as(?[][]const u8, null), cfg.Entrypoint);
    try testing.expectEqual(@as(?[]const u8, null), cfg.WorkingDir);
    try testing.expectEqual(@as(?[]const u8, null), cfg.User);
    try testing.expect(cfg.Labels == null);
    try testing.expect(cfg.ExposedPorts == null);
    try testing.expect(cfg.Volumes == null);
    try testing.expectEqual(@as(?[]const u8, null), cfg.StopSignal);
}

test "parse extracts User, ExposedPorts, Entrypoint from real memcached fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fixture = @embedFile("testdata/memcached_trixie_config.json");
    const c = try parse(arena.allocator(), fixture);
    const cfg = c.config orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("memcache", cfg.User.?);
    try testing.expect(cfg.ExposedPorts != null);
    try testing.expect(cfg.ExposedPorts.?.map.contains("11211/tcp"));
    try testing.expect(cfg.Entrypoint != null);
    try testing.expectEqual(@as(usize, 1), cfg.Entrypoint.?.len);
    try testing.expectEqualStrings("docker-entrypoint.sh", cfg.Entrypoint.?[0]);
    try testing.expect(cfg.Cmd != null);
    try testing.expectEqualStrings("memcached", cfg.Cmd.?[0]);
    try testing.expect(cfg.Labels == null);
    try testing.expect(cfg.Volumes == null);
    try testing.expectEqual(@as(?[]const u8, null), cfg.StopSignal);
}

test "parse extracts Labels, Volumes, StopSignal from full fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fixture = @embedFile("testdata/full_runtime_config.json");
    const c = try parse(arena.allocator(), fixture);
    const cfg = c.config orelse return error.TestExpectedNonNull;
    try testing.expect(cfg.Labels != null);
    try testing.expectEqualStrings(
        "rind-fixture",
        cfg.Labels.?.map.get("org.opencontainers.image.title").?,
    );
    try testing.expectEqualStrings(
        "0.1.0",
        cfg.Labels.?.map.get("org.opencontainers.image.version").?,
    );
    try testing.expect(cfg.Volumes != null);
    try testing.expect(cfg.Volumes.?.map.contains("/data"));
    try testing.expect(cfg.Volumes.?.map.contains("/var/log"));
    try testing.expect(cfg.ExposedPorts != null);
    try testing.expect(cfg.ExposedPorts.?.map.contains("8080/tcp"));
    try testing.expect(cfg.ExposedPorts.?.map.contains("9090/tcp"));
    try testing.expectEqualStrings("SIGTERM", cfg.StopSignal.?);
    try testing.expectEqualStrings("1000:1000", cfg.User.?);
    try testing.expectEqualStrings("/srv", cfg.WorkingDir.?);
}
