//! Output renderers for `rind pull`.
//!
//! Two formats are supported behind a single `Renderer` vtable:
//!
//!   * **Human** — terse one-line-per-event output. `--quiet` keeps
//!     only the final summary. No multi-line redraw; deferred to v0.2.
//!   * **JSON** — newline-delimited, schema-versioned. The shape is
//!     the **stable contract miru depends on**; bumping it requires a
//!     `schema_version` change. See `docs/rind.md` § "Integration with
//!     miru".
//!
//! Both renderers write to a caller-owned `Io.Writer`. They never log
//! to stderr — diagnostic lines belong in `std.log`.

const std = @import("std");
const Io = std.Io;

const pull_mod = @import("../pull.zig");
const run_mod = @import("../run.zig");
const digest_mod = @import("../image/digest.zig");

/// Stable JSON event-stream version. Bumping this is a contract
/// break; any consumer (miru) keys behavior off it.
///
/// v2 (T14): introduced the `pull_started` event and rearranged
/// `blob_done` emission so non-cached slots fire as each blob lands
/// rather than after the whole pool joins. Cached slots fire
/// `blob_done` before the pool runs. Field shapes for existing
/// events are unchanged.
///
/// v3 (T18): non-cached `blob_done` and `extracted` are now emitted
/// from worker threads (download / extract pools) in completion
/// order rather than slot order. The two event kinds may also
/// interleave because layer extraction now runs in parallel with
/// any still-finishing downloads of later layers. Cached
/// `blob_done` ordering is unchanged. Field shapes for existing
/// events are unchanged.
pub const schema_version: u32 = 3;

/// Fields needed to render the final summary line. The renderer never
/// allocates — all strings borrow from caller-owned storage.
pub const SummaryInput = struct {
    /// User-supplied image reference (`alpine:3.19`, etc.). Echoed
    /// back verbatim so miru can correlate.
    ref: []const u8,
    /// Output of the orchestrator. Borrowed; renderer must not keep it.
    result: *const pull_mod.PullResult,
};

/// Fields needed to render the final run summary. Distinct from
/// `SummaryInput` because pull's summary speaks in layers/bytes and
/// run's speaks in container-id/exit-code/signal.
pub const RunSummaryInput = struct {
    /// User-supplied image reference. Echoed for correlation.
    ref: []const u8,
    /// Orchestrator outcome. Borrowed; renderer must not keep it.
    result: *const run_mod.RunResult,
};

/// Vtable handed to the pull and run handlers. Decouples each handler
/// from the concrete output format so the same call-graph runs under
/// tests (capturing renderer) and production. Pull-only and run-only
/// methods coexist on the same vtable; consumers route by verb.
pub const Renderer = struct {
    /// Renderer state. Pointer-stable for the life of a single command.
    ctx: ?*anyopaque,
    /// Called once per `PullEvent` in orchestrator-order.
    on_event: *const fn (?*anyopaque, pull_mod.PullEvent) Io.Writer.Error!void,
    /// Called once after the pull orchestrator returns successfully.
    on_summary: *const fn (?*anyopaque, SummaryInput) Io.Writer.Error!void,
    /// Called once per `RunEvent` in orchestrator-order. T24.
    on_run_event: *const fn (?*anyopaque, run_mod.RunEvent) Io.Writer.Error!void,
    /// Called once after the run orchestrator returns successfully. T24.
    on_run_summary: *const fn (?*anyopaque, RunSummaryInput) Io.Writer.Error!void,
    /// Called when the handler is about to return a non-zero exit
    /// code. `msg` is a short user-facing description; renderers may
    /// elaborate (JSON wraps it in an envelope, human writes it raw
    /// to stderr).
    on_error: *const fn (?*anyopaque, msg: []const u8) Io.Writer.Error!void,
};

