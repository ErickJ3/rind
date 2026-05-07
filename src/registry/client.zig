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
//! map (see `token_cache.zig`) so concurrent layer downloads share a
//! single token per scope. The challenge parser, credentials
//! provider, and `Authorization: Basic` helper live in `auth.zig`.
//!
//! This module owns transport only — manifest parsing lives in
//! `manifest.zig`, blob streaming and concurrency in `blob_pool.zig`.
//! Integration tests against an in-process mock server live in
//! `client_test.zig` (test-only sibling, not imported here).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const auth = @import("auth.zig");
const manifest_mod = @import("manifest.zig");
const image_ref = @import("../image/ref.zig");
const digest_mod = @import("../image/digest.zig");

const TokenCache = @import("token_cache.zig").TokenCache;

/// Re-export of the credentials provider type so callers do not need
/// to also import `auth.zig`.
pub const Provider = auth.Provider;
/// Re-export of the credentials struct.
pub const Credentials = auth.Credentials;
/// Re-export of the manifest result type returned by `Client.getManifest`.
pub const ManifestResult = manifest_mod.ManifestResult;
/// Re-export of the manifest error set.
pub const ManifestError = manifest_mod.ManifestError;
/// Re-export of `Digest` so callers don't also need `image/digest.zig`.
pub const Digest = digest_mod.Digest;

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
    /// Any 4xx not specifically classified above.
    UnexpectedStatus,
    /// 5xx response from the registry. The blob pool retries on this
    /// with bounded backoff; other callers may treat it as terminal.
    ServerError,
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
    /// HTTP method (defaults to GET — the only verb used here).
    method: http.Method = .GET,
    /// Full URL (`http://...` or `https://...`).
    url: []const u8,
    /// Optional `Accept` header value, e.g. the comma-separated list
    /// of accepted manifest media types.
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
    /// `ETag` header value (allocator-owned dup) or null. Surfaced so
    /// the manifest cache can stamp it onto a cache record for the
    /// next conditional revalidation.
    etag: ?[]u8 = null,

    /// Free allocator-owned strings.
    pub fn deinit(self: *Response, gpa: Allocator) void {
        if (self.content_type) |s| gpa.free(s);
        if (self.etag) |s| gpa.free(s);
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

        // Phase 1: probe with no Authorization. Pass the user's
        // `body_writer` so a direct 200 (no auth needed) costs only
        // one round-trip. `sendOnce` discards the body on 401 so the
        // diagnostic JSON does not contaminate `body_writer` before
        // the auth dance retries with credentials.
        var attempt = try self.sendOnce(.{
            .method = req.method,
            .uri = uri,
            .accept = req.accept,
            .extra_headers = req.extra_headers,
            .auth_header = null,
        }, body_writer);

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
                    logHttpFailure(req.method, uri, final.status);
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
            logHttpFailure(req.method, uri, final.status);
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
            var refetch = try self.sendOnce(.{
                .method = req.method,
                .uri = uri,
                .accept = req.accept,
                .extra_headers = req.extra_headers,
                .auth_header = retry_auth_header,
            }, body_writer);
            defer refetch.deinit(self.gpa);
            return classify(&refetch, req.method, uri);
        }

        return classify(&send_mut, req.method, uri);
    }

    fn logHttpFailure(method: http.Method, uri: std.Uri, status: http.Status) void {
        // Tests intentionally trigger 4xx/5xx paths against mock servers;
        // suppress the diagnostic there to keep test output focused on
        // the assertion rather than the expected mock response.
        if (builtin.is_test) return;
        const phrase = status.phrase() orelse "(unknown)";
        std.debug.print(
            "http: {s} {f} -> {d} {s}\n",
            .{ @tagName(method), &uri, @intFromEnum(status), phrase },
        );
    }

    fn classify(send: *SendResult, method: http.Method, uri: std.Uri) FetchError!Response {
        if (@intFromEnum(send.status) >= 400) {
            logHttpFailure(method, uri, send.status);
        }
        switch (send.status) {
            .unauthorized => return error.Unauthorized,
            .forbidden => return error.Forbidden,
            .not_found => return error.NotFound,
            else => {},
        }
        if (@intFromEnum(send.status) >= 500) return error.ServerError;
        if (@intFromEnum(send.status) >= 400) return error.UnexpectedStatus;

        // Move ownership of allocator-owned strings out of the SendResult
        // so the deferred `deinit` does not double-free what now belongs
        // to the returned `Response`.
        const ct = send.content_type;
        send.content_type = null;
        const et = send.etag;
        send.etag = null;

        return .{
            .status = send.status,
            .content_type = ct,
            .content_length = send.content_length,
            .etag = et,
        };
    }

    fn acquireToken(
        self: *Client,
        host: []const u8,
        challenge: auth.Challenge,
        scope_str: []const u8,
    ) FetchError![]u8 {
        const service_str = challenge.service orelse "";
        const now_unix = Io.Clock.real.now(self.io).toSeconds();

        // Single-flight: when a peer caller (typically `prefetch.zig`)
        // is already mid-fetch for the same `(realm, service, scope)`,
        // wait on the cache's condvar rather than duplicate the
        // network round-trip.
        switch (try self.tokens.acquireOrWait(
            self.io,
            self.gpa,
            challenge.realm,
            service_str,
            scope_str,
            now_unix,
        )) {
            .have_token => |tok| return tok,
            .acquire => {},
        }
        errdefer self.tokens.clearInflight(self.io, self.gpa, challenge.realm, service_str, scope_str);

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

        if (send.status != .ok) {
            logHttpFailure(.GET, token_uri, send.status);
            return error.TokenEndpointFailed;
        }

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
            service_str,
            scope_str,
            tok_view,
            expires_at,
        );
        self.tokens.clearInflight(self.io, self.gpa, challenge.realm, service_str, scope_str);

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
        etag: ?[]u8 = null,
        /// True iff the body was discarded (no `body_writer` passed
        /// to `sendOnce`). The caller of `fetch` re-sends in this
        /// case to populate the user's writer.
        body_was_discarded: bool = false,

        fn deinit(self: *SendResult, gpa: Allocator) void {
            if (self.content_type) |s| gpa.free(s);
            if (self.www_authenticate) |s| gpa.free(s);
            if (self.etag) |s| gpa.free(s);
            self.* = undefined;
        }
    };

    fn sendOnce(
        self: *Client,
        opts: SendOptions,
        body_writer: ?*Io.Writer,
    ) FetchError!SendResult {
        // Manual redirect loop. We disable std.http's auto-follow
        // because it preserves every header in `extra_headers` across
        // cross-domain hops; forwarding the Bearer token to Docker
        // Hub's CDN trips S3's "only one auth mechanism" rule
        // (signed query + Authorization header → 400). On a host
        // change we drop `current_auth` before reissuing so the token
        // never reaches the CDN.
        var current_uri = opts.uri;
        var current_auth: ?[]const u8 = opts.auth_header;
        var owned_url: ?[]u8 = null;
        defer if (owned_url) |u| self.gpa.free(u);
        var redirects_left: u8 = 3;

        while (true) {
            // Build the extra-headers slice on the stack. Cap at 8 —
            // we never compose more than user_agent + accept + auth +
            // caller's extras (manifest's Accept list is one header value).
            var headers_buf: [8]http.Header = undefined;
            var n: usize = 0;
            headers_buf[n] = .{ .name = "user-agent", .value = self.user_agent };
            n += 1;
            if (opts.accept) |a| {
                headers_buf[n] = .{ .name = "accept", .value = a };
                n += 1;
            }
            if (current_auth) |h| {
                headers_buf[n] = .{ .name = "authorization", .value = h };
                n += 1;
            }
            for (opts.extra_headers) |h| {
                if (n >= headers_buf.len) break;
                headers_buf[n] = h;
                n += 1;
            }

            var redirect_buf: [8 * 1024]u8 = undefined;

            var req = try self.http.request(opts.method, current_uri, .{
                .extra_headers = headers_buf[0..n],
                .keep_alive = true,
                .redirect_behavior = .unhandled,
            });
            var req_alive = true;
            defer if (req_alive) req.deinit();

            req.sendBodiless() catch return error.WriteFailed;
            var response = try req.receiveHead(&redirect_buf);

            // 304 Not Modified is in the 3xx class but is not a redirect —
            // it carries no `Location` header and the conditional-GET
            // caller wants the status surfaced, not a hop chase.
            if (response.head.status.class() == .redirect and response.head.status != .not_modified and redirects_left > 0) {
                const loc_borrow = response.head.location orelse return error.UnexpectedStatus;
                const loc_dup = try self.gpa.dupe(u8, loc_borrow);
                errdefer self.gpa.free(loc_dup);

                // Drain the redirect body so the connection state is
                // sane before we close it.
                var drain_buf: [16 * 1024]u8 = undefined;
                _ = response.reader(&drain_buf).discardRemaining() catch {};
                req.deinit();
                req_alive = false;

                const new_uri = std.Uri.parse(loc_dup) catch {
                    self.gpa.free(loc_dup);
                    return error.UnexpectedStatus;
                };

                var ob: [std.Io.net.HostName.max_len]u8 = undefined;
                var nb: [std.Io.net.HostName.max_len]u8 = undefined;
                const old_host = current_uri.getHost(&ob) catch return error.UriMissingHost;
                const new_host = new_uri.getHost(&nb) catch return error.UriMissingHost;
                if (!std.ascii.eqlIgnoreCase(old_host.bytes, new_host.bytes)) {
                    current_auth = null;
                }

                if (owned_url) |u| self.gpa.free(u);
                owned_url = loc_dup;
                current_uri = new_uri;
                redirects_left -= 1;
                continue;
            }

            // 401 bodies are diagnostic JSON the auth dance discards;
            // never let them contaminate the caller's writer.
            const will_stream = body_writer != null and response.head.status != .unauthorized;

            var result: SendResult = .{
                .status = response.head.status,
                .content_length = response.head.content_length,
                .body_was_discarded = !will_stream,
            };
            errdefer result.deinit(self.gpa);

            if (response.head.content_type) |ct| {
                result.content_type = try self.gpa.dupe(u8, ct);
            }
            {
                var it = response.head.iterateHeaders();
                while (it.next()) |hdr| {
                    if (result.www_authenticate == null and std.ascii.eqlIgnoreCase(hdr.name, "www-authenticate")) {
                        result.www_authenticate = try self.gpa.dupe(u8, hdr.value);
                    } else if (result.etag == null and std.ascii.eqlIgnoreCase(hdr.name, "etag")) {
                        result.etag = try self.gpa.dupe(u8, hdr.value);
                    }
                }
            }

            var transfer_buf: [64 * 1024]u8 = undefined;
            const body_reader = response.reader(&transfer_buf);
            if (will_stream) {
                _ = body_reader.streamRemaining(body_writer.?) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.WriteFailed => return error.WriteFailed,
                };
            } else {
                _ = body_reader.discardRemaining() catch return error.ReadFailed;
            }

            return result;
        }
    }

    /// Speculative warm-up: GET the manifest URL and discard the body,
    /// purely for the side-effects on `std.http.Client`'s connection
    /// pool and `TokenCache`. Used by `prefetch.zig` to overlap the
    /// auth dance with the orchestrator's pre-fetch disk I/O.
    ///
    /// Returns successfully iff the GET completed (200 or 304); a
    /// 4xx/5xx surfaces as a `FetchError` the prefetch worker
    /// silently swallows. The main-path manifest GET will retry
    /// either way.
    pub fn warmup(
        self: *Client,
        manifest_base: []const u8,
        reference: []const u8,
        scope: []const u8,
        accept: []const u8,
    ) FetchError!void {
        const url = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ manifest_base, reference });
        defer self.gpa.free(url);
        var resp = try self.fetch(.{
            .url = url,
            .accept = accept,
            .scope = scope,
        }, null);
        resp.deinit(self.gpa);
    }

    /// Options for `getManifest` / `getManifestByUrl`.
    pub const GetManifestOptions = struct {
        /// Override target platform when dispatching an image-index.
        /// Defaults to `manifest_mod.default_platform`
        /// (`linux/<host_arch>` baked at comptime).
        platform: ?manifest_mod.Platform = null,
    };

    /// Errors returned by `getManifest`. Unions transport, parse,
    /// and digest errors so callers handle one set.
    pub const GetManifestError =
        FetchError ||
        ManifestError ||
        digest_mod.DigestError;

    /// `GET /v2/<repo>/manifests/<reference>` for the given image
    /// reference. Follows image-index / manifest-list responses
    /// transparently by selecting the picked platform's descriptor
    /// and re-fetching it by digest. Returns the picked
    /// single-platform manifest, its sha256, the resolved media
    /// type, and the verbatim response bytes (suitable for
    /// `Store.putBlob` without re-hashing).
    ///
    /// `<reference>` is `ref.digest` if non-null, else `ref.tag`,
    /// else `"latest"`. When `ref.digest` is present, the response
    /// body is verified against it.
    pub fn getManifest(
        self: *Client,
        ref: image_ref.ImageRef,
        opts: GetManifestOptions,
    ) GetManifestError!ManifestResult {
        const ep_base = try manifest_mod.buildManifestBaseUrl(self.gpa, ref.registry, ref.repository);
        defer self.gpa.free(ep_base);
        const reference = ref.digest orelse ref.tag orelse "latest";
        const scope = try std.fmt.allocPrint(self.gpa, "repository:{s}:pull", .{ref.repository});
        defer self.gpa.free(scope);
        const expected: ?Digest = if (ref.digest) |d| try Digest.parse(d) else null;
        return self.getManifestByUrl(ep_base, reference, scope, expected, opts);
    }

    /// Lower-level entry point used internally for index-recursion
    /// and by tests. `base_url` is the `manifests` endpoint without
    /// the trailing `/<reference>`. `expected_digest`, if non-null,
    /// is compared against the sha256 of the response body and
    /// `DigestMismatch` is returned on disagreement.
    pub fn getManifestByUrl(
        self: *Client,
        base_url: []const u8,
        reference: []const u8,
        scope: []const u8,
        expected_digest: ?Digest,
        opts: GetManifestOptions,
    ) GetManifestError!ManifestResult {
        return switch (try self.getManifestByUrlConditional(base_url, reference, scope, expected_digest, null, opts)) {
            .fetched => |m| m,
            .not_modified => unreachable,
        };
    }

    /// Outcome of `getManifestByUrlConditional`. `not_modified` happens
    /// only when the caller passed `if_none_match` and the registry
    /// honored the conditional with a 304. `fetched` is the same
    /// `ManifestResult` `getManifestByUrl` returns.
    pub const ConditionalManifest = union(enum) {
        not_modified,
        fetched: ManifestResult,

        pub fn deinit(self: *ConditionalManifest) void {
            switch (self.*) {
                .not_modified => {},
                .fetched => |*m| m.deinit(),
            }
        }
    };

    /// Same as `getManifestByUrl` but supports conditional GETs via an
    /// optional `If-None-Match` ETag. Returns `.not_modified` (no
    /// allocation) when the registry replies 304 — caller is expected
    /// to keep using the manifest blob it cached against `if_none_match`.
    pub fn getManifestByUrlConditional(
        self: *Client,
        base_url: []const u8,
        reference: []const u8,
        scope: []const u8,
        expected_digest: ?Digest,
        if_none_match: ?[]const u8,
        opts: GetManifestOptions,
    ) GetManifestError!ConditionalManifest {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        var arena_owned: bool = true;
        errdefer if (arena_owned) arena.deinit();
        const arena_alloc = arena.allocator();

        const url = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ base_url, reference });
        defer self.gpa.free(url);

        var extras_buf: [1]http.Header = undefined;
        const extras: []const http.Header = if (if_none_match) |inm| blk: {
            extras_buf[0] = .{ .name = "if-none-match", .value = inm };
            break :blk extras_buf[0..1];
        } else &.{};

        var body_buf: Io.Writer.Allocating = .init(arena_alloc);
        var resp = try self.fetch(.{
            .url = url,
            .accept = manifest_mod.accept_header_value,
            .extra_headers = extras,
            .scope = scope,
        }, &body_buf.writer);
        defer resp.deinit(self.gpa);

        if (resp.status == .not_modified) {
            return .not_modified;
        }

        const ct = resp.content_type orelse return error.UnsupportedMediaType;
        const mt = manifest_mod.MediaType.fromString(ct) orelse return error.UnsupportedMediaType;

        const raw_bytes = try body_buf.toOwnedSlice();

        const computed = digest_mod.Hasher.hash(raw_bytes);
        if (expected_digest) |exp| {
            if (!computed.eql(exp)) return error.DigestMismatch;
        }

        if (mt.isSingle()) {
            const m = try manifest_mod.parseManifest(arena_alloc, raw_bytes, mt);
            const etag_dup: ?[]const u8 = if (resp.etag) |e| try arena_alloc.dupe(u8, e) else null;
            arena_owned = false;
            return .{ .fetched = .{
                .manifest = m,
                .digest = computed,
                .media_type = mt,
                .raw_bytes = raw_bytes,
                .etag = etag_dup,
                .arena = arena,
            } };
        }

        // Index path: parse, select platform, recurse on the picked
        // descriptor's digest. The picked digest string lives in
        // `arena`, so dup it onto `self.gpa` before tearing down.
        const idx = try manifest_mod.parseIndex(arena_alloc, raw_bytes, mt);
        const target = opts.platform orelse manifest_mod.default_platform;
        const picked = try manifest_mod.selectPlatform(idx, target);
        const picked_dig = try Digest.parse(picked.digest);

        const picked_ref_dup = try self.gpa.dupe(u8, picked.digest);
        defer self.gpa.free(picked_ref_dup);

        arena.deinit();
        arena_owned = false;
        // Index recursion never sends If-None-Match — the digest in the
        // index already pins identity, and a registry that honored 304
        // for the index would not honor it for the picked manifest
        // anyway (different URL, different ETag).
        const inner = try self.getManifestByUrlConditional(base_url, picked_ref_dup, scope, picked_dig, null, opts);
        return inner;
    }

    /// Tunables for `getBlob` / `getBlobByUrl`. The defaults match the
    /// MVP spec: three retries, 100 ms initial backoff, 10 s ceiling.
    pub const GetBlobOptions = struct {
        /// Maximum number of *additional* attempts on top of the first.
        /// Total attempts = `max_retries + 1`.
        max_retries: u32 = 3,
        /// Backoff before the first retry, in milliseconds. Doubled on
        /// each subsequent retry up to `max_backoff_ms`.
        initial_backoff_ms: u32 = 100,
        /// Upper bound for backoff between retries, in milliseconds.
        max_backoff_ms: u32 = 10_000,
        /// Optional progress sink. When non-null, `getBlobByUrl`
        /// updates the node's completed-items count to the running
        /// byte total on every drained chunk. The node's
        /// estimated-total should be set by the caller to the blob
        /// `size` so the `std.Progress` renderer can fill its bar.
        progress_node: ?std.Progress.Node = null,
    };

    /// Errors returned by `getBlob` / `getBlobByUrl`. Unions transport,
    /// digest-parse, and the blob-specific cases (`DigestMismatch`,
    /// `ResumeRangeRejected`, `TooManyRetries`).
    pub const GetBlobError =
        FetchError ||
        digest_mod.DigestError ||
        error{
            /// Streamed body did not hash to the expected digest.
            DigestMismatch,
            /// We sent a `Range:` header to resume a partial download
            /// but the server replied 200 (full body) instead of 206.
            /// The caller's writer now contains a prefix from a prior
            /// attempt followed by a fresh full body — corrupt. The
            /// caller (the pull orchestrator) is expected to truncate
            /// its sink and retry from offset 0.
            ResumeRangeRejected,
            /// All retries exhausted on transient errors.
            TooManyRetries,
        };

    /// `GET /v2/<repo>/blobs/<digest>` with bounded retries and
    /// `Range:`-based resume on partial-failure. Streams the body
    /// through `dest_writer`, hashing live. Verifies the final hash
    /// against `expected` and returns `error.DigestMismatch` on any
    /// disagreement.
    ///
    /// The token cache is reused across attempts and across concurrent
    /// callers (the cache's mutex serialises access). On transient
    /// failure (network read drop, 5xx) the function sleeps for
    /// `min(initial_backoff_ms << attempt, max_backoff_ms)` and reissues
    /// the request with `Range: bytes=<n>-`, where `n` is the number of
    /// bytes already streamed to `dest_writer`.
    pub fn getBlob(
        self: *Client,
        ref: image_ref.ImageRef,
        expected: Digest,
        dest_writer: *Io.Writer,
        opts: GetBlobOptions,
    ) GetBlobError!void {
        var dig_buf: [digest_mod.string_length]u8 = undefined;
        const dig_str = expected.toString(&dig_buf);
        const url = try buildBlobUrl(self.gpa, ref.registry, ref.repository, dig_str);
        defer self.gpa.free(url);
        const scope = try std.fmt.allocPrint(self.gpa, "repository:{s}:pull", .{ref.repository});
        defer self.gpa.free(scope);
        return self.getBlobByUrl(url, scope, expected, dest_writer, opts);
    }

    /// Lower-level entrypoint used by `getBlob` and by tests. `url` is
    /// the absolute blob URL; `scope` is the OCI auth scope passed to
    /// the token cache.
    pub fn getBlobByUrl(
        self: *Client,
        url: []const u8,
        scope: []const u8,
        expected: Digest,
        dest_writer: *Io.Writer,
        opts: GetBlobOptions,
    ) GetBlobError!void {
        var hasher = digest_mod.Hasher.init();
        var bytes_written: u64 = 0;

        // Pre-format the short digest once for the throughput-display
        // node name. Lives the whole call so HashCount can borrow it
        // across retries. Docker-style: 12 hex chars without the
        // "sha256:" prefix.
        var dig_buf: [digest_mod.string_length]u8 = undefined;
        const dig_str = expected.toString(&dig_buf);
        const dig_short = if (dig_str.len >= "sha256:".len + 12)
            dig_str["sha256:".len .. "sha256:".len + 12]
        else
            dig_str;

        // Throughput state shared across retries. Cumulative MB/s
        // averages over recovered bytes — close enough for a UI hint.
        var hc_started_ns: i96 = 0;
        var hc_chunk_count: u32 = 0;
        var hc_name_buf: [64]u8 = undefined;

        var attempt: u32 = 0;
        retry: while (true) : (attempt += 1) {
            // Build the optional Range header for the second attempt
            // onwards. Stack-only: the buffer outlives the fetch call.
            var range_value_buf: [64]u8 = undefined;
            var headers_buf: [1]http.Header = undefined;
            var headers: []const http.Header = &.{};
            const sent_range = bytes_written > 0;
            if (sent_range) {
                const range_value = std.fmt.bufPrint(
                    &range_value_buf,
                    "bytes={d}-",
                    .{bytes_written},
                ) catch unreachable;
                headers_buf[0] = .{ .name = "range", .value = range_value };
                headers = headers_buf[0..1];
            }

            // Hashing/counting forwarder. Buffered (16 KiB) because
            // the body reader expects a non-empty writable slice; we
            // explicitly `flush` after the fetch so `hasher` and
            // `bytes_written` reflect every byte streamed before we
            // act on either branch.
            const hc: HashCount = .{
                .hasher = &hasher,
                .bytes = &bytes_written,
                .progress_node = opts.progress_node,
                .digest_short = dig_short,
                .io = self.io,
                .started_ns = &hc_started_ns,
                .chunk_count = &hc_chunk_count,
                .name_buf = &hc_name_buf,
            };
            var sink_buf: [16 * 1024]u8 = undefined;
            var sink = std.Io.Writer.Hashed(HashCount).initHasher(
                dest_writer,
                hc,
                &sink_buf,
            );

            const prior_written = bytes_written;
            const fetch_result = self.fetch(.{
                .url = url,
                .scope = scope,
                .extra_headers = headers,
            }, &sink.writer);
            sink.writer.flush() catch {};
            const this_round_bytes = bytes_written - prior_written;

            if (fetch_result) |resp_const| {
                var resp = resp_const;
                defer resp.deinit(self.gpa);

                if (sent_range and resp.status == .ok) {
                    // Server ignored Range and re-sent the whole body
                    // on top of our already-written prefix. The sink
                    // is now corrupt; the caller has to truncate.
                    return error.ResumeRangeRejected;
                }
                if (!sent_range and resp.status == .partial_content) {
                    // We didn't ask for a partial; the server is
                    // misbehaving — surface as unexpected.
                    return error.UnexpectedStatus;
                }

                // `streamRemaining` swallows `EndOfStream` from the
                // underlying socket, so a server that announced
                // Content-Length but cut mid-stream returns "OK"
                // here with fewer bytes than promised. Treat that
                // as a transient ReadFailed so the retry loop kicks
                // in with a Range request from where we left off.
                if (resp.content_length) |cl| {
                    if (this_round_bytes < cl) {
                        if (attempt >= opts.max_retries) return error.TooManyRetries;
                        try self.sleepBackoff(attempt, opts);
                        continue :retry;
                    }
                }

                const got = hasher.final();
                if (!got.eql(expected)) return error.DigestMismatch;
                return;
            } else |err| switch (err) {
                error.ServerError, error.ReadFailed, error.WriteFailed => {
                    if (attempt >= opts.max_retries) return error.TooManyRetries;
                    try self.sleepBackoff(attempt, opts);
                    continue :retry;
                },
                else => return err,
            }
        }
    }

    fn sleepBackoff(self: *Client, attempt: u32, opts: GetBlobOptions) GetBlobError!void {
        const shift: u5 = @intCast(@min(attempt, 16));
        const raw_ms: u64 = @as(u64, opts.initial_backoff_ms) << shift;
        const ms: u64 = @min(raw_ms, opts.max_backoff_ms);
        Io.sleep(self.io, Io.Duration.fromMilliseconds(@intCast(ms)), .real) catch
            return error.TooManyRetries;
    }
};

