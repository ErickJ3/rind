//! `rind run` orchestrator.
//!
//! `runImage` glues the runtime stack into a single foreground call:
//! ref parse → image lookup in `index.json` → ensure every layer is
//! extracted (via `image/extract.zig:ensureExtracted`, the helper shared
//! with `pull.zig`) → state allocation → overlay mount → bundle compose
//! → libcrun runForeground → unmount → (when `--rm`) recursive removal
//! of the container/bundle/overlay triplet.
//!
//! Not yet implemented:
//!   - bind mounts / pty,
//!   - state-file dynamic writes during the run,
//!   - detached `-d` supervision,
//!   - auto-pull when image is absent (the `RunOptions.pull` field is
//!     shipped as a stub today and surfaces `ImageNotPresent` because
//!     `runImage` has no client argument by spec).
//!
//! Signature deviation. Spec text reads
//! `runImage(io, gpa, store, ref_text, opts, progress_cb)`.
//! Implementation adds:
//!   - `env: Env` carrying `{root_dir, root_abspath, store_subpath}`,
//!     because state.allocate needs the parent dir of the store and
//!     overlay/libcrun need *absolute* paths that an `Io.Dir` handle
//!     does not by itself surface;
//!   - `deps: RunDeps` mirroring `cli/pull.zig:PullDeps` so unit tests
//!     can stub libcrun out.
//!
//! Cleanup discipline: errdefers run in reverse declaration order. The
//! orchestrator declares triplet cleanup *before* overlay-unmount, so on
//! the error path overlay is unmounted *first* — overlayfs cannot be
//! `deleteTree`d while the merged tree is still mounted. The success
//! path performs both steps explicitly in the same order and disables
//! both errdefers via flag toggles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const image_ref = @import("image/ref.zig");
const digest_mod = @import("image/digest.zig");
const extract = @import("image/extract.zig");
const image_config = @import("image/config.zig");
const layout = @import("store/layout.zig");
const manifest_mod = @import("registry/manifest.zig");
const state_mod = @import("runtime/state.zig");
const overlay_mod = @import("runtime/overlay.zig");
const bundle_mod = @import("runtime/bundle.zig");
const core = @import("runtime/core.zig");

/// Re-exported so callers don't double-import `runtime/bundle.zig`
/// just to construct overrides.
pub const RunOverrides = bundle_mod.RunOverrides;

/// Tagged union of orchestrator progress events. Emission order on the
/// success path: `run_started` (immediately after the container id is
/// allocated), `overlay_mounted`, `bundle_ready`, `started`, `exited`,
/// optionally `removed`. Error paths short-circuit; emitted events are
/// never withdrawn.
pub const RunEvent = union(enum) {
    /// Container directory triplet has been allocated. `id` is the
    /// 12-char short id; `ref` borrows the caller's `ref_text` slice.
    run_started: struct { ref: []const u8, id: [12]u8 },
    /// Overlay mount succeeded; merged rootfs is live.
    overlay_mounted,
    /// `config.json` has been written into the bundle directory.
    bundle_ready,
    /// libcrun has been handed the bundle. `pid` is `0` because
    /// `runForeground` is synchronous and does not surface the live
    /// container PID.
    started: struct { pid: u32 },
    /// libcrun returned. Exactly one of `code` / `signal` is non-zero
    /// for a clean run; both zero indicates `.exit = 0`.
    exited: struct { code: u8, signal: u8 },
    /// `--rm` removed the container/bundle/overlay triplet.
    removed,
};

/// Progress callback. Invoked synchronously from `runImage`'s thread,
/// no worker-thread parallelism here, unlike pull. Implementations need
/// not lock.
pub const ProgressFn = *const fn (ctx: ?*anyopaque, event: RunEvent) void;

/// Filesystem layout the orchestrator needs that the `Store` handle
/// doesn't already encode. The CLI builds this from `resolveRoot` and
/// the canonical `store_subpath` constant in `cli/root.zig`.
pub const Env = struct {
    /// Open handle to `~/.rind/` (or `RIND_ROOT`). Parent of
    /// `containers/`, `bundles/`, `overlays/`, and the store. Caller
    /// retains ownership; orchestrator does not close.
    root_dir: Io.Dir,
    /// Absolute filesystem path of `root_dir`. `overlay.mount` and
    /// libcrun both demand absolute paths; an `Io.Dir` alone cannot
    /// answer "what's my abspath" reliably.
    root_abspath: []const u8,
    /// Subdirectory of `root_dir` that contains the OCI image layout
    /// (`oci-layout`, `index.json`, `blobs/sha256/`, `extracted/`).
    /// Defaults to `"store"` to match `cli/root.zig:store_subpath`.
    store_subpath: []const u8 = "store",
};

