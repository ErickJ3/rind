//! OCI image reference parser.
//!
//! Decomposes user-supplied strings such as `alpine:3.19`,
//! `ghcr.io/foo/bar:latest`, or `docker.io/library/alpine@sha256:<hex>`
//! into their `{ registry, repository, tag, digest }` components and
//! applies Docker-compatible default expansion (missing registry →
//! `docker.io`; on `docker.io`, single-segment repository → prefixed
//! with `library/`).
//!
//! Pure library: no I/O. Allocation is owned by the caller through
//! `ImageRef.deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors returned by `parse`.
pub const ParseError = error{
    /// Input was the empty string.
    Empty,
    /// Registry component contained an invalid character or was empty.
    InvalidRegistry,
    /// Repository component violated the OCI naming grammar.
    InvalidRepository,
    /// Tag violated the `[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}` charset.
    InvalidTag,
    /// Digest had a malformed `algorithm:hex` shape or wrong hex length.
    InvalidDigest,
    /// Digest used an algorithm rind does not support (only `sha256`).
    UnsupportedDigestAlgorithm,
} || Allocator.Error;

/// Default registry applied when no registry component is provided.
pub const default_registry: []const u8 = "docker.io";

/// Namespace prefix added on `docker.io` for single-segment repositories.
pub const library_namespace: []const u8 = "library";

/// A parsed OCI image reference. Each field is owned by the allocator
/// passed to `parse`; call `deinit` to release them.
pub const ImageRef = struct {
    /// Registry hostname (and optional `:port`), e.g. `docker.io`,
    /// `ghcr.io`, `localhost:5000`.
    registry: []const u8,
    /// Repository path, e.g. `library/alpine`, `foo/bar`.
    repository: []const u8,
    /// Tag if provided, otherwise null.
    tag: ?[]const u8,
    /// Digest in `algorithm:hex` form if provided, otherwise null.
    digest: ?[]const u8,

    /// Free all owned slices. Safe to call exactly once on a successful
    /// `parse` result.
    pub fn deinit(self: *ImageRef, allocator: Allocator) void {
        allocator.free(self.registry);
        allocator.free(self.repository);
        if (self.tag) |t| allocator.free(t);
        if (self.digest) |d| allocator.free(d);
        self.* = undefined;
    }
};

/// Parse an OCI image reference. See module docs for default expansion
/// rules. The returned `ImageRef` owns its strings via `allocator`.
pub fn parse(allocator: Allocator, text: []const u8) ParseError!ImageRef {
    if (text.len == 0) return ParseError.Empty;

    // 1. Split off optional digest at the last `@`.
    var digest_view: ?[]const u8 = null;
    var head: []const u8 = text;
    if (std.mem.lastIndexOfScalar(u8, text, '@')) |at| {
        digest_view = text[at + 1 ..];
        head = text[0..at];
        try validateDigest(digest_view.?);
    }
    if (head.len == 0) return ParseError.InvalidRepository;

    // 2. Split off optional tag. Tag separator is the last `:` that
    // appears after the last `/` (or anywhere, if there is no `/`).
    var tag_view: ?[]const u8 = null;
    var name_part: []const u8 = head;
    if (std.mem.lastIndexOfScalar(u8, head, ':')) |colon| {
        const last_slash = std.mem.lastIndexOfScalar(u8, head, '/');
        const colon_is_tag = if (last_slash) |s| colon > s else true;
        if (colon_is_tag) {
            tag_view = head[colon + 1 ..];
            name_part = head[0..colon];
            try validateTag(tag_view.?);
        }
    }
    if (name_part.len == 0) return ParseError.InvalidRepository;

    // 3. Split off optional registry. Heuristic: the head segment of a
    // `head/tail` split is the registry iff it contains `.` or `:`, or
    // it equals `localhost`.
    var registry_view: []const u8 = default_registry;
    var repo_view: []const u8 = name_part;
    if (std.mem.indexOfScalar(u8, name_part, '/')) |slash| {
        const candidate = name_part[0..slash];
        if (looksLikeRegistry(candidate)) {
            registry_view = candidate;
            repo_view = name_part[slash + 1 ..];
        }
    }
    try validateRegistry(registry_view);
    if (repo_view.len == 0) return ParseError.InvalidRepository;
    try validateRepository(repo_view);

    // 4. Materialize. Library expansion only applies on `docker.io`
    // when the repository has no `/` separator.
    const needs_library = std.mem.eql(u8, registry_view, default_registry) and
        std.mem.indexOfScalar(u8, repo_view, '/') == null;

    const registry_owned = try allocator.dupe(u8, registry_view);
    errdefer allocator.free(registry_owned);

    const repository_owned = if (needs_library)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ library_namespace, repo_view })
    else
        try allocator.dupe(u8, repo_view);
    errdefer allocator.free(repository_owned);

    const tag_owned: ?[]const u8 = if (tag_view) |t| try allocator.dupe(u8, t) else null;
    errdefer if (tag_owned) |t| allocator.free(t);

    const digest_owned: ?[]const u8 = if (digest_view) |d| try allocator.dupe(u8, d) else null;

    return ImageRef{
        .registry = registry_owned,
        .repository = repository_owned,
        .tag = tag_owned,
        .digest = digest_owned,
    };
}