/// Hasher adapter wired into `std.Io.Writer.Hashed` so the same drain
/// pass that updates the sha256 also bumps a byte counter the retry
/// loop reads to build the next `Range:` header.
const HashCount = struct {
    hasher: *digest_mod.Hasher,
    bytes: *u64,
    /// Optional `std.Progress` sink. Bumped lock-free on every
    /// drained chunk so callers see live byte progress without
    /// any extra writer plumbing.
    progress_node: ?std.Progress.Node = null,

    /// Pre-formatted "sha256:abc123…" prefix for the node-name
    /// throughput display. Empty disables the display.
    digest_short: []const u8 = "",
    /// `Io` instance used to read the monotonic clock. Null disables
    /// the throughput display (e.g. unit tests with no progress UI).
    io: ?Io = null,
    /// Monotonic-clock reading at the first non-empty chunk, in
    /// nanoseconds. Zero before then. Pointed at caller-frame
    /// storage so retries keep the same clock origin.
    started_ns: ?*i96 = null,
    /// Drain-call counter; we refresh the node name every 64 chunks
    /// to keep `setName` cost negligible.
    chunk_count: ?*u32 = null,
    /// Caller-owned scratch the formatted name is written into.
    /// `setName` copies into the Progress ring buffer, so this only
    /// needs to outlive the `setName` call.
    name_buf: ?[]u8 = null,

    /// Forwarder. `pub` because `std.Io.Writer.Hashed(HashCount)`
    /// reaches in via comptime to call this on every drained chunk.
    pub fn update(self: *HashCount, data: []const u8) void {
        self.hasher.update(data);
        self.bytes.* += data.len;
        const node = self.progress_node orelse return;
        node.setCompletedItems(self.bytes.*);

        const io = self.io orelse return;
        const started_ns = self.started_ns orelse return;
        const chunk_count = self.chunk_count orelse return;
        const name_buf = self.name_buf orelse return;
        if (self.digest_short.len == 0) return;

        if (started_ns.* == 0) {
            started_ns.* = Io.Clock.awake.now(io).toNanoseconds();
        }
        chunk_count.* +%= 1;
        if (chunk_count.* % 64 != 0) return;

        const now_ns = Io.Clock.awake.now(io).toNanoseconds();
        const elapsed_ns: i96 = now_ns - started_ns.*;
        if (elapsed_ns <= 0) return;
        const mbps = @as(f64, @floatFromInt(self.bytes.*)) * 1e9 /
            @as(f64, @floatFromInt(@as(i128, elapsed_ns))) / (1024.0 * 1024.0);
        const txt = std.fmt.bufPrint(
            name_buf,
            "{s}: Downloading {d:.1} MB/s",
            .{ self.digest_short, mbps },
        ) catch return;
        node.setName(txt);
    }
};

fn buildBlobUrl(
    gpa: Allocator,
    registry_name: []const u8,
    repository: []const u8,
    digest_str: []const u8,
) Allocator.Error![]u8 {
    const ep = manifest_mod.registryEndpoint(registry_name);
    return std.fmt.allocPrint(
        gpa,
        "https://{s}/v2/{s}/blobs/{s}",
        .{ ep, repository, digest_str },
    );
}

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
