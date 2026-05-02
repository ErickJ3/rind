//! `WWW-Authenticate` challenge parsing and `Authorization` helpers.
//!
//! Pure library: no I/O, no allocation in `parseChallenge` (returned
//! slices alias the input header value, which the caller must outlive
//! the resulting `Challenge`). The `basicAuthHeader` helper allocates
//! the encoded header value via the caller's allocator.
//!
//! Format (RFC 7235 + Docker token spec):
//!
//!     WWW-Authenticate: Bearer realm="https://auth.example/token",
//!         service="registry.example.com",
//!         scope="repository:library/alpine:pull"
//!
//! Multiple challenges may be present, separated by top-level commas;
//! `parseChallenge` returns the first one whose scheme is recognised
//! (Bearer preferred over Basic when both are listed).
//!
//! Backslash escapes inside quoted values are not supported and produce
//! `BadChallenge` — real OCI registries do not use them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;

/// Auth scheme advertised in a `WWW-Authenticate` header.
pub const Scheme = enum {
    /// HTTP Bearer token. Requires the token-endpoint dance.
    bearer,
    /// HTTP Basic auth (RFC 7617). Used by registries that skip the
    /// token dance and expect the client to send creds directly.
    basic,
};

/// One parsed `WWW-Authenticate` challenge. All slices alias the
/// source header value passed to `parseChallenge`; the caller must
/// outlive them or copy.
pub const Challenge = struct {
    /// Scheme advertised by the server.
    scheme: Scheme,
    /// `realm=` parameter — the URL of the token endpoint for Bearer,
    /// or a free-form realm name for Basic. Always present (otherwise
    /// `parseChallenge` returns `BadChallenge`).
    realm: []const u8,
    /// `service=` parameter — registry identifier the token is scoped
    /// to. Required by Docker token spec for Bearer; optional in RFC.
    service: ?[]const u8 = null,
    /// `scope=` parameter — what the token should be authorised for,
    /// e.g. `repository:library/alpine:pull`.
    scope: ?[]const u8 = null,
    /// `error=` parameter — free-form server-side reason for 401.
    /// Useful for logging; not consumed by the auth flow.
    error_param: ?[]const u8 = null,
};

/// Errors returned by `parseChallenge`.
pub const ParseError = error{
    /// Header value was malformed: missing realm, unterminated quoted
    /// string, empty key, contained an unsupported backslash escape,
    /// etc.
    BadChallenge,
    /// Header value was well-formed but advertised only schemes other
    /// than Bearer or Basic (e.g. `Digest`).
    UnsupportedScheme,
};

/// HTTP Basic credentials. Empty `password` is permitted (some
/// registries accept identity tokens in the username field with an
/// empty password).
pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

/// Pluggable credentials source. Shaped like `std.mem.Allocator`'s
/// vtable so a file-backed (`auth.json`, M4) provider can be dropped
/// in with no API change.
pub const Provider = struct {
    /// Opaque user data passed to `lookup_fn`. May be null for the
    /// `anonymous` provider.
    ctx: ?*anyopaque,
    /// Returns credentials for `host` (the registry's hostname, no
    /// port) or null if none are configured.
    lookup_fn: *const fn (ctx: ?*anyopaque, host: []const u8) ?Credentials,

    /// Look up credentials for a registry hostname. Equivalent to
    /// invoking `lookup_fn` directly.
    pub fn lookup(self: Provider, host: []const u8) ?Credentials {
        return self.lookup_fn(self.ctx, host);
    }

    /// Provider that always returns null. Equivalent to running
    /// without a logged-in `auth.json`.
    pub const anonymous: Provider = .{
        .ctx = null,
        .lookup_fn = anonymousLookup,
    };
};

fn anonymousLookup(_: ?*anyopaque, _: []const u8) ?Credentials {
    return null;
}

