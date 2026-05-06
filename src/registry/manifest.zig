//! Manifest types, JSON parser, and platform dispatcher.
//!
//! Pure library: no I/O. Sits above the transport in `client.zig`,
//! which calls `parseManifest` / `parseIndex` / `selectPlatform` to
//! decode and dispatch responses from `GET /v2/<repo>/manifests/...`.
//!
//! Re-exports `Descriptor`, `Platform`, and `Index` from
//! `store/layout.zig` so the OCI JSON shapes have a single source of
//! truth across the codebase. Adds `Manifest` (single-platform image
//! manifest), `MediaType` (the four accepted media types), and
//! `ManifestResult` (caller-visible outcome of `Client.getManifest`).
//!
//! Endpoint quirks: `docker.io` is mapped to `registry-1.docker.io`
//! by `registryEndpoint` — that is the only Docker-Hub-specific
//! mapping in the MVP.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const layout = @import("../store/layout.zig");
const digest_mod = @import("../image/digest.zig");

/// OCI image-spec `Descriptor`. Re-exported from `store/layout.zig`
/// so manifest, index, and `index.json` share one source of truth.
pub const Descriptor = layout.Descriptor;

/// OCI image-spec `Platform` object. Re-exported from
/// `store/layout.zig`.
pub const Platform = layout.Platform;

/// OCI image-spec `ImageIndex`. Re-exported from `store/layout.zig`.
/// Same JSON shape covers Docker's `manifest.list.v2+json`.
pub const Index = layout.Index;

/// `Digest` re-export so callers do not also need to import
/// `image/digest.zig`.
pub const Digest = digest_mod.Digest;

/// Manifest media types accepted here. The two `*_index` variants
/// trigger platform dispatch; the two single-manifest variants are
/// the terminal result of `getManifest`.
pub const MediaType = enum {
    /// `application/vnd.oci.image.manifest.v1+json`.
    oci_manifest,
    /// `application/vnd.oci.image.index.v1+json`.
    oci_index,
    /// `application/vnd.docker.distribution.manifest.v2+json`.
    docker_manifest,
    /// `application/vnd.docker.distribution.manifest.list.v2+json`.
    docker_manifest_list,

    /// Canonical media-type string for this variant.
    pub fn toString(mt: MediaType) []const u8 {
        return switch (mt) {
            .oci_manifest => oci_manifest_str,
            .oci_index => oci_index_str,
            .docker_manifest => docker_manifest_str,
            .docker_manifest_list => docker_manifest_list_str,
        };
    }

    /// True for single-platform manifests (`*_manifest`); false for
    /// the index variants that require platform dispatch.
    pub fn isSingle(mt: MediaType) bool {
        return switch (mt) {
            .oci_manifest, .docker_manifest => true,
            .oci_index, .docker_manifest_list => false,
        };
    }

    /// Parse a `Content-Type` header value (or a manifest's inner
    /// `mediaType` field) into a `MediaType`. Tolerates a trailing
    /// `; charset=...` parameter and surrounding whitespace.
    /// Returns `null` for any unsupported value.
    pub fn fromString(ct: []const u8) ?MediaType {
        const semi = std.mem.indexOfScalar(u8, ct, ';') orelse ct.len;
        const trimmed = std.mem.trim(u8, ct[0..semi], " \t");
        if (std.mem.eql(u8, trimmed, oci_manifest_str)) return .oci_manifest;
        if (std.mem.eql(u8, trimmed, oci_index_str)) return .oci_index;
        if (std.mem.eql(u8, trimmed, docker_manifest_str)) return .docker_manifest;
        if (std.mem.eql(u8, trimmed, docker_manifest_list_str)) return .docker_manifest_list;
        return null;
    }
};

const oci_manifest_str = "application/vnd.oci.image.manifest.v1+json";
const oci_index_str = "application/vnd.oci.image.index.v1+json";
const docker_manifest_str = "application/vnd.docker.distribution.manifest.v2+json";
const docker_manifest_list_str = "application/vnd.docker.distribution.manifest.list.v2+json";

