//! Pull orchestrator (T09).
//!
//! `pullImage(ref_text, store, client, options) → PullResult` glues
//! T01 (ref parse), T05 (manifest GET), T06 (concurrent blob GET),
//! T03 (image-layout store), and T07/T08 (layer extraction) into a
//! single end-to-end image fetch.
//!
//! Steps, in order:
//!
//!   1. Parse `ref_text`.
//!   2. `Client.getManifest` → single-platform manifest (with index
//!      dispatch handled by T05).
//!   3. Persist the manifest blob into the store via `Store.putBlob`.
//!   4. Build a job table — config + each layer descriptor. Cached
//!      blobs are skipped (warm-cache fast path); the rest are fetched
//!      concurrently through `blob_pool.Pool`. Each job streams into a
//!      per-blob `Io.File.Atomic`, so a failed download leaves no file
//!      at the final blob path.
//!   5. After the pool joins, link the atomic temp files into place.
//!   6. Extract every layer, dispatching on its media type
//!      (`tar+gzip` → `extractGzip`, `tar+zstd` → `extractZstd`).
//!      Already-extracted dirs are left alone (idempotent warm cache).
//!   7. Tag `index.json` with the user-supplied reference text.
//!
//! Progress is reported through an optional callback. The callback
//! may fire from a pool worker thread (T18: blob_done events fire as
//! each download lands rather than being batched on the orchestrator
//! thread), so the caller must serialize against shared state — see
//! `cli/pull.zig`'s trampoline mutex. Live byte-level progress is
//! also surfaced through an optional `std.Progress.Node`; that path
//! is lock-free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const image_ref = @import("image/ref.zig");
const digest_mod = @import("image/digest.zig");
const extract = @import("image/extract.zig");
const layout = @import("store/layout.zig");
const client_mod = @import("registry/client.zig");
const manifest_mod = @import("registry/manifest.zig");
const blob_pool = @import("registry/blob_pool.zig");
const extract_pool = @import("image/extract_pool.zig");

/// Sha256 content digest. Re-exported so callers don't double-import.
pub const Digest = digest_mod.Digest;
/// Manifest media type variant. Re-exported for `PullEvent.manifest`.
pub const MediaType = manifest_mod.MediaType;

/// Distinguishes the image config blob from layer blobs in progress
/// events. The two are fetched the same way but consumers (T10's UI)
/// often render them differently.
pub const BlobKind = enum { config, layer };

/// Tagged union of orchestrator progress events. Emission order:
/// `pull_started` (once, immediately on entry, before any I/O so the
/// caller has something visible during the auth+manifest dance),
/// `manifest`, `blob_started` for every slot in slot order (config
/// first, then layers), `blob_done` for every cached slot in slot
/// order (these are decided up-front), then `blob_done` for each
/// non-cached slot as its worker thread finishes downloading +
/// linking the blob (T18: completion order, not slot order — may
/// interleave with `extracted`). `extracted` fires per layer as
/// each extract worker finishes (also out-of-order). `done` last.
pub const PullEvent = union(enum) {
    /// Pull invocation accepted; no I/O has happened yet. Lets
    /// renderers print "Pulling <ref>…" before the (potentially slow)
    /// auth + manifest fetch begins. `ref` borrows from the
    /// orchestrator's `ref_text` argument and is valid for the
    /// duration of the callback.
    pull_started: struct { ref: []const u8 },
    /// Manifest fetched and identified. `size` is the byte length of
    /// the verbatim manifest body.
    manifest: struct { digest: Digest, media_type: MediaType, size: u64 },
    /// A blob slot is about to be processed (or recognised as cached).
    blob_started: struct { digest: Digest, kind: BlobKind, size: u64 },
    /// A blob slot finished. `hit_cache` is true if the blob was
    /// already present and no network round-trip happened. For
    /// non-cached slots this fires *after* the atomic temp file has
    /// been linked into the store, not when the worker thread
    /// returned.
    blob_done: struct { digest: Digest, kind: BlobKind, hit_cache: bool },
    /// A layer's tar contents were materialized under
    /// `<store>/extracted/<hex>/`.
    extracted: struct { digest: Digest, media_type: []const u8 },
    /// Pull finished successfully and `index.json` has been tagged.
    done: struct { manifest_digest: Digest },
};

/// Progress callback. May be invoked from worker threads (blob and
/// extract pools), so the function must be thread-safe — typically
/// by serialising on a caller-owned mutex. See
/// `cli/pull.zig:TrampolineCtx` for the production wiring.
pub const ProgressFn = *const fn (ctx: ?*anyopaque, event: PullEvent) void;

/// Optional knobs handed to `pullImage`.
pub const PullOptions = struct {
    /// Override target platform when the registry returns an image
    /// index. `null` → `manifest_mod.default_platform`
    /// (`linux/<host_arch>`).
    platform: ?manifest_mod.Platform = null,
    /// Maximum concurrent blob downloads. `0` → defaults to
    /// `blob_pool.Pool.defaultConcurrency()`.
    concurrency: usize = 0,
    /// Transport scheme used to build manifest and blob URLs. The OCI
    /// distribution spec mandates HTTPS, so production callers should
    /// leave this at the default. Tests against a plain-HTTP loopback
    /// mock pass `"http"`.
    scheme: []const u8 = "https",
    /// Opaque pointer passed through to `progress_fn`.
    progress_ctx: ?*anyopaque = null,
    /// Progress sink. `null` disables progress reporting entirely.
    progress_fn: ?ProgressFn = null,
    /// Optional `std.Progress` root passed in by the CLI. When
    /// non-null, the orchestrator builds child nodes for each phase
    /// (manifest fetch, per-blob downloads with byte counters, per
    /// layer extraction). When null, no Progress tree work is done
    /// and the orchestrator falls back to events-only reporting.
    progress_node: ?std.Progress.Node = null,
    /// Print a per-phase ms summary on stderr at end of pull. Phases:
    /// manifest (auth + GET), blobs (pool runAll), extract (drain).
    /// blobs and extract overlap — sums won't match total.
    timing: bool = false,
};

