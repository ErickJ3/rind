//! OCI Distribution-Spec registry client with Bearer-token auth.
//!
//! Wraps `std.http.Client` with the four-step token dance:
//!
//!   1. Issue the request anonymously (or with a cached Bearer token).
//!   2. On 401, parse the `WWW-Authenticate` challenge.
//!   3. GET the realm token endpoint with `service` + `scope` query
//!      params, optionally carrying HTTP Basic credentials.
//!   4. Retry the original request with `Authorization: Bearer <tok>`.
//!
//! Tokens are cached per `(realm, service, scope)` in a thread-safe
//! map so that T06's concurrent layer downloads share a single token
//! per scope. The challenge parser, credentials provider, and
//! `Authorization: Basic` helper live in `auth.zig`.
//!
//! T04 owns transport only — manifest parsing is T05, blob streaming
//! and concurrency live in T06. The mock-server tests in this file
//! exercise only the auth machinery.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const auth = @import("auth.zig");

/// Re-export of the credentials provider type so callers do not need
/// to also import `auth.zig`.
pub const Provider = auth.Provider;
/// Re-export of the credentials struct.
pub const Credentials = auth.Credentials;

/// Semantic errors specific to the registry transport. Per-method
/// public error sets union this with the relevant std error sets.
pub const RegistryError = error{
    /// 401 still after the auth dance (or after one cache-bust retry).
    Unauthorized,
    /// 403 from the registry.
    Forbidden,
    /// 404 from the registry.
    NotFound,
    /// 401 response did not include a `WWW-Authenticate` header.
    ChallengeMissing,
    /// Token endpoint returned non-200.
    TokenEndpointFailed,
    /// Token endpoint returned a 200 whose JSON body had neither
    /// `token` nor `access_token`.
    BadTokenResponse,
    /// Any 4xx/5xx not specifically classified above.
    UnexpectedStatus,
    /// Bearer challenge from the registry but the configured
    /// `Provider` returned no credentials. Distinct from
    /// `Unauthorized` because the request never reached the token
    /// endpoint.
    NoCredentials,
};

/// Errors returned by `Client.fetch`. The merged set covers semantic
/// errors, challenge-parse errors, and every transport error
/// `std.http.Client` can surface.
pub const FetchError =
    RegistryError ||
    auth.ParseError ||
    Allocator.Error ||
    http.Client.RequestError ||
    http.Client.Request.ReceiveHeadError ||
    std.Uri.ParseError ||
    std.json.ParseFromValueError ||
    error{
        UriMissingHost,
        WriteFailed,
        ReadFailed,
        StreamTooLong,
    };

/// Single high-level request as input to `Client.fetch`.
pub const Request = struct {
    /// HTTP method (defaults to GET — the only one T04/T05/T06 use).
    method: http.Method = .GET,
    /// Full URL (`http://...` or `https://...`).
    url: []const u8,
    /// Optional `Accept` header value, e.g. the comma-separated list
    /// of manifest media types in T05.
    accept: ?[]const u8 = null,
    /// Caller-owned headers added verbatim on every attempt.
    extra_headers: []const http.Header = &.{},
    /// OCI auth scope to use for token-cache lookup and as the
    /// `scope` query param when fetching a fresh token. Example:
    /// `repository:library/alpine:pull`.
    scope: ?[]const u8 = null,
};

/// Outcome of a successful `Client.fetch`. Strings are owned by the
/// caller's allocator and freed via `deinit`.
pub const Response = struct {
    /// Final HTTP status code (after the auth dance, if any).
    status: http.Status,
    /// `Content-Type` header value (allocator-owned dup) or null.
    content_type: ?[]u8 = null,
    /// `Content-Length` header value or null.
    content_length: ?u64 = null,

    /// Free `content_type` if present.
    pub fn deinit(self: *Response, gpa: Allocator) void {
        if (self.content_type) |s| gpa.free(s);
        self.* = undefined;
    }
};

