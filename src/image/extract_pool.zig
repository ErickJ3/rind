//! Concurrent layer-extraction worker pool.
//!
//! Mirrors `registry/blob_pool.zig`: per-batch worker pool with an
//! atomic cursor over a job slice, no long-lived workers between
//! calls. Layers extract into independent `<store>/extracted/<hex>/`
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

/// Concurrent extract pool. No long-lived state between `runAll`
/// invocations; `init` only stores configuration.
pub const Pool = struct {
    gpa: Allocator,
    io: Io,
    store: *layout.Store,
    concurrency: usize,
    extract_fn: ExtractFn,
    next_idx: std.atomic.Value(usize),
    inflight: std.atomic.Value(usize),
    peak_inflight: std.atomic.Value(usize),

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
            .next_idx = .init(0),
            .inflight = .init(0),
            .peak_inflight = .init(0),
        };
    }

    pub fn deinit(self: *Pool) void {
        self.* = undefined;
    }

    /// Default concurrency: `min(host_cpus, 4)`. Falls back to 4 if
    /// cpu count is unavailable. Same heuristic as `blob_pool` so a
    /// shared `--concurrency` knob means the same thing for both
    /// phases.
    pub fn defaultConcurrency() usize {
        const cpus = std.Thread.getCpuCount() catch return 4;
        return @min(cpus, 4);
    }

    pub fn peakInflight(self: *const Pool) usize {
        return self.peak_inflight.load(.acquire);
    }

    pub fn runAll(self: *Pool, jobs: []ExtractJob) (Allocator.Error || std.Thread.SpawnError)!void {
        self.next_idx.store(0, .release);
        self.inflight.store(0, .release);
        self.peak_inflight.store(0, .release);

        if (jobs.len == 0) return;

        const n_threads = @min(self.concurrency, jobs.len);
        const threads = try self.gpa.alloc(std.Thread, n_threads);
        defer self.gpa.free(threads);

        var spawned: usize = 0;
        errdefer {
            self.next_idx.store(jobs.len, .release);
            for (threads[0..spawned]) |t| t.join();
        }

        while (spawned < n_threads) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, worker, .{ self, jobs });
        }

        for (threads) |t| t.join();
    }

    fn worker(self: *Pool, jobs: []ExtractJob) void {
        while (true) {
            const idx = self.next_idx.fetchAdd(1, .acq_rel);
            if (idx >= jobs.len) return;

            const cur = self.inflight.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak_inflight.fetchMax(cur, .acq_rel);

            jobs[idx].result = self.extract_fn(
                self.io,
                self.gpa,
                self.store,
                jobs[idx].digest,
                jobs[idx].media_type,
            );

            if (jobs[idx].on_complete) |cb| cb(jobs[idx].complete_ctx, &jobs[idx]);

            _ = self.inflight.fetchSub(1, .acq_rel);
        }
    }
};

const testing = std.testing;

test "Pool.defaultConcurrency clamped sensibly" {
    const c = Pool.defaultConcurrency();
    try testing.expect(c >= 1);
    try testing.expect(c <= 4);
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