/// Outcome of a successful `pullImage`.
pub const PullResult = struct {
    /// Sha256 of the picked single-platform manifest.
    manifest_digest: Digest,
    /// Sha256 of the image config blob.
    config_digest: Digest,
    /// Sha256 of every layer, in manifest order. Arena-owned.
    layer_digests: []const Digest,
    /// Backing arena for `layer_digests`.
    arena: std.heap.ArenaAllocator,

    /// Free everything owned by this result.
    pub fn deinit(self: *PullResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Closed error set returned by `pullImage`. Unions every typed error
/// produced by the dependencies plus the orchestrator's own
/// `UnsupportedLayerMediaType` case.
pub const PullError =
    image_ref.ParseError ||
    client_mod.Client.GetManifestError ||
    client_mod.Client.GetBlobError ||
    extract.ExtractGzipError ||
    extract.ExtractZstdError ||
    layout.Store.PutBlobError ||
    layout.Store.TagError ||
    layout.Store.OpenBlobError ||
    layout.StoreError ||
    digest_mod.DigestError ||
    Io.Dir.AccessError ||
    Io.Dir.OpenError ||
    Io.Dir.CreateFileAtomicError ||
    Io.Dir.CreateDirPathError ||
    Io.File.Atomic.LinkError ||
    Io.File.Writer.Error ||
    Io.Reader.Error ||
    Allocator.Error ||
    std.Thread.SpawnError ||
    error{
        /// A layer descriptor declared a media type we cannot decode
        /// (anything other than `tar+gzip` or `tar+zstd`).
        UnsupportedLayerMediaType,
    };

/// Slice 12 hex chars (without the "sha256:" prefix) from a digest
/// string for use as a docker-style short identifier in progress-node
/// labels. Returns the input on shorter strings.
fn shortHex12(dig_str: []const u8) []const u8 {
    const prefix_len: usize = "sha256:".len;
    if (dig_str.len < prefix_len + 12) return dig_str;
    return dig_str[prefix_len .. prefix_len + 12];
}

fn buildBlobUrl(
    gpa: Allocator,
    scheme: []const u8,
    registry_name: []const u8,
    repository: []const u8,
    digest_str: []const u8,
) Allocator.Error![]u8 {
    const ep = manifest_mod.registryEndpoint(registry_name);
    return std.fmt.allocPrint(
        gpa,
        "{s}://{s}/v2/{s}/blobs/{s}",
        .{ scheme, ep, repository, digest_str },
    );
}

fn buildManifestBaseUrl(
    gpa: Allocator,
    scheme: []const u8,
    registry_name: []const u8,
    repository: []const u8,
) Allocator.Error![]u8 {
    const ep = manifest_mod.registryEndpoint(registry_name);
    return std.fmt.allocPrint(
        gpa,
        "{s}://{s}/v2/{s}/manifests",
        .{ scheme, ep, repository },
    );
}

fn emit(options: PullOptions, ev: PullEvent) void {
    if (options.progress_fn) |f| f(options.progress_ctx, ev);
}

fn msBetween(a: ?Io.Timestamp, b: ?Io.Timestamp) u64 {
    const ai = a orelse return 0;
    const bi = b orelse return 0;
    const ns = ai.durationTo(bi).nanoseconds;
    if (ns <= 0) return 0;
    return @as(u64, @intCast(@divTrunc(ns, std.time.ns_per_ms)));
}

fn printTiming(
    t0: ?Io.Timestamp,
    t_manifest: ?Io.Timestamp,
    t_blobs: ?Io.Timestamp,
    t_extract: ?Io.Timestamp,
) void {
    const manifest_ms = msBetween(t0, t_manifest);
    const blobs_ms = msBetween(t_manifest, t_blobs);
    const extract_ms = msBetween(t_blobs, t_extract);
    const total_ms = msBetween(t0, t_extract);
    std.debug.print(
        "timing: total={d}ms  manifest={d}ms  blobs={d}ms  extract={d}ms  (blobs/extract overlap)\n",
        .{ total_ms, manifest_ms, blobs_ms, extract_ms },
    );
}

const Slot = struct {
    digest: Digest,
    media_type: []const u8,
    kind: BlobKind,
    size: u64,
    cached: bool,
};

/// Per-blob ephemeral state for a non-cached slot: the atomic temp
/// file, its buffered writer, and the URL/scope strings handed to the
/// pool. Pointer stability matters because the pool's `BlobJob.writer`
/// is `&self.fw.interface`; once `Pending` lives in a heap slice we
/// never realloc.
///
/// `hex_buf` lives in the struct (not on `initPending`'s stack) because
/// `Io.Dir.createFileAtomic` stores `dest_sub_path` by reference; if
/// the buffer were stack-local, the path would dangle the moment
/// `initPending` returned and `Atomic.link` would later fail with
/// `BadPathName` on the corrupt slice.
const Pending = struct {
    atomic: Io.File.Atomic,
    hex_buf: [digest_mod.hex_length]u8,
    write_buf: []u8,
    fw: Io.File.Writer,
    url: []u8,
    scope: []u8,
    linked: bool,
    /// Index back into the orchestrator's `slots` table so the
    /// completion callback can emit `blob_done` with the right
    /// digest+kind without parallel arrays.
    slot_idx: usize,
    /// Set by the worker-thread completion callback if `finalizePending`
    /// failed. The orchestrator surfaces it after the pool joins.
    /// Default `{}` = success (or finalize not yet attempted).
    finalize_result: anyerror!void = {},

    fn cleanup(self: *Pending, io: Io, gpa: Allocator) void {
        if (!self.linked) self.atomic.deinit(io);
        gpa.free(self.write_buf);
        gpa.free(self.url);
        gpa.free(self.scope);
        self.* = undefined;
    }
};

const PendingInitError = Allocator.Error || Io.Dir.CreateFileAtomicError;

fn initPending(
    self: *Pending,
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    scheme: []const u8,
    ref: *const image_ref.ImageRef,
    slot: Slot,
    slot_idx: usize,
) PendingInitError!void {
    // Materialize hex into self.hex_buf first; createFileAtomic stores
    // the path by reference, so the buffer must outlive the call.
    self.hex_buf = undefined;
    _ = slot.digest.encodedHex(&self.hex_buf);
    const hex: []const u8 = self.hex_buf[0..];

    self.atomic = try store.blobs_dir.createFileAtomic(io, hex, .{ .replace = false });
    errdefer self.atomic.deinit(io);

    self.write_buf = try gpa.alloc(u8, 64 * 1024);
    errdefer gpa.free(self.write_buf);

    var dig_buf: [digest_mod.string_length]u8 = undefined;
    const dig_str = slot.digest.toString(&dig_buf);

    self.url = try buildBlobUrl(gpa, scheme, ref.registry, ref.repository, dig_str);
    errdefer gpa.free(self.url);

    self.scope = try std.fmt.allocPrint(gpa, "repository:{s}:pull", .{ref.repository});
    errdefer gpa.free(self.scope);

    self.linked = false;
    self.slot_idx = slot_idx;
    self.finalize_result = {};
    self.fw = self.atomic.file.writer(io, self.write_buf);
}

fn finalizePending(self: *Pending, io: Io) (Io.File.Atomic.LinkError || Io.File.Writer.Error)!void {
    self.fw.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return self.fw.err.?,
    };
    try self.atomic.link(io);
    self.linked = true;
    self.atomic.deinit(io);
}

/// Adapter for `extract_pool.ExtractFn`. Forwards to
/// `extract.ensureLayer` and widens the error to `anyerror` so the
/// pool stays decoupled from `PullError`. The orchestrator narrows
/// back via `@errorCast` after the pool joins.
fn extractAdapter(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    digest: Digest,
    media_type: []const u8,
) anyerror!void {
    return extract.ensureLayer(io, gpa, store, digest, media_type);
}

/// Pull `ref_text` into `store` using `client` for transport. Returns
/// a `PullResult` whose `arena` carries the layer-digest slice; call
/// `result.deinit()` when done. On any error the store is left in a
/// crash-safe state — partial blob writes are dropped via the atomic
/// machinery, and `index.json` is only updated once every layer has
/// been downloaded and extracted.
pub fn pullImage(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    client: *client_mod.Client,
    ref_text: []const u8,
    options: PullOptions,
) PullError!PullResult {
    const t0: ?Io.Timestamp = if (options.timing) Io.Clock.awake.now(io) else null;

    emit(options, .{ .pull_started = .{ .ref = ref_text } });

    var ref = try image_ref.parse(gpa, ref_text);
    defer ref.deinit(gpa);

    // Step 2: manifest fetch via the URL-explicit entry so we honor
    // `options.scheme` (production HTTPS, tests plain HTTP). The
    // dispatcher in `getManifestByUrl` still handles image-index
    // recursion and digest verification.
    const manifest_base = try buildManifestBaseUrl(gpa, options.scheme, ref.registry, ref.repository);
    defer gpa.free(manifest_base);
    const reference: []const u8 = if (ref.digest) |d| d else if (ref.tag) |t| t else "latest";
    const manifest_scope = try std.fmt.allocPrint(gpa, "repository:{s}:pull", .{ref.repository});
    defer gpa.free(manifest_scope);
    const expected_manifest_digest: ?Digest = if (ref.digest) |d| try Digest.parse(d) else null;

    // Indeterminate spinner while we auth + GET the manifest. Closed
    // immediately after the call returns so subsequent phases get a
    // clean parent.
    const manifest_node: ?std.Progress.Node = if (options.progress_node) |root|
        root.start("fetching manifest", 0)
    else
        null;
    errdefer if (manifest_node) |n| n.end();

    var mres = client.getManifestByUrl(
        manifest_base,
        reference,
        manifest_scope,
        expected_manifest_digest,
        .{ .platform = options.platform },
    ) catch |e| {
        if (manifest_node) |n| n.end();
        return e;
    };
    if (manifest_node) |n| n.end();
    const t_manifest: ?Io.Timestamp = if (options.timing) Io.Clock.awake.now(io) else null;
    var mres_owned = true;
    defer if (mres_owned) mres.deinit();

    emit(options, .{ .manifest = .{
        .digest = mres.digest,
        .media_type = mres.media_type,
        .size = mres.raw_bytes.len,
    } });

    // Step 3: persist manifest blob.
    {
        var manifest_reader: Io.Reader = .fixed(mres.raw_bytes);
        try store.putBlob(io, mres.digest, &manifest_reader);
    }

    const config_digest = try Digest.parse(mres.manifest.config.digest);
    const layers = mres.manifest.layers;

    // Validate every layer media type up-front. Returning before any
    // download keeps the store unchanged on UnsupportedLayerMediaType.
    for (layers) |l| {
        if (extract.classifyLayer(l.mediaType) == null) {
            return error.UnsupportedLayerMediaType;
        }
    }

    // Step 4 setup: per-blob slot table.
    const slot_count = 1 + layers.len;
    var slots = try gpa.alloc(Slot, slot_count);
    defer gpa.free(slots);

    slots[0] = .{
        .digest = config_digest,
        .media_type = mres.manifest.config.mediaType,
        .kind = .config,
        .size = mres.manifest.config.size,
        .cached = store.hasBlob(io, config_digest),
    };
    for (layers, 0..) |ld, i| {
        const dig = try Digest.parse(ld.digest);
        slots[1 + i] = .{
            .digest = dig,
            .media_type = ld.mediaType,
            .kind = .layer,
            .size = ld.size,
            .cached = store.hasBlob(io, dig),
        };
    }

    var pending_count: usize = 0;
    var pending_bytes: u64 = 0;
    for (slots) |s| if (!s.cached) {
        pending_count += 1;
        pending_bytes +%= s.size;
    };

    // Per-non-cached-slot atomic + writer + URL/scope.
    var pendings = try gpa.alloc(Pending, pending_count);
    defer gpa.free(pendings);

    var jobs = try gpa.alloc(blob_pool.BlobJob, pending_count);
    defer gpa.free(jobs);

    // Per-job worker-thread context. Lives in a parallel slice so
    // `BlobJob.complete_ctx` can point at a stable address through
    // the entire `runAll` lifetime.
    var slot_ctxs = try gpa.alloc(BlobCompleteSlot, pending_count);
    defer gpa.free(slot_ctxs);

    // Per-blob progress children. Created lazily — only when
    // `options.progress_node` is non-null.
    var blob_nodes = try gpa.alloc(?std.Progress.Node, pending_count);
    defer gpa.free(blob_nodes);
    @memset(blob_nodes, null);

    // Track how many `pendings` slots are initialized so the errdefer
    // cleans up the right prefix on a partial-init failure.
    var init_count: usize = 0;
    errdefer {
        var k: usize = 0;
        while (k < init_count) : (k += 1) {
            if (blob_nodes[k]) |n| n.end();
            pendings[k].cleanup(io, gpa);
        }
    }

    // T-progress: build the extract pool + jobs BEFORE the blob pool
    // so layer N's bytes can land in `onBlobComplete` and immediately
    // submit to a running extract worker, overlapping extract of
    // layer N with download of layer N+k.
    try extract.ensureExtractedRoot(io, store);

    const eff_concurrency = if (options.concurrency == 0)
        blob_pool.Pool.defaultConcurrency()
    else
        options.concurrency;

    var extract_jobs = try gpa.alloc(extract_pool.ExtractJob, layers.len);
    defer gpa.free(extract_jobs);

    var extract_nodes = try gpa.alloc(?std.Progress.Node, layers.len);
    defer gpa.free(extract_nodes);
    @memset(extract_nodes, null);

    var extract_ctxs = try gpa.alloc(ExtractCompleteSlot, layers.len);
    defer gpa.free(extract_ctxs);

    const extract_parent: ?std.Progress.Node = if (options.progress_node) |root|
        root.start("extracting", layers.len)
    else
        null;
    errdefer if (extract_parent) |n| n.end();

    for (slots[1..], 0..) |s, i| {
        if (extract_parent) |ep| {
            var dig_buf: [digest_mod.string_length]u8 = undefined;
            const dig_str = s.digest.toString(&dig_buf);
            const short12 = shortHex12(dig_str);
            extract_nodes[i] = ep.startFmt(0, "{s}: Extracting", .{short12});
        }
        extract_ctxs[i] = .{
            .digest = s.digest,
            .media_type = s.media_type,
            .progress_fn = options.progress_fn,
            .progress_ctx = options.progress_ctx,
            .extract_node = extract_nodes[i],
        };
        extract_jobs[i] = .{
            .digest = s.digest,
            .media_type = s.media_type,
            .on_complete = onExtractComplete,
            .complete_ctx = @ptrCast(&extract_ctxs[i]),
        };
    }

    var ex_pool = extract_pool.Pool.init(gpa, io, store, eff_concurrency, extractAdapter);
    defer ex_pool.deinit();
    try ex_pool.start();
    // Persistent workers are now running; ensure they always join,
    // even on a blob-pool error path. `closeAndJoin` is idempotent
    // against being called once after the success path closes.
    var ex_pool_closed = false;
    errdefer if (!ex_pool_closed) ex_pool.closeAndJoin();

    // Build the "blobs" parent node up-front so children can attach.
    const blobs_parent: ?std.Progress.Node = if (options.progress_node) |root|
        root.start("downloading", pending_count)
    else
        null;
    errdefer if (blobs_parent) |n| n.end();

    {
        var j: usize = 0;
        for (slots, 0..) |s, slot_idx| {
            if (s.cached) continue;
            try initPending(&pendings[j], io, gpa, store, options.scheme, &ref, s, slot_idx);
            init_count = j + 1;

            if (blobs_parent) |bp| {
                var dig_buf: [digest_mod.string_length]u8 = undefined;
                const dig_str = s.digest.toString(&dig_buf);
                const short12 = shortHex12(dig_str);
                blob_nodes[j] = bp.startFmt(
                    @intCast(s.size),
                    "{s}: Downloading",
                    .{short12},
                );
            }

            // Layer slots: wire the matching extract job so the blob
            // worker can submit it the moment download finalizes.
            // Config slot has no extract phase.
            const extract_job_ptr: ?*extract_pool.ExtractJob = switch (s.kind) {
                .layer => &extract_jobs[slot_idx - 1], // slots[0] is config
                .config => null,
            };

            slot_ctxs[j] = .{
                .pending = &pendings[j],
                .slot = s,
                .progress_fn = options.progress_fn,
                .progress_ctx = options.progress_ctx,
                .blob_node = blob_nodes[j],
                .io = io,
                .ex_pool = &ex_pool,
                .extract_job = extract_job_ptr,
            };
            jobs[j] = .{
                .url = pendings[j].url,
                .scope = pendings[j].scope,
                .digest = s.digest,
                .writer = &pendings[j].fw.interface,
                .opts = .{ .progress_node = blob_nodes[j] },
                .on_complete = onBlobComplete,
                .complete_ctx = @ptrCast(&slot_ctxs[j]),
            };
            j += 1;
        }
    }

    // Emit blob_started for every slot in slot order: cached and not.
    for (slots) |s| {
        emit(options, .{ .blob_started = .{
            .digest = s.digest,
            .kind = s.kind,
            .size = s.size,
        } });
    }

    // Cached slots are decided up-front; emit their `blob_done`
    // before the pool runs so warm-cache pulls do not appear to
    // stall while the pool spins up workers for the rest. Cached
    // layers also need their extract job submitted so the extract
    // pool processes them — they will hit the `extract.ensureLayer`
    // idempotent fast-path inside the worker.
    for (slots, 0..) |s, slot_idx| if (s.cached) {
        emit(options, .{ .blob_done = .{
            .digest = s.digest,
            .kind = s.kind,
            .hit_cache = true,
        } });
        if (s.kind == .layer) {
            try ex_pool.submit(&extract_jobs[slot_idx - 1]);
        }
    };

    // Step 5: drive the blob pool. Workers fire `blob_done`,
    // finalize each Pending, and submit each layer's extract job to
    // `ex_pool` as it completes (see `onBlobComplete`).
    var pool = blob_pool.Pool.init(gpa, io, client, eff_concurrency);
    defer pool.deinit();
    try pool.runAll(jobs);
    const t_blobs: ?Io.Timestamp = if (options.timing) Io.Clock.awake.now(io) else null;

    if (blobs_parent) |n| n.end();

    // Step 6: surface per-job errors. Workers already emitted
    // `blob_done`, ran `finalizePending`, and submitted extract
    // jobs; we just collect any first-error here.
    for (jobs, 0..) |job, jx| {
        try job.result;
        // Narrow the worker-stored anyerror back to PullError. The
        // worker only ever stores errors out of `finalizePending`,
        // which are a strict subset of PullError.
        pendings[jx].finalize_result catch |e| return @errorCast(e);
    }

    // After link, pendings hold no atomic resources — but we still
    // need to free the heap-allocated buffers. Run cleanup explicitly
    // and disable the errdefer.
    {
        var k: usize = 0;
        while (k < init_count) : (k += 1) pendings[k].cleanup(io, gpa);
        init_count = 0;
    }

    // Step 7: drain remaining extract workers. Submissions for any
    // layer not yet processed are already queued; close signals "no
    // more work" so workers exit when the queue drains.
    ex_pool.closeAndJoin();
    ex_pool_closed = true;
    const t_extract: ?Io.Timestamp = if (options.timing) Io.Clock.awake.now(io) else null;

    if (extract_parent) |n| n.end();

    for (extract_jobs) |ej| {
        ej.result catch |e| return @errorCast(e);
    }

    // Step 8: tag index.json.
    try store.tag(io, gpa, ref_text, .{
        .media_type = mres.media_type.toString(),
        .digest = mres.digest,
        .size = mres.raw_bytes.len,
    });

    emit(options, .{ .done = .{ .manifest_digest = mres.digest } });

    if (options.timing) printTiming(t0, t_manifest, t_blobs, t_extract);

    // Build PullResult into its own arena so the caller can outlive
    // the manifest result.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();
    const layer_digs = try arena_alloc.alloc(Digest, layers.len);
    for (layers, 0..) |l, k| layer_digs[k] = try Digest.parse(l.digest);

    const out = PullResult{
        .manifest_digest = mres.digest,
        .config_digest = config_digest,
        .layer_digests = layer_digs,
        .arena = arena,
    };

    mres.deinit();
    mres_owned = false;
    return out;
}

/// Per-blob worker-thread context. `BlobJob.complete_ctx` points at
/// one of these; the worker hands it back to `onBlobComplete`. Holds
/// everything the callback needs to (a) finalize the temp file, (b)
/// emit `blob_done` through the (locked) trampoline, and (c) close
/// the per-blob progress child. Lives in a parallel slice in
/// `pullImage` so the pointer is stable through `runAll`.
const BlobCompleteSlot = struct {
    pending: *Pending,
    slot: Slot,
    progress_fn: ?ProgressFn,
    progress_ctx: ?*anyopaque,
    blob_node: ?std.Progress.Node,
    io: Io,
    /// Persistent extract pool the layer's extract job is submitted
    /// to once download finalises. `null` for callers that don't run
    /// an overlapping extract phase.
    ex_pool: ?*extract_pool.Pool = null,
    /// Stable pointer into the orchestrator's `extract_jobs` slice.
    /// `null` for the config slot (no extract) or when extract is
    /// disabled.
    extract_job: ?*extract_pool.ExtractJob = null,
};

fn onBlobComplete(ctx_opaque: ?*anyopaque, job: *blob_pool.BlobJob) void {
    const ctx: *BlobCompleteSlot = @ptrCast(@alignCast(ctx_opaque.?));
    if (job.result) |_| {
        // Finalize the atomic temp into the store. Errors land in
        // the Pending so the orchestrator can surface them after
        // the pool joins.
        if (finalizePending(ctx.pending, ctx.io)) |_| {
            if (ctx.progress_fn) |f| {
                f(ctx.progress_ctx, .{ .blob_done = .{
                    .digest = ctx.slot.digest,
                    .kind = ctx.slot.kind,
                    .hit_cache = false,
                } });
            }
            // Layer is on disk — kick off its extract immediately so
            // it overlaps with the next blob downloads. Submission
            // failure (only path: OOM growing the queue) is recorded
            // on the extract job so the main thread surfaces it.
            if (ctx.ex_pool) |ep| if (ctx.extract_job) |ej| {
                ep.submit(ej) catch |e| {
                    ej.result = e;
                };
            };
        } else |e| {
            ctx.pending.finalize_result = e;
        }
    } else |_| {
        // Download failed; main thread reads `job.result` directly.
    }
    if (ctx.blob_node) |n| n.end();
}

/// Per-layer extract-worker context. Same idea as `BlobCompleteSlot`
/// but for the extract pool's completion hook.
const ExtractCompleteSlot = struct {
    digest: Digest,
    media_type: []const u8,
    progress_fn: ?ProgressFn,
    progress_ctx: ?*anyopaque,
    extract_node: ?std.Progress.Node,
};

fn onExtractComplete(ctx_opaque: ?*anyopaque, job: *extract_pool.ExtractJob) void {
    const ctx: *ExtractCompleteSlot = @ptrCast(@alignCast(ctx_opaque.?));
    if (job.result) |_| {
        if (ctx.progress_fn) |f| {
            f(ctx.progress_ctx, .{ .extracted = .{
                .digest = ctx.digest,
                .media_type = ctx.media_type,
            } });
        }
    } else |_| {
        // Extract failed; main thread reads `job.result` directly.
    }
    if (ctx.extract_node) |n| n.end();
}

const testing = std.testing;
const http = std.http;
const flate = std.compress.flate;

/// One mock-server route. Requests are matched against routes by
/// substring on the request head, independent of arrival order, so
/// concurrent pool workers that race on `connect()` do not need a
/// deterministic accept schedule.
const Route = struct {
    path_contains: []const u8,
    status: http.Status = .ok,
    extra_headers: []const http.Header = &.{},
    body: []const u8 = "",
};

const MockServer = struct {
    server: std.Io.net.Server,
    io: Io,
    routes: []const Route,
    expected_requests: usize,
    err: ?anyerror = null,
    requests_seen: usize = 0,

    fn run(self: *MockServer) void {
        var i: usize = 0;
        while (i < self.expected_requests) : (i += 1) {
            self.handleOne() catch |e| {
                if (self.err == null) self.err = e;
                return;
            };
            self.requests_seen += 1;
        }
    }

    fn handleOne(self: *MockServer) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buf);
        var stream_writer = stream.writer(self.io, &write_buf);

        var server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);
        var request = try server.receiveHead();

        for (self.routes) |r| {
            if (std.mem.indexOf(u8, request.head_buffer, r.path_contains) != null) {
                try request.respond(r.body, .{
                    .status = r.status,
                    .extra_headers = r.extra_headers,
                    .keep_alive = false,
                });
                return;
            }
        }
        return error.NoRoute;
    }
};

