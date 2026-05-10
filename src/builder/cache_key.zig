//! Layer cache key derivation. Pure function: given a parent layer
//! digest, a parsed Instruction, the resolved env+shell at the point
//! of execution, and an optional build context, returns a deterministic
//! 32-byte sha256.
//!
//! Canonicalisation contract. DO NOT change without bumping
//! `cache_version`; every user's cache invalidates if any rule shifts:
//!   * Object keys sorted ascending by UTF-8 byte order; never omitted.
//!   * Optional fields emitted explicitly as `null`.
//!   * Arrays preserve source order.
//!   * Spans NEVER included (line/col shifts must not perturb keys).
//!   * Booleans `true`/`false`.
//!   * Strings escaped per RFC 8259 via std.json.Stringify.encodeJsonString.
//!   * UTF-8 strings are passed through verbatim. NFC normalisation is
//!     NOT applied in v1; adding it later is a breaking change and MUST
//!     bump `cache_version`.
//!   * ENV/LABEL maps and StepEnv vars are deduplicated last-write-wins,
//!     then sorted by key, emitted as JSON objects (not arrays).
//!   * RUN form (shell vs exec) is part of the key. Two surface forms
//!     with identical effective argv produce different keys, since
//!     shell-form goes through `/bin/sh -c` (word splitting, glob
//!     expansion) and exec-form does not.
//!   * CMD/ENTRYPOINT/HEALTHCHECK do NOT consume StepEnv: they record
//!     into the image config and execute at container runtime, not at
//!     build time.
//!   * COPY/ADD require a Context; metadata/RUN reject one. The COPY
//!     subset digest is hashed AFTER the canonical-JSON bytes, not
//!     embedded inside them, so the canonical form stays inspectable.
//!   * `COPY --from=<stage|image>` resolution against another stage's
//!     rootfs is deferred. Until then, all COPY/ADD subsets are taken
//!     against the build context. The future stage executor will widen
//!     the API to accept an alternate source.
//!
//! Pure: no IO inside `derive` itself. The optional Context handed in
//! has already done its disk walk; `derive` only walks its in-memory
//! entry list when computing a subset digest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const builder_context = @import("context.zig");
const digest_mod = @import("../image/digest.zig");
const image_ref = @import("../image/ref.zig");
const lex = @import("lex.zig");
const parse = @import("parse.zig");

/// Cache contract version. Bump on every observable change to canonical
/// encoding so older keys never collide with new ones.
pub const cache_version: u32 = 1;

/// Length of a cache key in raw bytes. Re-exported so callers do not
/// have to reach into the digest module for the constant.
pub const key_length: usize = digest_mod.byte_length;

/// Raw 32-byte sha256 cache key for one instruction in a build chain.
pub const Key = [key_length]u8;

/// Resolved per-step environment. Caller (the future build state
/// machine) computes this by walking ARG/ENV/SHELL up to but not
/// including the current step.
pub const StepEnv = struct {
    /// Effective env entries at this step. Order does not matter; the
    /// canonical encoding deduplicates last-write-wins and sorts by
    /// key.
    vars: []const parse.KeyValue,
    /// Active SHELL argv. Order is preserved verbatim. The Docker
    /// default is `&.{ "/bin/sh", "-c" }`.
    shell: []const []const u8,
};

/// Failure modes for cache-key derivation.
pub const CacheKeyError = error{
    /// A string field carried bytes that are not valid UTF-8.
    InvalidUtf8,
    /// COPY or ADD called without a Context. Caller must supply the
    /// build context so the subset digest can be hashed in.
    MissingContext,
    /// Metadata or RUN instruction called with a non-null Context. The
    /// Context is unused for these and rejected to surface wiring bugs.
    UnexpectedContext,
    /// A glob pattern in the instruction was malformed.
    BadPattern,
} || Allocator.Error || Io.Writer.Error;