/// Caller-tunable knobs for one `runImage` invocation.
pub const RunOptions = struct {
    /// `--rm`. When true, the orchestrator deletes the
    /// container/bundle/overlay triplet on every return path, success
    /// or failure, and emits `RunEvent.removed` on success.
    rm: bool = false,
    /// Reserved for auto-pull wiring (not yet implemented). The
    /// orchestrator returns `error.ImageNotPresent` whenever the image
    /// is absent from `index.json` (no `Client` is plumbed through
    /// the spec signature).
    pull: bool = false,
    /// CLI-flag overrides forwarded into `bundle.compose`. Default
    /// (`.{}`) leaves all image-config defaults intact.
    overrides: bundle_mod.RunOverrides = .{},
    /// Optional `--name`. The CLI surface for it is not yet wired.
    name: ?[]const u8 = null,
    /// Opaque pointer threaded through to `progress_fn`.
    progress_ctx: ?*anyopaque = null,
    /// Progress sink. `null` disables event reporting entirely.
    progress_fn: ?ProgressFn = null,
};

/// Outcome of a successful `runImage`. Carries the decoded exit
/// status and a copy of the short container id (no heap state).
pub const RunResult = struct {
    /// 12-char short id. Stable across restarts.
    container_id: [12]u8,
    /// `WEXITSTATUS`-equivalent. `0` when the process was signaled.
    exit_code: u8,
    /// Signal number (e.g. `9` for SIGKILL) or `0` on a normal exit.
    signal: u8,
    /// True when `--rm` was set and triplet cleanup succeeded.
    removed: bool,
};

/// Test seam mirroring `cli/pull.zig:PullDeps`. Production wires the
/// real runtime/overlay implementations; unit tests substitute stubs
/// that return synthetic `MountedOverlay` and `ExitStatus` values
/// without invoking libcrun or the kernel overlay code path (which
/// needs CAP_SYS_ADMIN or a rootless-capable kernel).
pub const RunDeps = struct {
    /// Defaults to `core.runForeground`. Stub returns a chosen
    /// `ExitStatus` or `RuntimeError` to drive the orchestrator.
    run_fn: *const fn (
        io: Io,
        gpa: Allocator,
        req: core.RunRequest,
    ) core.RuntimeError!core.ExitStatus = core.runForeground,
    /// Defaults to `overlay_mod.mount`. Stub for unit tests that need
    /// the orchestrator to run on hosts without overlay capability.
    mount_fn: *const fn (
        io: Io,
        gpa: Allocator,
        container_dir: []const u8,
        lowerdirs: []const []const u8,
    ) overlay_mod.OverlayError!overlay_mod.MountedOverlay = overlay_mod.mount,
    /// Defaults to `overlay_mod.unmount`. Paired with `mount_fn`; a
    /// stub `mount_fn` must come with a stub `unmount_fn` that frees
    /// whatever the mount stub allocated.
    unmount_fn: *const fn (
        io: Io,
        mounted: *overlay_mod.MountedOverlay,
    ) overlay_mod.OverlayError!void = overlay_mod.unmount,
};

/// Closed error set returned by `runImage`. Composes every typed set
/// reachable from the orchestrator with two semantic additions
/// (`ImageNotPresent`, `UnsupportedManifestMediaType`).
pub const RunError =
    image_ref.ParseError ||
    digest_mod.DigestError ||
    manifest_mod.ManifestError ||
    image_config.ConfigError ||
    extract.EnsureLayerError ||
    state_mod.AllocateError ||
    overlay_mod.OverlayError ||
    bundle_mod.BundleError ||
    core.RuntimeError ||
    layout.Store.ReadIndexError ||
    layout.Store.ReadBlobError ||
    Io.Dir.OpenError ||
    Io.Dir.DeleteTreeError ||
    Allocator.Error ||
    error{
        /// `ref_text` did not match any descriptor in `index.json`.
        /// Also fires when `opts.pull = true` because auto-pull is
        /// not yet implemented.
        ImageNotPresent,
        /// `index.json` resolved a descriptor whose `mediaType` is
        /// not a single-platform manifest (image-index, unknown).
        UnsupportedManifestMediaType,
    };

/// Cap on a manifest blob read into memory. Same magnitude as
/// `cli/inspect.zig:manifest_max_bytes`.
const manifest_max_bytes: usize = 8 * 1024 * 1024;
/// Cap on a config blob.
const config_max_bytes: usize = 4 * 1024 * 1024;

