//! OCI runtime bundle composer.
//!
//! T21 deliverable. `compose` writes `<bundle_dir>/config.json` per the
//! OCI runtime spec v1.0.2. Defaults flow from the image-config (`Env`,
//! `Entrypoint`, `Cmd`, `WorkingDir`, `User`); CLI overrides layer on
//! top via the `RunOverrides` struct (T24 populates it; T22/T23 hand it
//! through unchanged).
//!
//! The composed document is built as a Zig struct tree and rendered by
//! `std.json.Stringify.value`. Field-order stability — required for the
//! snapshot test — comes from struct declaration order; nothing in here
//! relies on hash-map iteration order.
//!
//! Bundle layout written: just `config.json` (rootfs/ stays virtual via
//! `root.path = overlay.merged_path`). The atomic write follows the
//! `state.zig` idiom (`createFileAtomic` + `atomic.link`), so a
//! half-written config never lands on disk.
//!
//! Out of scope here:
//!   - bind-mount overrides (T25),
//!   - pty / `process.terminal=true` (T25),
//!   - AppArmor / SELinux labels (M4),
//!   - `--read-only` rootfs flag (v0.2 polish).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const image_config = @import("../image/config.zig");
const state_mod = @import("state.zig");
const overlay_mod = @import("overlay.zig");
const subid_mod = @import("subid.zig");

/// File name written under `bundle_dir`. The OCI runtime spec mandates
/// this exact name; libcrun looks for it by string literal.
pub const config_filename: []const u8 = "config.json";

/// OCI runtime spec version we target. v1.0.2 is the minimum the rind
/// roadmap pins; v1.1+ fields are not emitted.
pub const oci_version: []const u8 = "1.0.2";

/// CLI-layered overrides. T24 (`rind run` arg parser) populates this;
/// T22/T23 hand it through. Slice ownership: caller-borrowed for the
/// duration of `compose` — no field is duped or freed by this module.
pub const RunOverrides = struct {
    /// Replaces `image_config.config.Entrypoint` when non-null.
    /// `&.{}` (length-zero non-null slice) means `--entrypoint ""` —
    /// drop the image's entrypoint entirely.
    entrypoint: ?[]const []const u8 = null,
    /// Replaces `image_config.config.Cmd` when non-null.
    cmd: ?[]const []const u8 = null,
    /// Appended to `image_config.config.Env`. On KEY collision the last
    /// entry wins (Docker semantics).
    env: []const []const u8 = &.{},
    /// Replaces `image_config.config.WorkingDir` when non-null.
    workdir: ?[]const u8 = null,
    /// Replaces `image_config.config.User` when non-null.
    user: ?[]const u8 = null,
};

/// Closed semantic error set composed at the public entry. Filesystem
/// and JSON-encoding errors propagate through the same return type.
///
/// `subid_mod.SubidError` is folded in so the optional 2-entry
/// uid/gid mapping path can surface `UserLookupFailed`,
/// `SubidNotConfigured`, or `SubidMalformed` with their canonical
/// names. Note: `compose` itself swallows these and falls back to a
/// 1-entry mapping (preserves the M2 fallback path); the variants
/// remain reachable when callers wire a custom `IdSource` that
/// returns them on purpose.
pub const BundleError = error{
    /// Neither image config nor overrides supplied any args. libcrun
    /// would reject the bundle later with `EINVAL`; we surface it now
    /// with a typed name so the orchestrator can map it to a friendly
    /// message.
    EmptyArgs,
    /// `User` field couldn't be parsed as `""`, `<uid>`, or
    /// `<uid>:<gid>` with both numeric. M2 doesn't resolve textual
    /// usernames against the rootfs's `/etc/passwd`.
    UnsupportedUserFormat,
    /// Env entry missing `=` or with an empty key. OCI spec mandates
    /// `KEY=VAL` and KEY non-empty.
    InvalidEnv,
    /// The embedded seccomp default JSON failed to parse. Indicates a
    /// build-time mistake (file replaced with a non-OCI shape).
    InvalidSeccompProfile,
} ||
    subid_mod.SubidError ||
    Allocator.Error ||
    Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.LinkError ||
    Io.File.Writer.Error ||
    std.json.Stringify.Error;

/// Hook for resolving the uid/gid that lands in the 1-entry mapping
/// line. Test seam — production reads `geteuid` / `getegid` directly.
/// Subuid/subgid ranges come off the `MountedOverlay` parameter (the
/// rootless mount path captures them before joining the user
/// namespace); see `resolveIdMappings` for shape rules.
pub const IdSource = struct {
    fetchUid: *const fn (ctx: ?*anyopaque) u32,
    fetchGid: *const fn (ctx: ?*anyopaque) u32,
    ctx: ?*anyopaque = null,
};

fn defaultUidFetch(ctx: ?*anyopaque) u32 {
    _ = ctx;
    return @intCast(std.os.linux.geteuid());
}

fn defaultGidFetch(ctx: ?*anyopaque) u32 {
    _ = ctx;
    return @intCast(std.os.linux.getegid());
}

/// Default resolver. Reads the live host uid/gid via the linux syscall
/// wrappers (matches `runtime/overlay.zig`).
pub const default_id_source: IdSource = .{
    .fetchUid = defaultUidFetch,
    .fetchGid = defaultGidFetch,
};