/// Registry client. Wraps a `*std.http.Client` so a single connection
/// pool and TLS context are shared across many `fetch` calls.
pub const Client = struct {
    /// Allocator used for owned slices (header dups, token cache,
    /// JSON parsing of token responses).
    gpa: Allocator,
    /// `Io` instance forwarded to `std.http.Client` for socket I/O.
    io: Io,
    /// Caller-owned HTTP client. Must outlive this `Client`.
    http: *http.Client,
    /// Credentials source. `auth.Provider.anonymous` for purely
    /// public registries.
    provider: Provider,
    /// `User-Agent` header sent on every request.
    user_agent: []const u8,
    /// Token cache shared across all `fetch` calls on this client.
    tokens: TokenCache,

    /// Construct a new `Client`. The returned value owns nothing
    /// outside its `tokens` cache; callers must `deinit` to free that
    /// cache when the client is dropped.
    pub fn init(
        gpa: Allocator,
        io: Io,
        http_client: *http.Client,
        provider: Provider,
    ) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .http = http_client,
            .provider = provider,
            .user_agent = "rind/0.1",
            .tokens = .{},
        };
    }

    /// Release the token cache. Does not deinit the underlying
    /// `*http.Client` — that is the caller's responsibility.
    pub fn deinit(self: *Client) void {
        self.tokens.deinit(self.io, self.gpa);
        self.* = undefined;
    }

    /// Issue an HTTP request, performing the OCI Bearer/Basic auth
    /// dance once on 401. If `body_writer` is non-null, the body of
    /// the final (post-auth) response is streamed there; on the auth
    /// dance the intermediate 401 body is silently discarded.
    pub fn fetch(
        self: *Client,
        req: Request,
        body_writer: ?*Io.Writer,
    ) FetchError!Response {
        const uri = try std.Uri.parse(req.url);
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buf) catch return error.UriMissingHost;
        const host_dup = try self.gpa.dupe(u8, host.bytes);
        defer self.gpa.free(host_dup);

        // Phase 1: probe with no Authorization. We intentionally
        // discard the body of this attempt: if it's 200, we re-issue
        // to populate `body_writer`; if it's 401, the body is
        // throwaway diagnostic JSON.
        var attempt = try self.sendOnce(.{
            .method = req.method,
            .uri = uri,
            .accept = req.accept,
            .extra_headers = req.extra_headers,
            .auth_header = null,
        }, null);

        if (attempt.status != .unauthorized) {
            return self.finalize(req, uri, attempt, body_writer, null);
        }

        // Phase 2: parse challenge.
        const ch_value = attempt.www_authenticate orelse {
            attempt.deinit(self.gpa);
            return error.ChallengeMissing;
        };
        // Copy challenge owned bytes since `attempt` will be dropped.
        const ch_owned = try self.gpa.dupe(u8, ch_value);
        attempt.deinit(self.gpa);
        defer self.gpa.free(ch_owned);

        const challenge = try auth.parseChallenge(ch_owned);

        switch (challenge.scheme) {
            .basic => {
                const creds = self.provider.lookup(host_dup) orelse return error.NoCredentials;
                const header = try auth.basicAuthHeader(self.gpa, creds);
                defer self.gpa.free(header);

                var final = try self.sendOnce(.{
                    .method = req.method,
                    .uri = uri,
                    .accept = req.accept,
                    .extra_headers = req.extra_headers,
                    .auth_header = header,
                }, body_writer);
                if (final.status == .unauthorized) {
                    final.deinit(self.gpa);
                    return error.Unauthorized;
                }
                return self.finalize(req, uri, final, null, null);
            },
            .bearer => return self.bearerFlow(req, uri, host_dup, challenge, body_writer),
        }
    }

    fn bearerFlow(
        self: *Client,
        req: Request,
        uri: std.Uri,
        host: []const u8,
        challenge: auth.Challenge,
        body_writer: ?*Io.Writer,
    ) FetchError!Response {
        const scope_str = req.scope orelse challenge.scope orelse "";
        const service_str = challenge.service orelse "";

        // Try cached token first.
        const now_unix = Io.Clock.real.now(self.io).toSeconds();
        if (try self.tokens.get(self.io, self.gpa, challenge.realm, service_str, scope_str, now_unix)) |cached| {
            defer self.gpa.free(cached);
            const header = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{cached});
            defer self.gpa.free(header);
            var final = try self.sendOnce(.{
                .method = req.method,
                .uri = uri,
                .accept = req.accept,
                .extra_headers = req.extra_headers,
                .auth_header = header,
            }, body_writer);
            if (final.status != .unauthorized) {
                return self.finalize(req, uri, final, null, null);
            }
            // Cached token rejected — drop it and fall through to a
            // fresh fetch from the token endpoint.
            final.deinit(self.gpa);
            self.tokens.invalidate(self.io, self.gpa, challenge.realm, service_str, scope_str);
        }

        // Fresh token from the realm endpoint.
        const token = try self.acquireToken(host, challenge, scope_str);
        defer self.gpa.free(token);

        const header = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{token});
        defer self.gpa.free(header);

        var final = try self.sendOnce(.{
            .method = req.method,
            .uri = uri,
            .accept = req.accept,
            .extra_headers = req.extra_headers,
            .auth_header = header,
        }, body_writer);
        if (final.status == .unauthorized) {
            final.deinit(self.gpa);
            return error.Unauthorized;
        }
        return self.finalize(req, uri, final, null, null);
    }

    fn finalize(
        self: *Client,
        req: Request,
        uri: std.Uri,
        send: SendResult,
        body_writer: ?*Io.Writer,
        retry_auth_header: ?[]const u8,
    ) FetchError!Response {
        var send_mut = send;
        defer send_mut.deinit(self.gpa);

        // If the caller asked for the body and Phase 1 already
        // consumed (and discarded) it, we need a fresh round-trip.
        if (body_writer != null and send_mut.body_was_discarded) {
            const refetch = try self.sendOnce(.{
                .method = req.method,
                .uri = uri,
                .accept = req.accept,
                .extra_headers = req.extra_headers,
                .auth_header = retry_auth_header,
            }, body_writer);
            return classify(refetch);
        }

        return classify(send_mut);
    }

    fn classify(send: SendResult) FetchError!Response {
        switch (send.status) {
            .unauthorized => return error.Unauthorized,
            .forbidden => return error.Forbidden,
            .not_found => return error.NotFound,
            else => {},
        }
        if (@intFromEnum(send.status) >= 400) return error.UnexpectedStatus;

        // Move ownership of content_type across into Response.
        var owned_send = send;
        const ct = owned_send.content_type;
        owned_send.content_type = null;

        return .{
            .status = owned_send.status,
            .content_type = ct,
            .content_length = owned_send.content_length,
        };
    }

    fn acquireToken(
        self: *Client,
        host: []const u8,
        challenge: auth.Challenge,
        scope_str: []const u8,
    ) FetchError![]u8 {
        const url = try buildTokenUrl(self.gpa, challenge.realm, challenge.service, scope_str);
        defer self.gpa.free(url);
        const token_uri = try std.Uri.parse(url);

        var auth_header: ?[]u8 = null;
        defer if (auth_header) |h| self.gpa.free(h);
        if (self.provider.lookup(host)) |creds| {
            auth_header = try auth.basicAuthHeader(self.gpa, creds);
        }

        var body_buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer body_buf.deinit();

        var send = try self.sendOnce(.{
            .method = .GET,
            .uri = token_uri,
            .accept = "application/json",
            .extra_headers = &.{},
            .auth_header = auth_header,
        }, &body_buf.writer);
        defer send.deinit(self.gpa);

        if (send.status != .ok) return error.TokenEndpointFailed;

        const TokenResponse = struct {
            token: ?[]const u8 = null,
            access_token: ?[]const u8 = null,
            expires_in: ?u64 = null,
            issued_at: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(TokenResponse, self.gpa, body_buf.written(), .{
            .ignore_unknown_fields = true,
        }) catch return error.BadTokenResponse;
        defer parsed.deinit();

        const tok_view = parsed.value.token orelse parsed.value.access_token orelse
            return error.BadTokenResponse;
        if (tok_view.len == 0) return error.BadTokenResponse;

        const expires_at: ?i64 = if (parsed.value.expires_in) |sec|
            Io.Clock.real.now(self.io).toSeconds() + @as(i64, @intCast(sec))
        else
            null;

        try self.tokens.put(
            self.io,
            self.gpa,
            challenge.realm,
            challenge.service orelse "",
            scope_str,
            tok_view,
            expires_at,
        );

        return self.gpa.dupe(u8, tok_view);
    }

    const SendOptions = struct {
        method: http.Method,
        uri: std.Uri,
        accept: ?[]const u8,
        extra_headers: []const http.Header,
        auth_header: ?[]const u8,
    };

    const SendResult = struct {
        status: http.Status,
        content_type: ?[]u8 = null,
        content_length: ?u64 = null,
        www_authenticate: ?[]u8 = null,
        /// True iff the body was discarded (no `body_writer` passed
        /// to `sendOnce`). The caller of `fetch` re-sends in this
        /// case to populate the user's writer.
        body_was_discarded: bool = false,

        fn deinit(self: *SendResult, gpa: Allocator) void {
            if (self.content_type) |s| gpa.free(s);
            if (self.www_authenticate) |s| gpa.free(s);
            self.* = undefined;
        }
    };

    fn sendOnce(
        self: *Client,
        opts: SendOptions,
        body_writer: ?*Io.Writer,
    ) FetchError!SendResult {
        // Build the extra-headers slice on the stack. Cap at 8 — we
        // never compose more than user_agent + accept + auth +
        // caller's extras (T05's Accept list is one header value).
        var headers_buf: [8]http.Header = undefined;
        var n: usize = 0;
        headers_buf[n] = .{ .name = "user-agent", .value = self.user_agent };
        n += 1;
        if (opts.accept) |a| {
            headers_buf[n] = .{ .name = "accept", .value = a };
            n += 1;
        }
        if (opts.auth_header) |h| {
            headers_buf[n] = .{ .name = "authorization", .value = h };
            n += 1;
        }
        for (opts.extra_headers) |h| {
            if (n >= headers_buf.len) break;
            headers_buf[n] = h;
            n += 1;
        }

        var redirect_buf: [8 * 1024]u8 = undefined;

        var req = try self.http.request(opts.method, opts.uri, .{
            .extra_headers = headers_buf[0..n],
            .keep_alive = false,
        });
        defer req.deinit();

        req.sendBodiless() catch return error.WriteFailed;
        var response = try req.receiveHead(&redirect_buf);

        var result: SendResult = .{
            .status = response.head.status,
            .content_length = response.head.content_length,
            .body_was_discarded = body_writer == null,
        };
        errdefer result.deinit(self.gpa);

        if (response.head.content_type) |ct| {
            result.content_type = try self.gpa.dupe(u8, ct);
        }
        {
            var it = response.head.iterateHeaders();
            while (it.next()) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name, "www-authenticate")) {
                    result.www_authenticate = try self.gpa.dupe(u8, hdr.value);
                    break;
                }
            }
        }

        var transfer_buf: [16 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        if (body_writer) |w| {
            _ = body_reader.streamRemaining(w) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return error.WriteFailed,
            };
        } else {
            _ = body_reader.discardRemaining() catch return error.ReadFailed;
        }

        return result;
    }
};

