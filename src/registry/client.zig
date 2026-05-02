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
const manifest_mod = @import("manifest.zig");
const image_ref = @import("../image/ref.zig");
const digest_mod = @import("../image/digest.zig");

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
    /// 5xx response from the registry. T06 retries on this with
    /// bounded backoff; other callers may treat it as terminal.
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
            var refetch = try self.sendOnce(.{
                .method = req.method,
                .uri = uri,
                .accept = req.accept,
                .extra_headers = req.extra_headers,
                .auth_header = retry_auth_header,
            }, body_writer);
            defer refetch.deinit(self.gpa);
            return classify(&refetch);
        }

        return classify(&send_mut);
    }

    fn classify(send: *SendResult) FetchError!Response {
        switch (send.status) {
            .unauthorized => return error.Unauthorized,
            .forbidden => return error.Forbidden,
            .not_found => return error.NotFound,
            else => {},
        }
        if (@intFromEnum(send.status) >= 500) return error.ServerError;
        if (@intFromEnum(send.status) >= 400) return error.UnexpectedStatus;

        // Move ownership of content_type out of the SendResult so the
        // deferred `deinit` does not double-free what now belongs to
        // the returned `Response`.
        const ct = send.content_type;
        send.content_type = null;

        return .{
            .status = send.status,
            .content_type = ct,
            .content_length = send.content_length,
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
                if (std.ascii.eqlIgnoreCase(hdr.name, "www-authenticate")) {
                    result.www_authenticate = try self.gpa.dupe(u8, hdr.value);
                    break;
                }
            }
        }

        var transfer_buf: [16 * 1024]u8 = undefined;
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
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        var arena_owned: bool = true;
        errdefer if (arena_owned) arena.deinit();
        const arena_alloc = arena.allocator();

        const url = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ base_url, reference });
        defer self.gpa.free(url);

        var body_buf: Io.Writer.Allocating = .init(arena_alloc);
        var resp = try self.fetch(.{
            .url = url,
            .accept = manifest_mod.accept_header_value,
            .scope = scope,
        }, &body_buf.writer);
        defer resp.deinit(self.gpa);

        const ct = resp.content_type orelse return error.UnsupportedMediaType;
        const mt = manifest_mod.MediaType.fromString(ct) orelse return error.UnsupportedMediaType;

        const raw_bytes = try body_buf.toOwnedSlice();

        const computed = digest_mod.Hasher.hash(raw_bytes);
        if (expected_digest) |exp| {
            if (!computed.eql(exp)) return error.DigestMismatch;
        }

        if (mt.isSingle()) {
            const m = try manifest_mod.parseManifest(arena_alloc, raw_bytes, mt);
            arena_owned = false;
            return .{
                .manifest = m,
                .digest = computed,
                .media_type = mt,
                .raw_bytes = raw_bytes,
                .arena = arena,
            };
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
        return self.getManifestByUrl(base_url, picked_ref_dup, scope, picked_dig, opts);
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
            /// caller (T09) is expected to truncate its sink and retry
            /// from offset 0.
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
            const hc: HashCount = .{ .hasher = &hasher, .bytes = &bytes_written };
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

    /// Forwarder. `pub` because `std.Io.Writer.Hashed(HashCount)`
    /// reaches in via comptime to call this on every drained chunk.
    pub fn update(self: *HashCount, data: []const u8) void {
        self.hasher.update(data);
        self.bytes.* += data.len;
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
    /// Optional Range-header assertion: the request head must contain
    /// `bytes=<N>-`. Used by T06 resume tests.
    head_must_contain_range_start: ?u64 = null,
    status: http.Status = .ok,
    /// Extra headers to send back. Lifetimes managed by the test.
    extra_headers: []const http.Header = &.{},
    body: []const u8 = "",
    /// If set, the response is hand-written: status line + headers +
    /// `body[0..truncate_at_bytes]`, then the connection is closed
    /// without sending the rest. Combined with
    /// `content_length_override` this simulates a server that drops
    /// mid-stream while claiming a longer body.
    truncate_at_bytes: ?usize = null,
    /// Optional override for the `content-length` header. When unset,
    /// the actual `body.len` is sent. Only meaningful in conjunction
    /// with `truncate_at_bytes` or the digest-mismatch tests.
    content_length_override: ?u64 = null,
    /// Sleep this many milliseconds after parsing the request and
    /// before responding. Used by T06's pool-concurrency test to
    /// keep multiple requests "in flight" simultaneously.
    before_respond_sleep_ms: u32 = 0,
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
        if (step.head_must_contain_range_start) |start| {
            var range_buf: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&range_buf, "bytes={d}-", .{start}) catch
                return error.MissingRangeHeader;
            if (std.mem.indexOf(u8, request.head_buffer, needle) == null) {
                return error.MissingRangeHeader;
            }
        }

        if (step.before_respond_sleep_ms > 0) {
            Io.sleep(
                self.io,
                Io.Duration.fromMilliseconds(@intCast(step.before_respond_sleep_ms)),
                .real,
            ) catch return error.SleepInterrupted;
        }

        if (step.truncate_at_bytes) |trunc| {
            const cl = step.content_length_override orelse step.body.len;
            const w = &stream_writer.interface;
            const phrase = step.status.phrase() orelse "";
            try w.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(step.status), phrase });
            try w.writeAll("connection: close\r\n");
            try w.print("content-length: {d}\r\n", .{cl});
            for (step.extra_headers) |h| {
                try w.print("{s}: {s}\r\n", .{ h.name, h.value });
            }
            try w.writeAll("\r\n");
            try w.writeAll(step.body[0..trunc]);
            w.flush() catch {};
            return;
        }

        if (step.content_length_override) |cl| {
            // Same hand-written path as truncate, but body is sent in
            // full. Used by the digest-mismatch tests that need a
            // misleading content-length without simulating a cut.
            const w = &stream_writer.interface;
            const phrase = step.status.phrase() orelse "";
            try w.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(step.status), phrase });
            try w.writeAll("connection: close\r\n");
            try w.print("content-length: {d}\r\n", .{cl});
            for (step.extra_headers) |h| {
                try w.print("{s}: {s}\r\n", .{ h.name, h.value });
            }
            try w.writeAll("\r\n");
            try w.writeAll(step.body);
            w.flush() catch {};
            return;
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