/// Run `ref_text` end-to-end: resolve the image in the store, allocate
/// container state, mount its overlay, compose the OCI runtime bundle,
/// invoke libcrun, and (when `opts.rm`) tear the triplet back down.
///
/// Returns when the container exits or libcrun reports a typed error.
/// The orchestrator never spawns threads; signal handling is owned by
/// `core.runForeground` for the duration of step 7 and torn down on
/// return.
pub fn runImage(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    env: Env,
    ref_text: []const u8,
    opts: RunOptions,
    deps: RunDeps,
) RunError!RunResult {
    var ref = try image_ref.parse(gpa, ref_text);
    defer ref.deinit(gpa);

    var parsed_index = try store.readIndex(io, gpa);
    defer parsed_index.deinit();

    const desc = findDescriptor(parsed_index.value, ref, ref_text) orelse
        return RunError.ImageNotPresent;

    const desc_mt = manifest_mod.MediaType.fromString(desc.mediaType) orelse
        return RunError.UnsupportedManifestMediaType;
    if (!desc_mt.isSingle()) return RunError.UnsupportedManifestMediaType;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const m_digest = try digest_mod.Digest.parse(desc.digest);
    const m_bytes = try store.readBlobAlloc(io, aa, m_digest, manifest_max_bytes);
    const manifest = try manifest_mod.parseManifest(aa, m_bytes, desc_mt);

    const c_digest = try digest_mod.Digest.parse(manifest.config.digest);
    const c_bytes = try store.readBlobAlloc(io, aa, c_digest, config_max_bytes);
    const img_cfg = try image_config.parse(aa, c_bytes);

    const layer_digests = try aa.alloc(digest_mod.Digest, manifest.layers.len);
    const layer_media_types = try aa.alloc([]const u8, manifest.layers.len);
    for (manifest.layers, 0..) |l, i| {
        layer_digests[i] = try digest_mod.Digest.parse(l.digest);
        layer_media_types[i] = l.mediaType;
    }

    var m_digest_buf: [digest_mod.string_length]u8 = undefined;
    const manifest_digest_str = m_digest.toString(&m_digest_buf);

    var container = try state_mod.allocate(
        io,
        gpa,
        env.root_dir,
        ref_text,
        manifest_digest_str,
        opts.name,
    );
    var container_owned = true;
    errdefer if (container_owned) container.deinit(gpa);

    // Triplet now exists on disk. `keep_dirs` controls the errdefer:
    // - rm=false → keep on disk regardless of outcome (keep_dirs = true).
    // - rm=true  → cleanup runs on every return path; flipped to true
    //              after the explicit success-path cleanup so the
    //              errdefer becomes a no-op when control returns.
    var keep_dirs = !opts.rm;
    errdefer if (!keep_dirs) cleanupTriplet(io, env.root_dir, container.id);

    emit(opts, .{ .run_started = .{ .ref = ref_text, .id = container.id } });

    try extract.ensureExtracted(io, gpa, store, layer_digests, layer_media_types);

    const lowerdirs = try buildLowerdirs(aa, env, layer_digests);
    const overlays_abspath = try std.fmt.allocPrint(
        aa,
        "{s}/{s}/{s}",
        .{ env.root_abspath, state_mod.overlays_subpath, container.id[0..] },
    );

    var mounted = try deps.mount_fn(io, gpa, overlays_abspath, lowerdirs);
    var overlay_owned = true;
    errdefer if (overlay_owned) deps.unmount_fn(io, &mounted) catch {};

    emit(opts, .overlay_mounted);

    var bundle_subpath_buf: [state_mod.bundles_subpath.len + 1 + state_mod.id_short_length]u8 = undefined;
    const bundle_subpath = std.fmt.bufPrint(&bundle_subpath_buf, "{s}/{s}", .{
        state_mod.bundles_subpath, container.id[0..],
    }) catch unreachable;

    var bundle_dir = try env.root_dir.openDir(io, bundle_subpath, .{});
    defer bundle_dir.close(io);

    try bundle_mod.compose(io, gpa, bundle_dir, container, img_cfg, opts.overrides, mounted);

    emit(opts, .bundle_ready);

    // libcrun owns `<runtime>/<id>/` and writes its own `state.json`
    // there. Keep it separate from rind's `containers/<id>/state.json`
    // metadata to avoid the "already exists" collision.
    try env.root_dir.createDirPath(io, state_mod.runtime_subpath);
    const state_root_abs = try std.fmt.allocPrint(
        aa,
        "{s}/{s}",
        .{ env.root_abspath, state_mod.runtime_subpath },
    );
    const bundle_abs = try std.fmt.allocPrint(
        aa,
        "{s}/{s}/{s}",
        .{ env.root_abspath, state_mod.bundles_subpath, container.id[0..] },
    );

    emit(opts, .{ .started = .{ .pid = 0 } });

    const console_socket_path: ?[]const u8 = if (opts.overrides.tty)
        try std.fmt.allocPrint(aa, "{s}/console.sock", .{bundle_abs})
    else
        null;

    const pid_file_path = try std.fmt.allocPrint(aa, "{s}/pid", .{bundle_abs});

    var watcher = PidWatcher{
        .io = io,
        .gpa = gpa,
        .root_dir = env.root_dir,
        .container_id = container.id,
        .pid_file_path = pid_file_path,
    };
    const watcher_thread_opt: ?std.Thread = std.Thread.spawn(
        .{},
        PidWatcher.run,
        .{&watcher},
    ) catch |err| spawn_blk: {
        std.log.debug("rind: pid watcher spawn failed: {s}", .{@errorName(err)});
        break :spawn_blk null;
    };
    var watcher_joined = false;
    defer if (!watcher_joined) {
        watcher.done.store(true, .release);
        if (watcher_thread_opt) |t| t.join();
    };

    const status = try deps.run_fn(io, gpa, .{
        .id = container.id[0..],
        .state_root = state_root_abs,
        .bundle = bundle_abs,
        .tty = opts.overrides.tty,
        .console_socket_path = console_socket_path,
        .pid_file_path = pid_file_path,
    });

    watcher.done.store(true, .release);
    if (watcher_thread_opt) |t| t.join();
    watcher_joined = true;

    const exit_code: u8, const signal: u8 = switch (status) {
        .exit => |c| .{ c, 0 },
        .signal => |s| .{ 0, s },
    };

    state_mod.transition(io, gpa, env.root_dir, container.id[0..], .{
        .status = .exited,
        .exit_code = @intCast(exit_code),
        .signal = @intCast(signal),
    }) catch |err| {
        std.log.debug("rind: state transition exited failed: {s}", .{@errorName(err)});
    };

    emit(opts, .{ .exited = .{ .code = exit_code, .signal = signal } });

    try deps.unmount_fn(io, &mounted);
    overlay_owned = false;

    var removed = false;
    if (opts.rm) {
        try strictCleanupTriplet(io, env.root_dir, container.id);
        keep_dirs = true;
        emit(opts, .removed);
        removed = true;
    }

    const out: RunResult = .{
        .container_id = container.id,
        .exit_code = exit_code,
        .signal = signal,
        .removed = removed,
    };

    container.deinit(gpa);
    container_owned = false;
    return out;
}

