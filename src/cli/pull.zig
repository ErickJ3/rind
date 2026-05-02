//! `rind pull <image>` subcommand.
//!
//! Argparse, validation, and orchestration glue. The actual fetch is
//! delegated to `pull.zig` via `PullDeps.pull_fn` so tests can swap
//! in a stub that returns synthetic results without standing up a
//! mock registry.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const clap = @import("clap");

const pull_mod = @import("../pull.zig");
const manifest_mod = @import("../registry/manifest.zig");
const client_mod = @import("../registry/client.zig");
const layout = @import("../store/layout.zig");
const digest_mod = @import("../image/digest.zig");

const exit = @import("exit.zig");
const output = @import("output.zig");

/// Output format. `human` is the TTY default; `json` is the
/// schema-versioned NDJSON contract.
pub const OutputKind = enum { human, json };

/// Validated argv for `rind pull`. All slices borrow from the
/// caller-owned argument iterator's arena.
pub const PullArgs = struct {
    /// Image reference (`alpine:3.19`, `ghcr.io/x/y@sha256:...`).
    image: []const u8,
    /// Output format. `--output {human,json}`. Defaults to human.
    output: OutputKind = .human,
    /// `-q/--quiet`. Drops per-event human output; summary kept.
    quiet: bool = false,
    /// `--platform <str>`. Optional; rejected unless equal to host.
    platform: ?[]const u8 = null,
};

/// Pull-handler dependency injection. Production wires the real
/// `pull_mod.pullImage`; tests substitute a stub to drive
/// the handler's exit-mapping and rendering logic in isolation.
pub const PullDeps = struct {
    /// The orchestrator entry point. Must match `pull_mod.pullImage`.
    pull_fn: *const fn (
        Io,
        Allocator,
        *layout.Store,
        *client_mod.Client,
        []const u8,
        pull_mod.PullOptions,
    ) pull_mod.PullError!pull_mod.PullResult = pull_mod.pullImage,
};

/// Canonical host platform (e.g. `"linux/amd64"`). Used to validate
/// `--platform` flags. Comptime so the string is interned.
pub const expected_platform: []const u8 = std.fmt.comptimePrint(
    "{s}/{s}",
    .{ manifest_mod.default_platform.os, manifest_mod.default_platform.architecture },
);

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\    --output <kind>     Output format: human (default) or json.
    \\-q, --quiet             Suppress per-event output (terse summary still prints).
    \\    --platform <str>    Target platform (only the host is supported in MVP).
    \\<str>                   Image reference (e.g. alpine:3.19).
    \\
);

const value_parsers = .{
    .str = clap.parsers.string,
    .kind = clap.parsers.enumeration(OutputKind),
};

/// One-line usage banner. Stable enough that scripts can grep it.
pub const usage_line: []const u8 = "Usage: rind pull [--output human|json] [-q|--quiet] [--platform <plat>] <image>";

/// Parse argv (after the `pull` subcommand has already been peeled
/// off) into a validated `PullArgs`. `iter` is consumed; `gpa` backs
/// clap's working arena. Returns `error.Usage` for any structural
/// problem and writes a one-line diagnostic to `err_writer`.
pub fn parseArgs(
    gpa: Allocator,
    iter: anytype,
    err_writer: *Io.Writer,
) !PullArgs {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, value_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch {
        err_writer.print("{s}\n", .{usage_line}) catch {};
        return error.Usage;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try err_writer.print("{s}\n", .{usage_line});
        return error.Usage;
    }

    const image = res.positionals[0] orelse {
        try err_writer.print("{s}\n", .{usage_line});
        return error.Usage;
    };

    // Owned-by-arena strings would dangle once `res.deinit()` runs;
    // dupe out anything we want to keep. The caller (`run`) frees
    // these via the supplied gpa once it's done with `PullArgs`.
    const image_owned = try gpa.dupe(u8, image);
    errdefer gpa.free(image_owned);

    const platform_owned: ?[]const u8 = if (res.args.platform) |p|
        try gpa.dupe(u8, p)
    else
        null;

    return .{
        .image = image_owned,
        .output = res.args.output orelse .human,
        .quiet = res.args.quiet != 0,
        .platform = platform_owned,
    };
}

/// Free strings owned by `args`. Mirrors the dupes done in
/// `parseArgs`; `gpa` must be the same allocator.
pub fn freeArgs(gpa: Allocator, args: PullArgs) void {
    gpa.free(args.image);
    if (args.platform) |p| gpa.free(p);
}