/// Comma-joined `Accept` header value listing every media type this
/// module understands. Sent with every manifest GET so the registry can
/// content-negotiate (e.g. return an OCI index instead of Docker
/// when both exist).
pub const accept_header_value: []const u8 =
    oci_manifest_str ++ "," ++
    oci_index_str ++ "," ++
    docker_manifest_str ++ "," ++
    docker_manifest_list_str;

/// Semantic errors specific to manifest fetch and dispatch. Transport
/// errors come from `client.FetchError`; the public method-level
/// error sets union the two.
pub const ManifestError = error{
    /// `Content-Type` was missing or not in our accepted set.
    UnsupportedMediaType,
    /// Body's inner `mediaType` field disagreed with the
    /// `Content-Type` header value.
    MediaTypeMismatch,
    /// Index had no descriptor matching the target platform.
    PlatformNotFound,
    /// JSON parse failed (any std.json error rolls up here).
    BadManifestJson,
    /// Caller asked for `<repo>@sha256:<X>` but the body hashed to a
    /// different digest.
    DigestMismatch,
};

/// Single-platform image manifest (OCI v1 or Docker schema-2). Field
/// names mirror the JSON schema so `std.json` parses without rename
/// hooks. `mediaType` is optional because OCI 1.0 manifests
/// frequently omit it (the type is derived from the response
/// `Content-Type`).
pub const Manifest = struct {
    schemaVersion: u32 = 2,
    mediaType: ?[]const u8 = null,
    config: Descriptor,
    layers: []Descriptor,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
};

/// Outcome of `Client.getManifest`. Owns the raw response bytes plus
/// every nested allocation made while parsing. All allocations live
/// in `arena`; `deinit` reclaims them in one shot.
pub const ManifestResult = struct {
    /// Parsed single-platform manifest (after dispatch through any
    /// image-index layer).
    manifest: Manifest,
    /// SHA-256 of `raw_bytes`, computed once during fetch.
    digest: Digest,
    /// Final media type — always one of the two `isSingle == true`
    /// variants by construction.
    media_type: MediaType,
    /// Verbatim response body the caller can hand directly to
    /// `Store.putBlob` without re-fetching or re-hashing.
    raw_bytes: []const u8,
    /// Last-seen `ETag` from the registry, arena-owned. Null if the
    /// registry omitted the header. The pull orchestrator stamps this
    /// onto the manifest cache so the next refresh can send
    /// `If-None-Match`.
    etag: ?[]const u8 = null,
    /// Backing arena for `manifest`, `raw_bytes`, `etag`, and any
    /// nested strings.
    arena: std.heap.ArenaAllocator,

    /// Free every allocation owned by this result.
    pub fn deinit(self: *ManifestResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Default target platform for image-index dispatch when the caller
/// passes no override. Always `linux/<host_arch>` — rind manages
/// Linux containers, and `architecture` is derived from the build
/// target at comptime. Build fails at comptime if the host arch has
/// no OCI mapping.
pub const default_platform: Platform = .{
    .architecture = ociArchName(builtin.cpu.arch) orelse
        @compileError("rind: unsupported host architecture for default OCI platform"),
    .os = "linux",
};

/// Map a Zig `std.Target.Cpu.Arch` enum to the OCI architecture
/// string. Returns `null` for archs that have no canonical OCI name.
/// Public so callers (e.g. the `--platform` CLI flag) can build
/// their own override `Platform` from a different arch.
pub fn ociArchName(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64, .aarch64_be => "arm64",
        .arm, .armeb => "arm",
        .x86 => "386",
        .powerpc64le => "ppc64le",
        .powerpc64 => "ppc64",
        .riscv64 => "riscv64",
        .s390x => "s390x",
        else => null,
    };
}

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    // `manifest.config.size` and `layers[].size` are u64; the spec
    // permits the full range so do not duplicate-key check beyond the
    // default.
    .duplicate_field_behavior = .@"error",
};