const test_oci_manifest_body =
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

const test_amd64_only_index_no_inner_dig =
    \\{
    \\  "schemaVersion": 2,
    \\  "mediaType": "application/vnd.oci.image.index.v1+json",
    \\  "manifests": [
    \\    { "mediaType": "application/vnd.oci.image.manifest.v1+json",
    \\      "digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
    \\      "size": 7000,
    \\      "platform": { "architecture": "s390x", "os": "linux" } }
    \\  ]
    \\}
;

test "getManifest — single OCI manifest direct" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();

    const ct_headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/vnd.oci.image.manifest.v1+json" },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .ok,
            .extra_headers = &ct_headers,
            .body = test_oci_manifest_body,
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests", .{port});
    defer gpa.free(base_url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var result = try client.getManifestByUrl(
        base_url,
        "latest",
        "repository:test:pull",
        null,
        .{},
    );
    defer result.deinit();

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqual(manifest_mod.MediaType.oci_manifest, result.media_type);
    try testing.expectEqual(@as(usize, 2), result.manifest.layers.len);
    try testing.expectEqualStrings(test_oci_manifest_body, result.raw_bytes);
    try testing.expect(result.digest.eql(digest_mod.Hasher.hash(test_oci_manifest_body)));
    try testing.expectEqual(@as(usize, 1), ms.requests_seen);
}