/// Stateful human-format renderer. The state is just the writer
/// handle and a `quiet` flag — no buffering beyond what the
/// underlying `Io.Writer` already does.
pub const Human = struct {
    /// Output sink (typically stdout).
    writer: *Io.Writer,
    /// Error sink (typically stderr). Used only by `on_error` and the
    /// JSON renderer's `on_error`.
    err_writer: *Io.Writer,
    /// When set, drop everything except the final summary line.
    quiet: bool,
    /// When true, `std.Progress` owns the live UI on `err_writer`.
    /// The renderer suppresses the per-event lines it would
    /// otherwise print on stdout (they'd interleave with the
    /// progress tree and add nothing the tree isn't already
    /// showing). The terse `manifest` line is also dropped — the
    /// full digest reappears in the summary.
    progress_active: bool = false,
    /// Layer byte total accumulated as `blob_started` events arrive.
    /// Used to render the summary without re-walking the result.
    total_bytes: u64 = 0,
    /// Layer count tracked the same way.
    layer_count: usize = 0,
    /// `blob_done` (layer, !hit_cache) count. Zero at end ⇒ nothing
    /// new pulled ⇒ "Image is up to date" status line.
    cache_misses: usize = 0,

    /// Return a `Renderer` view over `*self`. `*self` must outlive
    /// every renderer call.
    pub fn renderer(self: *Human) Renderer {
        return .{
            .ctx = self,
            .on_event = onEvent,
            .on_summary = onSummary,
            .on_run_event = onRunEvent,
            .on_run_summary = onRunSummary,
            .on_error = onError,
        };
    }

    fn onEvent(ctx: ?*anyopaque, ev: pull_mod.PullEvent) Io.Writer.Error!void {
        const self: *Human = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .pull_started => |p| {
                if (self.quiet) return;
                try self.writer.print("Pulling {s}\n", .{p.ref});
            },
            .manifest => |m| {
                if (self.quiet or self.progress_active) return;
                var buf: [digest_mod.string_length]u8 = undefined;
                try self.writer.print(
                    "{s}\n",
                    .{shortDigest(m.digest.toString(&buf))},
                );
            },
            .blob_started => |b| {
                if (b.kind == .layer) {
                    self.total_bytes +%= b.size;
                    self.layer_count += 1;
                }
            },
            .blob_done => |b| {
                if (b.kind == .layer and !b.hit_cache) self.cache_misses += 1;
                // `std.Progress` already shows per-blob progress on
                // stderr; emitting a per-event line on stdout would
                // just duplicate it.
                if (self.progress_active) return;
                if (self.quiet) return;
                var buf: [digest_mod.string_length]u8 = undefined;
                const status: []const u8 = if (b.hit_cache) "hit " else "miss";
                const kind: []const u8 = switch (b.kind) {
                    .config => "config",
                    .layer => "layer ",
                };
                try self.writer.print(
                    "{s} {s} {s}\n",
                    .{ shortDigest(b.digest.toString(&buf)), kind, status },
                );
            },
            .extracted => |x| {
                // Same reasoning as `blob_done`: the live progress
                // tree on stderr is the source of truth here.
                if (self.progress_active) return;
                if (self.quiet) return;
                var buf: [digest_mod.string_length]u8 = undefined;
                try self.writer.print(
                    "extract {s}\n",
                    .{shortDigest(x.digest.toString(&buf))},
                );
            },
            .done => {},
        }
        try self.writer.flush();
    }

    fn onSummary(ctx: ?*anyopaque, sum: SummaryInput) Io.Writer.Error!void {
        const self: *Human = @ptrCast(@alignCast(ctx.?));
        // "Image is up to date" only makes sense in the live-UI
        // path; `--no-progress` and JSON callers expect the verbose
        // "Pulled …" line regardless.
        const all_cached = self.progress_active and self.cache_misses == 0 and self.layer_count > 0;
        if (!all_cached) {
            try self.writer.print(
                "Pulled {s} ({d} layers, {d} bytes)\n",
                .{ sum.ref, self.layer_count, self.total_bytes },
            );
        }
        var dig_buf: [digest_mod.string_length]u8 = undefined;
        try self.writer.print(
            "Digest: {s}\n",
            .{sum.result.manifest_digest.toString(&dig_buf)},
        );
        if (all_cached) {
            try self.writer.print("Status: Image is up to date for {s}\n", .{sum.ref});
        }
        try self.writer.flush();
    }

    fn onError(ctx: ?*anyopaque, msg: []const u8) Io.Writer.Error!void {
        const self: *Human = @ptrCast(@alignCast(ctx.?));
        try self.err_writer.print("error: {s}\n", .{msg});
        try self.err_writer.flush();
    }

    fn onRunEvent(ctx: ?*anyopaque, ev: run_mod.RunEvent) Io.Writer.Error!void {
        _ = ctx;
        // Default human output for `rind run` matches Docker: only the
        // container's own stdout/stderr lands on stdout. Per-step
        // progress drops to debug logs on stderr (gated by
        // `RIND_LOG=rind=debug` via `main.rindLogFn`), so pipelines
        // (`rind run … | wc -l`) stay clean and the renderer doesn't
        // shout over short-lived containers like `echo hi`. The JSON
        // renderer below keeps the full event stream — that's the
        // machine-readable contract miru consumes.
        switch (ev) {
            .run_started => |r| std.log.debug("run_started ref={s} id={s}", .{ r.ref, r.id[0..] }),
            .overlay_mounted => std.log.debug("overlay_mounted", .{}),
            .bundle_ready => std.log.debug("bundle_ready", .{}),
            .started => |s| std.log.debug("started pid={d}", .{s.pid}),
            .exited => |e| std.log.debug("exited code={d} signal={d}", .{ e.code, e.signal }),
            .removed => std.log.debug("removed", .{}),
        }
    }

    fn onRunSummary(ctx: ?*anyopaque, sum: RunSummaryInput) Io.Writer.Error!void {
        _ = ctx;
        std.log.debug("run_summary id={s} code={d} signal={d}", .{
            sum.result.container_id[0..],
            sum.result.exit_code,
            sum.result.signal,
        });
    }
};