fn emit(opts: RunOptions, ev: RunEvent) void {
    if (opts.progress_fn) |f| f(opts.progress_ctx, ev);
}

/// Build the absolute lowerdir paths overlay.mount expects, in OCI
/// oldest-first order. Allocations land on the supplied arena.
fn buildLowerdirs(
    aa: Allocator,
    env: Env,
    layer_digests: []const digest_mod.Digest,
) Allocator.Error![][]const u8 {
    const out = try aa.alloc([]const u8, layer_digests.len);
    for (layer_digests, 0..) |dig, i| {
        var hex_buf: [digest_mod.hex_length]u8 = undefined;
        const hex = dig.encodedHex(&hex_buf);
        out[i] = try std.fmt.allocPrint(aa, "{s}/{s}/{s}/{s}", .{
            env.root_abspath, env.store_subpath, layout.extracted_subpath, hex,
        });
    }
    return out;
}

/// Match a parsed `Index` against the user-supplied ref. Mirrors
/// `cli/inspect.zig:findDescriptor` — digest refs match on
/// `desc.digest`; tag refs match the literal `raw_ref` against the
/// `org.opencontainers.image.ref.name` annotation written by
/// `Store.tag` at pull time.
fn findDescriptor(
    index: layout.Index,
    ref: image_ref.ImageRef,
    raw_ref: []const u8,
) ?layout.Descriptor {
    for (index.manifests) |desc| {
        if (ref.digest) |d| {
            if (std.mem.eql(u8, desc.digest, d)) return desc;
        } else {
            const ann = desc.annotations orelse continue;
            const name = ann.map.get(layout.ref_name_annotation) orelse continue;
            if (std.mem.eql(u8, name, raw_ref)) return desc;
        }
    }
    return null;
}

/// Best-effort triplet teardown for the errdefer cleanup path. Errors
/// are swallowed because errdefer cannot return them; the success
/// path uses `strictCleanupTriplet` instead.
fn cleanupTriplet(
    io: Io,
    root_dir: Io.Dir,
    id: [state_mod.id_short_length]u8,
) void {
    deleteOne(io, root_dir, state_mod.containers_subpath, id) catch {};
    deleteOne(io, root_dir, state_mod.bundles_subpath, id) catch {};
    deleteOne(io, root_dir, state_mod.overlays_subpath, id) catch {};
}