/// Compose `<bundle_dir>/config.json` per OCI runtime spec v1.0.2.
///
/// `bundle_dir` is an open `Io.Dir` handle to `<root>/bundles/<id>/`,
/// which T19 (`state.allocate`) already created. `compose` writes
/// atomically (`createFileAtomic` + `link`) so partial writes never
/// land on disk.
pub fn compose(
    io: Io,
    gpa: Allocator,
    bundle_dir: Io.Dir,
    container: state_mod.Container,
    img_cfg: image_config.ImageConfig,
    overrides: RunOverrides,
    overlay: overlay_mod.MountedOverlay,
) BundleError!void {
    return composeWithIds(io, gpa, bundle_dir, container, img_cfg, overrides, overlay, default_id_source);
}

/// Test-friendly variant: caller-supplied `id_source` replaces the
/// `geteuid` / `getegid` / `/etc/sub{u,g}id` lookups. Production code
/// calls `compose` instead.
pub fn composeWithIds(
    io: Io,
    gpa: Allocator,
    bundle_dir: Io.Dir,
    container: state_mod.Container,
    img_cfg: image_config.ImageConfig,
    overrides: RunOverrides,
    overlay: overlay_mod.MountedOverlay,
    id_source: IdSource,
) BundleError!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const args = try resolveArgs(aa, img_cfg.config, overrides);
    if (args.len == 0) return BundleError.EmptyArgs;

    const env = try mergeEnv(aa, img_cfg.config, overrides);
    const user = try parseUser(if (overrides.user) |u| u else if (img_cfg.config) |c| c.User orelse "" else "");
    const cwd = if (overrides.workdir) |w| w else if (img_cfg.config) |c| c.WorkingDir orelse "/" else "/";

    // Hand the moby seccomp resolver the same cap set the container
    // actually holds at runtime. Passing `caps_held = &.{}` would drop
    // every `caps:`-gated rule in the upstream profile and leave the
    // container with a tiny allowlist that can't satisfy musl's
    // startup syscalls — manifesting as SIGSEGV on container init for
    // unprivileged alpine runs.
    const seccomp_off = std.c.getenv("RIND_NO_SECCOMP") != null;
    const seccomp: ?Seccomp = if (seccomp_off) null else try resolveSeccomp(aa, .{
        .caps_held = default_caps,
        .image_arch = imageArchToSeccomp(img_cfg.architecture),
    });

    const euid: u32 = id_source.fetchUid(id_source.ctx);
    const egid: u32 = id_source.fetchGid(id_source.ctx);

    const id_maps = try resolveIdMappings(aa, overlay, euid, egid);

    var cgroups_buf: [96]u8 = undefined;
    const cgroups_path = std.fmt.bufPrint(
        &cgroups_buf,
        "user.slice:rind:{s}",
        .{container.id[0..]},
    ) catch unreachable;

    var hostname_buf: [state_mod.id_short_length]u8 = undefined;
    @memcpy(&hostname_buf, container.id[0..]);

    const merged_path: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(overlay.merged_path.ptr)));

    const doc: Document = .{
        .ociVersion = oci_version,
        .process = .{
            .terminal = false,
            .user = .{ .uid = user.uid, .gid = user.gid },
            .args = args,
            .env = env,
            .cwd = cwd,
            .capabilities = default_capabilities,
            .rlimits = &default_rlimits,
            .noNewPrivileges = true,
        },
        .root = .{ .path = merged_path, .readonly = false },
        .hostname = hostname_buf[0..],
        .mounts = &default_mounts,
        .linux = .{
            .uidMappings = id_maps.uid,
            .gidMappings = id_maps.gid,
            .namespaces = &default_namespaces,
            .maskedPaths = default_masked_paths,
            .readonlyPaths = default_readonly_paths,
            .cgroupsPath = cgroups_path,
            .resources = .{},
            .seccomp = seccomp,
        },
    };

    try writeConfigJson(io, bundle_dir, doc);
}

const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

fn writeConfigJson(io: Io, bundle_dir: Io.Dir, doc: Document) (Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.LinkError ||
    Io.File.Writer.Error ||
    std.json.Stringify.Error)!void {
    var atomic = try bundle_dir.createFileAtomic(io, config_filename, .{ .replace = false });
    defer atomic.deinit(io);

    var write_buf: [16384]u8 = undefined;
    var fw = atomic.file.writer(io, &write_buf);
    std.json.Stringify.value(doc, stringify_options, &fw.interface) catch |err| switch (err) {
        error.WriteFailed => return fw.err.?,
    };
    fw.interface.flush() catch return fw.err.?;

    try atomic.link(io);
}

fn resolveArgs(
    aa: Allocator,
    img: ?image_config.ImageConfig.Config,
    overrides: RunOverrides,
) Allocator.Error![][]const u8 {
    const ep_src: []const []const u8 = blk: {
        if (overrides.entrypoint) |o| break :blk o;
        if (img) |c| if (c.Entrypoint) |e| break :blk e;
        break :blk &[_][]const u8{};
    };
    const cmd_src: []const []const u8 = blk: {
        if (overrides.cmd) |o| break :blk o;
        if (img) |c| if (c.Cmd) |cmd| break :blk cmd;
        break :blk &[_][]const u8{};
    };
    var out = try aa.alloc([]const u8, ep_src.len + cmd_src.len);
    for (ep_src, 0..) |s, i| out[i] = s;
    for (cmd_src, 0..) |s, i| out[ep_src.len + i] = s;
    return out;
}

