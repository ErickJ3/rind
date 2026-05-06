//! Concurrent layer-extraction worker pool.
//!
//! Two execution modes share the same `Pool` type:
//!
//!   * Per-batch (`runAll`) — the original blob-pool-style contract.
//!     Spawns N
//!     worker threads that drain a fixed `[]ExtractJob` slice via a
//!     mutex-guarded LIFO, joins on the way out. Used by tests and
//!     by callers that have all jobs up front.
//!
//!   * Persistent (`start` + `submit` + `closeAndJoin`) — workers
//!     wait on a queue protected by `Io.Mutex` + `Io.Condition`, so
//!     `pull.zig` can submit extract jobs from the blob-completion
//!     callback as each layer's bytes land. Lets extracts overlap
//!     with the still-running download pool.
//!
//! Layers extract into independent `<store>/extracted/<hex>/`
//! directories, so concurrent workers do not contend on the same
//! paths.
//!
//! The pool is generic over the actual extract function — pull.zig
//! injects `extractIfMissing` at `init` time. Keeping the function
//! pointer at the pool (not per-job) avoids a circular import:
//! `pull.zig` imports this module; this module never imports
//! `pull.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const layout = @import("../store/layout.zig");
const digest_mod = @import("digest.zig");

pub const Digest = digest_mod.Digest;

/// Worker callable. `pull.zig` plugs in its `extractIfMissing` here.
/// Returns `anyerror!void` so the pool stays decoupled from
/// `pull.PullError`'s exact union shape.
pub const ExtractFn = *const fn (
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    digest: Digest,
    media_type: []const u8,
) anyerror!void;

/// One layer to extract. Caller owns `media_type`; pool fills `result`.
pub const ExtractJob = struct {
    digest: Digest,
    media_type: []const u8,
    /// Worker writes the extract function's result here.
    result: anyerror!void = {},
    /// Worker-thread completion hook. Invoked once the extract
    /// function returns (success or error). Caller is responsible
    /// for synchronising any shared state the callback touches.
    on_complete: ?*const fn (ctx: ?*anyopaque, job: *ExtractJob) void = null,
    complete_ctx: ?*anyopaque = null,
};