/// Derive the cache key for one instruction. Returns
/// `sha256(parent || canonical_json(instruction, step_env))` for
/// metadata and RUN; for COPY/ADD the build-context subset digest is
/// hashed in as a third segment after the canonical JSON.
pub fn derive(
    gpa: Allocator,
    parent: Key,
    instruction: parse.Instruction,
    step_env: StepEnv,
    context: ?*const builder_context.Context,
) CacheKeyError!Key {
    const expects_context = switch (instruction) {
        .copy, .add => true,
        else => false,
    };
    if (expects_context and context == null) return CacheKeyError.MissingContext;
    if (!expects_context and context != null) return CacheKeyError.UnexpectedContext;

    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try writeCanonical(gpa, &buf.writer, instruction, step_env);

    var hasher = digest_mod.Hasher.init();
    hasher.update(&parent);
    hasher.update(buf.written());

    if (expects_context) {
        const ctx = context.?;
        const sources = switch (instruction) {
            .copy => |c| c.sources,
            .add => |c| c.sources,
            else => unreachable,
        };
        const subset = ctx.digestSubset(gpa, sources) catch |err| switch (err) {
            error.BadPattern => return CacheKeyError.BadPattern,
        };
        hasher.update(&subset);
    }

    return hasher.final().bytes;
}

/// Emit the canonical-JSON encoding of an instruction (folding the
/// step env into RUN). Exposed so the regression harness can author
/// and diff goldens against the inspectable form.
pub fn writeCanonical(
    gpa: Allocator,
    w: *Io.Writer,
    instruction: parse.Instruction,
    step_env: StepEnv,
) CacheKeyError!void {
    switch (instruction) {
        .from => |v| try writeFrom(w, v),
        .run => |v| try writeRun(gpa, w, v, step_env),
        .copy => |v| try writeCopyLike(w, v, "copy"),
        .add => |v| try writeCopyLike(w, v, "add"),
        .env => |v| try writeEntries(gpa, w, v.entries, "env"),
        .workdir => |v| try writeSingle(w, v.value, "workdir"),
        .user => |v| try writeSingle(w, v.value, "user"),
        .cmd => |v| try writeRunPayloadOnly(w, v, "cmd"),
        .entrypoint => |v| try writeRunPayloadOnly(w, v, "entrypoint"),
        .expose => |v| try writeManyStrings(w, v.values, "expose"),
        .label => |v| try writeEntries(gpa, w, v.entries, "label"),
        .arg => |v| try writeArg(w, v),
        .stopsignal => |v| try writeSingle(w, v.value, "stopsignal"),
        .healthcheck => |v| try writeHealthcheck(w, v.value),
        .shell => |v| try writeManyStrings(w, v.values, "shell"),
        .volume => |v| try writeManyStrings(w, v.values, "volume"),
        .maintainer => |v| try writeSingle(w, v.value, "maintainer"),
        .onbuild => |v| try writeOnBuild(w, v),
    }
}

fn writeFrom(w: *Io.Writer, v: parse.From) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"alias\":");
    try writeOptStr(w, v.alias);
    try w.writeAll(",\"directive\":\"from\"");
    try w.writeAll(",\"image\":");
    try writeOptImageRef(w, v.image);
    try w.writeAll(",\"is_scratch\":");
    try writeBool(w, v.is_scratch);
    try w.writeAll(",\"platform\":");
    try writeOptStr(w, v.platform);
    try w.writeAll(",\"raw\":");
    try writeStr(w, v.raw);
    try w.writeAll(",\"stage_ref\":");
    try writeOptStr(w, v.stage_ref);
    try w.writeByte('}');
}

fn writeRun(
    gpa: Allocator,
    w: *Io.Writer,
    v: parse.Run,
    step_env: StepEnv,
) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"args\":");
    try writeStringArray(w, v.args);
    try w.writeAll(",\"directive\":\"run\"");
    try w.writeAll(",\"env\":");
    try writeKeyValueMap(gpa, w, step_env.vars);
    try w.writeAll(",\"form\":");
    try writeStr(w, @tagName(v.form));
    try w.writeAll(",\"heredocs\":");
    try writeHeredocs(w, v.heredocs);
    try w.writeAll(",\"shell\":");
    try writeStringArray(w, step_env.shell);
    try w.writeByte('}');
}

fn writeRunPayloadOnly(
    w: *Io.Writer,
    v: parse.Run,
    comptime tag: []const u8,
) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"args\":");
    try writeStringArray(w, v.args);
    try w.writeAll(",\"directive\":\"" ++ tag ++ "\"");
    try w.writeAll(",\"form\":");
    try writeStr(w, @tagName(v.form));
    try w.writeAll(",\"heredocs\":");
    try writeHeredocs(w, v.heredocs);
    try w.writeByte('}');
}

