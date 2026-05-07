//! Integration tests for `Client` against an in-process `MockServer`.
//!
//! Test-only sibling to `client.zig` — production `client.zig` does
//! not import this file. The mock server scripts a fixed sequence of
//! request/response steps so we can exercise the auth dance, redirect
//! handling, manifest dispatch, blob streaming, range-resume, and
//! retry/backoff paths without hitting a real registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const testing = std.testing;

// Routed through the `rind` named module so client_test.zig owns no
// `../` imports that would escape its own module path. The named
// module is itself rooted at src/root.zig, so all transitive
// `../`-style imports inside `registry/client.zig` and friends
// remain within bounds.
const rind = @import("rind");
const auth = rind.Registry.auth;
const manifest_mod = rind.Registry.manifest;
const digest_mod = rind.Image.digest;

const client_mod = rind.Registry.client;
const Client = client_mod.Client;
const Provider = client_mod.Provider;
const Digest = client_mod.Digest;

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
    /// `bytes=<N>-`. Used by the resume tests.
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
    /// before responding. Used by the pool-concurrency test to keep
    /// multiple requests "in flight" simultaneously.
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
    return startMockServerAt(io, .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 }, steps);
}

fn startMockServerAt(
    io: Io,
    ip4: std.Io.net.Ip4Address,
    steps: []const ScriptStep,
) !*MockServer {
    const gpa = testing.allocator;
    const ms = try gpa.create(MockServer);
    errdefer gpa.destroy(ms);

    var addr: std.Io.net.IpAddress = .{ .ip4 = ip4 };
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

test "fetch — cross-domain redirect strips Authorization (Docker Hub CDN gotcha)" {
    const gpa = testing.allocator;
    const io = testing.io;

    // Server A on 127.0.0.1: serves the bearer challenge + redirect.
    // Server B on 127.0.0.2: receives the followed redirect; must
    // NOT see Authorization (else AWS S3 returns 400 — see sendOnce
    // for the rationale).
    var msa = try startMockServerAt(io, .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 }, &.{});
    defer stopMockServer(msa);
    var msb = try startMockServerAt(io, .{ .bytes = .{ 127, 0, 0, 2 }, .port = 0 }, &.{});
    defer stopMockServer(msb);

    const port_a = msa.server.socket.address.getPort();
    const port_b = msb.server.socket.address.getPort();

    const challenge_value = try std.fmt.allocPrint(
        gpa,
        "Bearer realm=\"http://127.0.0.1:{d}/token\",service=\"rind-test\",scope=\"repository:test:pull\"",
        .{port_a},
    );
    defer gpa.free(challenge_value);
    const challenge_headers = [_]http.Header{
        .{ .name = "www-authenticate", .value = challenge_value },
    };

    const redirect_target = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.2:{d}/cdn/blob",
        .{port_b},
    );
    defer gpa.free(redirect_target);
    const redirect_headers = [_]http.Header{
        .{ .name = "location", .value = redirect_target },
    };

    msa.steps = &.{
        .{
            .path_contains = "/v2/test/blobs/",
            .head_not_contains = "authorization:",
            .status = .unauthorized,
            .extra_headers = &challenge_headers,
        },
        .{
            .path_contains = "/token?service=rind-test",
            .status = .ok,
            .body = "{\"token\":\"deadbeef\"}",
        },
        .{
            .path_contains = "/v2/test/blobs/",
            .head_contains = "Bearer deadbeef",
            .status = .temporary_redirect,
            .extra_headers = &redirect_headers,
        },
    };

    msb.steps = &.{
        .{
            .path_contains = "/cdn/blob",
            .head_not_contains = "authorization:",
            .status = .ok,
            .body = "blob-bytes",
        },
    };

    const ta = try std.Thread.spawn(.{}, MockServer.run, .{msa});
    const tb = try std.Thread.spawn(.{}, MockServer.run, .{msb});

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/blobs/sha256:abc", .{port_a});
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

    ta.join();
    tb.join();
    if (msa.err) |e| return e;
    if (msb.err) |e| return e;

    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings("blob-bytes", body_buf.written());
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