/// Concurrent extract pool. Supports both per-batch (`runAll`) and
/// persistent (`start` / `submit` / `closeAndJoin`) modes — see the
/// module doc-comment for when to use each.
pub const Pool = struct {
    gpa: Allocator,
    io: Io,
    store: *layout.Store,
    concurrency: usize,
    extract_fn: ExtractFn,
    inflight: std.atomic.Value(usize),
    peak_inflight: std.atomic.Value(usize),
    /// LIFO queue of pending extract jobs. Order does not matter
    /// because layers extract into independent directories.
    queue: std.ArrayListUnmanaged(*ExtractJob) = .empty,
    /// Guards `queue` and `closed`.
    mu: Io.Mutex = .init,
    /// Signaled by `submit` (one waiter) and `closeAndJoin`
    /// (broadcast). Workers re-check the predicate after each wake.
    cond_nonempty: Io.Condition = .init,
    /// Set by `closeAndJoin`; once true, workers exit when the queue
    /// drains.
    closed: bool = false,
    /// Worker thread handles owned by the pool while persistent mode
    /// is active. Empty at all other times.
    threads: []std.Thread = &.{},

    pub fn init(
        gpa: Allocator,
        io: Io,
        store: *layout.Store,
        concurrency: usize,
        extract_fn: ExtractFn,
    ) Pool {
        return .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .concurrency = if (concurrency == 0) 1 else concurrency,
            .extract_fn = extract_fn,
            .inflight = .init(0),
            .peak_inflight = .init(0),
        };
    }

    pub fn deinit(self: *Pool) void {
        std.debug.assert(self.threads.len == 0);
        self.* = undefined;
    }

    /// Default parallel-extract cap: `min(cpus, 8)`. Extract is
    /// CPU-bound (zlib-ng decompress + tar walk), so the cap matches
    /// the host core count up to 8 — past that point a registry's
    /// blob delivery becomes the bottleneck instead.
    pub fn defaultExtractJobs() usize {
        const cpus = std.Thread.getCpuCount() catch return 4;
        return @min(cpus, 8);
    }

    /// Legacy alias for `defaultExtractJobs`. Kept for callers that
    /// haven't migrated yet.
    pub fn defaultConcurrency() usize {
        return defaultExtractJobs();
    }

    pub fn peakInflight(self: *const Pool) usize {
        return self.peak_inflight.load(.acquire);
    }

    /// Persistent mode: spawn `concurrency` workers that wait on the
    /// internal queue. Pair with `submit` calls and one terminating
    /// `closeAndJoin`.
    pub fn start(self: *Pool) (Allocator.Error || std.Thread.SpawnError)!void {
        std.debug.assert(self.threads.len == 0);
        self.inflight.store(0, .release);
        self.peak_inflight.store(0, .release);
        self.closed = false;
        self.queue = .empty;

        self.threads = try self.gpa.alloc(std.Thread, self.concurrency);
        var spawned: usize = 0;
        errdefer {
            // Drain anyone already waiting and join them before we bail.
            self.mu.lockUncancelable(self.io);
            self.closed = true;
            self.cond_nonempty.broadcast(self.io);
            self.mu.unlock(self.io);
            for (self.threads[0..spawned]) |t| t.join();
            self.queue.deinit(self.gpa);
            self.gpa.free(self.threads);
            self.threads = &.{};
        }
        while (spawned < self.concurrency) : (spawned += 1) {
            self.threads[spawned] = try std.Thread.spawn(.{}, persistentWorker, .{self});
        }
    }

    /// Persistent mode: enqueue one job. Threadsafe — workers and
    /// other submitters serialise on `mu`.
    pub fn submit(self: *Pool, job: *ExtractJob) Allocator.Error!void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.queue.append(self.gpa, job);
        self.cond_nonempty.signal(self.io);
    }

    /// Persistent mode: signal "no more submissions" then wait for
    /// every queued job to finish. Safe to call exactly once per
    /// `start`.
    pub fn closeAndJoin(self: *Pool) void {
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.closed = true;
            self.cond_nonempty.broadcast(self.io);
        }
        for (self.threads) |t| t.join();
        self.queue.deinit(self.gpa);
        self.gpa.free(self.threads);
        self.threads = &.{};
    }

    fn persistentWorker(self: *Pool) void {
        while (true) {
            self.mu.lockUncancelable(self.io);
            while (self.queue.items.len == 0 and !self.closed) {
                self.cond_nonempty.waitUncancelable(self.io, &self.mu);
            }
            if (self.queue.items.len == 0 and self.closed) {
                self.mu.unlock(self.io);
                return;
            }
            // LIFO pop; layer order does not matter for extract.
            const job = self.queue.pop().?;
            self.mu.unlock(self.io);

            const cur = self.inflight.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak_inflight.fetchMax(cur, .acq_rel);

            job.result = self.extract_fn(
                self.io,
                self.gpa,
                self.store,
                job.digest,
                job.media_type,
            );
            if (job.on_complete) |cb| cb(job.complete_ctx, job);

            _ = self.inflight.fetchSub(1, .acq_rel);
        }
    }

    /// Per-batch mode: enqueue every job, then drain. Composes
    /// `start` + `submit` + `closeAndJoin` so callers that already
    /// have the full job slice keep their original control flow.
    pub fn runAll(self: *Pool, jobs: []ExtractJob) (Allocator.Error || std.Thread.SpawnError)!void {
        if (jobs.len == 0) return;
        try self.start();
        // start() succeeded — workers are alive; we own the cleanup.
        for (jobs) |*j| {
            self.submit(j) catch |e| {
                self.closeAndJoin();
                return e;
            };
        }
        self.closeAndJoin();
    }
};

const testing = std.testing;

test "Pool.defaultConcurrency clamped sensibly" {
    const c = Pool.defaultConcurrency();
    try testing.expect(c >= 1);
    try testing.expect(c <= 8);
}

test "Pool.runAll noop on empty job slice" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    var pool = Pool.init(gpa, io, &store, 2, stubExtract);
    defer pool.deinit();

    var jobs: [0]ExtractJob = .{};
    try pool.runAll(jobs[0..]);
    try testing.expectEqual(@as(usize, 0), pool.peakInflight());
}

fn stubExtract(_: Io, _: Allocator, _: *layout.Store, _: Digest, _: []const u8) anyerror!void {
    return;
}

test "Pool.runAll fans out jobs and fires on_complete on worker thread" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    var completed: std.atomic.Value(usize) = .init(0);

    const Cb = struct {
        fn onComplete(ctx: ?*anyopaque, _: *ExtractJob) void {
            const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx.?));
            _ = counter.fetchAdd(1, .acq_rel);
        }
    };

    var d: Digest = undefined;
    @memset(&d.bytes, 0xcc);

    var jobs: [3]ExtractJob = undefined;
    for (&jobs) |*j| {
        j.* = .{
            .digest = d,
            .media_type = "application/vnd.oci.image.layer.v1.tar+gzip",
            .on_complete = Cb.onComplete,
            .complete_ctx = @ptrCast(&completed),
        };
    }

    var pool = Pool.init(gpa, io, &store, 2, stubExtract);
    defer pool.deinit();
    try pool.runAll(jobs[0..]);

    try testing.expectEqual(@as(usize, 3), completed.load(.acquire));
    for (jobs) |j| try j.result;
}