fn looksLikeRegistry(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "localhost")) return true;
    for (s) |c| {
        if (c == '.' or c == ':') return true;
    }
    return false;
}

fn validateRegistry(s: []const u8) ParseError!void {
    if (s.len == 0) return ParseError.InvalidRegistry;
    // Optional `:port` suffix.
    var host: []const u8 = s;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
        const port = s[colon + 1 ..];
        if (port.len == 0) return ParseError.InvalidRegistry;
        for (port) |c| {
            if (c < '0' or c > '9') return ParseError.InvalidRegistry;
        }
        host = s[0..colon];
    }
    if (host.len == 0) return ParseError.InvalidRegistry;
    // Host = one or more labels separated by `.`, each label
    // `[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?`.
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |label| {
        if (label.len == 0) return ParseError.InvalidRegistry;
        if (!isHostLabelEdge(label[0])) return ParseError.InvalidRegistry;
        if (!isHostLabelEdge(label[label.len - 1])) return ParseError.InvalidRegistry;
        for (label) |c| {
            const ok = isHostLabelEdge(c) or c == '-';
            if (!ok) return ParseError.InvalidRegistry;
        }
    }
}

fn isHostLabelEdge(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9');
}

fn validateTag(s: []const u8) ParseError!void {
    if (s.len == 0 or s.len > 128) return ParseError.InvalidTag;
    const first = s[0];
    const first_ok = (first >= 'a' and first <= 'z') or
        (first >= 'A' and first <= 'Z') or
        (first >= '0' and first <= '9') or
        first == '_';
    if (!first_ok) return ParseError.InvalidTag;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '.' or c == '-';
        if (!ok) return ParseError.InvalidTag;
    }
}

/// Repository grammar (per OCI Distribution Spec): one or more
/// `/`-separated *components*, each matching
/// `[a-z0-9]+(([._]|__|[-]+)[a-z0-9]+)*`.
fn validateRepository(s: []const u8) ParseError!void {
    if (s.len == 0) return ParseError.InvalidRepository;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |comp| {
        try validateRepoComponent(comp);
    }
}

fn validateRepoComponent(comp: []const u8) ParseError!void {
    if (comp.len == 0) return ParseError.InvalidRepository;
    var i: usize = 0;
    // Must start with [a-z0-9].
    if (!isAlnumLower(comp[0])) return ParseError.InvalidRepository;
    while (i < comp.len) {
        // alnum-lower run.
        while (i < comp.len and isAlnumLower(comp[i])) : (i += 1) {}
        if (i == comp.len) return; // ended cleanly on alnum.
        // Separator run. Must be one of `.`, `_`, `__`, or all-`-`.
        const sep_start = i;
        while (i < comp.len and isSeparator(comp[i])) : (i += 1) {}
        const sep = comp[sep_start..i];
        if (!validSeparatorRun(sep)) return ParseError.InvalidRepository;
        if (i == comp.len) return ParseError.InvalidRepository; // trailing sep.
        if (!isAlnumLower(comp[i])) return ParseError.InvalidRepository;
    }
}

fn isAlnumLower(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

fn isSeparator(c: u8) bool {
    return c == '.' or c == '_' or c == '-';
}

fn validSeparatorRun(run: []const u8) bool {
    if (run.len == 0) return false;
    if (run.len == 1) return run[0] == '.' or run[0] == '_' or run[0] == '-';
    if (run.len == 2 and run[0] == '_' and run[1] == '_') return true;
    // Any run of 2+ dashes is allowed.
    for (run) |c| if (c != '-') return false;
    return true;
}

fn validateDigest(s: []const u8) ParseError!void {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse
        return ParseError.InvalidDigest;
    const algo = s[0..colon];
    const hex = s[colon + 1 ..];
    if (algo.len == 0 or hex.len == 0) return ParseError.InvalidDigest;
    for (algo) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        if (!ok) return ParseError.InvalidDigest;
    }
    if (!std.mem.eql(u8, algo, "sha256")) {
        return ParseError.UnsupportedDigestAlgorithm;
    }
    if (hex.len != 64) return ParseError.InvalidDigest;
    for (hex) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return ParseError.InvalidDigest;
    }
}

const testing = std.testing;
const sample_hex: []const u8 =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "short ref expands to docker.io/library" {
    var r = try parse(testing.allocator, "alpine");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("docker.io", r.registry);
    try testing.expectEqualStrings("library/alpine", r.repository);
    try testing.expect(r.tag == null);
    try testing.expect(r.digest == null);
}

test "short ref with tag" {
    var r = try parse(testing.allocator, "alpine:3.19");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("docker.io", r.registry);
    try testing.expectEqualStrings("library/alpine", r.repository);
    try testing.expectEqualStrings("3.19", r.tag.?);
    try testing.expect(r.digest == null);
}