fn startMockServer(io: Io) !*MockServer {
    const gpa = testing.allocator;
    const ms = try gpa.create(MockServer);
    errdefer gpa.destroy(ms);
    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    ms.* = .{
        .server = server,
        .io = io,
        .routes = &.{},
        .expected_requests = 0,
        .err = null,
        .requests_seen = 0,
    };
    return ms;
}

fn stopMockServer(ms: *MockServer) void {
    ms.server.deinit(ms.io);
    testing.allocator.destroy(ms);
}

/// Build a tar+gzip blob containing a single regular file. Caller owns
/// the returned slice.
fn buildSingleFileTarGz(
    gpa: Allocator,
    path: []const u8,
    content: []const u8,
) ![]u8 {
    var raw: Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer raw.deinit();

    var tar_writer: std.tar.Writer = .{ .underlying_writer = &raw.writer };
    try tar_writer.writeFileBytes(path, content, .{ .mode = 0o644 });
    try raw.writer.flush();

    var gz: Io.Writer.Allocating = try .initCapacity(gpa, 64);
    errdefer gz.deinit();

    var window: [flate.max_window_len]u8 = undefined;
    var compress = try flate.Compress.init(&gz.writer, &window, .gzip, .default);
    try compress.writer.writeAll(raw.written());
    try compress.finish();
    try gz.writer.flush();
    return gz.toOwnedSlice();
}