fn buildTokenUrl(
    gpa: Allocator,
    realm: []const u8,
    service: ?[]const u8,
    scope: []const u8,
) Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();

    w.writer.writeAll(realm) catch return error.OutOfMemory;
    var sep: u8 = if (std.mem.indexOfScalar(u8, realm, '?')) |_| '&' else '?';
    if (service) |svc| if (svc.len > 0) {
        w.writer.writeByte(sep) catch return error.OutOfMemory;
        w.writer.writeAll("service=") catch return error.OutOfMemory;
        writeUrlEncoded(&w.writer, svc) catch return error.OutOfMemory;
        sep = '&';
    };
    if (scope.len > 0) {
        w.writer.writeByte(sep) catch return error.OutOfMemory;
        w.writer.writeAll("scope=") catch return error.OutOfMemory;
        writeUrlEncoded(&w.writer, scope) catch return error.OutOfMemory;
    }

    return w.toOwnedSlice();
}

fn writeUrlEncoded(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or
            c == '.' or c == '~' or c == ':' or c == '/';
        if (safe) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// Thread-safe `(realm, service, scope)` → token map. T06 will hit
/// this from N concurrent layer-download threads sharing a single
/// `Client`; the mutex serialises all accesses.
const TokenCache = struct {
    mutex: Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        token: []u8,
        /// Absolute unix-second deadline, or null for "never expires".
        expires_at: ?i64 = null,
    };

    fn deinit(self: *TokenCache, io: Io, gpa: Allocator) void {
        // No locking: deinit by definition has exclusive access. The
        // mutex may have been left in any state (locked or unlocked)
        // and we mark `self` undefined at the end either way.
        _ = io;
        var it = self.entries.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.token);
        }
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    fn get(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
        now_unix: i64,
    ) Allocator.Error!?[]u8 {
        var key_buf: [768]u8 = undefined;
        const key = makeStackKey(&key_buf, realm, service, scope) orelse {
            // Key too long; fall back to heap.
            const heap_key = try makeKey(gpa, realm, service, scope);
            defer gpa.free(heap_key);
            return self.lookupAndDup(io, gpa, heap_key, now_unix);
        };
        return self.lookupAndDup(io, gpa, key, now_unix);
    }

    fn lookupAndDup(self: *TokenCache, io: Io, gpa: Allocator, key: []const u8, now_unix: i64) Allocator.Error!?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = self.entries.get(key) orelse return null;
        if (entry.expires_at) |exp| {
            if (now_unix >= exp) return null;
        }
        return try gpa.dupe(u8, entry.token);
    }

    fn put(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
        token: []const u8,
        expires_at: ?i64,
    ) Allocator.Error!void {
        const key = try makeKey(gpa, realm, service, scope);
        errdefer gpa.free(key);
        const tok_dup = try gpa.dupe(u8, token);
        errdefer gpa.free(tok_dup);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const gop = try self.entries.getOrPut(gpa, key);
        if (gop.found_existing) {
            gpa.free(key);
            gpa.free(gop.value_ptr.token);
        } else {
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = .{ .token = tok_dup, .expires_at = expires_at };
    }

    fn invalidate(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
    ) void {
        var key_buf: [768]u8 = undefined;
        const key = makeStackKey(&key_buf, realm, service, scope) orelse return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.fetchRemove(key)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value.token);
        }
    }

    fn keyLen(realm: []const u8, service: []const u8, scope: []const u8) usize {
        return realm.len + 1 + service.len + 1 + scope.len;
    }

    fn writeKey(buf: []u8, realm: []const u8, service: []const u8, scope: []const u8) void {
        @memcpy(buf[0..realm.len], realm);
        buf[realm.len] = 0;
        @memcpy(buf[realm.len + 1 ..][0..service.len], service);
        buf[realm.len + 1 + service.len] = 0;
        @memcpy(buf[realm.len + 2 + service.len ..][0..scope.len], scope);
    }

    fn makeKey(gpa: Allocator, realm: []const u8, service: []const u8, scope: []const u8) Allocator.Error![]u8 {
        const total = keyLen(realm, service, scope);
        const buf = try gpa.alloc(u8, total);
        writeKey(buf, realm, service, scope);
        return buf;
    }

    fn makeStackKey(buf: []u8, realm: []const u8, service: []const u8, scope: []const u8) ?[]u8 {
        const total = keyLen(realm, service, scope);
        if (total > buf.len) return null;
        writeKey(buf[0..total], realm, service, scope);
        return buf[0..total];
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "buildTokenUrl appends service and scope" {
    const gpa = testing.allocator;
    const url = try buildTokenUrl(gpa, "https://auth.example/token", "registry.example", "repository:lib/alpine:pull");
    defer gpa.free(url);
    try testing.expectEqualStrings(
        "https://auth.example/token?service=registry.example&scope=repository:lib/alpine:pull",
        url,
    );
}

test "buildTokenUrl preserves existing query string with `&` separator" {
    const gpa = testing.allocator;
    const url = try buildTokenUrl(gpa, "https://auth.example/token?foo=bar", "svc", "rep:x:pull");
    defer gpa.free(url);
    try testing.expectEqualStrings(
        "https://auth.example/token?foo=bar&service=svc&scope=rep:x:pull",
        url,
    );
}

test "buildTokenUrl percent-encodes spaces and reserved chars" {
    const gpa = testing.allocator;
    const url = try buildTokenUrl(gpa, "https://auth.example/token", "a b", "rep:x:pull");
    defer gpa.free(url);
    try testing.expectEqualStrings(
        "https://auth.example/token?service=a%20b&scope=rep:x:pull",
        url,
    );
}

test "TokenCache put/get roundtrip" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok-1", null);

    const got = (try cache.get(io, gpa, "realm", "svc", "scope", 0)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("tok-1", got);
}

test "TokenCache returns null after expiry" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok", 100);
    try testing.expectEqual(@as(?[]u8, null), try cache.get(io, gpa, "realm", "svc", "scope", 100));
    try testing.expectEqual(@as(?[]u8, null), try cache.get(io, gpa, "realm", "svc", "scope", 999));
}