/// Same as `cleanupTriplet` but propagates the first error. Used on
/// the success path with `--rm` so the caller sees real failures
/// (e.g. EBUSY because the overlay never unmounted).
fn strictCleanupTriplet(
    io: Io,
    root_dir: Io.Dir,
    id: [state_mod.id_short_length]u8,
) Io.Dir.DeleteTreeError!void {
    try deleteOne(io, root_dir, state_mod.containers_subpath, id);
    try deleteOne(io, root_dir, state_mod.bundles_subpath, id);
    try deleteOne(io, root_dir, state_mod.overlays_subpath, id);
}

fn deleteOne(
    io: Io,
    root_dir: Io.Dir,
    parent_subpath: []const u8,
    id: [state_mod.id_short_length]u8,
) Io.Dir.DeleteTreeError!void {
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ parent_subpath, id[0..] }) catch unreachable;
    try root_dir.deleteTree(io, path);
}

const pid_watcher_max_attempts: u32 = 500;
const pid_watcher_poll_interval_ns: i64 = 20 * std.time.ns_per_ms;

/// Polls libcrun's pid_file while a foreground run is in flight. On
/// the first successful read, transitions `state.json` to `.running`
/// and exits. Bounded by `pid_watcher_max_attempts` (~10s wall) and
/// short-circuited via `done` once the orchestrator returns from
/// `run_fn`. All transition failures are best-effort: a watcher that
/// cannot persist `.running` doesn't break the run; the subsequent
/// `.exited` transition will still record exit_code/signal.
const PidWatcher = struct {
    io: Io,
    gpa: Allocator,
    root_dir: Io.Dir,
    container_id: [state_mod.id_short_length]u8,
    pid_file_path: []const u8,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *PidWatcher) void {
        var attempts: u32 = 0;
        while (attempts < pid_watcher_max_attempts) : (attempts += 1) {
            if (readPidFile(self.pid_file_path)) |pid| {
                state_mod.transition(self.io, self.gpa, self.root_dir, self.container_id[0..], .{
                    .status = .running,
                    .pid = pid,
                }) catch |err| {
                    std.log.debug("rind: state transition running failed: {s}", .{@errorName(err)});
                };
                return;
            } else |_| {}

            if (self.done.load(.acquire)) return;

            const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = pid_watcher_poll_interval_ns };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }
};

fn readPidFile(path: []const u8) !i32 {
    var path_buf: [256:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        path_z.ptr,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    defer _ = std.os.linux.close(fd);

    var buf: [32]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    if (n == 0) return error.EmptyPidFile;

    const trimmed = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    if (trimmed.len == 0) return error.EmptyPidFile;
    return std.fmt.parseInt(i32, trimmed, 10);
}

const testing = std.testing;

const fixture_layer_diff_id: []const u8 =
    "sha256:0000000000000000000000000000000000000000000000000000000000000000";

const fixture_cfg_template: []const u8 =
    \\{{
    \\  "architecture": "amd64",
    \\  "os": "linux",
    \\  "created": "2024-05-02T12:00:00Z",
    \\  "rootfs": {{ "type": "layers", "diff_ids": ["{s}"] }},
    \\  "config": {{
    \\    "Cmd": ["/bin/true"],
    \\    "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
    \\  }}
    \\}}
;

/// Build the smallest possible tar+gzip layer (just the 1024-byte
/// EOF trailer — two zeroed 512-byte blocks) and stash it in the
/// store. Mirrors the gzip-fixture pattern in `image/extract.zig`'s
/// own test block.
fn putEmptyLayer(io: Io, gpa: Allocator, store: *layout.Store) !digest_mod.Digest {
    const tar_buf: [1024]u8 = .{0} ** 1024;

    var gz: Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer gz.deinit();

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&gz.writer, &window, .gzip, .default);
    try compress.writer.writeAll(&tar_buf);
    try compress.finish();
    try gz.writer.flush();

    const gzip_bytes = gz.written();
    const dig = digest_mod.Hasher.hash(gzip_bytes);
    var blob_reader: Io.Reader = .fixed(gzip_bytes);
    try store.putBlob(io, dig, &blob_reader);
    return dig;
}

const FixtureImage = struct {
    manifest_digest: digest_mod.Digest,
    config_digest: digest_mod.Digest,
    layer_digest: digest_mod.Digest,
    ref_name: []const u8,
};