const TestImage = struct {
    config: []u8,
    config_digest: Digest,
    layer1: []u8,
    layer1_digest: Digest,
    layer2: []u8,
    layer2_digest: Digest,
    manifest: []u8,
    manifest_digest: Digest,

    fn deinit(self: *TestImage, gpa: Allocator) void {
        gpa.free(self.config);
        gpa.free(self.layer1);
        gpa.free(self.layer2);
        gpa.free(self.manifest);
    }
};

/// Synthesize a two-layer OCI image (config + 2 layers + manifest).
/// Layer media type defaults to OCI tar+gzip; pass an override to
/// exercise the unsupported-media-type path.
fn buildTestImage(
    gpa: Allocator,
    layer_media_type: []const u8,
) !TestImage {
    const config_bytes = try gpa.dupe(u8, "{\"architecture\":\"amd64\",\"os\":\"linux\"}");
    errdefer gpa.free(config_bytes);
    const config_dig = digest_mod.Hasher.hash(config_bytes);

    const l1 = try buildSingleFileTarGz(gpa, "foo.txt", "foo-content\n");
    errdefer gpa.free(l1);
    const l1_dig = digest_mod.Hasher.hash(l1);

    const l2 = try buildSingleFileTarGz(gpa, "bar.txt", "bar-content\n");
    errdefer gpa.free(l2);
    const l2_dig = digest_mod.Hasher.hash(l2);

    var c_buf: [digest_mod.string_length]u8 = undefined;
    var l1_buf: [digest_mod.string_length]u8 = undefined;
    var l2_buf: [digest_mod.string_length]u8 = undefined;
    const c_str = config_dig.toString(&c_buf);
    const l1_str = l1_dig.toString(&l1_buf);
    const l2_str = l2_dig.toString(&l2_buf);

    const manifest = try std.fmt.allocPrint(gpa,
        \\{{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
        \\"config":{{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"{s}","size":{d}}},
        \\"layers":[
        \\{{"mediaType":"{s}","digest":"{s}","size":{d}}},
        \\{{"mediaType":"{s}","digest":"{s}","size":{d}}}
        \\]}}
    , .{
        c_str,            config_bytes.len,
        layer_media_type, l1_str,
        l1.len,           layer_media_type,
        l2_str,           l2.len,
    });
    errdefer gpa.free(manifest);
    const m_dig = digest_mod.Hasher.hash(manifest);

    return .{
        .config = config_bytes,
        .config_digest = config_dig,
        .layer1 = l1,
        .layer1_digest = l1_dig,
        .layer2 = l2,
        .layer2_digest = l2_dig,
        .manifest = manifest,
        .manifest_digest = m_dig,
    };
}