/// Decode a single-platform manifest. `arena_alloc` should be the
/// allocator from a `std.heap.ArenaAllocator` (reset/deinit owned by
/// the caller). On success the returned `Manifest` aliases bytes in
/// `arena_alloc`. If the body has its own `mediaType` field, it must
/// agree with `header_mt` — otherwise `MediaTypeMismatch`.
pub fn parseManifest(
    arena_alloc: Allocator,
    bytes: []const u8,
    header_mt: MediaType,
) ManifestError!Manifest {
    if (!header_mt.isSingle()) return error.MediaTypeMismatch;

    const m = std.json.parseFromSliceLeaky(Manifest, arena_alloc, bytes, parse_options) catch
        return error.BadManifestJson;

    if (m.mediaType) |inner| {
        if (MediaType.fromString(inner)) |inner_mt| {
            if (inner_mt != header_mt) return error.MediaTypeMismatch;
        } else {
            return error.MediaTypeMismatch;
        }
    }
    return m;
}

/// Decode an image-index / manifest-list. Same arena rules as
/// `parseManifest`. Validates inner `mediaType` against `header_mt`
/// when present in the body; tolerates a missing `mediaType` field
/// (some registries omit it and rely on the response Content-Type).
pub fn parseIndex(
    arena_alloc: Allocator,
    bytes: []const u8,
    header_mt: MediaType,
) ManifestError!Index {
    if (header_mt.isSingle()) return error.MediaTypeMismatch;

    // Parse via a local struct with optional `mediaType` so a missing
    // body field does not collide with `layout.Index`'s hardcoded
    // default (which would otherwise produce a spurious mismatch
    // for bodies that omit the field).
    const Parsed = struct {
        schemaVersion: u32 = 2,
        mediaType: ?[]const u8 = null,
        manifests: []Descriptor,
        annotations: ?std.json.ArrayHashMap([]const u8) = null,
    };

    const p = std.json.parseFromSliceLeaky(Parsed, arena_alloc, bytes, parse_options) catch
        return error.BadManifestJson;

    if (p.mediaType) |inner| {
        if (MediaType.fromString(inner)) |inner_mt| {
            if (inner_mt != header_mt) return error.MediaTypeMismatch;
        } else {
            return error.MediaTypeMismatch;
        }
    }

    return .{
        .schemaVersion = p.schemaVersion,
        .mediaType = p.mediaType orelse header_mt.toString(),
        .manifests = p.manifests,
        .annotations = p.annotations,
    };
}

/// Pick the descriptor in `idx` whose embedded `Platform` matches
/// `target` on `(os, architecture)`. Returns `PlatformNotFound` if
/// no entry matches. Variant (e.g. `arm/v7`) is ignored in MVP.
pub fn selectPlatform(idx: Index, target: Platform) ManifestError!Descriptor {
    for (idx.manifests) |d| {
        const p = d.platform orelse continue;
        if (std.mem.eql(u8, p.os, target.os) and
            std.mem.eql(u8, p.architecture, target.architecture))
        {
            return d;
        }
    }
    return error.PlatformNotFound;
}

/// Map an OCI registry name to its actual HTTPS endpoint. Only
/// `docker.io` is rewritten (the public Docker Hub serves the v2 API
/// at `registry-1.docker.io`). Every other input is returned as-is.
pub fn registryEndpoint(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "docker.io")) return "registry-1.docker.io";
    return name;
}

/// Build the manifest base URL (`https://<endpoint>/v2/<repo>/manifests`)
/// for a given `(registry_name, repository)`. Append `/<reference>`
/// to address an individual manifest.
pub fn buildManifestBaseUrl(
    gpa: Allocator,
    registry_name: []const u8,
    repository: []const u8,
) Allocator.Error![]u8 {
    const ep = registryEndpoint(registry_name);
    return std.fmt.allocPrint(gpa, "https://{s}/v2/{s}/manifests", .{ ep, repository });
}

const testing = std.testing;

test "MediaType.fromString round-trips canonical values" {
    inline for (.{
        .oci_manifest,
        .oci_index,
        .docker_manifest,
        .docker_manifest_list,
    }) |mt| {
        const got = MediaType.fromString(@as(MediaType, mt).toString()).?;
        try testing.expectEqual(@as(MediaType, mt), got);
    }
}

test "MediaType.fromString tolerates charset suffix and whitespace" {
    try testing.expectEqual(
        MediaType.oci_manifest,
        MediaType.fromString("application/vnd.oci.image.manifest.v1+json; charset=utf-8").?,
    );
    try testing.expectEqual(
        MediaType.oci_index,
        MediaType.fromString("  application/vnd.oci.image.index.v1+json  ").?,
    );
}