/// Run the pull. The renderer is invoked for each progress event,
/// once for the success summary, and once for an error message on
/// failure. Errors propagate; `main.zig` maps them to exit codes.
pub fn run(
    io: Io,
    gpa: Allocator,
    store: *layout.Store,
    client: *client_mod.Client,
    args: PullArgs,
    out: *output.Renderer,
    deps: PullDeps,
) !void {
    if (args.platform) |p| {
        if (!std.mem.eql(u8, p, expected_platform)) {
            try out.on_error(out.ctx, "unsupported --platform (host-only in MVP)");
            return error.UnsupportedPlatform;
        }
    }

    const trampoline_ctx: TrampolineCtx = .{ .renderer = out };
    const opts: pull_mod.PullOptions = .{
        .progress_ctx = @ptrCast(@constCast(&trampoline_ctx)),
        .progress_fn = trampoline,
    };

    var result = deps.pull_fn(io, gpa, store, client, args.image, opts) catch |err| {
        try out.on_error(out.ctx, @errorName(err));
        return err;
    };
    defer result.deinit();

    try out.on_summary(out.ctx, .{ .ref = args.image, .result = &result });
}

const TrampolineCtx = struct {
    renderer: *output.Renderer,
};

fn trampoline(ctx: ?*anyopaque, ev: pull_mod.PullEvent) void {
    const self: *const TrampolineCtx = @ptrCast(@alignCast(ctx.?));
    // Renderer write failures are swallowed: the orchestrator's
    // ProgressFn signature is `void`, so we cannot propagate. A
    // broken stdout pipe will surface again on the next write the
    // handler attempts (summary), where it can return as an error.
    self.renderer.on_event(self.renderer.ctx, ev) catch {};
}

const testing = std.testing;

const SliceIter = struct {
    items: []const []const u8,
    idx: usize = 0,
    pub fn next(self: *SliceIter) ?[]const u8 {
        if (self.idx >= self.items.len) return null;
        defer self.idx += 1;
        return self.items[self.idx];
    }
};

fn parseFromSlice(gpa: Allocator, argv: []const []const u8, err_writer: *Io.Writer) !PullArgs {
    var iter: SliceIter = .{ .items = argv };
    return parseArgs(gpa, &iter, err_writer);
}

test "parseArgs accepts bare image" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(gpa, &.{"alpine:3.19"}, &err_buf.writer);
    defer freeArgs(gpa, a);

    try testing.expectEqualStrings("alpine:3.19", a.image);
    try testing.expectEqual(OutputKind.human, a.output);
    try testing.expect(!a.quiet);
    try testing.expectEqual(@as(?[]const u8, null), a.platform);
}

test "parseArgs accepts --output json and --quiet" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();

    const a = try parseFromSlice(
        gpa,
        &.{ "--output", "json", "-q", "ghcr.io/x/y:1" },
        &err_buf.writer,
    );
    defer freeArgs(gpa, a);

    try testing.expectEqual(OutputKind.json, a.output);
    try testing.expect(a.quiet);
    try testing.expectEqualStrings("ghcr.io/x/y:1", a.image);
}

test "parseArgs rejects missing positional" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(error.Usage, parseFromSlice(gpa, &.{}, &err_buf.writer));
}

test "parseArgs rejects unknown --output value" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(
        error.Usage,
        parseFromSlice(gpa, &.{ "--output", "bogus", "alpine" }, &err_buf.writer),
    );
}

test "parseArgs rejects unknown flag" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(
        error.Usage,
        parseFromSlice(gpa, &.{ "--bogus", "alpine" }, &err_buf.writer),
    );
}

test "parseArgs --help is treated as a usage exit" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    try testing.expectError(
        error.Usage,
        parseFromSlice(gpa, &.{"--help"}, &err_buf.writer),
    );
}

test "parseArgs accepts --platform that matches host" {
    const gpa = testing.allocator;
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    const a = try parseFromSlice(
        gpa,
        &.{ "--platform", expected_platform, "alpine" },
        &err_buf.writer,
    );
    defer freeArgs(gpa, a);
    try testing.expect(a.platform != null);
}

const StubState = struct {
    return_err: ?pull_mod.PullError = null,
};

threadlocal var stub_state: StubState = .{};