const EventCapture = struct {
    list: std.ArrayList(PullEvent) = .empty,
    gpa: Allocator,
    /// Pull worker pools fire `blob_done` and `extracted` from
    /// worker threads; the callback must serialise.
    mu: Io.Mutex = .init,
    io: Io,

    fn deinit(self: *EventCapture) void {
        self.list.deinit(self.gpa);
    }

    fn cb(ctx: ?*anyopaque, ev: PullEvent) void {
        const self: *EventCapture = @ptrCast(@alignCast(ctx.?));
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.list.append(self.gpa, ev) catch {};
    }
};

fn loopbackUrl(gpa: Allocator, port: u16, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
}

/// Caller owns `headers` so the returned `Route` does not dangle —
/// `&[_]http.Header{...}` inside this function would point at this
/// function's stack frame.
fn manifestRoute(headers: []const http.Header, body: []const u8) Route {
    return .{
        .path_contains = "/manifests/",
        .status = .ok,
        .extra_headers = headers,
        .body = body,
    };
}

const manifest_oci_v1_headers = [_]http.Header{
    .{ .name = "content-type", .value = "application/vnd.oci.image.manifest.v1+json" },
};

fn blobRoute(digest_substr: []const u8, body: []const u8) Route {
    return .{
        .path_contains = digest_substr,
        .status = .ok,
        .body = body,
    };
}

