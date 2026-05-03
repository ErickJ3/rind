//! T06 — concurrent blob downloader.
//!
//! Wraps a single `registry.Client` with a small worker pool so a
//! caller can fetch N layers in parallel while sharing the underlying
//! HTTP connection pool and bearer-token cache. The pool itself is
//! per-batch: `runAll` spawns `min(concurrency, jobs.len)` threads,
//! drains the job slice via an atomic counter, and joins. There are
//! no long-lived workers between calls — `init` only stores
//! configuration.
//!
//! Zig 0.16.0 does not ship `std.Thread.Pool`; this module fills
//! that gap with the minimal shape T06 needs and nothing more.
//!
//! `BlobJob` carries a pre-built absolute URL + auth scope rather
//! than an `ImageRef`. T09 (or the test) is responsible for URL
//! construction; the pool's only job is concurrency + result
//! accounting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const client_mod = @import("client.zig");
const digest_mod = @import("../image/digest.zig");

/// Re-export so callers don't double-import.
pub const Client = client_mod.Client;
/// Re-export of the per-blob options.
pub const GetBlobOptions = Client.GetBlobOptions;
/// Re-export of the per-blob error set.
pub const GetBlobError = Client.GetBlobError;
/// Re-export of the digest type.
pub const Digest = digest_mod.Digest;

/// One blob to fetch. The caller owns `url`, `scope`, and `writer`;
/// the pool fills `result` as the job completes.
pub const BlobJob = struct {
    /// Absolute blob URL, e.g. `https://reg/v2/repo/blobs/sha256:...`.
    url: []const u8,
    /// OCI auth scope, e.g. `repository:library/alpine:pull`.
    scope: []const u8,
    /// Expected sha256 of the blob.
    digest: Digest,
    /// Sink the streamed body is written to. Must be safe for the
    /// worker thread to use exclusively for the duration of the job.
    writer: *Io.Writer,
    /// Per-job retry/backoff knobs.
    opts: GetBlobOptions = .{},
    /// Set by the worker on completion. `{}` on success, otherwise
    /// the typed error returned by `Client.getBlobByUrl`.
    result: GetBlobError!void = {},
    /// Worker-thread completion hook. Invoked once `getBlobByUrl`
    /// returns (success or error), with `result` already populated.
    /// The callback runs on the worker thread, so any shared state
    /// it touches must be synchronized by the caller.
    on_complete: ?*const fn (ctx: ?*anyopaque, job: *BlobJob) void = null,
    /// Opaque pointer forwarded to `on_complete`.
    complete_ctx: ?*anyopaque = null,
};