test "TokenCache replace existing entry frees old token" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok-old", null);
    try cache.put(io, gpa, "realm", "svc", "scope", "tok-new", null);

    const got = (try cache.get(io, gpa, "realm", "svc", "scope", 0)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("tok-new", got);
}

test "TokenCache distinguishes scopes" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "rep:a:pull", "tok-a", null);
    try cache.put(io, gpa, "realm", "svc", "rep:b:pull", "tok-b", null);

    const a = (try cache.get(io, gpa, "realm", "svc", "rep:a:pull", 0)).?;
    defer gpa.free(a);
    const b = (try cache.get(io, gpa, "realm", "svc", "rep:b:pull", 0)).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("tok-a", a);
    try testing.expectEqualStrings("tok-b", b);
}

test "TokenCache invalidate removes entry" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok", null);
    cache.invalidate(io, gpa, "realm", "svc", "scope");
    try testing.expectEqual(@as(?[]u8, null), try cache.get(io, gpa, "realm", "svc", "scope", 0));
}

// ---------------------------------------------------------------------
// Mock-server integration tests
// ---------------------------------------------------------------------

const ScriptStep = struct {
    /// Substring the request target must contain (used to identify
    /// /v2/... vs /token).
    path_contains: []const u8,
    /// Optional substring required somewhere in the request head
    /// (used to assert the Authorization header).
    head_contains: ?[]const u8 = null,
    /// Optional substring required to *not* appear (e.g. asserting
    /// no `authorization` was sent).
    head_not_contains: ?[]const u8 = null,
    status: http.Status = .ok,
    /// Extra headers to send back. Lifetimes managed by the test.
    extra_headers: []const http.Header = &.{},
    body: []const u8 = "",
};