/// Build an `image_ref.ImageRef` whose `registry` field is the
/// loopback address of `port`. We use this both to talk to the mock
/// server (the orchestrator constructs the URL from the ref) and to
/// satisfy the OCI ref grammar (loopback host has a `:port` suffix
/// which `validateRegistry` accepts).
fn buildLoopbackRefText(
    gpa: Allocator,
    port: u16,
) ![]u8 {
    return std.fmt.allocPrint(gpa, "127.0.0.1:{d}/test/repo:latest", .{port});
}

test "pullImage end-to-end against mock registry, two-layer image" {
    const gpa = testing.allocator;
    const io = testing.io;

    var img = try buildTestImage(gpa, extract.oci_layer_gzip);
    defer img.deinit(gpa);

    var c_buf: [digest_mod.string_length]u8 = undefined;
    var l1_buf: [digest_mod.string_length]u8 = undefined;
    var l2_buf: [digest_mod.string_length]u8 = undefined;
    const c_str = img.config_digest.toString(&c_buf);
    const l1_str = img.layer1_digest.toString(&l1_buf);
    const l2_str = img.layer2_digest.toString(&l2_buf);

    var ms = try startMockServer(io);
    defer stopMockServer(ms);

    const routes = [_]Route{
        manifestRoute(&manifest_oci_v1_headers, img.manifest),
        blobRoute(c_str, img.config),
        blobRoute(l1_str, img.layer1),
        blobRoute(l2_str, img.layer2),
    };
    ms.routes = &routes;
    ms.expected_requests = 4;
    const port = ms.server.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = client_mod.Client.init(gpa, io, &http_client, client_mod.Provider.anonymous);
    defer client.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    const ref_text = try buildLoopbackRefText(gpa, port);
    defer gpa.free(ref_text);

    var capture: EventCapture = .{ .gpa = gpa, .io = io };
    defer capture.deinit();

    var result = try pullImage(io, gpa, &store, &client, ref_text, .{
        .concurrency = 2,
        .scheme = "http",
        .progress_ctx = &capture,
        .progress_fn = EventCapture.cb,
    });
    defer result.deinit();

    thread.join();
    if (ms.err) |e| return e;

    // Blobs all present.
    try testing.expect(store.hasBlob(io, img.manifest_digest));
    try testing.expect(store.hasBlob(io, img.config_digest));
    try testing.expect(store.hasBlob(io, img.layer1_digest));
    try testing.expect(store.hasBlob(io, img.layer2_digest));

    // index.json has one entry pointing at our manifest.
    var parsed = try store.readIndex(io, gpa);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.manifests.len);
    var m_buf: [digest_mod.string_length]u8 = undefined;
    try testing.expectEqualStrings(
        img.manifest_digest.toString(&m_buf),
        parsed.value.manifests[0].digest,
    );
    try testing.expectEqualStrings(
        ref_text,
        parsed.value.manifests[0].annotations.?.map.get(layout.ref_name_annotation).?,
    );

    // Extracted dirs contain the expected files.
    var l1_hex_buf: [digest_mod.hex_length]u8 = undefined;
    var l2_hex_buf: [digest_mod.hex_length]u8 = undefined;
    var l1_path_buf: [128]u8 = undefined;
    var l2_path_buf: [128]u8 = undefined;
    const l1_path = try std.fmt.bufPrint(&l1_path_buf, "store/extracted/{s}/foo.txt", .{
        img.layer1_digest.encodedHex(&l1_hex_buf),
    });
    const l2_path = try std.fmt.bufPrint(&l2_path_buf, "store/extracted/{s}/bar.txt", .{
        img.layer2_digest.encodedHex(&l2_hex_buf),
    });
    var l1_content_buf: [32]u8 = undefined;
    var l2_content_buf: [32]u8 = undefined;
    const l1_content = try tmp.dir.readFile(io, l1_path, &l1_content_buf);
    const l2_content = try tmp.dir.readFile(io, l2_path, &l2_content_buf);
    try testing.expectEqualStrings("foo-content\n", l1_content);
    try testing.expectEqualStrings("bar-content\n", l2_content);

    // PullResult layer order matches manifest.
    try testing.expectEqual(@as(usize, 2), result.layer_digests.len);
    try testing.expect(result.layer_digests[0].eql(img.layer1_digest));
    try testing.expect(result.layer_digests[1].eql(img.layer2_digest));
}