fn mergeEnv(
    aa: Allocator,
    img: ?image_config.ImageConfig.Config,
    overrides: RunOverrides,
) BundleError![][]const u8 {
    var list = std.array_list.Aligned([]const u8, null).empty;

    const base: []const []const u8 = if (img) |c| (c.Env orelse &[_][]const u8{}) else &[_][]const u8{};
    for (base) |e| {
        try validateEnvEntry(e);
        try list.append(aa, e);
    }
    for (overrides.env) |e| {
        try validateEnvEntry(e);
        try replaceOrAppendEnv(aa, &list, e);
    }
    return list.items;
}

fn validateEnvEntry(entry: []const u8) BundleError!void {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return BundleError.InvalidEnv;
    if (eq == 0) return BundleError.InvalidEnv;
}

fn keyOf(entry: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse unreachable;
    return entry[0..eq];
}

fn replaceOrAppendEnv(
    aa: Allocator,
    list: *std.array_list.Aligned([]const u8, null),
    entry: []const u8,
) Allocator.Error!void {
    const new_key = keyOf(entry);
    for (list.items, 0..) |existing, i| {
        if (std.mem.eql(u8, keyOf(existing), new_key)) {
            list.items[i] = entry;
            return;
        }
    }
    try list.append(aa, entry);
}

/// Build the OCI `linux.uidMappings` / `gidMappings` arrays based on
/// the privilege model the overlay mount used.
///
/// **Rootless (`overlay.joined_userns == true`)**: bundle.compose runs
/// inside the namespace `newuidmap`/`newgidmap` already populated. The
/// calling process appears as uid 0 of that namespace; the host
/// subuid range is mapped to ids `1..1+sub.count`. So the OCI mapping
/// must use joined-userns ids, not original host ids:
///   `{containerID:0, hostID:0, size:1}` plus, when a sub range was
///   captured pre-join, `{containerID:1, hostID:1, size:sub.count}`.
///
/// **Privileged (`overlay.joined_userns == false`)**: no namespace
/// transition has happened; `euid`/`egid` are the real host ids. Emit
/// a single `{containerID:0, hostID:euid|egid, size:1}` line.
fn resolveIdMappings(
    aa: Allocator,
    overlay: overlay_mod.MountedOverlay,
    euid: u32,
    egid: u32,
) Allocator.Error!struct { uid: []const IdMapping, gid: []const IdMapping } {
    if (overlay.joined_userns) {
        const uid = try buildJoinedMaps(aa, overlay.host_sub_uid);
        const gid = try buildJoinedMaps(aa, overlay.host_sub_gid);
        return .{ .uid = uid, .gid = gid };
    }
    return .{
        .uid = try singleMap(aa, euid),
        .gid = try singleMap(aa, egid),
    };
}

fn buildJoinedMaps(aa: Allocator, sub: ?subid_mod.Range) Allocator.Error![]const IdMapping {
    if (sub) |s| {
        const out = try aa.alloc(IdMapping, 2);
        out[0] = .{ .containerID = 0, .hostID = 0, .size = 1 };
        // hostID `1` is correct here: inside the joined userns,
        // newuidmap mapped `host_sub.start` → `1` (and the next
        // `sub.count` ids in lockstep). Using `s.start` would point
        // back into the original host id space which the joined
        // userns can't see.
        out[1] = .{ .containerID = 1, .hostID = 1, .size = s.count };
        return out;
    }
    const out = try aa.alloc(IdMapping, 1);
    out[0] = .{ .containerID = 0, .hostID = 0, .size = 1 };
    return out;
}

fn singleMap(aa: Allocator, host_id: u32) Allocator.Error![]const IdMapping {
    const out = try aa.alloc(IdMapping, 1);
    out[0] = .{ .containerID = 0, .hostID = host_id, .size = 1 };
    return out;
}

fn parseUser(text: []const u8) BundleError!struct { uid: u32, gid: u32 } {
    if (text.len == 0) return .{ .uid = 0, .gid = 0 };
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const uid_str = if (colon) |c| text[0..c] else text;
    const gid_str: []const u8 = if (colon) |c| text[c + 1 ..] else "0";
    const uid = std.fmt.parseInt(u32, uid_str, 10) catch return BundleError.UnsupportedUserFormat;
    const gid = std.fmt.parseInt(u32, gid_str, 10) catch return BundleError.UnsupportedUserFormat;
    return .{ .uid = uid, .gid = gid };
}

/// Embedded upstream seccomp profile, kept verbatim from
/// containers/common's moby-shape default (`pkg/seccomp/seccomp.json`,
/// Apache-2.0). The shape is **not** the OCI runtime spec — `archMap`
/// flattens to OCI `architectures` and per-syscall `includes`/`excludes`
/// gates resolve at compose time against the live container env. See
/// `data/LICENSE.seccomp`.
const seccomp_default_bytes: []const u8 = @embedFile("data/seccomp_default.json");

/// Container env passed to the moby→OCI seccomp resolver. M2 runs
/// every container with no extra caps (the bounding set is the
/// 14-cap docker default applied separately via
/// `process.capabilities`); the resolver treats `caps_held` as the
/// set of capabilities a `caps:` filter is allowed to require — empty
/// here means cap-gated allows are dropped, which is the correct
/// rootless behaviour. v0.2 will widen this when `--cap-add` lands.
const SeccompEnv = struct {
    /// Effective cap set. Empty in M2.
    caps_held: []const []const u8,
    /// Architecture family the container's processes execute under.
    /// Drives `archMap` lookup and per-syscall `arches` filters.
    image_arch: []const u8,
};