/// In-memory `Provider` backed by a hashmap from hostname to
/// `Credentials`. Intended for tests and as a reference
/// implementation; M4 will add a file-backed provider that reads
/// `auth.json`.
pub const StaticProvider = struct {
    map: std.StringHashMapUnmanaged(Credentials) = .empty,

    /// Free every host/credential string and the underlying map.
    pub fn deinit(self: *StaticProvider, gpa: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.username);
            gpa.free(entry.value_ptr.password);
        }
        self.map.deinit(gpa);
        self.* = undefined;
    }

    /// Insert or replace credentials for `host`. `host` and
    /// `creds.{username,password}` are copied with `gpa`.
    pub fn put(
        self: *StaticProvider,
        gpa: Allocator,
        host: []const u8,
        creds: Credentials,
    ) Allocator.Error!void {
        const gop = try self.map.getOrPut(gpa, host);
        if (gop.found_existing) {
            gpa.free(gop.value_ptr.username);
            gpa.free(gop.value_ptr.password);
        } else {
            gop.key_ptr.* = try gpa.dupe(u8, host);
        }
        const u = try gpa.dupe(u8, creds.username);
        errdefer gpa.free(u);
        const p = try gpa.dupe(u8, creds.password);
        gop.value_ptr.* = .{ .username = u, .password = p };
    }

    /// Return a `Provider` view over this map. The returned provider
    /// borrows `*self`; the map must outlive every `lookup` call.
    pub fn provider(self: *StaticProvider) Provider {
        return .{ .ctx = self, .lookup_fn = staticLookup };
    }
};

fn staticLookup(ctx: ?*anyopaque, host: []const u8) ?Credentials {
    const self: *StaticProvider = @ptrCast(@alignCast(ctx.?));
    return self.map.get(host);
}

/// Encode `creds` as the `Authorization: Basic <base64(user:pass)>`
/// header value. Returned slice is owned by the caller and starts
/// with the literal `Basic ` prefix.
pub fn basicAuthHeader(gpa: Allocator, creds: Credentials) Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const concat_len = creds.username.len + 1 + creds.password.len;

    const tmp = try gpa.alloc(u8, concat_len);
    defer gpa.free(tmp);
    @memcpy(tmp[0..creds.username.len], creds.username);
    tmp[creds.username.len] = ':';
    @memcpy(tmp[creds.username.len + 1 ..], creds.password);

    const prefix = "Basic ";
    const out = try gpa.alloc(u8, prefix.len + enc.calcSize(concat_len));
    @memcpy(out[0..prefix.len], prefix);
    _ = enc.encode(out[prefix.len..], tmp);
    return out;
}

/// Parse a `WWW-Authenticate` header value into the first supported
/// `Challenge`. Returns `BadChallenge` for malformed input,
/// `UnsupportedScheme` if the header advertised only schemes other
/// than Bearer/Basic.
pub fn parseChallenge(input: []const u8) ParseError!Challenge {
    var i: usize = 0;
    var saw_unsupported = false;

    while (i < input.len) {
        skipWs(input, &i);
        while (i < input.len and input[i] == ',') {
            i += 1;
            skipWs(input, &i);
        }
        if (i >= input.len) break;

        const scheme_start = i;
        while (i < input.len and isTokenChar(input[i])) i += 1;
        if (i == scheme_start) return error.BadChallenge;
        const scheme_str = input[scheme_start..i];
        const maybe_scheme = matchScheme(scheme_str);

        skipWs(input, &i);

        var ch: Challenge = .{
            .scheme = maybe_scheme orelse .bearer,
            .realm = "",
        };
        var have_realm = false;
        try parseParams(input, &i, &ch, &have_realm);

        if (maybe_scheme) |sch| {
            if (!have_realm) return error.BadChallenge;
            ch.scheme = sch;
            return ch;
        }
        saw_unsupported = true;
    }

    if (saw_unsupported) return error.UnsupportedScheme;
    return error.BadChallenge;
}