fn writeCopyLike(
    w: *Io.Writer,
    v: parse.Copy,
    comptime tag: []const u8,
) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"chmod\":");
    try writeOptStr(w, v.chmod);
    try w.writeAll(",\"chown\":");
    try writeOptStr(w, v.chown);
    try w.writeAll(",\"dest\":");
    try writeStr(w, v.dest);
    try w.writeAll(",\"directive\":\"" ++ tag ++ "\"");
    try w.writeAll(",\"from\":");
    try writeOptStr(w, v.from);
    try w.writeAll(",\"is_add\":");
    try writeBool(w, v.is_add);
    try w.writeAll(",\"sources\":");
    try writeStringArray(w, v.sources);
    try w.writeByte('}');
}

fn writeEntries(
    gpa: Allocator,
    w: *Io.Writer,
    entries: []const parse.KeyValue,
    comptime tag: []const u8,
) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"directive\":\"" ++ tag ++ "\"");
    try w.writeAll(",\"entries\":");
    try writeKeyValueMap(gpa, w, entries);
    try w.writeByte('}');
}

fn writeSingle(
    w: *Io.Writer,
    value: []const u8,
    comptime tag: []const u8,
) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"directive\":\"" ++ tag ++ "\"");
    try w.writeAll(",\"value\":");
    try writeStr(w, value);
    try w.writeByte('}');
}

fn writeManyStrings(
    w: *Io.Writer,
    values: []const []const u8,
    comptime tag: []const u8,
) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"directive\":\"" ++ tag ++ "\"");
    try w.writeAll(",\"values\":");
    try writeStringArray(w, values);
    try w.writeByte('}');
}

fn writeArg(w: *Io.Writer, v: parse.Arg) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"default\":");
    try writeOptStr(w, v.default);
    try w.writeAll(",\"directive\":\"arg\"");
    try w.writeAll(",\"is_global\":");
    try writeBool(w, v.is_global);
    try w.writeAll(",\"name\":");
    try writeStr(w, v.name);
    try w.writeByte('}');
}

fn writeHealthcheck(w: *Io.Writer, hc: parse.Healthcheck) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"directive\":\"healthcheck\"");
    try w.writeAll(",\"value\":");
    switch (hc) {
        .none => try w.writeAll("{\"kind\":\"none\"}"),
        .cmd => |c| {
            try w.writeByte('{');
            try w.writeAll("\"args\":");
            try writeStringArray(w, c.args);
            try w.writeAll(",\"form\":");
            try writeStr(w, @tagName(c.form));
            try w.writeAll(",\"interval\":");
            try writeOptStr(w, c.interval);
            try w.writeAll(",\"kind\":\"cmd\"");
            try w.writeAll(",\"retries\":");
            try writeOptStr(w, c.retries);
            try w.writeAll(",\"start_period\":");
            try writeOptStr(w, c.start_period);
            try w.writeAll(",\"timeout\":");
            try writeOptStr(w, c.timeout);
            try w.writeByte('}');
        },
    }
    try w.writeByte('}');
}

fn writeOnBuild(w: *Io.Writer, v: parse.OnBuild) CacheKeyError!void {
    try w.writeByte('{');
    try w.writeAll("\"directive\":\"onbuild\"");
    try w.writeAll(",\"inner_directive\":");
    try writeStr(w, @tagName(v.inner_directive));
    try w.writeAll(",\"raw_args\":");
    try writeStringArray(w, v.raw_args);
    try w.writeByte('}');
}

fn writeBool(w: *Io.Writer, b: bool) CacheKeyError!void {
    try w.writeAll(if (b) "true" else "false");
}