fn imageArchToSeccomp(image_arch: []const u8) []const u8 {
    if (std.mem.eql(u8, image_arch, "amd64")) return "SCMP_ARCH_X86_64";
    if (std.mem.eql(u8, image_arch, "arm64")) return "SCMP_ARCH_AARCH64";
    if (std.mem.eql(u8, image_arch, "386")) return "SCMP_ARCH_X86";
    if (std.mem.eql(u8, image_arch, "arm")) return "SCMP_ARCH_ARM";
    if (std.mem.eql(u8, image_arch, "s390x")) return "SCMP_ARCH_S390X";
    if (std.mem.eql(u8, image_arch, "mips64le")) return "SCMP_ARCH_MIPSEL64";
    return "SCMP_ARCH_X86_64";
}

const MobyProfile = struct {
    defaultAction: []const u8,
    defaultErrnoRet: ?u32 = null,
    architectures: ?[][]const u8 = null,
    archMap: ?[]MobyArchEntry = null,
    syscalls: []MobySyscall,
};

const MobyArchEntry = struct {
    architecture: []const u8,
    subArchitectures: ?[][]const u8 = null,
};

const MobySyscall = struct {
    names: [][]const u8,
    action: []const u8,
    errnoRet: ?u32 = null,
    args: ?[]SyscallArg = null,
    includes: ?MobyFilter = null,
    excludes: ?MobyFilter = null,
};

const MobyFilter = struct {
    caps: ?[][]const u8 = null,
    arches: ?[][]const u8 = null,
    minKernel: ?[]const u8 = null,
};

/// Parse the embedded moby-shape profile and resolve it against `env`
/// into a pure OCI `linux.seccomp` object. Filter semantics mirror the
/// upstream resolver in github.com/containers/common's seccomp pkg:
///   - `excludes` matches the env  → syscall is dropped.
///   - `includes` non-empty and doesn't match → syscall is dropped.
///   - otherwise the syscall ships through (with `args`/`errnoRet`).
///
/// `minKernel` filters are intentionally treated as always-satisfied:
/// rind's M2 runtime floor is Linux 5.11 (rootless overlayfs) which is
/// already past every minKernel value the upstream profile carries.
fn resolveSeccomp(aa: Allocator, env: SeccompEnv) BundleError!Seccomp {
    const opts: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    };
    const moby = std.json.parseFromSliceLeaky(MobyProfile, aa, seccomp_default_bytes, opts) catch
        return BundleError.InvalidSeccompProfile;

    var arches = std.array_list.Aligned([]const u8, null).empty;
    if (moby.archMap) |entries| {
        for (entries) |e| {
            if (!std.mem.eql(u8, e.architecture, env.image_arch)) continue;
            try arches.append(aa, e.architecture);
            if (e.subArchitectures) |subs| {
                for (subs) |s| try arches.append(aa, s);
            }
        }
    } else if (moby.architectures) |list| {
        for (list) |s| try arches.append(aa, s);
    }

    var rules = std.array_list.Aligned(SyscallRule, null).empty;
    for (moby.syscalls) |sc| {
        if (sc.excludes) |f| if (!filterIsEmpty(f) and filterMatches(f, env, arches.items)) continue;
        if (sc.includes) |f| if (!filterIsEmpty(f) and !filterMatches(f, env, arches.items)) continue;
        try rules.append(aa, .{
            .names = sc.names,
            .action = sc.action,
            .errnoRet = sc.errnoRet,
            .args = sc.args,
        });
    }

    return .{
        .defaultAction = moby.defaultAction,
        .defaultErrnoRet = moby.defaultErrnoRet,
        .architectures = arches.items,
        .syscalls = rules.items,
    };
}

fn filterIsEmpty(f: MobyFilter) bool {
    const no_caps = f.caps == null or f.caps.?.len == 0;
    const no_arches = f.arches == null or f.arches.?.len == 0;
    const no_kernel = f.minKernel == null;
    return no_caps and no_arches and no_kernel;
}

fn filterMatches(f: MobyFilter, env: SeccompEnv, env_arches: []const []const u8) bool {
    if (f.caps) |caps| if (caps.len > 0) {
        for (caps) |needed| {
            if (!containsString(env.caps_held, needed)) return false;
        }
    };
    if (f.arches) |arches| if (arches.len > 0) {
        var any = false;
        for (arches) |a| {
            // The moby profile uses GOARCH-style short names
            // (`amd64`, `arm64`, `x86`, …) while `env_arches` carries
            // libseccomp constants (`SCMP_ARCH_X86_64`, …). Compare
            // through `mobyArchToSeccomp` so amd64/arm64/x86/x32
            // entries actually match on x86_64 hosts — without this,
            // `arch_prctl` and friends fall through to the default
            // ERRNO=ENOSYS arm and the container init segfaults
            // before reaching its first instruction.
            const a_scmp = mobyArchToSeccomp(a);
            if (containsString(env_arches, a_scmp) or containsString(env_arches, a)) {
                any = true;
                break;
            }
        }
        if (!any) return false;
    };
    // minKernel intentionally ignored — runtime floor exceeds every
    // upstream-listed value.
    return true;
}