test "pullImage skips blobs already present in the store" {
    const gpa = testing.allocator;
    const io = testing.io;

    var img = try buildTestImage(gpa, extract.oci_layer_gzip);
    defer img.deinit(gpa);

    var c_buf: [digest_mod.string_length]u8 = undefined;
    var l1_buf: [digest_mod.string_length]u8 = undefined;
    var l2_buf: [digest_mod.string_length]u8 = undefined;
    const c_str = img.config_digest.toString(&c_buf);
    const l1_str = img.layer1_digest.toString(&l1_buf);
    const l2_str = img.layer2_digest.toString(&l2_buf);
    _ = l2_str;

    var ms = try startMockServer(io);
    defer stopMockServer(ms);

    // Pre-stage layer2 in the store. The mock server will only need
    // to serve manifest, config, layer1.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);
    {
        var pre: Io.Reader = .fixed(img.layer2);
        try store.putBlob(io, img.layer2_digest, &pre);
    }

    const routes = [_]Route{
        manifestRoute(&manifest_oci_v1_headers, img.manifest),
        blobRoute(c_str, img.config),
        blobRoute(l1_str, img.layer1),
    };
    ms.routes = &routes;
    ms.expected_requests = 3;
    const port = ms.server.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = client_mod.Client.init(gpa, io, &http_client, client_mod.Provider.anonymous);
    defer client.deinit();

    const ref_text = try buildLoopbackRefText(gpa, port);
    defer gpa.free(ref_text);

    var capture: EventCapture = .{ .gpa = gpa, .io = io };
    defer capture.deinit();

    var result = try pullImage(io, gpa, &store, &client, ref_text, .{
        .concurrency = 2,
        .scheme = "http",
        .progress_ctx = &capture,
        .progress_fn = EventCapture.cb,
    });
    defer result.deinit();

    thread.join();
    if (ms.err) |e| return e;

    // Mock saw exactly: 1 manifest + 2 blobs (not 3 — layer2 was cached).
    try testing.expectEqual(@as(usize, 3), ms.requests_seen);

    // blob_done event for layer2 has hit_cache=true; layer1+config are
    // hit_cache=false.
    var hit_l2 = false;
    var miss_l1 = false;
    var miss_cfg = false;
    for (capture.list.items) |ev| switch (ev) {
        .blob_done => |b| {
            if (b.digest.eql(img.layer2_digest)) {
                try testing.expect(b.hit_cache);
                hit_l2 = true;
            } else if (b.digest.eql(img.layer1_digest)) {
                try testing.expect(!b.hit_cache);
                miss_l1 = true;
            } else if (b.digest.eql(img.config_digest)) {
                try testing.expect(!b.hit_cache);
                miss_cfg = true;
            }
        },
        else => {},
    };
    try testing.expect(hit_l2);
    try testing.expect(miss_l1);
    try testing.expect(miss_cfg);
}