const MockServer = struct {
    server: std.Io.net.Server,
    io: Io,
    steps: []const ScriptStep,
    /// Set on assertion failure inside the worker thread; checked by
    /// the main thread after `join`.
    err: ?anyerror = null,
    requests_seen: usize = 0,

    fn run(self: *MockServer) void {
        for (self.steps) |step| {
            self.handleOne(step) catch |e| {
                self.err = e;
                return;
            };
            self.requests_seen += 1;
        }
    }

    fn handleOne(self: *MockServer, step: ScriptStep) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buf);
        var stream_writer = stream.writer(self.io, &write_buf);

        var server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);
        var request = try server.receiveHead();

        if (std.mem.indexOf(u8, request.head_buffer, step.path_contains) == null) {
            return error.PathMismatch;
        }
        if (step.head_contains) |needle| {
            if (std.mem.indexOf(u8, request.head_buffer, needle) == null) {
                return error.MissingHeader;
            }
        }
        if (step.head_not_contains) |needle| {
            if (std.mem.indexOf(u8, request.head_buffer, needle) != null) {
                return error.UnexpectedHeader;
            }
        }

        try request.respond(step.body, .{
            .status = step.status,
            .extra_headers = step.extra_headers,
            .keep_alive = false,
        });
    }
};

fn startMockServer(io: Io, steps: []const ScriptStep) !*MockServer {
    const gpa = testing.allocator;
    const ms = try gpa.create(MockServer);
    errdefer gpa.destroy(ms);

    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    ms.* = .{
        .server = server,
        .io = io,
        .steps = steps,
        .err = null,
        .requests_seen = 0,
    };
    return ms;
}