fn seedFixtureImage(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    ref_name: []const u8,
) !FixtureImage {
    const layer_dig = try putEmptyLayer(io, gpa, store);
    var layer_dig_buf: [digest_mod.string_length]u8 = undefined;
    const layer_dig_str = layer_dig.toString(&layer_dig_buf);

    const cfg_bytes = try std.fmt.allocPrint(gpa, fixture_cfg_template, .{fixture_layer_diff_id});
    defer gpa.free(cfg_bytes);
    const cfg_dig = digest_mod.Hasher.hash(cfg_bytes);
    var cfg_reader: Io.Reader = .fixed(cfg_bytes);
    try store.putBlob(io, cfg_dig, &cfg_reader);

    var cfg_dig_buf: [digest_mod.string_length]u8 = undefined;
    const cfg_dig_str = cfg_dig.toString(&cfg_dig_buf);

    const manifest_bytes = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schemaVersion": 2,
        \\  "mediaType": "application/vnd.oci.image.manifest.v1+json",
        \\  "config": {{
        \\    "mediaType": "application/vnd.oci.image.config.v1+json",
        \\    "digest": "{s}",
        \\    "size": {d}
        \\  }},
        \\  "layers": [
        \\    {{
        \\      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
        \\      "digest": "{s}",
        \\      "size": {d}
        \\    }}
        \\  ]
        \\}}
    , .{ cfg_dig_str, cfg_bytes.len, layer_dig_str, 0 });
    defer gpa.free(manifest_bytes);

    const m_dig = digest_mod.Hasher.hash(manifest_bytes);
    var m_reader: Io.Reader = .fixed(manifest_bytes);
    try store.putBlob(io, m_dig, &m_reader);

    try store.tag(io, gpa, ref_name, .{
        .media_type = "application/vnd.oci.image.manifest.v1+json",
        .digest = m_dig,
        .size = manifest_bytes.len,
    });

    return .{
        .manifest_digest = m_dig,
        .config_digest = cfg_dig,
        .layer_digest = layer_dig,
        .ref_name = ref_name,
    };
}

const Capture = struct {
    events: std.ArrayList(EventTag),
    gpa: Allocator,

    const EventTag = enum { run_started, overlay_mounted, bundle_ready, started, exited, removed };

    fn init(gpa: Allocator) Capture {
        return .{ .events = .empty, .gpa = gpa };
    }
    fn deinit(self: *Capture) void {
        self.events.deinit(self.gpa);
    }
    fn record(ctx: ?*anyopaque, ev: RunEvent) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        const tag: EventTag = switch (ev) {
            .run_started => .run_started,
            .overlay_mounted => .overlay_mounted,
            .bundle_ready => .bundle_ready,
            .started => .started,
            .exited => .exited,
            .removed => .removed,
        };
        self.events.append(self.gpa, tag) catch {};
    }
};

/// Stub overlay backend used by every unit test. Allocates the
/// merged/upper/work strings on the testing allocator (so unmount
/// can free them) and returns a synthetic `MountedOverlay` whose
/// merged_path is a NUL-terminated dummy string the bundle composer
/// can dereference.
const StubOverlay = struct {
    fn mount(
        io: Io,
        gpa: Allocator,
        container_dir: []const u8,
        lowerdirs: []const []const u8,
    ) overlay_mod.OverlayError!overlay_mod.MountedOverlay {
        _ = io;
        _ = lowerdirs;
        const merged = try std.fmt.allocPrintSentinel(gpa, "{s}/merged", .{container_dir}, 0);
        const upper = try std.fmt.allocPrint(gpa, "{s}/upper", .{container_dir});
        const work = try std.fmt.allocPrint(gpa, "{s}/work", .{container_dir});
        return .{
            .allocator = gpa,
            .merged_path = merged,
            .upper_path = upper,
            .work_path = work,
            .joined_userns = false,
            .host_sub_uid = null,
            .host_sub_gid = null,
        };
    }
    fn unmount(io: Io, mounted: *overlay_mod.MountedOverlay) overlay_mod.OverlayError!void {
        _ = io;
        mounted.deinit();
    }
};

const StubExit = struct {
    var status: core.ExitStatus = .{ .exit = 0 };
    var fail: ?core.RuntimeError = null;
    var calls: usize = 0;

    fn reset(s: core.ExitStatus, f: ?core.RuntimeError) void {
        status = s;
        fail = f;
        calls = 0;
    }
    fn run(io: Io, gpa: Allocator, req: core.RunRequest) core.RuntimeError!core.ExitStatus {
        _ = io;
        _ = gpa;
        _ = req;
        calls += 1;
        if (fail) |e| return e;
        return status;
    }
};

fn openTriplet(
    io: Io,
    root_dir: Io.Dir,
    id: [state_mod.id_short_length]u8,
) struct { containers: bool, bundles: bool, overlays: bool } {
    var buf: [128]u8 = undefined;

    const cpath = std.fmt.bufPrint(&buf, "containers/{s}", .{id[0..]}) catch unreachable;
    const c_ok = if (root_dir.access(io, cpath, .{})) |_| true else |_| false;

    const bpath = std.fmt.bufPrint(&buf, "bundles/{s}", .{id[0..]}) catch unreachable;
    const b_ok = if (root_dir.access(io, bpath, .{})) |_| true else |_| false;

    const opath = std.fmt.bufPrint(&buf, "overlays/{s}", .{id[0..]}) catch unreachable;
    const o_ok = if (root_dir.access(io, opath, .{})) |_| true else |_| false;

    return .{ .containers = c_ok, .bundles = b_ok, .overlays = o_ok };
}