fn parseParams(
    src: []const u8,
    idx: *usize,
    ch: *Challenge,
    have_realm: *bool,
) ParseError!void {
    while (idx.* < src.len) {
        skipWs(src, idx);
        if (idx.* >= src.len) return;

        const key_start = idx.*;
        while (idx.* < src.len and isTokenChar(src[idx.*])) idx.* += 1;
        const key = src[key_start..idx.*];
        if (key.len == 0) return;

        skipWs(src, idx);
        if (idx.* >= src.len or src[idx.*] != '=') {
            // Token without `=`: this is the start of the next
            // challenge in a multi-challenge header. Rewind so the
            // outer loop can pick it up.
            idx.* = key_start;
            return;
        }
        idx.* += 1;
        skipWs(src, idx);
        if (idx.* >= src.len) return error.BadChallenge;

        const value = try readValue(src, idx);
        applyParam(ch, key, value, have_realm);

        skipWs(src, idx);
        if (idx.* < src.len and src[idx.*] == ',') {
            idx.* += 1;
        } else {
            return;
        }
    }
}

fn readValue(src: []const u8, idx: *usize) ParseError![]const u8 {
    if (src[idx.*] == '"') {
        idx.* += 1;
        const start = idx.*;
        while (idx.* < src.len) : (idx.* += 1) {
            const c = src[idx.*];
            if (c == '"') {
                const out = src[start..idx.*];
                idx.* += 1;
                return out;
            }
            if (c == '\\') return error.BadChallenge;
        }
        return error.BadChallenge;
    }
    const start = idx.*;
    while (idx.* < src.len) : (idx.* += 1) {
        const c = src[idx.*];
        if (c == ',' or c == ' ' or c == '\t') break;
    }
    if (idx.* == start) return error.BadChallenge;
    return src[start..idx.*];
}

fn applyParam(ch: *Challenge, key: []const u8, value: []const u8, have_realm: *bool) void {
    var lower_buf: [16]u8 = undefined;
    if (key.len > lower_buf.len) return;
    const k = ascii.lowerString(lower_buf[0..key.len], key);
    if (std.mem.eql(u8, k, "realm")) {
        ch.realm = value;
        have_realm.* = true;
    } else if (std.mem.eql(u8, k, "service")) {
        ch.service = value;
    } else if (std.mem.eql(u8, k, "scope")) {
        ch.scope = value;
    } else if (std.mem.eql(u8, k, "error")) {
        ch.error_param = value;
    }
}

fn matchScheme(name: []const u8) ?Scheme {
    if (ascii.eqlIgnoreCase(name, "Bearer")) return .bearer;
    if (ascii.eqlIgnoreCase(name, "Basic")) return .basic;
    return null;
}

fn skipWs(src: []const u8, idx: *usize) void {
    while (idx.* < src.len and (src[idx.*] == ' ' or src[idx.*] == '\t')) idx.* += 1;
}