fn stopMockServer(ms: *MockServer) void {
    ms.server.deinit(ms.io);
    testing.allocator.destroy(ms);
}

fn formatChallengeUrl(gpa: Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/token", .{port});
}

test "fetch — anonymous bearer flow against mock server" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{}); // populated below
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();

    const challenge_value = try std.fmt.allocPrint(
        gpa,
        "Bearer realm=\"http://127.0.0.1:{d}/token\",service=\"rind-test\",scope=\"repository:test:pull\"",
        .{port},
    );
    defer gpa.free(challenge_value);

    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = challenge_value },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .head_not_contains = "authorization:",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
            .body = "{\"errors\":[{\"code\":\"UNAUTHORIZED\"}]}",
        },
        .{
            .path_contains = "/token?service=rind-test",
            .head_not_contains = "authorization:",
            .status = .ok,
            .body = "{\"token\":\"deadbeef\",\"expires_in\":60}",
        },
        .{
            .path_contains = "/v2/test/manifests/latest",
            .head_contains = "Bearer deadbeef",
            .status = .ok,
            .body = "hello",
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests/latest", .{port});
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var body_buf: Io.Writer.Allocating = .init(gpa);
    defer body_buf.deinit();

    var resp = try client.fetch(.{
        .url = url,
        .scope = "repository:test:pull",
    }, &body_buf.writer);
    defer resp.deinit(gpa);

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings("hello", body_buf.written());
    try testing.expectEqual(@as(usize, 3), ms.requests_seen);
}