test "getManifest — index dispatches to picked platform manifest" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();

    // Compute digest of the inner manifest body so the index can
    // reference it with the real sha256 — letting `getManifestByUrl`
    // verify the body on recursion.
    const inner_dig = digest_mod.Hasher.hash(test_oci_manifest_body);
    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const inner_dig_str = inner_dig.toString(&dig_buf);

    const index_body = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schemaVersion": 2,
        \\  "mediaType": "application/vnd.oci.image.index.v1+json",
        \\  "manifests": [
        \\    {{ "mediaType": "application/vnd.oci.image.manifest.v1+json",
        \\       "digest": "{s}",
        \\       "size": {d},
        \\       "platform": {{ "architecture": "amd64", "os": "linux" }} }}
        \\  ]
        \\}}
    , .{ inner_dig_str, test_oci_manifest_body.len });
    defer gpa.free(index_body);

    const inner_path = try std.fmt.allocPrint(gpa, "/v2/test/manifests/{s}", .{inner_dig_str});
    defer gpa.free(inner_path);

    const ct_index = [_]http.Header{
        .{ .name = "content-type", .value = "application/vnd.oci.image.index.v1+json" },
    };
    const ct_manifest = [_]http.Header{
        .{ .name = "content-type", .value = "application/vnd.oci.image.manifest.v1+json" },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .ok,
            .extra_headers = &ct_index,
            .body = index_body,
        },
        .{
            .path_contains = inner_path,
            .status = .ok,
            .extra_headers = &ct_manifest,
            .body = test_oci_manifest_body,
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests", .{port});
    defer gpa.free(base_url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var result = try client.getManifestByUrl(
        base_url,
        "latest",
        "repository:test:pull",
        null,
        .{ .platform = .{ .architecture = "amd64", .os = "linux" } },
    );
    defer result.deinit();

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqual(manifest_mod.MediaType.oci_manifest, result.media_type);
    try testing.expectEqualStrings(test_oci_manifest_body, result.raw_bytes);
    try testing.expect(result.digest.eql(inner_dig));
    try testing.expectEqual(@as(usize, 2), ms.requests_seen);
}

test "getManifest — DigestMismatch when body hash diverges from expected" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();

    const ct_headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/vnd.oci.image.manifest.v1+json" },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/sha256:",
            .status = .ok,
            .extra_headers = &ct_headers,
            .body = test_oci_manifest_body,
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests", .{port});
    defer gpa.free(base_url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    // Wrong expected digest — server returns the OCI manifest body
    // but caller pinned to an unrelated sha256.
    const wrong = try Digest.parse("sha256:0000000000000000000000000000000000000000000000000000000000000000");

    try testing.expectError(error.DigestMismatch, client.getManifestByUrl(
        base_url,
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        "repository:test:pull",
        wrong,
        .{},
    ));

    thread.join();
    if (ms.err) |e| return e;
}

test "getManifest — PlatformNotFound when index has no matching platform" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();

    const ct_index = [_]http.Header{
        .{ .name = "content-type", .value = "application/vnd.oci.image.index.v1+json" },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .ok,
            .extra_headers = &ct_index,
            .body = test_amd64_only_index_no_inner_dig,
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests", .{port});
    defer gpa.free(base_url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    try testing.expectError(error.PlatformNotFound, client.getManifestByUrl(
        base_url,
        "latest",
        "repository:test:pull",
        null,
        // Index only has linux/s390x; ask for windows/ppc64 to
        // guarantee no host-arch match regardless of the build host.
        .{ .platform = .{ .architecture = "ppc64", .os = "windows" } },
    ));

    thread.join();
    if (ms.err) |e| return e;
}

test "getManifest — MediaTypeMismatch when body mediaType disagrees with header" {
    const gpa = testing.allocator;
    const io = testing.io;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);

    const port = ms.server.socket.address.getPort();

    // Header says OCI manifest; body's mediaType field says Docker.
    const mismatch_body =
        \\{
        \\  "schemaVersion": 2,
        \\  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
        \\  "config": {
        \\    "mediaType": "application/vnd.oci.image.config.v1+json",
        \\    "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
        \\    "size": 100
        \\  },
        \\  "layers": []
        \\}
    ;

    const ct_oci = [_]http.Header{
        .{ .name = "content-type", .value = "application/vnd.oci.image.manifest.v1+json" },
    };

    ms.steps = &.{
        .{
            .path_contains = "/v2/test/manifests/latest",
            .status = .ok,
            .extra_headers = &ct_oci,
            .body = mismatch_body,
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/manifests", .{port});
    defer gpa.free(base_url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    try testing.expectError(error.MediaTypeMismatch, client.getManifestByUrl(
        base_url,
        "latest",
        "repository:test:pull",
        null,
        .{},
    ));

    thread.join();
    if (ms.err) |e| return e;
}

// --- T06: blob GET tests --------------------------------------------------

/// Generate a deterministic, non-trivial test blob: 4096 bytes whose
/// content depends on the offset, so any truncation or substitution is
/// visible in the sha256.
fn buildTestBlob(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @intCast(((i *% 2654435761) ^ (i >> 3)) & 0xff);
}

test "getBlob — happy path streams body and verifies digest" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [4096]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const expected = digest_mod.Hasher.hash(&blob_bytes);
    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = expected.toString(&dig_buf);

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);
    const port = ms.server.socket.address.getPort();

    const path = try std.fmt.allocPrint(gpa, "/v2/test/blobs/{s}", .{dig_str});
    defer gpa.free(path);

    ms.steps = &.{
        .{ .path_contains = path, .status = .ok, .body = &blob_bytes },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();

    try client.getBlobByUrl(url, "repository:test:pull", expected, &sink.writer, .{});

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqualSlices(u8, &blob_bytes, sink.written());
}

test "getBlob — DigestMismatch on truncated body (honest content-length)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [4096]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const expected = digest_mod.Hasher.hash(&blob_bytes); // hash of FULL blob

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);
    const port = ms.server.socket.address.getPort();

    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = expected.toString(&dig_buf);
    const path = try std.fmt.allocPrint(gpa, "/v2/test/blobs/{s}", .{dig_str});
    defer gpa.free(path);

    // Server sends only first 2000 bytes, with content-length=2000
    // (no transport error), but the caller pinned to the full hash.
    ms.steps = &.{
        .{
            .path_contains = path,
            .status = .ok,
            .body = blob_bytes[0..2000],
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();

    try testing.expectError(
        error.DigestMismatch,
        client.getBlobByUrl(url, "repository:test:pull", expected, &sink.writer, .{
            .max_retries = 0,
        }),
    );

    thread.join();
    if (ms.err) |e| return e;
}

test "getBlob — DigestMismatch on tampered body (same length)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [4096]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const expected = digest_mod.Hasher.hash(&blob_bytes);

    // Mutate one byte to produce a different but same-length body.
    var tampered = blob_bytes;
    tampered[123] ^= 0xff;

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);
    const port = ms.server.socket.address.getPort();

    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = expected.toString(&dig_buf);
    const path = try std.fmt.allocPrint(gpa, "/v2/test/blobs/{s}", .{dig_str});
    defer gpa.free(path);

    ms.steps = &.{
        .{ .path_contains = path, .status = .ok, .body = &tampered },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();

    try testing.expectError(
        error.DigestMismatch,
        client.getBlobByUrl(url, "repository:test:pull", expected, &sink.writer, .{
            .max_retries = 0,
        }),
    );

    thread.join();
    if (ms.err) |e| return e;
}

test "getBlob — Range resume after mid-stream cut yields byte-identical blob" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [4096]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const expected = digest_mod.Hasher.hash(&blob_bytes);
    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = expected.toString(&dig_buf);

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);
    const port = ms.server.socket.address.getPort();

    const path = try std.fmt.allocPrint(gpa, "/v2/test/blobs/{s}", .{dig_str});
    defer gpa.free(path);

    const cut_at: usize = 1500;

    // Step 2 needs Content-Range: bytes=cut_at-(total-1)/total
    var range_hdr_buf: [64]u8 = undefined;
    const range_value = try std.fmt.bufPrint(
        &range_hdr_buf,
        "bytes={d}-{d}/{d}",
        .{ cut_at, blob_bytes.len - 1, blob_bytes.len },
    );
    const partial_headers = [_]http.Header{
        .{ .name = "content-range", .value = range_value },
    };

    ms.steps = &.{
        // Initial GET: lie about content-length, write only `cut_at`
        // bytes, then close. Client should surface ReadFailed and
        // retry with Range.
        .{
            .path_contains = path,
            .status = .ok,
            .body = &blob_bytes,
            .truncate_at_bytes = cut_at,
            .content_length_override = blob_bytes.len,
        },
        // Retry: must carry Range header. Reply 206 + tail bytes.
        .{
            .path_contains = path,
            .head_must_contain_range_start = cut_at,
            .status = .partial_content,
            .extra_headers = &partial_headers,
            .body = blob_bytes[cut_at..],
        },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();

    try client.getBlobByUrl(url, "repository:test:pull", expected, &sink.writer, .{
        .max_retries = 1,
        .initial_backoff_ms = 1,
    });

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqualSlices(u8, &blob_bytes, sink.written());
    try testing.expectEqual(@as(usize, 2), ms.requests_seen);
}

test "getBlob — backoff schedule honored on transient ServerError" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [256]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const expected = digest_mod.Hasher.hash(&blob_bytes);
    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = expected.toString(&dig_buf);

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);
    const port = ms.server.socket.address.getPort();

    const path = try std.fmt.allocPrint(gpa, "/v2/test/blobs/{s}", .{dig_str});
    defer gpa.free(path);

    ms.steps = &.{
        .{ .path_contains = path, .status = .service_unavailable },
        .{ .path_contains = path, .status = .service_unavailable },
        .{ .path_contains = path, .status = .ok, .body = &blob_bytes },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();

    const t0 = Io.Clock.awake.now(io);
    try client.getBlobByUrl(url, "repository:test:pull", expected, &sink.writer, .{
        .max_retries = 3,
        .initial_backoff_ms = 30,
        .max_backoff_ms = 1_000,
    });
    const elapsed_ms = t0.untilNow(io, .awake).toMilliseconds();

    thread.join();
    if (ms.err) |e| return e;

    // Two backoffs: 30ms + 60ms = 90ms. Allow generous slop.
    try testing.expect(elapsed_ms >= 80);
    try testing.expectEqualSlices(u8, &blob_bytes, sink.written());
    try testing.expectEqual(@as(usize, 3), ms.requests_seen);
}

test "getBlob — TooManyRetries when transient errors exhaust budget" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [64]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const expected = digest_mod.Hasher.hash(&blob_bytes);
    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = expected.toString(&dig_buf);

    var ms = try startMockServer(io, &.{});
    defer stopMockServer(ms);
    const port = ms.server.socket.address.getPort();

    const path = try std.fmt.allocPrint(gpa, "/v2/test/blobs/{s}", .{dig_str});
    defer gpa.free(path);

    ms.steps = &.{
        .{ .path_contains = path, .status = .service_unavailable },
        .{ .path_contains = path, .status = .service_unavailable },
        .{ .path_contains = path, .status = .service_unavailable },
    };

    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();

    try testing.expectError(
        error.TooManyRetries,
        client.getBlobByUrl(url, "repository:test:pull", expected, &sink.writer, .{
            .max_retries = 2,
            .initial_backoff_ms = 1,
        }),
    );

    thread.join();
    if (ms.err) |e| return e;

    try testing.expectEqual(@as(usize, 3), ms.requests_seen);
}