const TestRoot = struct {
    tmp: std.testing.TmpDir,
    abs: []u8,
    dir: Io.Dir,

    fn init(gpa: Allocator) !TestRoot {
        var tmp = testing.tmpDir(.{ .iterate = true });
        const cwd = try std.process.currentPathAlloc(testing.io, gpa);
        defer gpa.free(cwd);
        const abs = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "rind" });
        const dir = try tmp.dir.createDirPathOpen(testing.io, "rind", .{
            .open_options = .{ .iterate = true },
        });
        return .{ .tmp = tmp, .abs = abs, .dir = dir };
    }
    fn deinit(self: *TestRoot, gpa: Allocator) void {
        self.dir.close(testing.io);
        self.tmp.cleanup();
        gpa.free(self.abs);
        self.* = undefined;
    }
};

test "runImage emits expected event sequence with stub runtime" {
    const gpa = testing.allocator;
    var root = try TestRoot.init(gpa);
    defer root.deinit(gpa);

    var store = try layout.Store.init(testing.io, root.dir, "store");
    defer store.close(testing.io);

    const fix = try seedFixtureImage(testing.io, gpa, &store, "alpine:test");

    StubExit.reset(.{ .exit = 0 }, null);
    var cap = Capture.init(gpa);
    defer cap.deinit();

    const result = try runImage(
        testing.io,
        gpa,
        &store,
        .{ .root_dir = root.dir, .root_abspath = root.abs },
        "alpine:test",
        .{
            .progress_ctx = @ptrCast(&cap),
            .progress_fn = Capture.record,
        },
        .{
            .run_fn = StubExit.run,
            .mount_fn = StubOverlay.mount,
            .unmount_fn = StubOverlay.unmount,
        },
    );

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqual(@as(u8, 0), result.signal);
    try testing.expectEqual(false, result.removed);
    try testing.expectEqual(@as(usize, 1), StubExit.calls);

    try testing.expectEqual(@as(usize, 5), cap.events.items.len);
    try testing.expectEqual(Capture.EventTag.run_started, cap.events.items[0]);
    try testing.expectEqual(Capture.EventTag.overlay_mounted, cap.events.items[1]);
    try testing.expectEqual(Capture.EventTag.bundle_ready, cap.events.items[2]);
    try testing.expectEqual(Capture.EventTag.started, cap.events.items[3]);
    try testing.expectEqual(Capture.EventTag.exited, cap.events.items[4]);

    _ = fix;
}

test "runImage --rm removes triplet on success" {
    const gpa = testing.allocator;
    var root = try TestRoot.init(gpa);
    defer root.deinit(gpa);

    var store = try layout.Store.init(testing.io, root.dir, "store");
    defer store.close(testing.io);

    _ = try seedFixtureImage(testing.io, gpa, &store, "alpine:test");

    StubExit.reset(.{ .exit = 0 }, null);
    var cap = Capture.init(gpa);
    defer cap.deinit();

    const result = try runImage(
        testing.io,
        gpa,
        &store,
        .{ .root_dir = root.dir, .root_abspath = root.abs },
        "alpine:test",
        .{
            .rm = true,
            .progress_ctx = @ptrCast(&cap),
            .progress_fn = Capture.record,
        },
        .{
            .run_fn = StubExit.run,
            .mount_fn = StubOverlay.mount,
            .unmount_fn = StubOverlay.unmount,
        },
    );

    try testing.expectEqual(true, result.removed);

    const present = openTriplet(testing.io, root.dir, result.container_id);
    try testing.expectEqual(false, present.containers);
    try testing.expectEqual(false, present.bundles);
    try testing.expectEqual(false, present.overlays);

    try testing.expectEqual(Capture.EventTag.removed, cap.events.items[cap.events.items.len - 1]);
}

test "runImage --rm removes triplet on libcrun failure" {
    const gpa = testing.allocator;
    var root = try TestRoot.init(gpa);
    defer root.deinit(gpa);

    var store = try layout.Store.init(testing.io, root.dir, "store");
    defer store.close(testing.io);

    _ = try seedFixtureImage(testing.io, gpa, &store, "alpine:test");

    StubExit.reset(.{ .exit = 0 }, core.RuntimeError.LibcrunFailure);

    const err = runImage(
        testing.io,
        gpa,
        &store,
        .{ .root_dir = root.dir, .root_abspath = root.abs },
        "alpine:test",
        .{ .rm = true },
        .{
            .run_fn = StubExit.run,
            .mount_fn = StubOverlay.mount,
            .unmount_fn = StubOverlay.unmount,
        },
    );
    try testing.expectError(core.RuntimeError.LibcrunFailure, err);

    // Walk containers/ and assert nothing remains: errdefer cleanup
    // ran. There's no way to recover the id post-error, so iterate.
    var containers_dir = try root.dir.openDir(testing.io, "containers", .{ .iterate = true });
    defer containers_dir.close(testing.io);
    var it = containers_dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 0), n);
}