/// Concurrent blob-download pool over a shared `*Client`.
pub const Pool = struct {
    /// Allocator used for per-batch thread-handle storage.
    gpa: Allocator,
    /// `Io` instance forwarded into spawned threads.
    io: Io,
    /// Borrowed client — the pool does NOT own it. Must outlive the
    /// pool and any in-flight `runAll` call.
    client: *Client,
    /// Maximum number of jobs in flight at once. Clamped to `>= 1`
    /// at construction time.
    concurrency: usize,
    /// Atomic cursor into the current `runAll` job slice.
    next_idx: std.atomic.Value(usize),
    /// Live count of jobs whose worker is currently inside
    /// `getBlobByUrl`.
    inflight: std.atomic.Value(usize),
    /// Maximum value `inflight` reached during the last `runAll`.
    /// Tests use this to assert the concurrency cap.
    peak_inflight: std.atomic.Value(usize),

    /// Construct a pool. `concurrency` is clamped to at least 1.
    pub fn init(gpa: Allocator, io: Io, client: *Client, concurrency: usize) Pool {
        return .{
            .gpa = gpa,
            .io = io,
            .client = client,
            .concurrency = if (concurrency == 0) 1 else concurrency,
            .next_idx = .init(0),
            .inflight = .init(0),
            .peak_inflight = .init(0),
        };
    }

    /// No long-lived state to release; provided for symmetry.
    pub fn deinit(self: *Pool) void {
        self.* = undefined;
    }

    /// Default concurrency used by callers that don't specify one:
    /// `min(host_cpus, 8)`. Falls back to 4 if cpu count is
    /// unavailable. Cap raised to 8 (T-progress): blob fetches are
    /// I/O-bound, so extra workers fill TCP+TLS handshake stalls
    /// without burning CPU.
    pub fn defaultConcurrency() usize {
        const cpus = std.Thread.getCpuCount() catch return 4;
        return @min(cpus, 8);
    }

    /// Snapshot of the highest concurrent-inflight count seen during
    /// the most recent `runAll`.
    pub fn peakInflight(self: *const Pool) usize {
        return self.peak_inflight.load(.acquire);
    }

    /// Run every job to completion. Per-job errors are written into
    /// each job's `result` field; the function itself only returns
    /// `Allocator.Error` if the thread-handle slice cannot be
    /// allocated or `std.Thread.SpawnError` if a worker can't be
    /// spawned.
    pub fn runAll(self: *Pool, jobs: []BlobJob) (Allocator.Error || std.Thread.SpawnError)!void {
        self.next_idx.store(0, .release);
        self.inflight.store(0, .release);
        self.peak_inflight.store(0, .release);

        if (jobs.len == 0) return;

        const n_threads = @min(self.concurrency, jobs.len);
        const threads = try self.gpa.alloc(std.Thread, n_threads);
        defer self.gpa.free(threads);

        var spawned: usize = 0;
        errdefer {
            // If a spawn fails midway, drain the queue so already-
            // spawned workers can finish, then join them.
            self.next_idx.store(jobs.len, .release);
            for (threads[0..spawned]) |t| t.join();
        }

        while (spawned < n_threads) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, worker, .{ self, jobs });
        }

        for (threads) |t| t.join();
    }

    fn worker(self: *Pool, jobs: []BlobJob) void {
        while (true) {
            const idx = self.next_idx.fetchAdd(1, .acq_rel);
            if (idx >= jobs.len) return;

            const cur = self.inflight.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak_inflight.fetchMax(cur, .acq_rel);

            jobs[idx].result = self.client.getBlobByUrl(
                jobs[idx].url,
                jobs[idx].scope,
                jobs[idx].digest,
                jobs[idx].writer,
                jobs[idx].opts,
            );

            if (jobs[idx].on_complete) |cb| cb(jobs[idx].complete_ctx, &jobs[idx]);

            _ = self.inflight.fetchSub(1, .acq_rel);
        }
    }
};

const testing = std.testing;
const http = std.http;
const Provider = client_mod.Provider;

/// Generate a deterministic blob.
fn buildTestBlob(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @intCast(((i *% 2654435761) ^ (i >> 3)) & 0xff);
}

/// Concurrent mock server: spawns one handler thread per accepted
/// connection so multiple blob requests can be in flight at once.
const ConcurrentMockServer = struct {
    server: std.Io.net.Server,
    io: Io,
    body: []const u8,
    sleep_ms: u32,
    /// Total number of requests served.
    served: std.atomic.Value(usize) = .init(0),
    /// Set if any handler errors. Read after stop.
    err: ?anyerror = null,
    err_mu: Io.Mutex = .init,
    /// Handler thread handles.
    threads: std.ArrayList(std.Thread) = .empty,
    /// Pre-allocated capacity for `threads`; also the number of
    /// connections the listener will accept before returning.
    expected: usize,

    fn run(self: *ConcurrentMockServer) void {
        var i: usize = 0;
        while (i < self.expected) : (i += 1) {
            var stream = self.server.accept(self.io) catch |e| {
                self.recordErr(e);
                return;
            };
            const t = std.Thread.spawn(.{}, handle, .{ self, stream }) catch |e| {
                stream.close(self.io);
                self.recordErr(e);
                return;
            };
            self.threads.append(testing.allocator, t) catch |e| {
                t.detach();
                self.recordErr(e);
                return;
            };
        }
    }

    fn handle(self: *ConcurrentMockServer, stream_in: std.Io.net.Stream) void {
        var stream = stream_in;
        defer stream.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buf);
        var stream_writer = stream.writer(self.io, &write_buf);

        var server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);
        var request = server.receiveHead() catch |e| {
            self.recordErr(e);
            return;
        };

        if (self.sleep_ms > 0) {
            Io.sleep(self.io, Io.Duration.fromMilliseconds(@intCast(self.sleep_ms)), .real) catch {};
        }

        request.respond(self.body, .{
            .status = .ok,
            .keep_alive = false,
        }) catch |e| {
            self.recordErr(e);
            return;
        };

        _ = self.served.fetchAdd(1, .acq_rel);
    }

    fn recordErr(self: *ConcurrentMockServer, e: anyerror) void {
        self.err_mu.lockUncancelable(self.io);
        defer self.err_mu.unlock(self.io);
        if (self.err == null) self.err = e;
    }
};