test "pullImage rejects unsupported layer media type" {
    const gpa = testing.allocator;
    const io = testing.io;

    var img = try buildTestImage(gpa, "application/vnd.example.unsupported");
    defer img.deinit(gpa);

    var ms = try startMockServer(io);
    defer stopMockServer(ms);

    const routes = [_]Route{
        manifestRoute(&manifest_oci_v1_headers, img.manifest),
    };
    ms.routes = &routes;
    ms.expected_requests = 1;
    const port = ms.server.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = client_mod.Client.init(gpa, io, &http_client, client_mod.Provider.anonymous);
    defer client.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    const ref_text = try buildLoopbackRefText(gpa, port);
    defer gpa.free(ref_text);

    try testing.expectError(
        error.UnsupportedLayerMediaType,
        pullImage(io, gpa, &store, &client, ref_text, .{ .scheme = "http" }),
    );

    thread.join();

    // index.json was not tagged.
    var parsed = try store.readIndex(io, gpa);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.manifests.len);
}

test "pullImage emits progress events in deterministic order" {
    const gpa = testing.allocator;
    const io = testing.io;

    var img = try buildTestImage(gpa, extract.oci_layer_gzip);
    defer img.deinit(gpa);

    var c_buf: [digest_mod.string_length]u8 = undefined;
    var l1_buf: [digest_mod.string_length]u8 = undefined;
    var l2_buf: [digest_mod.string_length]u8 = undefined;
    const c_str = img.config_digest.toString(&c_buf);
    const l1_str = img.layer1_digest.toString(&l1_buf);
    const l2_str = img.layer2_digest.toString(&l2_buf);

    var ms = try startMockServer(io);
    defer stopMockServer(ms);

    const routes = [_]Route{
        manifestRoute(&manifest_oci_v1_headers, img.manifest),
        blobRoute(c_str, img.config),
        blobRoute(l1_str, img.layer1),
        blobRoute(l2_str, img.layer2),
    };
    ms.routes = &routes;
    ms.expected_requests = 4;
    const port = ms.server.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, MockServer.run, .{ms});

    var http_client: http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var client = client_mod.Client.init(gpa, io, &http_client, client_mod.Provider.anonymous);
    defer client.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try layout.Store.init(io, tmp.dir, "store");
    defer store.close(io);

    const ref_text = try buildLoopbackRefText(gpa, port);
    defer gpa.free(ref_text);

    var capture: EventCapture = .{ .gpa = gpa, .io = io };
    defer capture.deinit();

    var result = try pullImage(io, gpa, &store, &client, ref_text, .{
        .concurrency = 2,
        .scheme = "http",
        .progress_ctx = &capture,
        .progress_fn = EventCapture.cb,
    });
    defer result.deinit();

    thread.join();
    if (ms.err) |e| return e;

    // After T-progress restructuring, extract events interleave with
    // late blob_done events (extract of layer N runs while later
    // blobs are still downloading). The test now asserts:
    //   * stable head: pull_started → manifest → 3× blob_started.
    //   * stable tail: done is last.
    //   * counts: 3 blob_done, 2 extracted, exactly one done.
    //   * causality: every extracted is preceded by at least as many
    //     blob_done events as itself (i.e. layer extract never
    //     fires before the layer's own blob_done).
    const tags = blk: {
        var arr: std.ArrayList(std.meta.Tag(PullEvent)) = .empty;
        defer arr.deinit(gpa);
        for (capture.list.items) |ev| arr.append(gpa, std.meta.activeTag(ev)) catch return error.OutOfMemory;
        break :blk try arr.toOwnedSlice(gpa);
    };
    defer gpa.free(tags);

    try testing.expectEqual(@as(usize, 11), tags.len);
    try testing.expectEqual(std.meta.Tag(PullEvent).pull_started, tags[0]);
    try testing.expectEqual(std.meta.Tag(PullEvent).manifest, tags[1]);
    try testing.expectEqual(std.meta.Tag(PullEvent).blob_started, tags[2]);
    try testing.expectEqual(std.meta.Tag(PullEvent).blob_started, tags[3]);
    try testing.expectEqual(std.meta.Tag(PullEvent).blob_started, tags[4]);
    try testing.expectEqual(std.meta.Tag(PullEvent).done, tags[tags.len - 1]);

    var blob_done_count: usize = 0;
    var extracted_count: usize = 0;
    var done_count: usize = 0;
    for (tags) |t| switch (t) {
        .blob_done => {
            blob_done_count += 1;
            // Each extracted seen so far must correspond to an
            // earlier blob_done (causality: layer must download
            // before its extract can complete).
        },
        .extracted => {
            extracted_count += 1;
            try testing.expect(extracted_count <= blob_done_count);
        },
        .done => done_count += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), blob_done_count);
    try testing.expectEqual(@as(usize, 2), extracted_count);
    try testing.expectEqual(@as(usize, 1), done_count);
}

test "buildBlobUrl applies docker.io rewrite" {
    const gpa = testing.allocator;
    const url = try buildBlobUrl(gpa, "https", "docker.io", "library/alpine", "sha256:" ++ ("0" ** 64));
    defer gpa.free(url);
    try testing.expectEqualStrings(
        "https://registry-1.docker.io/v2/library/alpine/blobs/sha256:" ++ ("0" ** 64),
        url,
    );
}