/// Truncate `"sha256:<64-hex>"` to `"sha256:<12-hex>"` for terminal
/// output. Pure; the input slice is returned aliased on short input.
fn shortDigest(s: []const u8) []const u8 {
    const prefix_len: usize = "sha256:".len;
    const short_hex: usize = 12;
    if (s.len <= prefix_len + short_hex) return s;
    return s[0 .. prefix_len + short_hex];
}

/// JSON-format renderer. Emits NDJSON (one event per line). Field
/// order is fixed by hand — `std.json.Stringify` is avoided here
/// because the wire format is a stable contract and reordering
/// fields silently would be a contract break.
pub const Json = struct {
    /// Output sink (typically stdout).
    writer: *Io.Writer,
    /// Error sink (typically stderr).
    err_writer: *Io.Writer,

    /// See `Human.renderer`.
    pub fn renderer(self: *Json) Renderer {
        return .{
            .ctx = self,
            .on_event = onEvent,
            .on_summary = onSummary,
            .on_run_event = onRunEvent,
            .on_run_summary = onRunSummary,
            .on_error = onError,
        };
    }

    fn onEvent(ctx: ?*anyopaque, ev: pull_mod.PullEvent) Io.Writer.Error!void {
        const self: *Json = @ptrCast(@alignCast(ctx.?));
        try writeEvent(self.writer, ev);
        try self.writer.flush();
    }

    fn onSummary(ctx: ?*anyopaque, sum: SummaryInput) Io.Writer.Error!void {
        const self: *Json = @ptrCast(@alignCast(ctx.?));
        var dig_buf: [digest_mod.string_length]u8 = undefined;
        try self.writer.print(
            "{{\"schema_version\":{d},\"event\":\"summary\",\"ref\":",
            .{schema_version},
        );
        try writeJsonString(self.writer, sum.ref);
        try self.writer.print(
            ",\"manifest_digest\":\"{s}\",\"layer_count\":{d}}}\n",
            .{
                sum.result.manifest_digest.toString(&dig_buf),
                sum.result.layer_digests.len,
            },
        );
        try self.writer.flush();
    }

    fn onError(ctx: ?*anyopaque, msg: []const u8) Io.Writer.Error!void {
        const self: *Json = @ptrCast(@alignCast(ctx.?));
        try self.err_writer.print(
            "{{\"schema_version\":{d},\"event\":\"error\",\"message\":",
            .{schema_version},
        );
        try writeJsonString(self.err_writer, msg);
        try self.err_writer.writeAll("}\n");
        try self.err_writer.flush();
    }

    fn onRunEvent(ctx: ?*anyopaque, ev: run_mod.RunEvent) Io.Writer.Error!void {
        const self: *Json = @ptrCast(@alignCast(ctx.?));
        try writeRunEvent(self.writer, ev);
        try self.writer.flush();
    }

    fn onRunSummary(ctx: ?*anyopaque, sum: RunSummaryInput) Io.Writer.Error!void {
        const self: *Json = @ptrCast(@alignCast(ctx.?));
        try self.writer.print(
            "{{\"schema_version\":{d},\"event\":\"run_summary\",\"ref\":",
            .{schema_version},
        );
        try writeJsonString(self.writer, sum.ref);
        try self.writer.print(
            ",\"container_id\":\"{s}\",\"exit_code\":{d},\"signal\":{d},\"removed\":{s}}}\n",
            .{
                sum.result.container_id[0..],
                sum.result.exit_code,
                sum.result.signal,
                boolName(sum.result.removed),
            },
        );
        try self.writer.flush();
    }
};