test "MediaType.fromString returns null for unknown" {
    try testing.expectEqual(@as(?MediaType, null), MediaType.fromString("application/json"));
    try testing.expectEqual(@as(?MediaType, null), MediaType.fromString(""));
}

test "MediaType.isSingle distinguishes manifest vs index" {
    try testing.expect(MediaType.oci_manifest.isSingle());
    try testing.expect(MediaType.docker_manifest.isSingle());
    try testing.expect(!MediaType.oci_index.isSingle());
    try testing.expect(!MediaType.docker_manifest_list.isSingle());
}

test "registryEndpoint rewrites docker.io and passes through others" {
    try testing.expectEqualStrings("registry-1.docker.io", registryEndpoint("docker.io"));
    try testing.expectEqualStrings("ghcr.io", registryEndpoint("ghcr.io"));
    try testing.expectEqualStrings("localhost:5000", registryEndpoint("localhost:5000"));
}

test "buildManifestBaseUrl formats https path" {
    const gpa = testing.allocator;
    const url = try buildManifestBaseUrl(gpa, "ghcr.io", "foo/bar");
    defer gpa.free(url);
    try testing.expectEqualStrings("https://ghcr.io/v2/foo/bar/manifests", url);
}

test "buildManifestBaseUrl applies docker.io rewrite" {
    const gpa = testing.allocator;
    const url = try buildManifestBaseUrl(gpa, "docker.io", "library/alpine");
    defer gpa.free(url);
    try testing.expectEqualStrings(
        "https://registry-1.docker.io/v2/library/alpine/manifests",
        url,
    );
}

const oci_manifest_fixture =
    \\{
    \\  "schemaVersion": 2,
    \\  "mediaType": "application/vnd.oci.image.manifest.v1+json",
    \\  "config": {
    \\    "mediaType": "application/vnd.oci.image.config.v1+json",
    \\    "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    \\    "size": 7023
    \\  },
    \\  "layers": [
    \\    {
    \\      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
    \\      "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    \\      "size": 32654
    \\    },
    \\    {
    \\      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
    \\      "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
    \\      "size": 16724
    \\    }
    \\  ]
    \\}
;

const docker_manifest_fixture =
    \\{
    \\  "schemaVersion": 2,
    \\  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    \\  "config": {
    \\    "mediaType": "application/vnd.docker.container.image.v1+json",
    \\    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\    "size": 1234
    \\  },
    \\  "layers": [
    \\    {
    \\      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
    \\      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    \\      "size": 9999
    \\    }
    \\  ]
    \\}
;

const oci_index_fixture =
    \\{
    \\  "schemaVersion": 2,
    \\  "mediaType": "application/vnd.oci.image.index.v1+json",
    \\  "manifests": [
    \\    {
    \\      "mediaType": "application/vnd.oci.image.manifest.v1+json",
    \\      "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
    \\      "size": 7000,
    \\      "platform": { "architecture": "amd64", "os": "linux" }
    \\    },
    \\    {
    \\      "mediaType": "application/vnd.oci.image.manifest.v1+json",
    \\      "digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555",
    \\      "size": 7000,
    \\      "platform": { "architecture": "arm64", "os": "linux" }
    \\    },
    \\    {
    \\      "mediaType": "application/vnd.oci.image.manifest.v1+json",
    \\      "digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666",
    \\      "size": 7000,
    \\      "platform": { "architecture": "arm", "os": "linux", "variant": "v7" }
    \\    }
    \\  ]
    \\}
;

const docker_manifest_list_fixture =
    \\{
    \\  "schemaVersion": 2,
    \\  "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json",
    \\  "manifests": [
    \\    {
    \\      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    \\      "digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
    \\      "size": 5000,
    \\      "platform": { "architecture": "amd64", "os": "linux" }
    \\    },
    \\    {
    \\      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    \\      "digest": "sha256:8888888888888888888888888888888888888888888888888888888888888888",
    \\      "size": 5000,
    \\      "platform": { "architecture": "s390x", "os": "linux" }
    \\    }
    \\  ]
    \\}
;