test "fetch — authenticated bearer flow sends Basic to token endpoint" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();

    const challenge_value = try std.fmt.allocPrint(
        gpa,
        "Bearer realm=\"http://127.0.0.1:{d}/token\",service=\"rind-test\",scope=\"repository:test:pull\"",
        .{port},
    );
    defer gpa.free(challenge_value);
    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = challenge_value },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
        .{
            .path_contains = "/token?service=rind-test",
            // alice:secret -> YWxpY2U6c2VjcmV0
            .head_contains = "Basic YWxpY2U6c2VjcmV0",
            .status = .ok,
            .body = "{\"token\":\"deadbeef\"}",
        },
        .{
            .path_contains = "/v2/test/manifests/latest",
            .head_contains = "Bearer deadbeef",
            .status = .ok,
            .body = "ok",
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests/latest", .{port});
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var sp: auth.StaticProvider = .{};
    defer sp.deinit(gpa);
    try sp.put(gpa, "127.0.0.1", .{ .username = "alice", .password = "secret" });

    var client = Client.init(gpa, io, &http_client, sp.provider());
    defer client.deinit();

    var body_buf: Io.Writer.Allocating = .init(gpa);
    defer body_buf.deinit();

    var resp = try client.fetch(.{
        .url = url,
        .scope = "repository:test:pull",
    }, &body_buf.writer);
    defer resp.deinit(gpa);

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings("ok", body_buf.written());
}

test "fetch — basic-only registry (no token dance)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();
    _ = port;

    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = "Basic realm=\"private\"" },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/private/manifests/latest",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
        .{
            .path_contains = "/v2/private/manifests/latest",
            .head_contains = "Basic YWxpY2U6c2VjcmV0",
            .status = .ok,
            .body = "private-body",
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/private/manifests/latest", .{ms.server.socket.address.getPort()});
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var sp: auth.StaticProvider = .{};
    defer sp.deinit(gpa);
    try sp.put(gpa, "127.0.0.1", .{ .username = "alice", .password = "secret" });

    var client = Client.init(gpa, io, &http_client, sp.provider());
    defer client.deinit();

    var body_buf: Io.Writer.Allocating = .init(gpa);
    defer body_buf.deinit();

    var resp = try client.fetch(.{ .url = url }, &body_buf.writer);
    defer resp.deinit(gpa);

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings("private-body", body_buf.written());
}