test "registry-prefixed ref no library expansion" {
    var r = try parse(testing.allocator, "ghcr.io/foo/bar:latest");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("ghcr.io", r.registry);
    try testing.expectEqualStrings("foo/bar", r.repository);
    try testing.expectEqualStrings("latest", r.tag.?);
}

test "localhost with port is registry not tag" {
    var r = try parse(testing.allocator, "localhost:5000/myimg:v1");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("localhost:5000", r.registry);
    try testing.expectEqualStrings("myimg", r.repository);
    try testing.expectEqualStrings("v1", r.tag.?);
}

test "localhost with port no tag" {
    var r = try parse(testing.allocator, "localhost:5000/myimg");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("localhost:5000", r.registry);
    try testing.expectEqualStrings("myimg", r.repository);
    try testing.expect(r.tag == null);
}

test "digest-only ref" {
    const input = "alpine@sha256:" ++ sample_hex;
    var r = try parse(testing.allocator, input);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("docker.io", r.registry);
    try testing.expectEqualStrings("library/alpine", r.repository);
    try testing.expect(r.tag == null);
    try testing.expectEqualStrings("sha256:" ++ sample_hex, r.digest.?);
}

test "mixed tag and digest" {
    const input = "alpine:3.19@sha256:" ++ sample_hex;
    var r = try parse(testing.allocator, input);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("3.19", r.tag.?);
    try testing.expectEqualStrings("sha256:" ++ sample_hex, r.digest.?);
}

test "fully-qualified explicit ref no expansion" {
    var r = try parse(testing.allocator, "docker.io/library/alpine:3.19");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("docker.io", r.registry);
    try testing.expectEqualStrings("library/alpine", r.repository);
    try testing.expectEqualStrings("3.19", r.tag.?);
}

test "ghcr.io with deep path" {
    var r = try parse(testing.allocator, "ghcr.io/owner/team/proj:1.2.3");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("ghcr.io", r.registry);
    try testing.expectEqualStrings("owner/team/proj", r.repository);
    try testing.expectEqualStrings("1.2.3", r.tag.?);
}

test "empty input rejected" {
    try testing.expectError(ParseError.Empty, parse(testing.allocator, ""));
}

test "bad digest hex length rejected" {
    const short_hex = sample_hex[0..63];
    var buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&buf, "alpine@sha256:{s}", .{short_hex});
    try testing.expectError(ParseError.InvalidDigest, parse(testing.allocator, input));
}

test "non-hex digest rejected" {
    const bad_hex = "g" ++ sample_hex[1..];
    var buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&buf, "alpine@sha256:{s}", .{bad_hex});
    try testing.expectError(ParseError.InvalidDigest, parse(testing.allocator, input));
}

test "unknown digest algo rejected" {
    const input = "alpine@md5:" ++ ("0" ** 32);
    try testing.expectError(
        ParseError.UnsupportedDigestAlgorithm,
        parse(testing.allocator, input),
    );
}

test "missing digest hex rejected" {
    try testing.expectError(
        ParseError.InvalidDigest,
        parse(testing.allocator, "alpine@sha256:"),
    );
}

test "illegal tag char rejected" {
    try testing.expectError(
        ParseError.InvalidTag,
        parse(testing.allocator, "alpine:bad tag"),
    );
}

test "tag starting with dot rejected" {
    try testing.expectError(
        ParseError.InvalidTag,
        parse(testing.allocator, "alpine:.bad"),
    );
}

test "tag too long rejected" {
    var buf: [200]u8 = undefined;
    const long_tag = buf[0..129];
    @memset(long_tag, 'a');
    var input_buf: [256]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf, "alpine:{s}", .{long_tag});
    try testing.expectError(ParseError.InvalidTag, parse(testing.allocator, input));
}

test "uppercase repo rejected" {
    try testing.expectError(
        ParseError.InvalidRepository,
        parse(testing.allocator, "Alpine"),
    );
}

test "trailing slash repo rejected" {
    try testing.expectError(
        ParseError.InvalidRepository,
        parse(testing.allocator, "foo/"),
    );
}

test "empty repo component rejected" {
    try testing.expectError(
        ParseError.InvalidRepository,
        parse(testing.allocator, "ghcr.io//bar"),
    );
}

test "trailing separator in component rejected" {
    try testing.expectError(
        ParseError.InvalidRepository,
        parse(testing.allocator, "docker.io/foo./bar"),
    );
}

test "triple underscore separator rejected" {
    try testing.expectError(
        ParseError.InvalidRepository,
        parse(testing.allocator, "foo___bar"),
    );
}

test "double dash separator allowed" {
    var r = try parse(testing.allocator, "foo--bar");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("library/foo--bar", r.repository);
}

test "deinit frees all fields under testing allocator" {
    // testing.allocator detects leaks; the explicit defer in the other
    // tests already exercises this, but lock it in with an all-fields case.
    const input = "ghcr.io/foo/bar:1.0@sha256:" ++ sample_hex;
    var r = try parse(testing.allocator, input);
    r.deinit(testing.allocator);
}