test "runImage returns ImageNotPresent when ref not in index" {
    const gpa = testing.allocator;
    var root = try TestRoot.init(gpa);
    defer root.deinit(gpa);

    var store = try layout.Store.init(testing.io, root.dir, "store");
    defer store.close(testing.io);

    StubExit.reset(.{ .exit = 0 }, null);

    try testing.expectError(RunError.ImageNotPresent, runImage(
        testing.io,
        gpa,
        &store,
        .{ .root_dir = root.dir, .root_abspath = root.abs },
        "alpine:missing",
        .{},
        .{
            .run_fn = StubExit.run,
            .mount_fn = StubOverlay.mount,
            .unmount_fn = StubOverlay.unmount,
        },
    ));

    // pull=true: same outcome (no client wired).
    try testing.expectError(RunError.ImageNotPresent, runImage(
        testing.io,
        gpa,
        &store,
        .{ .root_dir = root.dir, .root_abspath = root.abs },
        "alpine:missing",
        .{ .pull = true },
        .{
            .run_fn = StubExit.run,
            .mount_fn = StubOverlay.mount,
            .unmount_fn = StubOverlay.unmount,
        },
    ));

    // No container directories should have been created.
    const containers_exists = if (root.dir.access(testing.io, "containers", .{})) |_| true else |_| false;
    try testing.expectEqual(false, containers_exists);
}

test "runImage signal exit surfaces signal in result" {
    const gpa = testing.allocator;
    var root = try TestRoot.init(gpa);
    defer root.deinit(gpa);

    var store = try layout.Store.init(testing.io, root.dir, "store");
    defer store.close(testing.io);

    _ = try seedFixtureImage(testing.io, gpa, &store, "alpine:test");

    StubExit.reset(.{ .signal = 2 }, null);

    const result = try runImage(
        testing.io,
        gpa,
        &store,
        .{ .root_dir = root.dir, .root_abspath = root.abs },
        "alpine:test",
        .{},
        .{
            .run_fn = StubExit.run,
            .mount_fn = StubOverlay.mount,
            .unmount_fn = StubOverlay.unmount,
        },
    );

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqual(@as(u8, 2), result.signal);
}

const StubExitWritesPidFile = struct {
    const recorded_pid: i32 = 12345;

    fn run(io: Io, gpa: Allocator, req: core.RunRequest) core.RuntimeError!core.ExitStatus {
        _ = io;
        _ = gpa;
        const pid_file_path = req.pid_file_path orelse return .{ .exit = 0 };

        var path_buf: [256:0]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{pid_file_path}) catch
            return .{ .exit = 0 };

        const fd = std.posix.openatZ(
            std.posix.AT.FDCWD,
            path_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o600,
        ) catch return .{ .exit = 0 };
        defer _ = std.os.linux.close(fd);

        var contents_buf: [16]u8 = undefined;
        const contents = std.fmt.bufPrint(&contents_buf, "{d}\n", .{recorded_pid}) catch
            return .{ .exit = 0 };
        _ = std.os.linux.write(fd, contents.ptr, contents.len);

        const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 60 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);

        return .{ .exit = 0 };
    }
};

test "runImage walks state.json from created -> running -> exited" {
    const gpa = testing.allocator;
    var root = try TestRoot.init(gpa);
    defer root.deinit(gpa);

    var store = try layout.Store.init(testing.io, root.dir, "store");
    defer store.close(testing.io);

    _ = try seedFixtureImage(testing.io, gpa, &store, "alpine:test");

    const result = try runImage(
        testing.io,
        gpa,
        &store,
        .{ .root_dir = root.dir, .root_abspath = root.abs },
        "alpine:test",
        .{},
        .{
            .run_fn = StubExitWritesPidFile.run,
            .mount_fn = StubOverlay.mount,
            .unmount_fn = StubOverlay.unmount,
        },
    );

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqual(@as(u8, 0), result.signal);

    var parsed = try state_mod.read(testing.io, gpa, root.dir, result.container_id[0..]);
    defer parsed.deinit();

    try testing.expectEqual(state_mod.Status.exited, parsed.value.status);
    try testing.expectEqual(@as(?i32, 0), parsed.value.exit_code);
    try testing.expectEqual(@as(?i32, 0), parsed.value.signal);
    try testing.expectEqual(@as(?i32, StubExitWritesPidFile.recorded_pid), parsed.value.pid);
}