/// Write a single `PullEvent` to `w` as one NDJSON line. Public so
/// tests can drive it directly without standing up a `Json` instance.
pub fn writeEvent(w: *Io.Writer, ev: pull_mod.PullEvent) Io.Writer.Error!void {
    var dig_buf: [digest_mod.string_length]u8 = undefined;
    switch (ev) {
        .pull_started => |p| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"pull_started\",\"ref\":",
                .{schema_version},
            );
            try writeJsonString(w, p.ref);
            try w.writeAll("}\n");
        },
        .manifest => |m| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"manifest\",\"digest\":\"{s}\",\"media_type\":\"{s}\",\"size\":{d}}}\n",
                .{ schema_version, m.digest.toString(&dig_buf), m.media_type.toString(), m.size },
            );
        },
        .blob_started => |b| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"blob_started\",\"digest\":\"{s}\",\"kind\":\"{s}\",\"size\":{d}}}\n",
                .{ schema_version, b.digest.toString(&dig_buf), kindName(b.kind), b.size },
            );
        },
        .blob_done => |b| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"blob_done\",\"digest\":\"{s}\",\"kind\":\"{s}\",\"hit_cache\":{s}}}\n",
                .{ schema_version, b.digest.toString(&dig_buf), kindName(b.kind), boolName(b.hit_cache) },
            );
        },
        .extracted => |x| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"extracted\",\"digest\":\"{s}\",\"media_type\":",
                .{ schema_version, x.digest.toString(&dig_buf) },
            );
            try writeJsonString(w, x.media_type);
            try w.writeAll("}\n");
        },
        .done => |d| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"done\",\"manifest_digest\":\"{s}\"}}\n",
                .{ schema_version, d.manifest_digest.toString(&dig_buf) },
            );
        },
    }
}

/// Write a single `RunEvent` to `w` as one NDJSON line. Public so
/// tests can drive it directly without standing up a `Json` instance.
/// Field order is fixed by hand — wire-format stability matters as
/// much for run as for pull.
pub fn writeRunEvent(w: *Io.Writer, ev: run_mod.RunEvent) Io.Writer.Error!void {
    switch (ev) {
        .run_started => |r| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"run_started\",\"ref\":",
                .{schema_version},
            );
            try writeJsonString(w, r.ref);
            try w.print(",\"id\":\"{s}\"}}\n", .{r.id[0..]});
        },
        .overlay_mounted => {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"overlay_mounted\"}}\n",
                .{schema_version},
            );
        },
        .bundle_ready => {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"bundle_ready\"}}\n",
                .{schema_version},
            );
        },
        .started => |s| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"started\",\"pid\":{d}}}\n",
                .{ schema_version, s.pid },
            );
        },
        .exited => |e| {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"exited\",\"code\":{d},\"signal\":{d}}}\n",
                .{ schema_version, e.code, e.signal },
            );
        },
        .removed => {
            try w.print(
                "{{\"schema_version\":{d},\"event\":\"removed\"}}\n",
                .{schema_version},
            );
        },
    }
}

fn kindName(k: pull_mod.BlobKind) []const u8 {
    return switch (k) {
        .config => "config",
        .layer => "layer",
    };
}