fn isTokenChar(c: u8) bool {
    // RFC 7230 token charset, intersected with what realm/service/
    // scope keys actually use. We accept the safe ASCII subset.
    return ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

const testing = std.testing;

test "parseChallenge bearer with quoted realm/service/scope" {
    const ch = try parseChallenge(
        \\Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/alpine:pull"
    );
    try testing.expectEqual(Scheme.bearer, ch.scheme);
    try testing.expectEqualStrings("https://auth.docker.io/token", ch.realm);
    try testing.expectEqualStrings("registry.docker.io", ch.service.?);
    try testing.expectEqualStrings("repository:library/alpine:pull", ch.scope.?);
    try testing.expectEqual(@as(?[]const u8, null), ch.error_param);
}

test "parseChallenge bearer with bare unquoted values" {
    const ch = try parseChallenge("Bearer realm=x,service=y,scope=z");
    try testing.expectEqual(Scheme.bearer, ch.scheme);
    try testing.expectEqualStrings("x", ch.realm);
    try testing.expectEqualStrings("y", ch.service.?);
    try testing.expectEqualStrings("z", ch.scope.?);
}

test "parseChallenge ignores unknown params like charset" {
    const ch = try parseChallenge(
        \\Bearer realm="x",service="y",scope="z",charset="UTF-8"
    );
    try testing.expectEqualStrings("x", ch.realm);
    try testing.expectEqualStrings("y", ch.service.?);
    try testing.expectEqualStrings("z", ch.scope.?);
}

test "parseChallenge captures error param" {
    const ch = try parseChallenge(
        \\Bearer realm="x",error="insufficient_scope"
    );
    try testing.expectEqualStrings("insufficient_scope", ch.error_param.?);
}

test "parseChallenge basic scheme" {
    const ch = try parseChallenge(
        \\Basic realm="my-private-registry"
    );
    try testing.expectEqual(Scheme.basic, ch.scheme);
    try testing.expectEqualStrings("my-private-registry", ch.realm);
}

test "parseChallenge picks Bearer when both Bearer and Basic offered" {
    const ch = try parseChallenge(
        \\Bearer realm="https://auth/token",service="reg", Basic realm="reg"
    );
    try testing.expectEqual(Scheme.bearer, ch.scheme);
    try testing.expectEqualStrings("https://auth/token", ch.realm);
}

test "parseChallenge picks Basic when Bearer not offered" {
    const ch = try parseChallenge(
        \\Digest realm="x", Basic realm="y"
    );
    try testing.expectEqual(Scheme.basic, ch.scheme);
    try testing.expectEqualStrings("y", ch.realm);
}

test "parseChallenge missing realm fails" {
    try testing.expectError(error.BadChallenge, parseChallenge("Bearer service=x"));
}

test "parseChallenge unterminated quote fails" {
    try testing.expectError(error.BadChallenge, parseChallenge(
        \\Bearer realm="x
    ));
}

test "parseChallenge backslash escapes rejected" {
    try testing.expectError(error.BadChallenge, parseChallenge(
        \\Bearer realm="a\"b"
    ));
}

test "parseChallenge unknown-only scheme returns UnsupportedScheme" {
    try testing.expectError(error.UnsupportedScheme, parseChallenge(
        \\Digest realm="x"
    ));
}

test "parseChallenge empty value fails" {
    try testing.expectError(error.BadChallenge, parseChallenge("Bearer realm="));
}

test "basicAuthHeader RFC 7617 example" {
    const gpa = testing.allocator;
    const header = try basicAuthHeader(gpa, .{ .username = "Aladdin", .password = "open sesame" });
    defer gpa.free(header);
    try testing.expectEqualStrings("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==", header);
}

test "basicAuthHeader simple alice/secret" {
    const gpa = testing.allocator;
    const header = try basicAuthHeader(gpa, .{ .username = "alice", .password = "secret" });
    defer gpa.free(header);
    try testing.expectEqualStrings("Basic YWxpY2U6c2VjcmV0", header);
}

test "StaticProvider stores and looks up credentials" {
    const gpa = testing.allocator;
    var sp: StaticProvider = .{};
    defer sp.deinit(gpa);
    try sp.put(gpa, "registry.example.com", .{ .username = "alice", .password = "secret" });

    const provider_v = sp.provider();
    const got = provider_v.lookup("registry.example.com").?;
    try testing.expectEqualStrings("alice", got.username);
    try testing.expectEqualStrings("secret", got.password);

    try testing.expectEqual(@as(?Credentials, null), provider_v.lookup("other.example.com"));
}

test "StaticProvider replaces existing credentials" {
    const gpa = testing.allocator;
    var sp: StaticProvider = .{};
    defer sp.deinit(gpa);
    try sp.put(gpa, "host", .{ .username = "u1", .password = "p1" });
    try sp.put(gpa, "host", .{ .username = "u2", .password = "p2" });

    const got = sp.provider().lookup("host").?;
    try testing.expectEqualStrings("u2", got.username);
    try testing.expectEqualStrings("p2", got.password);
}

test "Provider.anonymous always returns null" {
    try testing.expectEqual(@as(?Credentials, null), Provider.anonymous.lookup("anything"));
}