const oci_index_no_linux_amd64 =
    \\{
    \\  "schemaVersion": 2,
    \\  "mediaType": "application/vnd.oci.image.index.v1+json",
    \\  "manifests": [
    \\    {
    \\      "mediaType": "application/vnd.oci.image.manifest.v1+json",
    \\      "digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
    \\      "size": 7000,
    \\      "platform": { "architecture": "s390x", "os": "linux" }
    \\    }
    \\  ]
    \\}
;

test "parseManifest decodes OCI v1 fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const m = try parseManifest(arena.allocator(), oci_manifest_fixture, .oci_manifest);
    try testing.expectEqual(@as(u32, 2), m.schemaVersion);
    try testing.expectEqualStrings(
        "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        m.config.digest,
    );
    try testing.expectEqual(@as(u64, 7023), m.config.size);
    try testing.expectEqual(@as(usize, 2), m.layers.len);
    try testing.expectEqual(@as(u64, 32654), m.layers[0].size);
}

test "parseManifest decodes Docker schema-2 fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const m = try parseManifest(arena.allocator(), docker_manifest_fixture, .docker_manifest);
    try testing.expectEqual(@as(usize, 1), m.layers.len);
    try testing.expectEqualStrings(
        "application/vnd.docker.image.rootfs.diff.tar.gzip",
        m.layers[0].mediaType,
    );
}

test "parseManifest rejects header_mt that is an index variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.MediaTypeMismatch,
        parseManifest(arena.allocator(), oci_manifest_fixture, .oci_index),
    );
}

test "parseManifest detects body/header mediaType mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Body says OCI but header claims Docker.
    try testing.expectError(
        error.MediaTypeMismatch,
        parseManifest(arena.allocator(), oci_manifest_fixture, .docker_manifest),
    );
}

test "parseManifest rolls up bad JSON to BadManifestJson" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.BadManifestJson,
        parseManifest(arena.allocator(), "{not valid json", .oci_manifest),
    );
}

test "parseIndex decodes OCI image-index fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const idx = try parseIndex(arena.allocator(), oci_index_fixture, .oci_index);
    try testing.expectEqual(@as(usize, 3), idx.manifests.len);
    try testing.expectEqualStrings("amd64", idx.manifests[0].platform.?.architecture);
    try testing.expectEqualStrings("arm64", idx.manifests[1].platform.?.architecture);
}

test "parseIndex decodes Docker manifest-list fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const idx = try parseIndex(arena.allocator(), docker_manifest_list_fixture, .docker_manifest_list);
    try testing.expectEqual(@as(usize, 2), idx.manifests.len);
    try testing.expectEqualStrings("s390x", idx.manifests[1].platform.?.architecture);
}

test "parseIndex rejects single-manifest header_mt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.MediaTypeMismatch,
        parseIndex(arena.allocator(), oci_index_fixture, .oci_manifest),
    );
}

test "selectPlatform picks linux/amd64 from multi-arch index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const idx = try parseIndex(arena.allocator(), oci_index_fixture, .oci_index);
    const picked = try selectPlatform(idx, .{ .architecture = "amd64", .os = "linux" });
    try testing.expectEqualStrings(
        "sha256:4444444444444444444444444444444444444444444444444444444444444444",
        picked.digest,
    );
}

test "selectPlatform returns PlatformNotFound when no match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const idx = try parseIndex(arena.allocator(), oci_index_no_linux_amd64, .oci_index);
    try testing.expectError(
        error.PlatformNotFound,
        selectPlatform(idx, .{ .architecture = "amd64", .os = "linux" }),
    );
}

test "ociArchName covers common architectures" {
    try testing.expectEqualStrings("amd64", ociArchName(.x86_64).?);
    try testing.expectEqualStrings("arm64", ociArchName(.aarch64).?);
    try testing.expectEqualStrings("riscv64", ociArchName(.riscv64).?);
    try testing.expectEqualStrings("s390x", ociArchName(.s390x).?);
    try testing.expectEqual(@as(?[]const u8, null), ociArchName(.xtensa));
}

test "default_platform OS is linux" {
    try testing.expectEqualStrings("linux", default_platform.os);
    try testing.expect(default_platform.architecture.len > 0);
}