fn mobyArchToSeccomp(short: []const u8) []const u8 {
    if (std.mem.eql(u8, short, "amd64")) return "SCMP_ARCH_X86_64";
    if (std.mem.eql(u8, short, "arm64")) return "SCMP_ARCH_AARCH64";
    if (std.mem.eql(u8, short, "x86")) return "SCMP_ARCH_X86";
    if (std.mem.eql(u8, short, "x32")) return "SCMP_ARCH_X32";
    if (std.mem.eql(u8, short, "386")) return "SCMP_ARCH_X86";
    if (std.mem.eql(u8, short, "arm")) return "SCMP_ARCH_ARM";
    if (std.mem.eql(u8, short, "s390x")) return "SCMP_ARCH_S390X";
    if (std.mem.eql(u8, short, "s390")) return "SCMP_ARCH_S390";
    if (std.mem.eql(u8, short, "ppc64le")) return "SCMP_ARCH_PPC64LE";
    if (std.mem.eql(u8, short, "riscv64")) return "SCMP_ARCH_RISCV64";
    if (std.mem.eql(u8, short, "mips64le")) return "SCMP_ARCH_MIPSEL64";
    if (std.mem.eql(u8, short, "mips64")) return "SCMP_ARCH_MIPS64";
    return short;
}

fn containsString(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

const Document = struct {
    ociVersion: []const u8,
    process: Process,
    root: Root,
    hostname: []const u8,
    mounts: []const Mount,
    linux: Linux,
};

const Process = struct {
    terminal: bool,
    user: User,
    args: []const []const u8,
    env: []const []const u8,
    cwd: []const u8,
    capabilities: Capabilities,
    rlimits: []const Rlimit,
    noNewPrivileges: bool,
};

const User = struct {
    uid: u32,
    gid: u32,
};

const Capabilities = struct {
    bounding: []const []const u8,
    effective: []const []const u8,
    inheritable: []const []const u8 = &.{},
    permitted: []const []const u8,
    ambient: []const []const u8 = &.{},
};

const Rlimit = struct {
    type: []const u8,
    hard: u64,
    soft: u64,
};

const Root = struct {
    path: []const u8,
    readonly: bool,
};

const Mount = struct {
    destination: []const u8,
    type: ?[]const u8 = null,
    source: ?[]const u8 = null,
    options: ?[]const []const u8 = null,
};

const Linux = struct {
    uidMappings: []const IdMapping,
    gidMappings: []const IdMapping,
    namespaces: []const Namespace,
    maskedPaths: []const []const u8,
    readonlyPaths: []const []const u8,
    cgroupsPath: []const u8,
    resources: Resources,
    seccomp: ?Seccomp,
};

const IdMapping = struct {
    containerID: u32,
    hostID: u32,
    size: u32,
};

const Namespace = struct {
    type: []const u8,
};

const Resources = struct {};

/// Mirrors the OCI `linux.seccomp` schema. Field order is fixed so the
/// re-stringified output is deterministic across builds.
const Seccomp = struct {
    defaultAction: []const u8,
    defaultErrnoRet: ?u32 = null,
    architectures: []const []const u8,
    syscalls: []const SyscallRule,
};

const SyscallRule = struct {
    names: [][]const u8,
    action: []const u8,
    errnoRet: ?u32 = null,
    args: ?[]SyscallArg = null,
};

const SyscallArg = struct {
    index: u32,
    value: u64,
    valueTwo: ?u64 = null,
    op: []const u8,
};

/// 14-cap docker default bounding set. Same list goes into `bounding`,
/// `effective`, and `permitted`; `inheritable`/`ambient` stay empty.
const default_caps: []const []const u8 = &[_][]const u8{
    "CAP_AUDIT_WRITE",
    "CAP_CHOWN",
    "CAP_DAC_OVERRIDE",
    "CAP_FOWNER",
    "CAP_FSETID",
    "CAP_KILL",
    "CAP_MKNOD",
    "CAP_NET_BIND_SERVICE",
    "CAP_NET_RAW",
    "CAP_SETFCAP",
    "CAP_SETGID",
    "CAP_SETPCAP",
    "CAP_SETUID",
    "CAP_SYS_CHROOT",
};

const default_capabilities: Capabilities = .{
    .bounding = default_caps,
    .effective = default_caps,
    .permitted = default_caps,
};

const default_rlimits: [1]Rlimit = .{
    .{ .type = "RLIMIT_NOFILE", .hard = 1024, .soft = 1024 },
};

/// Default mount set — matches `runc spec --rootless`. `/dev` is a
/// tmpfs with bind-mounted device nodes added by libcrun at runtime
/// (rootless `mknod` is forbidden in user namespaces).
const default_mounts = [_]Mount{
    .{
        .destination = "/proc",
        .type = "proc",
        .source = "proc",
    },
    .{
        .destination = "/dev",
        .type = "tmpfs",
        .source = "tmpfs",
        .options = &[_][]const u8{ "nosuid", "strictatime", "mode=755", "size=65536k" },
    },
    .{
        .destination = "/dev/pts",
        .type = "devpts",
        .source = "devpts",
        .options = &[_][]const u8{ "nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620" },
    },
    .{
        .destination = "/dev/shm",
        .type = "tmpfs",
        .source = "shm",
        .options = &[_][]const u8{ "nosuid", "noexec", "nodev", "mode=1777", "size=65536k" },
    },
    .{
        .destination = "/dev/mqueue",
        .type = "mqueue",
        .source = "mqueue",
        .options = &[_][]const u8{ "nosuid", "noexec", "nodev" },
    },
    .{
        .destination = "/sys",
        .type = "none",
        .source = "/sys",
        .options = &[_][]const u8{ "rbind", "nosuid", "noexec", "nodev", "ro" },
    },
};

const default_namespaces = [_]Namespace{
    .{ .type = "pid" },
    .{ .type = "network" },
    .{ .type = "ipc" },
    .{ .type = "uts" },
    .{ .type = "mount" },
    .{ .type = "user" },
};

/// runc default: paths inside the container that get `MS_BIND` masked
/// so reads return all-zeros. Prevents proc-info leakage.
const default_masked_paths: []const []const u8 = &[_][]const u8{
    "/proc/acpi",
    "/proc/asound",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/proc/scsi",
    "/sys/firmware",
};

/// runc default: paths inside the container remounted read-only.
const default_readonly_paths: []const []const u8 = &[_][]const u8{
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger",
};

const testing = std.testing;

fn fixedEuid(ctx: ?*anyopaque) u32 {
    _ = ctx;
    return 1000;
}

fn fixedEgid(ctx: ?*anyopaque) u32 {
    _ = ctx;
    return 1000;
}

const fixed_id_source: IdSource = .{
    .fetchUid = fixedEuid,
    .fetchGid = fixedEgid,
};

fn fakeContainer() state_mod.Container {
    var id: [state_mod.id_short_length]u8 = undefined;
    @memcpy(&id, "abcdefabcdef");
    var id_full: [state_mod.id_full_length]u8 = undefined;
    @memcpy(id_full[0..12], "abcdefabcdef");
    @memset(id_full[12..], '0');
    return .{
        .id = id,
        .id_full = id_full,
        .name = null,
        .image_ref = "alpine:3.19",
        .image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .started_at = "2026-05-03T12:34:56Z",
    };
}

fn fakeOverlay(allocator: Allocator) !overlay_mod.MountedOverlay {
    const merged = try allocator.allocSentinel(u8, "/run/rind/overlays/abcdefabcdef/merged".len, 0);
    @memcpy(merged, "/run/rind/overlays/abcdefabcdef/merged");
    const upper = try allocator.dupe(u8, "/run/rind/overlays/abcdefabcdef/upper");
    const work = try allocator.dupe(u8, "/run/rind/overlays/abcdefabcdef/work");
    return .{
        .allocator = allocator,
        .merged_path = merged,
        .upper_path = upper,
        .work_path = work,
        .joined_userns = false,
        .host_sub_uid = null,
        .host_sub_gid = null,
    };
}

fn fakeRootlessOverlay(
    allocator: Allocator,
    sub_uid: ?subid_mod.Range,
    sub_gid: ?subid_mod.Range,
) !overlay_mod.MountedOverlay {
    var ov = try fakeOverlay(allocator);
    ov.joined_userns = true;
    ov.host_sub_uid = sub_uid;
    ov.host_sub_gid = sub_gid;
    return ov;
}

const alpine_fixture = @embedFile("../image/testdata/alpine_3_19_config.json");

fn parseAlpine(arena: *std.heap.ArenaAllocator) !image_config.ImageConfig {
    return image_config.parse(arena.allocator(), alpine_fixture);
}

fn composeIntoTmp(
    aa: Allocator,
    overrides: RunOverrides,
    img_cfg: image_config.ImageConfig,
) !struct { bytes: []u8, tmp: testing.TmpDir } {
    var tmp = testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();

    var io_bundle_dir = try tmp.dir.createDirPathOpen(testing.io, "bundle", .{
        .open_options = .{ .iterate = true },
    });
    defer io_bundle_dir.close(testing.io);

    var ovl = try fakeOverlay(aa);
    defer ovl.deinit();

    const c = fakeContainer();

    try composeWithIds(testing.io, aa, io_bundle_dir, c, img_cfg, overrides, ovl, fixed_id_source);

    const bytes = try io_bundle_dir.readFileAlloc(testing.io, config_filename, aa, .limited(256 * 1024));
    return .{ .bytes = bytes, .tmp = tmp };
}

test "compose snapshot matches golden bundle_config.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const img_cfg = try parseAlpine(&arena);
    const env_overrides = [_][]const u8{"MY_VAR=1"};
    const cmd_overrides = [_][]const u8{ "echo", "hi" };
    const overrides: RunOverrides = .{
        .cmd = &cmd_overrides,
        .env = &env_overrides,
    };

    var got = try composeIntoTmp(aa, overrides, img_cfg);
    defer got.tmp.cleanup();

    if (std.c.getenv("RIND_REGEN_BUNDLE_FIXTURE")) |dest_cstr| {
        const dest = std.mem.span(dest_cstr);
        var file = try Io.Dir.createFileAbsolute(testing.io, dest, .{});
        defer file.close(testing.io);
        var write_buf: [4096]u8 = undefined;
        var fw = file.writer(testing.io, &write_buf);
        fw.interface.writeAll(got.bytes) catch return fw.err.?;
        fw.interface.flush() catch return fw.err.?;
        std.debug.print("regenerated bundle fixture at {s} ({d} bytes)\n", .{ dest, got.bytes.len });
        return;
    }

    const golden = @embedFile("testdata/bundle_config.json");
    if (!std.mem.eql(u8, std.mem.trim(u8, golden, &std.ascii.whitespace), std.mem.trim(u8, got.bytes, &std.ascii.whitespace))) {
        std.debug.print("snapshot drift; got {d} bytes, golden {d} bytes\n", .{ got.bytes.len, golden.len });
        std.debug.print("--- generated ---\n{s}\n", .{got.bytes});
        return error.SnapshotMismatch;
    }
}