fn boolName(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Write `s` as a JSON-quoted string. Handles the small escape set
/// the OCI media-type and ref grammars can actually produce; chars
/// outside ASCII print are escaped as `\u00xx`.
fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

const testing = std.testing;

fn fixedDigest(byte: u8) digest_mod.Digest {
    var d: digest_mod.Digest = undefined;
    @memset(&d.bytes, byte);
    return d;
}

test "writeEvent JSON snapshot — full sequence" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    const m_dig = fixedDigest(0x11);
    const c_dig = fixedDigest(0x22);
    const l1_dig = fixedDigest(0x33);
    const l2_dig = fixedDigest(0x44);

    const events = [_]pull_mod.PullEvent{
        .{ .pull_started = .{ .ref = "alpine:3.19" } },
        .{ .manifest = .{
            .digest = m_dig,
            .media_type = .oci_manifest,
            .size = 512,
        } },
        .{ .blob_started = .{ .digest = c_dig, .kind = .config, .size = 64 } },
        .{ .blob_started = .{ .digest = l1_dig, .kind = .layer, .size = 1024 } },
        .{ .blob_started = .{ .digest = l2_dig, .kind = .layer, .size = 2048 } },
        .{ .blob_done = .{ .digest = l1_dig, .kind = .layer, .hit_cache = true } },
        .{ .blob_done = .{ .digest = c_dig, .kind = .config, .hit_cache = false } },
        .{ .blob_done = .{ .digest = l2_dig, .kind = .layer, .hit_cache = false } },
        .{ .extracted = .{
            .digest = l1_dig,
            .media_type = "application/vnd.oci.image.layer.v1.tar+gzip",
        } },
        .{ .extracted = .{
            .digest = l2_dig,
            .media_type = "application/vnd.oci.image.layer.v1.tar+gzip",
        } },
        .{ .done = .{ .manifest_digest = m_dig } },
    };
    for (events) |ev| try writeEvent(&buf.writer, ev);

    const expected = @embedFile("testdata/pull_events.ndjson");
    try testing.expectEqualStrings(expected, buf.written());
}

test "human renderer formats events terse" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();

    var human: Human = .{ .writer = &out.writer, .err_writer = &err_out.writer, .quiet = false };
    const r = human.renderer();

    const dig = fixedDigest(0xab);
    try r.on_event(r.ctx, .{ .blob_started = .{
        .digest = dig,
        .kind = .layer,
        .size = 100,
    } });
    try r.on_event(r.ctx, .{ .blob_done = .{
        .digest = dig,
        .kind = .layer,
        .hit_cache = true,
    } });

    // blob_started is silent (state-only); blob_done writes one line.
    try testing.expect(std.mem.indexOf(u8, out.written(), "layer  hit") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sha256:abababababab") != null);
}

test "human renderer suppresses per-blob/per-extract lines when progress_active" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();

    var human: Human = .{
        .writer = &out.writer,
        .err_writer = &err_out.writer,
        .quiet = false,
        .progress_active = true,
    };
    const r = human.renderer();

    const dig = fixedDigest(0xab);
    try r.on_event(r.ctx, .{ .pull_started = .{ .ref = "alpine:3.19" } });
    try r.on_event(r.ctx, .{ .manifest = .{
        .digest = dig,
        .media_type = .oci_manifest,
        .size = 100,
    } });
    try r.on_event(r.ctx, .{ .blob_started = .{ .digest = dig, .kind = .layer, .size = 100 } });
    try r.on_event(r.ctx, .{ .blob_done = .{ .digest = dig, .kind = .layer, .hit_cache = false } });
    try r.on_event(r.ctx, .{ .extracted = .{
        .digest = dig,
        .media_type = "application/vnd.oci.image.layer.v1.tar+gzip",
    } });

    // `Pulling` prelude stays on stdout; `manifest`, per-blob, and
    // per-extract lines are all suppressed because `std.Progress`
    // owns the live UI on stderr now.
    try testing.expect(std.mem.indexOf(u8, out.written(), "Pulling alpine:3.19") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sha256:abababababab") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "layer  miss") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "extract sha256:") == null);
    // The Human renderer no longer touches stderr in progress mode
    // (apart from `on_error`, which this test does not exercise).
    try testing.expectEqualStrings("", err_out.written());
}