test "fetch — basic challenge with no creds returns NoCredentials" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = "Basic realm=\"private\"" },
    };
    ms.steps = &.{
        .{
            .path_contains = "/v2/private/manifests/latest",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/private/manifests/latest", .{ms.server.socket.address.getPort()});
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    try testing.expectError(error.NoCredentials, client.fetch(.{ .url = url }, null));

    thread.join();
    if (ms.err) |e| return e;
}

test "fetch — bearer token reused on second request" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();
    const challenge_value = try std.fmt.allocPrint(
        gpa,
        "Bearer realm=\"http://127.0.0.1:{d}/token\",service=\"rind-test\",scope=\"repository:test:pull\"",
        .{port},
    );
    defer gpa.free(challenge_value);
    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = challenge_value },
    };

    ms.steps = &.{
        // Request #1: 401 → token → 200
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
        .{
            .path_contains = "/token?service=rind-test",
            .status = .ok,
            .body = "{\"token\":\"deadbeef\",\"expires_in\":60}",
        },
        .{
            .path_contains = "/v2/test/manifests/latest",
            .head_contains = "Bearer deadbeef",
            .status = .ok,
            .body = "first",
        },
        // Request #2: probe gets 401 again, but cached token is sent
        // on the retry directly (no second token endpoint hit).
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
        .{
            .path_contains = "/v2/test/manifests/latest",
            .head_contains = "Bearer deadbeef",
            .status = .ok,
            .body = "second",
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests/latest", .{port});
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var b1: Io.Writer.Allocating = .init(gpa);
    defer b1.deinit();
    var r1 = try client.fetch(.{ .url = url, .scope = "repository:test:pull" }, &b1.writer);
    defer r1.deinit(gpa);
    try testing.expectEqualStrings("first", b1.written());

    var b2: Io.Writer.Allocating = .init(gpa);
    defer b2.deinit();
    var r2 = try client.fetch(.{ .url = url, .scope = "repository:test:pull" }, &b2.writer);
    defer r2.deinit(gpa);
    try testing.expectEqualStrings("second", b2.written());

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqual(@as(usize, 5), ms.requests_seen);
}

test "fetch — 401 after fresh token returns Unauthorized (no infinite loop)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();
    const challenge_value = try std.fmt.allocPrint(
        gpa,
        "Bearer realm=\"http://127.0.0.1:{d}/token\",service=\"rind-test\",scope=\"repository:test:pull\"",
        .{port},
    );
    defer gpa.free(challenge_value);
    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = challenge_value },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
        .{
            .path_contains = "/token?service=rind-test",
            .status = .ok,
            .body = "{\"token\":\"deadbeef\"}",
        },
        .{
            .path_contains = "/v2/test/manifests/latest",
            .head_contains = "Bearer deadbeef",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests/latest", .{port});
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    try testing.expectError(error.Unauthorized, client.fetch(.{
        .url = url,
        .scope = "repository:test:pull",
    }, null));

    thread.join();
    if (ms.err) |e| return e;
}

test "fetch — token endpoint failure surfaces TokenEndpointFailed" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();
    const challenge_value = try std.fmt.allocPrint(
        gpa,
        "Bearer realm=\"http://127.0.0.1:{d}/token\",service=\"rind-test\",scope=\"repository:test:pull\"",
        .{port},
    );
    defer gpa.free(challenge_value);
    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = challenge_value },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
        .{
            .path_contains = "/token?service=rind-test",
            .status = .internal_server_error,
            .body = "boom",
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests/latest", .{port});
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    try testing.expectError(error.TokenEndpointFailed, client.fetch(.{
        .url = url,
        .scope = "repository:test:pull",
    }, null));

    thread.join();
    if (ms.err) |e| return e;
}