test "compose: empty image config + cmd override yields cmd as args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const img_cfg: image_config.ImageConfig = .{
        .architecture = "amd64",
        .os = "linux",
        .rootfs = .{ .type = "layers", .diff_ids = &[_][]const u8{} },
    };
    const cmd_overrides = [_][]const u8{ "/bin/echo", "x" };
    const overrides: RunOverrides = .{ .cmd = &cmd_overrides };

    var got = try composeIntoTmp(aa, overrides, img_cfg);
    defer got.tmp.cleanup();

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, got.bytes, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("process").?.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqualStrings("/bin/echo", args.items[0].string);
    try testing.expectEqualStrings("x", args.items[1].string);
}

test "compose: image entrypoint + cli cmd concatenates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ep = [_][]const u8{ "docker-entrypoint.sh", "--config" };
    const img_cfg: image_config.ImageConfig = .{
        .architecture = "amd64",
        .os = "linux",
        .rootfs = .{ .type = "layers", .diff_ids = &[_][]const u8{} },
        .config = .{
            .Entrypoint = @constCast(&ep),
        },
    };
    const cmd_overrides = [_][]const u8{ "redis", "/etc/redis.conf" };
    const overrides: RunOverrides = .{ .cmd = &cmd_overrides };

    var got = try composeIntoTmp(aa, overrides, img_cfg);
    defer got.tmp.cleanup();

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, got.bytes, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("process").?.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 4), args.items.len);
    try testing.expectEqualStrings("docker-entrypoint.sh", args.items[0].string);
    try testing.expectEqualStrings("--config", args.items[1].string);
    try testing.expectEqualStrings("redis", args.items[2].string);
    try testing.expectEqualStrings("/etc/redis.conf", args.items[3].string);
}