test "human renderer manifest terse format outside progress mode" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();

    var human: Human = .{ .writer = &out.writer, .err_writer = &err_out.writer, .quiet = false };
    const r = human.renderer();

    const dig = fixedDigest(0xcd);
    try r.on_event(r.ctx, .{ .manifest = .{
        .digest = dig,
        .media_type = .oci_manifest,
        .size = 100,
    } });

    // Short digest only; no bytes/media_type noise.
    try testing.expect(std.mem.indexOf(u8, out.written(), "sha256:cdcdcdcdcdcd") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "bytes") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "manifest") == null);
}

test "human renderer --quiet drops events but keeps summary" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();

    var human: Human = .{ .writer = &out.writer, .err_writer = &err_out.writer, .quiet = true };
    const r = human.renderer();

    const dig = fixedDigest(0x33);
    try r.on_event(r.ctx, .{ .blob_started = .{ .digest = dig, .kind = .layer, .size = 7 } });
    try r.on_event(r.ctx, .{ .blob_done = .{ .digest = dig, .kind = .layer, .hit_cache = false } });
    try testing.expectEqualStrings("", out.written());

    // Summary still goes through.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = pull_mod.PullResult{
        .manifest_digest = fixedDigest(0x01),
        .config_digest = fixedDigest(0x02),
        .layer_digests = &.{},
        .arena = arena,
    };
    try r.on_summary(r.ctx, .{ .ref = "alpine:3.19", .result = &result });
    try testing.expect(std.mem.indexOf(u8, out.written(), "Pulled alpine:3.19") != null);
}

test "writeRunEvent JSON snapshot — full sequence" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    const id = [12]u8{ 'a', 'b', 'c', '1', '2', '3', 'd', 'e', 'f', '4', '5', '6' };
    const events = [_]run_mod.RunEvent{
        .{ .run_started = .{ .ref = "alpine:3.19", .id = id } },
        .overlay_mounted,
        .bundle_ready,
        .{ .started = .{ .pid = 0 } },
        .{ .exited = .{ .code = 0, .signal = 0 } },
        .removed,
    };
    for (events) |ev| try writeRunEvent(&buf.writer, ev);

    const expected = @embedFile("testdata/run_events.ndjson");
    try testing.expectEqualStrings(expected, buf.written());
}

test "human renderer is silent on run events (Docker parity)" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();

    var human: Human = .{ .writer = &out.writer, .err_writer = &err_out.writer, .quiet = false };
    const r = human.renderer();

    const id = [12]u8{ 'a', 'b', 'c', '1', '2', '3', 'd', 'e', 'f', '4', '5', '6' };
    try r.on_run_event(r.ctx, .{ .run_started = .{ .ref = "alpine:3.19", .id = id } });
    try r.on_run_event(r.ctx, .overlay_mounted);
    try r.on_run_event(r.ctx, .bundle_ready);
    try r.on_run_event(r.ctx, .{ .started = .{ .pid = 0 } });
    try r.on_run_event(r.ctx, .{ .exited = .{ .code = 0, .signal = 0 } });
    try r.on_run_event(r.ctx, .removed);

    // Default human writes nothing — progress lives in std.log.debug,
    // gated on `RIND_LOG=rind=debug` by `main.rindLogFn`.
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "human renderer is silent on run summary (Docker parity)" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();

    var human: Human = .{ .writer = &out.writer, .err_writer = &err_out.writer, .quiet = false };
    const r = human.renderer();

    const id = [12]u8{ 'a', 'b', 'c', '1', '2', '3', 'd', 'e', 'f', '4', '5', '6' };
    const result = run_mod.RunResult{
        .container_id = id,
        .exit_code = 0,
        .signal = 0,
        .removed = true,
    };
    try r.on_run_summary(r.ctx, .{ .ref = "alpine:3.19", .result = &result });
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "writeJsonString escapes the small set we care about" {
    const gpa = testing.allocator;
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try writeJsonString(&buf.writer, "a\"b\\c\nd\te\x01");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001\"", buf.written());
}