test "Pool — concurrency cap respected with overlapping jobs" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [256]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const expected = digest_mod.Hasher.hash(&blob_bytes);

    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    var ms = ConcurrentMockServer{
        .server = server,
        .io = io,
        .body = &blob_bytes,
        .sleep_ms = 25,
        .expected = 5,
    };
    try ms.threads.ensureTotalCapacity(testing.allocator, ms.expected);
    defer {
        for (ms.threads.items) |t| t.join();
        ms.threads.deinit(testing.allocator);
        ms.server.deinit(io);
    }

    const port = ms.server.socket.address.getPort();
    const listener = try std.Thread.spawn(.{}, ConcurrentMockServer.run, .{&ms});

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = expected.toString(&dig_buf);
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/blobs/{s}", .{ port, dig_str });
    defer gpa.free(url);

    var sinks: [5]std.Io.Writer.Allocating = undefined;
    for (&sinks) |*s| s.* = .init(gpa);
    defer for (&sinks) |*s| s.deinit();

    var jobs: [5]BlobJob = undefined;
    for (&jobs, 0..) |*j, i| {
        j.* = .{
            .url = url,
            .scope = "repository:test:pull",
            .digest = expected,
            .writer = &sinks[i].writer,
            .opts = .{ .max_retries = 0 },
        };
    }

    var pool = Pool.init(gpa, io, &client, 2);
    defer pool.deinit();

    try pool.runAll(jobs[0..]);

    listener.join();
    if (ms.err) |e| return e;

    for (jobs) |j| try j.result;
    for (&sinks) |*s| try testing.expectEqualSlices(u8, &blob_bytes, s.written());

    const peak_seen = pool.peakInflight();
    try testing.expect(peak_seen <= 2);
    try testing.expect(peak_seen >= 2);
}

test "Pool — runAll drains jobs and surfaces per-job results" {
    const gpa = testing.allocator;
    const io = testing.io;

    var blob_bytes: [128]u8 = undefined;
    buildTestBlob(&blob_bytes);
    const good = digest_mod.Hasher.hash(&blob_bytes);
    const wrong = try Digest.parse("sha256:0000000000000000000000000000000000000000000000000000000000000000");

    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    var ms = ConcurrentMockServer{
        .server = server,
        .io = io,
        .body = &blob_bytes,
        .sleep_ms = 0,
        .expected = 4,
    };
    try ms.threads.ensureTotalCapacity(testing.allocator, ms.expected);
    defer {
        for (ms.threads.items) |t| t.join();
        ms.threads.deinit(testing.allocator);
        ms.server.deinit(io);
    }

    const port = ms.server.socket.address.getPort();
    const listener = try std.Thread.spawn(.{}, ConcurrentMockServer.run, .{&ms});

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = good.toString(&dig_buf);
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v2/test/blobs/{s}", .{ port, dig_str });
    defer gpa.free(url);

    var sinks: [4]std.Io.Writer.Allocating = undefined;
    for (&sinks) |*s| s.* = .init(gpa);
    defer for (&sinks) |*s| s.deinit();

    // Three good, one with the wrong expected digest -> DigestMismatch.
    const expected_per_job = [_]Digest{ good, good, good, wrong };
    var jobs: [4]BlobJob = undefined;
    for (&jobs, 0..) |*j, i| {
        j.* = .{
            .url = url,
            .scope = "repository:test:pull",
            .digest = expected_per_job[i],
            .writer = &sinks[i].writer,
            .opts = .{ .max_retries = 0 },
        };
    }

    var pool = Pool.init(gpa, io, &client, 3);
    defer pool.deinit();

    try pool.runAll(jobs[0..]);

    listener.join();
    if (ms.err) |e| return e;

    try jobs[0].result;
    try jobs[1].result;
    try jobs[2].result;
    try testing.expectError(error.DigestMismatch, jobs[3].result);
}

test "Pool.defaultConcurrency clamped sensibly" {
    const c = Pool.defaultConcurrency();
    try testing.expect(c >= 1);
    try testing.expect(c <= 8);
}

test "Pool.runAll noop on empty job slice" {
    const gpa = testing.allocator;
    const io = testing.io;
    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = Client.init(gpa, io, &http_client, Provider.anonymous);
    defer client.deinit();

    var pool = Pool.init(gpa, io, &client, 2);
    defer pool.deinit();

    var jobs: [0]BlobJob = .{};
    try pool.runAll(jobs[0..]);
    try testing.expectEqual(@as(usize, 0), pool.peakInflight());
}