test "compose: --entrypoint clears image entrypoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ep = [_][]const u8{"docker-entrypoint.sh"};
    const cmd = [_][]const u8{"redis"};
    const img_cfg: image_config.ImageConfig = .{
        .architecture = "amd64",
        .os = "linux",
        .rootfs = .{ .type = "layers", .diff_ids = &[_][]const u8{} },
        .config = .{
            .Entrypoint = @constCast(&ep),
            .Cmd = @constCast(&cmd),
        },
    };
    const empty_ep: []const []const u8 = &.{};
    const overrides: RunOverrides = .{ .entrypoint = empty_ep };

    var got = try composeIntoTmp(aa, overrides, img_cfg);
    defer got.tmp.cleanup();

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, got.bytes, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("process").?.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 1), args.items.len);
    try testing.expectEqualStrings("redis", args.items[0].string);
}

test "compose: -e KEY=val merges, replaces inherited KEY" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var env_image = [_][]const u8{ "PATH=/usr/bin", "FOO=old" };
    const cmd = [_][]const u8{"/bin/sh"};
    const img_cfg: image_config.ImageConfig = .{
        .architecture = "amd64",
        .os = "linux",
        .rootfs = .{ .type = "layers", .diff_ids = &[_][]const u8{} },
        .config = .{
            .Env = &env_image,
            .Cmd = @constCast(&cmd),
        },
    };
    const env_overrides = [_][]const u8{ "FOO=new", "BAR=baz" };
    const overrides: RunOverrides = .{ .env = &env_overrides };

    var got = try composeIntoTmp(aa, overrides, img_cfg);
    defer got.tmp.cleanup();

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, got.bytes, .{});
    defer parsed.deinit();
    const env = parsed.value.object.get("process").?.object.get("env").?.array;
    try testing.expectEqual(@as(usize, 3), env.items.len);
    try testing.expectEqualStrings("PATH=/usr/bin", env.items[0].string);
    try testing.expectEqualStrings("FOO=new", env.items[1].string);
    try testing.expectEqualStrings("BAR=baz", env.items[2].string);
}

test "compose: EmptyArgs error when nothing supplies args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const img_cfg: image_config.ImageConfig = .{
        .architecture = "amd64",
        .os = "linux",
        .rootfs = .{ .type = "layers", .diff_ids = &[_][]const u8{} },
    };
    const overrides: RunOverrides = .{};

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var io_bundle_dir = try tmp.dir.createDirPathOpen(testing.io, "bundle", .{
        .open_options = .{ .iterate = true },
    });
    defer io_bundle_dir.close(testing.io);

    var ovl = try fakeOverlay(aa);
    defer ovl.deinit();
    const c = fakeContainer();

    try testing.expectError(BundleError.EmptyArgs, composeWithIds(testing.io, aa, io_bundle_dir, c, img_cfg, overrides, ovl, fixed_id_source));
}

test "compose: InvalidEnv on missing equals sign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const img_cfg: image_config.ImageConfig = .{
        .architecture = "amd64",
        .os = "linux",
        .rootfs = .{ .type = "layers", .diff_ids = &[_][]const u8{} },
    };
    const cmd_overrides = [_][]const u8{"/bin/true"};
    const env_overrides = [_][]const u8{"NO_EQUALS_HERE"};
    const overrides: RunOverrides = .{
        .cmd = &cmd_overrides,
        .env = &env_overrides,
    };

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var io_bundle_dir = try tmp.dir.createDirPathOpen(testing.io, "bundle", .{
        .open_options = .{ .iterate = true },
    });
    defer io_bundle_dir.close(testing.io);

    var ovl = try fakeOverlay(aa);
    defer ovl.deinit();
    const c = fakeContainer();

    try testing.expectError(BundleError.InvalidEnv, composeWithIds(testing.io, aa, io_bundle_dir, c, img_cfg, overrides, ovl, fixed_id_source));
}