fn stubPullSuccess(
    _: Io,
    gpa: Allocator,
    _: *layout.Store,
    _: *client_mod.Client,
    _: []const u8,
    opts: pull_mod.PullOptions,
) pull_mod.PullError!pull_mod.PullResult {
    if (stub_state.return_err) |e| return e;

    var d: digest_mod.Digest = undefined;
    @memset(&d.bytes, 0xaa);

    if (opts.progress_fn) |f| {
        f(opts.progress_ctx, .{ .manifest = .{ .digest = d, .media_type = .oci_manifest, .size = 100 } });
        f(opts.progress_ctx, .{ .blob_started = .{ .digest = d, .kind = .config, .size = 50 } });
        f(opts.progress_ctx, .{ .blob_done = .{ .digest = d, .kind = .config, .hit_cache = false } });
        f(opts.progress_ctx, .{ .done = .{ .manifest_digest = d } });
    }

    const arena = std.heap.ArenaAllocator.init(gpa);
    return pull_mod.PullResult{
        .manifest_digest = d,
        .config_digest = d,
        .layer_digests = &.{},
        .arena = arena,
    };
}

fn dummyStoreAndClient(io: Io, gpa: Allocator, tmp: *std.testing.TmpDir) !struct {
    store: layout.Store,
    http: std.http.Client,
    client: client_mod.Client,
} {
    var store = try layout.Store.init(io, tmp.dir, "store");
    errdefer store.close(io);
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    errdefer http_client.deinit();
    const client = client_mod.Client.init(gpa, io, &http_client, client_mod.Provider.anonymous);
    return .{ .store = store, .http = http_client, .client = client };
}

test "run drives renderer and reports success" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var bundle = try dummyStoreAndClient(io, gpa, &tmp);
    defer bundle.store.close(io);
    defer bundle.http.deinit();
    defer bundle.client.deinit();

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    stub_state = .{};
    const args: PullArgs = .{ .image = "alpine:3.19" };
    try run(io, gpa, &bundle.store, &bundle.client, args, &r, .{ .pull_fn = stubPullSuccess });

    try testing.expect(std.mem.indexOf(u8, out_buf.written(), "Pulled alpine:3.19") != null);
}

test "run surfaces UnsupportedPlatform on non-host platform" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var bundle = try dummyStoreAndClient(io, gpa, &tmp);
    defer bundle.store.close(io);
    defer bundle.http.deinit();
    defer bundle.client.deinit();

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    const args: PullArgs = .{ .image = "alpine:3.19", .platform = "windows/i386" };
    try testing.expectError(
        error.UnsupportedPlatform,
        run(io, gpa, &bundle.store, &bundle.client, args, &r, .{ .pull_fn = stubPullSuccess }),
    );
    try testing.expectEqual(exit.Code.usage, exit.mapErrorToExitCode(error.UnsupportedPlatform));
}

test "run forwards orchestrator errors and maps to exit codes" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var bundle = try dummyStoreAndClient(io, gpa, &tmp);
    defer bundle.store.close(io);
    defer bundle.http.deinit();
    defer bundle.client.deinit();

    var out_buf: Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Io.Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var human: output.Human = .{
        .writer = &out_buf.writer,
        .err_writer = &err_buf.writer,
        .quiet = false,
    };
    var r = human.renderer();

    // Network failure → exit 3.
    stub_state = .{ .return_err = error.ConnectionRefused };
    try testing.expectError(
        error.ConnectionRefused,
        run(io, gpa, &bundle.store, &bundle.client, .{ .image = "x:1" }, &r, .{ .pull_fn = stubPullSuccess }),
    );
    try testing.expectEqual(exit.Code.network, exit.mapErrorToExitCode(error.ConnectionRefused));

    // Verification failure → exit 4.
    stub_state = .{ .return_err = error.DigestMismatch };
    try testing.expectError(
        error.DigestMismatch,
        run(io, gpa, &bundle.store, &bundle.client, .{ .image = "x:1" }, &r, .{ .pull_fn = stubPullSuccess }),
    );
    try testing.expectEqual(exit.Code.verification, exit.mapErrorToExitCode(error.DigestMismatch));

    // Unsupported layer → exit 1 (generic).
    stub_state = .{ .return_err = error.UnsupportedLayerMediaType };
    try testing.expectError(
        error.UnsupportedLayerMediaType,
        run(io, gpa, &bundle.store, &bundle.client, .{ .image = "x:1" }, &r, .{ .pull_fn = stubPullSuccess }),
    );
    try testing.expectEqual(exit.Code.generic, exit.mapErrorToExitCode(error.UnsupportedLayerMediaType));

    // Reset for any later tests.
    stub_state = .{};
}