fn writeStr(w: *Io.Writer, s: []const u8) CacheKeyError!void {
    if (!std.unicode.utf8ValidateSlice(s)) return CacheKeyError.InvalidUtf8;
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn writeOptStr(w: *Io.Writer, v: ?[]const u8) CacheKeyError!void {
    if (v) |s| {
        try writeStr(w, s);
    } else {
        try w.writeAll("null");
    }
}

fn writeStringArray(w: *Io.Writer, arr: []const []const u8) CacheKeyError!void {
    try w.writeByte('[');
    for (arr, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        try writeStr(w, s);
    }
    try w.writeByte(']');
}

fn writeHeredocs(w: *Io.Writer, hds: []const parse.Heredoc) CacheKeyError!void {
    try w.writeByte('[');
    for (hds, 0..) |h, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"body\":");
        try writeStr(w, h.body);
        try w.writeAll(",\"strip_tabs\":");
        try writeBool(w, h.strip_tabs);
        try w.writeAll(",\"tag\":");
        try writeStr(w, h.tag);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn writeOptImageRef(w: *Io.Writer, ref: ?image_ref.ImageRef) CacheKeyError!void {
    if (ref) |r| {
        try w.writeByte('{');
        try w.writeAll("\"digest\":");
        try writeOptStr(w, r.digest);
        try w.writeAll(",\"registry\":");
        try writeStr(w, r.registry);
        try w.writeAll(",\"repository\":");
        try writeStr(w, r.repository);
        try w.writeAll(",\"tag\":");
        try writeOptStr(w, r.tag);
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }
}

fn writeKeyValueMap(
    gpa: Allocator,
    w: *Io.Writer,
    kvs: []const parse.KeyValue,
) CacheKeyError!void {
    if (kvs.len == 0) {
        try w.writeAll("{}");
        return;
    }

    const Indexed = struct { kv: parse.KeyValue, idx: usize };
    const items = try gpa.alloc(Indexed, kvs.len);
    defer gpa.free(items);
    for (kvs, 0..) |kv, i| items[i] = .{ .kv = kv, .idx = i };

    std.sort.block(Indexed, items, {}, struct {
        fn lt(_: void, a: Indexed, b: Indexed) bool {
            return std.mem.order(u8, a.kv.key, b.kv.key) == .lt;
        }
    }.lt);

    try w.writeByte('{');
    var first = true;
    var i: usize = 0;
    while (i < items.len) {
        var j = i;
        while (j + 1 < items.len and std.mem.eql(u8, items[j + 1].kv.key, items[i].kv.key)) j += 1;
        var best = i;
        var k = i + 1;
        while (k <= j) : (k += 1) {
            if (items[k].idx > items[best].idx) best = k;
        }
        if (!first) try w.writeByte(',');
        first = false;
        try writeStr(w, items[best].kv.key);
        try w.writeByte(':');
        try writeStr(w, items[best].kv.value);
        i = j + 1;
    }
    try w.writeByte('}');
}

const testing = std.testing;

const zero32: Key = @splat(0);
const one32: Key = blk: {
    var b: Key = @splat(0);
    b[0] = 1;
    break :blk b;
};
const default_shell_argv: []const []const u8 = &.{ "/bin/sh", "-c" };

fn makeSpan() lex.Span {
    return .{ .offset = 0, .len = 0, .line = 1, .col = 1 };
}

test "derive: same FROM scratch produces same key across calls" {
    const ins: parse.Instruction = .{ .from = .{
        .span = makeSpan(),
        .raw = "scratch",
        .image = null,
        .stage_ref = null,
        .is_scratch = true,
        .alias = null,
        .platform = null,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const k1 = try derive(testing.allocator, zero32, ins, env, null);
    const k2 = try derive(testing.allocator, zero32, ins, env, null);
    try testing.expectEqualSlices(u8, &k1, &k2);
}

test "derive: changing parent changes key" {
    const ins: parse.Instruction = .{ .from = .{
        .span = makeSpan(),
        .raw = "scratch",
        .image = null,
        .stage_ref = null,
        .is_scratch = true,
        .alias = null,
        .platform = null,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const k1 = try derive(testing.allocator, zero32, ins, env, null);
    const k2 = try derive(testing.allocator, one32, ins, env, null);
    try testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "derive: RUN exec same args+env yields stable key across calls" {
    const args = [_][]const u8{ "echo", "hi" };
    const ins: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .exec,
        .args = &args,
        .heredocs = &.{},
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const k1 = try derive(testing.allocator, zero32, ins, env, null);
    const k2 = try derive(testing.allocator, zero32, ins, env, null);
    try testing.expectEqualSlices(u8, &k1, &k2);
}

test "writeCanonical: byte-stable across two calls" {
    const ins: parse.Instruction = .{ .workdir = .{
        .span = makeSpan(),
        .value = "/work",
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    var b1: Io.Writer.Allocating = .init(testing.allocator);
    defer b1.deinit();
    var b2: Io.Writer.Allocating = .init(testing.allocator);
    defer b2.deinit();
    try writeCanonical(testing.allocator, &b1.writer, ins, env);
    try writeCanonical(testing.allocator, &b2.writer, ins, env);
    try testing.expectEqualStrings(b1.written(), b2.written());
}

test "derive: WORKDIR /a vs /b differ" {
    const a: parse.Instruction = .{ .workdir = .{ .span = makeSpan(), .value = "/a" } };
    const b: parse.Instruction = .{ .workdir = .{ .span = makeSpan(), .value = "/b" } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: WORKDIR span change does not affect key" {
    const a: parse.Instruction = .{ .workdir = .{
        .span = .{ .offset = 0, .len = 0, .line = 1, .col = 1 },
        .value = "/a",
    } };
    const b: parse.Instruction = .{ .workdir = .{
        .span = .{ .offset = 100, .len = 5, .line = 9, .col = 4 },
        .value = "/a",
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expectEqualSlices(u8, &ka, &kb);
}

test "derive: ENV K=1 vs K=2 differ" {
    const e1 = [_]parse.KeyValue{.{ .key = "K", .value = "1" }};
    const e2 = [_]parse.KeyValue{.{ .key = "K", .value = "2" }};
    const a: parse.Instruction = .{ .env = .{ .span = makeSpan(), .entries = &e1 } };
    const b: parse.Instruction = .{ .env = .{ .span = makeSpan(), .entries = &e2 } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: ENV order does not matter" {
    const e1 = [_]parse.KeyValue{
        .{ .key = "K", .value = "1" },
        .{ .key = "K2", .value = "2" },
    };
    const e2 = [_]parse.KeyValue{
        .{ .key = "K2", .value = "2" },
        .{ .key = "K", .value = "1" },
    };
    const a: parse.Instruction = .{ .env = .{ .span = makeSpan(), .entries = &e1 } };
    const b: parse.Instruction = .{ .env = .{ .span = makeSpan(), .entries = &e2 } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expectEqualSlices(u8, &ka, &kb);
}

test "derive: ENV duplicates collapse last-write-wins" {
    const e_dup = [_]parse.KeyValue{
        .{ .key = "K", .value = "1" },
        .{ .key = "K", .value = "2" },
    };
    const e_one = [_]parse.KeyValue{.{ .key = "K", .value = "2" }};
    const a: parse.Instruction = .{ .env = .{ .span = makeSpan(), .entries = &e_dup } };
    const b: parse.Instruction = .{ .env = .{ .span = makeSpan(), .entries = &e_one } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expectEqualSlices(u8, &ka, &kb);
}

test "derive: LABEL keys sort the same as ENV" {
    const e_unsorted = [_]parse.KeyValue{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
    };
    const e_sorted = [_]parse.KeyValue{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    };
    const a: parse.Instruction = .{ .label = .{ .span = makeSpan(), .entries = &e_unsorted } };
    const b: parse.Instruction = .{ .label = .{ .span = makeSpan(), .entries = &e_sorted } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expectEqualSlices(u8, &ka, &kb);
}

test "derive: ARG with default vs without differ" {
    const a: parse.Instruction = .{ .arg = .{
        .span = makeSpan(),
        .name = "X",
        .default = "1",
        .is_global = false,
    } };
    const b: parse.Instruction = .{ .arg = .{
        .span = makeSpan(),
        .name = "X",
        .default = null,
        .is_global = false,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: EXPOSE port-list order preserved" {
    const v1 = [_][]const u8{ "8080", "9090" };
    const v2 = [_][]const u8{ "9090", "8080" };
    const a: parse.Instruction = .{ .expose = .{ .span = makeSpan(), .values = &v1 } };
    const b: parse.Instruction = .{ .expose = .{ .span = makeSpan(), .values = &v2 } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: RUN exec vs shell with equivalent argv differ" {
    const args_exec = [_][]const u8{ "/bin/sh", "-c", "echo hi" };
    const args_shell = [_][]const u8{"echo hi"};
    const a: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .exec,
        .args = &args_exec,
        .heredocs = &.{},
    } };
    const b: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .shell,
        .args = &args_shell,
        .heredocs = &.{},
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: RUN env value change changes key" {
    const args = [_][]const u8{"echo $X"};
    const e1 = [_]parse.KeyValue{.{ .key = "X", .value = "v1" }};
    const e2 = [_]parse.KeyValue{.{ .key = "X", .value = "v2" }};
    const ins: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .shell,
        .args = &args,
        .heredocs = &.{},
    } };
    const env_a: StepEnv = .{ .vars = &e1, .shell = default_shell_argv };
    const env_b: StepEnv = .{ .vars = &e2, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, ins, env_a, null);
    const kb = try derive(testing.allocator, zero32, ins, env_b, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: RUN shell argv change changes key" {
    const args = [_][]const u8{"echo hi"};
    const sh_bash = [_][]const u8{ "/bin/bash", "-c" };
    const sh_sh = [_][]const u8{ "/bin/sh", "-c" };
    const ins: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .shell,
        .args = &args,
        .heredocs = &.{},
    } };
    const env_a: StepEnv = .{ .vars = &.{}, .shell = &sh_bash };
    const env_b: StepEnv = .{ .vars = &.{}, .shell = &sh_sh };
    const ka = try derive(testing.allocator, zero32, ins, env_a, null);
    const kb = try derive(testing.allocator, zero32, ins, env_b, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: RUN env order does not matter" {
    const args = [_][]const u8{"echo"};
    const e_ab = [_]parse.KeyValue{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    };
    const e_ba = [_]parse.KeyValue{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
    };
    const ins: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .shell,
        .args = &args,
        .heredocs = &.{},
    } };
    const env_a: StepEnv = .{ .vars = &e_ab, .shell = default_shell_argv };
    const env_b: StepEnv = .{ .vars = &e_ba, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, ins, env_a, null);
    const kb = try derive(testing.allocator, zero32, ins, env_b, null);
    try testing.expectEqualSlices(u8, &ka, &kb);
}

test "derive: RUN heredoc body change changes key" {
    const args = [_][]const u8{"<<EOF"};
    const h1 = [_]parse.Heredoc{.{ .tag = "EOF", .body = "echo one\n", .strip_tabs = false }};
    const h2 = [_]parse.Heredoc{.{ .tag = "EOF", .body = "echo two\n", .strip_tabs = false }};
    const a: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .shell,
        .args = &args,
        .heredocs = &h1,
    } };
    const b: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .shell,
        .args = &args,
        .heredocs = &h2,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: CMD ignores StepEnv" {
    const args = [_][]const u8{ "/bin/sh", "-c", "echo hi" };
    const e1 = [_]parse.KeyValue{.{ .key = "X", .value = "v1" }};
    const e2 = [_]parse.KeyValue{.{ .key = "X", .value = "v2" }};
    const ins: parse.Instruction = .{ .cmd = .{
        .span = makeSpan(),
        .form = .exec,
        .args = &args,
        .heredocs = &.{},
    } };
    const env_a: StepEnv = .{ .vars = &e1, .shell = default_shell_argv };
    const env_b: StepEnv = .{ .vars = &e2, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, ins, env_a, null);
    const kb = try derive(testing.allocator, zero32, ins, env_b, null);
    try testing.expectEqualSlices(u8, &ka, &kb);
}

test "derive: COPY without context errors" {
    const sources = [_][]const u8{"a.txt"};
    const ins: parse.Instruction = .{ .copy = .{
        .span = makeSpan(),
        .sources = &sources,
        .dest = "/dst",
        .from = null,
        .chown = null,
        .chmod = null,
        .is_add = false,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    try testing.expectError(
        CacheKeyError.MissingContext,
        derive(testing.allocator, zero32, ins, env, null),
    );
}

test "derive: COPY content change changes key" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "v1" });
    var ctx_a = try builder_context.load(testing.io, testing.allocator, tmp.dir);
    defer ctx_a.deinit();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "v2" });
    var ctx_b = try builder_context.load(testing.io, testing.allocator, tmp.dir);
    defer ctx_b.deinit();

    const sources = [_][]const u8{"a.txt"};
    const ins: parse.Instruction = .{ .copy = .{
        .span = makeSpan(),
        .sources = &sources,
        .dest = "/dst",
        .from = null,
        .chown = null,
        .chmod = null,
        .is_add = false,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, ins, env, &ctx_a);
    const kb = try derive(testing.allocator, zero32, ins, env, &ctx_b);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: COPY different sources differ" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "v" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "v" });
    var ctx = try builder_context.load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const src_a = [_][]const u8{"a.txt"};
    const src_b = [_][]const u8{"b.txt"};
    const a: parse.Instruction = .{ .copy = .{
        .span = makeSpan(),
        .sources = &src_a,
        .dest = "/dst",
        .from = null,
        .chown = null,
        .chmod = null,
        .is_add = false,
    } };
    const b: parse.Instruction = .{ .copy = .{
        .span = makeSpan(),
        .sources = &src_b,
        .dest = "/dst",
        .from = null,
        .chown = null,
        .chmod = null,
        .is_add = false,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, &ctx);
    const kb = try derive(testing.allocator, zero32, b, env, &ctx);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: COPY chown change changes key" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "v" });
    var ctx = try builder_context.load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const sources = [_][]const u8{"a.txt"};
    const a: parse.Instruction = .{ .copy = .{
        .span = makeSpan(),
        .sources = &sources,
        .dest = "/dst",
        .from = null,
        .chown = "u:g",
        .chmod = null,
        .is_add = false,
    } };
    const b: parse.Instruction = .{ .copy = .{
        .span = makeSpan(),
        .sources = &sources,
        .dest = "/dst",
        .from = null,
        .chown = "u",
        .chmod = null,
        .is_add = false,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, &ctx);
    const kb = try derive(testing.allocator, zero32, b, env, &ctx);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: ADD vs COPY with identical payload differ" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "v" });
    var ctx = try builder_context.load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const sources = [_][]const u8{"a.txt"};
    const cp: parse.Copy = .{
        .span = makeSpan(),
        .sources = &sources,
        .dest = "/dst",
        .from = null,
        .chown = null,
        .chmod = null,
        .is_add = false,
    };
    const ad: parse.Copy = .{
        .span = cp.span,
        .sources = cp.sources,
        .dest = cp.dest,
        .from = cp.from,
        .chown = cp.chown,
        .chmod = cp.chmod,
        .is_add = true,
    };
    const a: parse.Instruction = .{ .copy = cp };
    const b: parse.Instruction = .{ .add = ad };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, &ctx);
    const kb = try derive(testing.allocator, zero32, b, env, &ctx);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: RUN with non-null context errors" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "" });
    var ctx = try builder_context.load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const args = [_][]const u8{"echo"};
    const ins: parse.Instruction = .{ .run = .{
        .span = makeSpan(),
        .form = .shell,
        .args = &args,
        .heredocs = &.{},
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    try testing.expectError(
        CacheKeyError.UnexpectedContext,
        derive(testing.allocator, zero32, ins, env, &ctx),
    );
}

test "derive: HEALTHCHECK NONE vs CMD differ" {
    const a: parse.Instruction = .{ .healthcheck = .{
        .span = makeSpan(),
        .value = .none,
    } };
    const b_args = [_][]const u8{"curl localhost"};
    const b: parse.Instruction = .{ .healthcheck = .{
        .span = makeSpan(),
        .value = .{ .cmd = .{
            .form = .shell,
            .args = &b_args,
            .interval = null,
            .timeout = null,
            .start_period = null,
            .retries = null,
        } },
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const ka = try derive(testing.allocator, zero32, a, env, null);
    const kb = try derive(testing.allocator, zero32, b, env, null);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "derive: ONBUILD COPY vs literal COPY differ" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "" });
    var ctx = try builder_context.load(testing.io, testing.allocator, tmp.dir);
    defer ctx.deinit();

    const raw_args = [_][]const u8{ "a.txt", "/dst" };
    const ob: parse.Instruction = .{ .onbuild = .{
        .span = makeSpan(),
        .inner_directive = .copy,
        .raw_args = &raw_args,
    } };
    const sources = [_][]const u8{"a.txt"};
    const cp: parse.Instruction = .{ .copy = .{
        .span = makeSpan(),
        .sources = &sources,
        .dest = "/dst",
        .from = null,
        .chown = null,
        .chmod = null,
        .is_add = false,
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    const k_ob = try derive(testing.allocator, zero32, ob, env, null);
    const k_cp = try derive(testing.allocator, zero32, cp, env, &ctx);
    try testing.expect(!std.mem.eql(u8, &k_ob, &k_cp));
}

test "writeCanonical: invalid UTF-8 errors" {
    const bad = [_]u8{ 0xff, 0xfe };
    const ins: parse.Instruction = .{ .workdir = .{
        .span = makeSpan(),
        .value = bad[0..],
    } };
    const env: StepEnv = .{ .vars = &.{}, .shell = default_shell_argv };
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(
        CacheKeyError.InvalidUtf8,
        writeCanonical(testing.allocator, &aw.writer, ins, env),
    );
}