test "compose: UnsupportedUserFormat on textual user" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const img_cfg: image_config.ImageConfig = .{
        .architecture = "amd64",
        .os = "linux",
        .rootfs = .{ .type = "layers", .diff_ids = &[_][]const u8{} },
    };
    const cmd_overrides = [_][]const u8{"/bin/true"};
    const overrides: RunOverrides = .{
        .cmd = &cmd_overrides,
        .user = "memcache",
    };

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var io_bundle_dir = try tmp.dir.createDirPathOpen(testing.io, "bundle", .{
        .open_options = .{ .iterate = true },
    });
    defer io_bundle_dir.close(testing.io);

    var ovl = try fakeOverlay(aa);
    defer ovl.deinit();
    const c = fakeContainer();

    try testing.expectError(BundleError.UnsupportedUserFormat, composeWithIds(testing.io, aa, io_bundle_dir, c, img_cfg, overrides, ovl, fixed_id_source));
}

test "parseUser accepts uid, uid:gid, empty" {
    try testing.expectEqual(@as(u32, 0), (try parseUser("")).uid);
    try testing.expectEqual(@as(u32, 0), (try parseUser("")).gid);
    try testing.expectEqual(@as(u32, 1000), (try parseUser("1000")).uid);
    try testing.expectEqual(@as(u32, 0), (try parseUser("1000")).gid);
    try testing.expectEqual(@as(u32, 1000), (try parseUser("1000:2000")).uid);
    try testing.expectEqual(@as(u32, 2000), (try parseUser("1000:2000")).gid);
    try testing.expectError(BundleError.UnsupportedUserFormat, parseUser("memcache"));
    try testing.expectError(BundleError.UnsupportedUserFormat, parseUser("1000:groupname"));
}

test "resolveIdMappings: privileged path emits 1-entry with egid (not euid)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var ovl = try fakeOverlay(aa); // joined_userns=false
    defer ovl.deinit();

    // euid=1000, egid=42 — distinct so a regression that copies euid
    // into gidMappings is caught by the assertion below.
    const maps = try resolveIdMappings(aa, ovl, 1000, 42);
    try testing.expectEqual(@as(usize, 1), maps.uid.len);
    try testing.expectEqual(@as(usize, 1), maps.gid.len);
    try testing.expectEqual(@as(u32, 1000), maps.uid[0].hostID);
    try testing.expectEqual(@as(u32, 42), maps.gid[0].hostID);
}

test "resolveIdMappings: rootless without sub ranges falls back to 1-entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var ovl = try fakeRootlessOverlay(aa, null, null);
    defer ovl.deinit();

    const maps = try resolveIdMappings(aa, ovl, 1000, 42);
    try testing.expectEqual(@as(usize, 1), maps.uid.len);
    // Joined userns: hostID is the joined-userns root (always 0), not
    // the original host euid.
    try testing.expectEqual(@as(u32, 0), maps.uid[0].hostID);
    try testing.expectEqual(@as(u32, 0), maps.gid[0].hostID);
}

test "resolveIdMappings: rootless + sub ranges emits 2-entry with hostID=1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var ovl = try fakeRootlessOverlay(
        aa,
        .{ .start = 100000, .count = 65536 },
        .{ .start = 200000, .count = 32768 },
    );
    defer ovl.deinit();

    const maps = try resolveIdMappings(aa, ovl, 1000, 1000);
    try testing.expectEqual(@as(usize, 2), maps.uid.len);
    try testing.expectEqual(@as(u32, 0), maps.uid[0].hostID);
    try testing.expectEqual(@as(u32, 1), maps.uid[1].containerID);
    // Critical: hostID is `1` (the joined-userns offset newuidmap
    // mapped the subuid range into), NOT the original `start` value
    // 100000 — that's invisible inside the joined namespace.
    try testing.expectEqual(@as(u32, 1), maps.uid[1].hostID);
    try testing.expectEqual(@as(u32, 65536), maps.uid[1].size);

    try testing.expectEqual(@as(usize, 2), maps.gid.len);
    try testing.expectEqual(@as(u32, 1), maps.gid[1].hostID);
    try testing.expectEqual(@as(u32, 32768), maps.gid[1].size);
}

test "compose rootless+subid emits 2-entry mappings in config.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const img_cfg = try parseAlpine(&arena);
    const cmd_overrides = [_][]const u8{ "echo", "hi" };
    const overrides: RunOverrides = .{ .cmd = &cmd_overrides };

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var io_bundle_dir = try tmp.dir.createDirPathOpen(testing.io, "bundle", .{
        .open_options = .{ .iterate = true },
    });
    defer io_bundle_dir.close(testing.io);

    var ovl = try fakeRootlessOverlay(
        aa,
        .{ .start = 100000, .count = 65536 },
        .{ .start = 200000, .count = 65536 },
    );
    defer ovl.deinit();
    const c = fakeContainer();

    try composeWithIds(testing.io, aa, io_bundle_dir, c, img_cfg, overrides, ovl, fixed_id_source);

    const bytes = try io_bundle_dir.readFileAlloc(testing.io, config_filename, aa, .limited(256 * 1024));
    // Two-entry shape lands as a JSON array of length 2 — the
    // `containerID:1` literal never appears in the 1-entry fallback.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"containerID\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"size\": 65536") != null);
}
