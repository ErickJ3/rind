const std = @import("std");

pub fn build(b: *std.Build) void {
    // Pin a glibc version on the default target so Zig links against
    // its bundled CRT (`crt1.o` etc.) instead of the system's
    // `/usr/lib/gcc/.../crt1.o`. GCC ≥15 emits a `.sframe` stack-unwind
    // section there, and Zig 0.16's LLD doesn't yet handle the
    // R_X86_64_PC64 relocations inside it — link fails with
    // "unhandled relocation type R_X86_64_PC64 ... in crt1.o:.sframe".
    // Override with `-Dtarget=...` if cross-building.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const enable_e2e = b.option(
        bool,
        "rind-e2e",
        "Enable e2e tests that pull from real registries (requires RIND_E2E=1 at runtime).",
    ) orelse false;

    // Dev-only escape hatch: link the host's libc dynamically so DNS
    // resolution goes through the system's nsswitch (works with
    // systemd-resolved on typical Linux dev boxes). The default
    // build stays statically linked with Zig's musl — that's what
    // ships, but it currently can't talk to the systemd-resolved
    // stub at 127.0.0.53. A native Zig DNS resolver is on the M4
    // polish list; until then use `-Ddev-libc=true` to smoke-test
    // pulls locally.
    const dev_libc = b.option(
        bool,
        "dev-libc",
        "Link host libc dynamically (workaround for musl + systemd-resolved DNS issues).",
    ) orelse false;

    // libcrun memfd-clones `/proc/self/exe` at every container start
    // an unstripped 71MB Debug binary costs ~33ms wall on `rind run`.
    // Strip in non-Debug by default; debug keeps symbols for gdb.
    const strip = b.option(
        bool,
        "strip",
        "Strip debug info from the rind binary (default: true in non-Debug builds).",
    ) orelse (optimize != .Debug);

    const build_options = b.addOptions();
    build_options.addOption(bool, "e2e_enabled", enable_e2e);
    const build_options_mod = build_options.createModule();

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("rind", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        // src/compress/zlib_ng.zig uses @cImport on <zlib-ng.h>; the
        // module needs libc + the header search path so unit tests
        // built off this module compile.
        .link_libc = true,
    });
    // Inline E2E tests gate themselves on `build_options.e2e_enabled`,
    // so the same module needs to import it. Without this, any
    // `@import("build_options")` from a `src/` file fails at compile.
    mod.addImport("build_options", build_options_mod);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = dev_libc,
        .strip = strip,
        .imports = &.{
            .{ .name = "rind", .module = mod },
            .{ .name = "clap", .module = clap_dep.module("clap") },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "rind",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const client_test_mod = b.createModule(.{
        .root_source_file = b.path("src/registry/client_test.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "rind", .module = mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const client_tests = b.addTest(.{ .root_module = client_test_mod });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&b.addRunArtifact(client_tests).step);

    // Regression harness: walks /tests/cases/<scenario>/ and diffs
    // against expected_* goldens. The harness is a separate binary
    // so the rind exe stays tight; build.zig wires the freshly
    // installed `rind` path in as argv[1] of the runner.
    const update_goldens = b.option(
        bool,
        "update-goldens",
        "Rewrite stale regression goldens on diff and exit 0.",
    ) orelse false;

    const harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/cases/_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const harness_exe = b.addExecutable(.{
        .name = "regression-runner",
        .root_module = harness_mod,
    });

    const run_harness = b.addRunArtifact(harness_exe);
    run_harness.addArtifactArg(exe);
    run_harness.addArg("--cases-dir");
    run_harness.addDirectoryArg(b.path("tests/cases"));
    if (update_goldens) run_harness.addArg("--update-goldens");
    run_harness.step.dependOn(b.getInstallStep());

    const regression_step = b.step("regression", "Run regression scenarios");
    regression_step.dependOn(&run_harness.step);

    const lex_harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/cases/_lex_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "rind", .module = mod }},
    });
    const lex_harness_exe = b.addExecutable(.{
        .name = "lex-harness",
        .root_module = lex_harness_mod,
    });

    const run_lex = b.addRunArtifact(lex_harness_exe);
    run_lex.addArg("--cases-dir");
    run_lex.addDirectoryArg(b.path("tests/lex_cases/lex_smoke"));
    if (update_goldens) run_lex.addArg("--update");

    const lex_regression_step = b.step("lex-regression", "Diff lex_smoke output against goldens");
    lex_regression_step.dependOn(&run_lex.step);

    const parse_harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/cases/_parse_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "rind", .module = mod }},
    });
    const parse_harness_exe = b.addExecutable(.{
        .name = "parse-harness",
        .root_module = parse_harness_mod,
    });

    const run_parse = b.addRunArtifact(parse_harness_exe);
    run_parse.addArg("--cases-dir");
    run_parse.addDirectoryArg(b.path("tests/parse_cases/parse_smoke"));
    if (update_goldens) run_parse.addArg("--update");

    const parse_regression_step = b.step("parse-regression", "Diff parse_smoke output against goldens");
    parse_regression_step.dependOn(&run_parse.step);

    const check_step = b.step("check", "Aggregate test + regression");
    check_step.dependOn(test_step);
    check_step.dependOn(regression_step);
    check_step.dependOn(lex_regression_step);
    check_step.dependOn(parse_regression_step);

    const harness_unit = b.addTest(.{ .root_module = harness_mod });
    test_step.dependOn(&b.addRunArtifact(harness_unit).step);

    const lex_harness_unit = b.addTest(.{ .root_module = lex_harness_mod });
    test_step.dependOn(&b.addRunArtifact(lex_harness_unit).step);

    const parse_harness_unit = b.addTest(.{ .root_module = parse_harness_mod });
    test_step.dependOn(&b.addRunArtifact(parse_harness_unit).step);

    // T17 — static-link libcrun.a + libseccomp.a + libcap.a +
    // argp_standalone.a into the rind exe (helpers below). Link order
    // matters: libcrun → libseccomp → libcap → argp_standalone (libcrun
    // references argp_parse, which resolves last).

    const crun_lib = cLibcrun(b, target, optimize);
    const seccomp_lib = cSeccomp(b, target, optimize);
    const cap_lib = cLibcap(b, target, optimize);
    const argp_lib = cArgpStandalone(b, target, optimize);
    const zlib_ng_lib = cZlibNg(b, target, optimize);

    if (crun_lib) |l| {
        exe_module.linkLibrary(l);
        // src/runtime/libcrun.zig (T18) re-exports libcrun's public headers
        // via @cImport. Tests rooted at root.zig need to link the lib too,
        // so wire the same lib + headers onto `mod`.
        mod.linkLibrary(l);
        addLibcrunHeaders(b, exe_module);
        addLibcrunHeaders(b, mod);
    }
    if (seccomp_lib) |l| {
        exe_module.linkLibrary(l);
        // libcrun pulls libseccomp symbols (seccomp_*) at link time; the
        // root.zig test binary needs them too once it imports runtime.libcrun.
        mod.linkLibrary(l);
    }
    if (cap_lib) |l| {
        exe_module.linkLibrary(l);
        mod.linkLibrary(l);
    }
    if (argp_lib) |l| {
        exe_module.linkLibrary(l);
        mod.linkLibrary(l);
    }
    if (zlib_ng_lib) |l| {
        exe_module.linkLibrary(l);
        // Wrapper at src/compress/zlib_ng.zig uses @cImport on
        // <zlib-ng.h>; the header lives at cdeps/zlib-ng/.
        exe_module.addIncludePath(b.path("cdeps/zlib-ng"));
        // mod re-exports image.extract (and thus the zlib_ng wrapper),
        // so unit tests rooted at root.zig need the same wiring.
        mod.linkLibrary(l);
        mod.addIncludePath(b.path("cdeps/zlib-ng"));
    }
}

// addLibcrunHeaders — attaches the four header roots required for
// `@cImport({ @cInclude("container.h"); @cInclude("error.h"); })` in
// src/runtime/libcrun.zig:
//   1. cdeps/crun                          → <config.h>
//   2. vendor/crun-1.23/src                      → container.h, error.h, string_map.h
//   3. vendor/crun-1.23/libocispec/src           → <ocispec/runtime_spec_schema_*>
//   4. vendor/crun-1.23/libocispec/yajl/src/api  → <yajl/yajl_tree.h> (transitive)
// All four roots are in-tree (not lazy deps), so this attaches unconditionally.
fn addLibcrunHeaders(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("cdeps/crun"));
    mod.addIncludePath(b.path("vendor/crun-1.23/src"));
    mod.addIncludePath(b.path("vendor/crun-1.23/libocispec/src"));
    mod.addIncludePath(b.path("vendor/crun-1.23/libocispec/yajl/src/api"));
}

// cArgpStandalone — argp-standalone 1.5.0 as a static lib. argp is
// part of glibc but absent from musl; libcrun calls argp_parse, so we
// link this in last on the chain. Lazy dep: first build fetches the
// tarball declared in build.zig.zon. Returns null when the dep is
// resolved-but-unavailable (Zig 0.16 lazy contract).
//
// File list per cdeps/argp/SOURCES.md. Hand-authored config.h
// at cdeps/argp/config.h pins HAVE_* knobs for x86_64-linux-musl.
fn cArgpStandalone(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("argp_standalone", .{}) orelse return null;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &.{
            "argp-ba.c",
            "argp-eexst.c",
            "argp-fmtstream.c",
            "argp-help.c",
            "argp-parse.c",
            "argp-pv.c",
            "argp-pvh.c",
        },
        .flags = &.{
            "-D_GNU_SOURCE",
            "-DHAVE_CONFIG_H",
            "-std=gnu99",
            "-Wno-unused-result",
        },
    });

    // Hand-authored config.h (HAVE_PROGRAM_INVOCATION_NAME=0, etc.).
    mod.addIncludePath(b.path("cdeps/argp"));
    // argp's own headers (argp.h, argp-fmtstream.h) live at the tarball root.
    mod.addIncludePath(dep.path(""));

    return b.addLibrary(.{
        .name = "argp_standalone",
        .linkage = .static,
        .root_module = mod,
    });
}

// capNamesHeader — codegen step that produces cap_names.h. Mirrors
// libcap's upstream Makefile recipe (sed → cap_names.list.h, build
// _makenames, run it, capture stdout). Source for the cap list is
// the host's /usr/include/linux/capability.h (per T17 plan; a vendored
// UAPI snapshot under cdeps/cap/uapi/ is the reproducible
// alternative documented at cdeps/cap/generated/PROVENANCE.md).
fn capNamesHeader(b: *std.Build, libcap_dep: *std.Build.Dependency) std.Build.LazyPath {
    // 1. sed | awk on host UAPI → cap_names.list.h.
    const sed_run = b.addSystemCommand(&.{
        "sh",
        "-c",
        "sed -n -e '/^#define[ \\t]CAP[_A-Z]\\+[ \\t]\\+[0-9]\\+$/p' /usr/include/linux/capability.h | awk '{ print \"    {\\\"\" tolower($2) \"\\\", \" $3 \"},\" }'",
    });
    const cap_names_list = sed_run.captureStdOut(.{ .basename = "cap_names.list.h" });

    // 2. Compile _makenames.c as a host-target executable. Native
    //    target so it runs at build time on the build host.
    const host_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    host_mod.addCSourceFile(.{
        .file = libcap_dep.path("libcap/_makenames.c"),
        .flags = &.{},
    });
    host_mod.addIncludePath(cap_names_list.dirname());

    const makenames_exe = b.addExecutable(.{
        .name = "_makenames",
        .root_module = host_mod,
    });

    // 3. Run _makenames; capture stdout → cap_names.h.
    const run_makenames = b.addRunArtifact(makenames_exe);
    return run_makenames.captureStdOut(.{ .basename = "cap_names.h" });
}

// cLibcap — libcap 2.76 as a static lib. Selected BSD-3-Clause from
// libcap's BSD/GPL dual-licence offer (recorded in NOTICE +
// THIRD_PARTY_LICENSES.md). cap_names.h is generated above; the rest
// of the source list lives at cdeps/cap/SOURCES.md.
fn cLibcap(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("libcap", .{}) orelse return null;

    const cap_names_h = capNamesHeader(b, dep);

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addCSourceFiles(.{
        .root = dep.path("libcap"),
        .files = &.{
            "cap_alloc.c",
            "cap_extint.c",
            "cap_file.c",
            "cap_flag.c",
            "cap_proc.c",
            // cap_syscalls.c provides a weak fallback for
            // psx_load_syscalls (overridden by libpsx when present;
            // we don't link libpsx, so the weak no-op stands in).
            // Phase A SOURCES.md oversight — adding here.
            "cap_syscalls.c",
            "cap_text.c",
        },
        .flags = &.{
            "-D_GNU_SOURCE",
        },
    });

    // Hand-authored config.h.
    mod.addIncludePath(b.path("cdeps/cap"));
    // libcap public API (sys/capability.h, sys/securebits.h).
    mod.addIncludePath(dep.path("libcap/include"));
    // libcap private headers (libcap.h sibling to the .c sources).
    mod.addIncludePath(dep.path("libcap"));
    // Generated cap_names.h lives in the run-artifact cache dir.
    mod.addIncludePath(cap_names_h.dirname());

    return b.addLibrary(.{
        .name = "cap",
        .linkage = .static,
        .root_module = mod,
    });
}

// cSeccomp — libseccomp 2.5.6 as a static lib. Sources per
// cdeps/seccomp/SOURCES.md (x86_64 arch only). Hand-authored
// configure.h at cdeps/seccomp/ (note: the file MUST be named
// `configure.h` because system.h has `#include "configure.h"`).
//
// The release tarball ships pre-generated arch-x86_64.h, syscalls.h,
// syscalls.csv, and syscalls.perf.c — no Python/gperf codegen needed.
fn cSeccomp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("libseccomp", .{}) orelse return null;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &.{
            "api.c",
            "arch.c",
            // arch.c hard-references arch_def_<every-arch>; the lookup
            // table is not macro-guarded, so we have to compile every
            // arch backend even though rind only targets x86_64.
            "arch-aarch64.c",
            "arch-arm.c",
            "arch-mips.c",
            "arch-mips64.c",
            "arch-mips64n32.c",
            "arch-parisc.c",
            "arch-parisc64.c",
            "arch-ppc.c",
            "arch-ppc64.c",
            "arch-riscv64.c",
            "arch-s390.c",
            "arch-s390x.c",
            "arch-x32.c",
            "arch-x86.c",
            "arch-x86_64.c",
            "db.c",
            "gen_bpf.c",
            "gen_pfc.c",
            "hash.c",
            "helper.c",
            "syscalls.c",
            // syscalls.perf.c is the gperf output that exports
            // syscall_resolve_{name,num} + syscall_iterate. arch.c
            // and arch-x86_64.c reference them. Phase A SOURCES.md
            // oversight — adding here.
            "syscalls.perf.c",
            "system.c",
        },
        .flags = &.{
            "-D_GNU_SOURCE",
        },
    });

    // configure.h — note this dir intentionally only holds configure.h
    // (renamed from config.h in T17 phase B because system.h hard-codes
    // the name).
    mod.addIncludePath(b.path("cdeps/seccomp"));
    // Public API: seccomp.h.
    mod.addIncludePath(dep.path("include"));
    // Private headers + pre-generated codegen artifacts.
    mod.addIncludePath(dep.path("src"));

    return b.addLibrary(.{
        .name = "seccomp",
        .linkage = .static,
        .root_module = mod,
    });
}

// cLibcrun — libcrun 1.23 as a static lib. Vendored in-tree at
// vendor/crun-1.23/ (Zig 0.16's tar reader rejects the hard-link
// entries in the upstream release tarball, so this dep is NOT lazy).
//
// File list per cdeps/crun/SOURCES.md:
//   - libcrun core (src/*.c)
//   - libcrun handlers (src/handlers/handler-utils.c + exec.c only —
//     wasm/lua/krun/spin/mono handlers excluded; their feature toggles
//     are 0 in cdeps/crun/config.h)
//   - BLAKE3 portable (src/blake3/blake3.c + blake3_portable.c — no
//     dispatch.c needed; impl.h aliases portable fns to public names)
//   - embedded yajl (libocispec/yajl/src/*.c)
//   - libocispec codegen (libocispec/src/ocispec/*_schema.c +
//     *_defs.c + json_common.c + read-file.c + validate.c)
fn cLibcrun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // HAVE_CONFIG_H propagates to every TU. _GNU_SOURCE is self-
    // defined by every libcrun source; setting it via -D causes a
    // redefinition error against the source's bare `#define _GNU_SOURCE`.
    mod.addCMacro("HAVE_CONFIG_H", "1");

    const crun_flags = &[_][]const u8{
        "-Wno-unused-result",
        "-Wno-unused-parameter",
        "-Wno-unused-function",
        "-Wno-unused-variable",
        "-Wno-sign-compare",
        "-std=gnu11",
    };

    // libcrun core — vendor/crun-1.23/src/*.c.
    mod.addCSourceFiles(.{
        .root = b.path("vendor/crun-1.23/src"),
        .files = &.{
            "cgroup.c",
            "cgroup-cgroupfs.c",
            "cgroup-resources.c",
            "cgroup-setup.c",
            "cgroup-systemd.c",
            "cgroup-utils.c",
            "chroot_realpath.c",
            "cloned_binary.c",
            "container.c",
            "criu.c",
            "custom-handler.c",
            "ebpf.c",
            "error.c",
            "intelrdt.c",
            "io_priority.c",
            "linux.c",
            "mount_flags.c",
            "net_device.c",
            "ring_buffer.c",
            "scheduler.c",
            "seccomp.c",
            "seccomp_notify.c",
            "signals.c",
            "status.c",
            "string_map.c",
            "terminal.c",
            "utils.c",
        },
        .flags = crun_flags,
    });

    // Handlers — handler-utils only. The wasm/lua/krun/spin/mono
    // handlers compile when their HAVE_* flags are non-zero, which
    // they aren't in cdeps/crun/config.h. (No handlers/exec.c
    // in libcrun 1.23; the in-process exec dispatch lives in
    // container.c — SOURCES.md errata.)
    mod.addCSourceFiles(.{
        .root = b.path("vendor/crun-1.23/src"),
        .files = &.{
            "handlers/handler-utils.c",
        },
        .flags = crun_flags,
    });

    // BLAKE3 — portable build. impl.h has #define
    // blake3_compress_in_place_portable blake3_compress_in_place,
    // so blake3.c's references to the public name resolve to the
    // portable.c definitions. No blake3_dispatch.c on this build.
    mod.addCSourceFiles(.{
        .root = b.path("vendor/crun-1.23/src"),
        .files = &.{
            "blake3/blake3.c",
            "blake3/blake3_portable.c",
        },
        .flags = crun_flags,
    });

    // Embedded yajl — vendor/crun-1.23/libocispec/yajl/src/*.c.
    // (No yajl_version.c in this snapshot — the libocispec embed strips it.)
    mod.addCSourceFiles(.{
        .root = b.path("vendor/crun-1.23/libocispec/yajl/src"),
        .files = &.{
            "yajl.c",
            "yajl_alloc.c",
            "yajl_buf.c",
            "yajl_encode.c",
            "yajl_gen.c",
            "yajl_lex.c",
            "yajl_parser.c",
            "yajl_tree.c",
        },
        .flags = &.{},
    });

    // libocispec codegen — *_schema.c + *_defs.c + a few helpers.
    // List enumerated from `ls vendor/crun-1.23/libocispec/src/ocispec/*.c`
    // minus the basic_test_*.c / test_*.c testbench files.
    mod.addCSourceFiles(.{
        .root = b.path("vendor/crun-1.23/libocispec/src/ocispec"),
        .files = &.{
            "image_manifest_items_image_manifest_items_schema.c",
            "image_spec_schema_config_schema.c",
            "image_spec_schema_content_descriptor.c",
            "image_spec_schema_defs.c",
            "image_spec_schema_defs_descriptor.c",
            "image_spec_schema_image_index_schema.c",
            "image_spec_schema_image_layout_schema.c",
            "image_spec_schema_image_manifest_schema.c",
            "json_common.c",
            "read-file.c",
            "runtime_spec_schema_config_linux.c",
            "runtime_spec_schema_config_schema.c",
            "runtime_spec_schema_config_solaris.c",
            "runtime_spec_schema_config_vm.c",
            "runtime_spec_schema_config_windows.c",
            "runtime_spec_schema_config_zos.c",
            "runtime_spec_schema_defs.c",
            "runtime_spec_schema_defs_linux.c",
            "runtime_spec_schema_defs_vm.c",
            "runtime_spec_schema_defs_windows.c",
            "runtime_spec_schema_defs_zos.c",
            "runtime_spec_schema_features_linux.c",
            "runtime_spec_schema_features_schema.c",
            "runtime_spec_schema_state_schema.c",
            // validate.c — libocispec CLI validator, GPL-3 + has its
            // own `int main()`. NOT part of the library half. Dropped
            // from the compile set; ditto from any future SOURCES.md
            // refresh.
        },
        .flags = crun_flags,
    });

    // Includes — order matters. The lazy-dep public-header dirs MUST
    // come before vendor/crun-1.23/src/ because libcrun ships its own
    // `seccomp.h` and `error.h` wrappers in src/ that shadow the
    // libseccomp `<seccomp.h>` and break SCMP_* symbol resolution.
    // (Quoted-include `"seccomp.h"` finds the local libcrun wrapper;
    // angle-include `<seccomp.h>` from the same TU then ALSO finds
    // the local one because clang searches all `-I` paths in order
    // for both forms. Putting libseccomp's `include/` first fixes it.)
    if (b.lazyDependency("libcap", .{})) |cap_dep| {
        mod.addIncludePath(cap_dep.path("libcap/include"));
    }
    if (b.lazyDependency("libseccomp", .{})) |seccomp_dep| {
        mod.addIncludePath(seccomp_dep.path("include"));
    }
    if (b.lazyDependency("argp_standalone", .{})) |argp_dep| {
        mod.addIncludePath(argp_dep.path(""));
    }
    mod.addIncludePath(b.path("cdeps/crun")); // config.h, git-version.h
    mod.addIncludePath(b.path("vendor/crun-1.23/src")); // libcrun internal
    mod.addIncludePath(b.path("vendor/crun-1.23/libocispec/src")); // <ocispec/...>
    mod.addIncludePath(b.path("vendor/crun-1.23/libocispec/yajl/src/api")); // yajl public
    mod.addIncludePath(b.path("vendor/crun-1.23/libocispec/yajl/src")); // yajl private

    return b.addLibrary(.{
        .name = "crun",
        .linkage = .static,
        .root_module = mod,
    });
}

// cZlibNg — zlib-ng 2.2.5 as a static lib, native API (zng_*).
// Replaces std.compress.flate for layer extract: pure-zig flate is
// single-thread and ~5–10× slower than zlib-ng's runtime-dispatched
// SSE2/SSSE3/SSE4.2/PCLMUL/AVX2 inflate path.
//
// File list per cdeps/zlib-ng/SOURCES.md. Hand-authored
// zconf-ng.h, zlib-ng.h, zlib_name_mangling-ng.h live alongside it
// (we don't run upstream's CMake, so the @VAR@ template substitution
// is done once at vendoring time).
//
// AVX-512 + VPCLMULQDQ paths are intentionally skipped — they're
// runtime-gated and add binary size for marginal gain on the
// decompress-dominated `pull` workload. Re-enable here if a
// compress-heavy workload appears.
fn cZlibNg(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("zlib_ng", .{}) orelse return null;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Feature-detect macros that upstream's CMake would set after
    // probing the host. Pinned for x86_64-linux + GCC/Clang; add a
    // target-aware switch if rind ever ships for arm64.
    const zng_macros = [_]struct { []const u8, []const u8 }{
        .{ "HAVE_VISIBILITY_HIDDEN", "1" },
        .{ "HAVE_ATTRIBUTE_ALIGNED", "1" },
        .{ "HAVE_BUILTIN_CTZ", "1" },
        .{ "HAVE_BUILTIN_CTZLL", "1" },
        .{ "HAVE_BUILTIN_ASSUME_ALIGNED", "1" },
        .{ "HAVE_POSIX_MEMALIGN", "1" },
        .{ "HAVE_ALIGNED_ALLOC", "1" },
        .{ "HAVE_SYS_AUXV_H", "1" },
        .{ "HAVE_UNISTD_H", "1" },
        .{ "HAVE_THREAD_LOCAL", "1" },
        .{ "_LARGEFILE64_SOURCE", "1" },
        .{ "__USE_LARGEFILE64", "1" },
        .{ "WITH_RUNTIME_CPU_DETECTION", "1" },
        .{ "X86_FEATURES", "1" },
        .{ "X86_SSE2", "1" },
        .{ "X86_SSSE3", "1" },
        .{ "X86_SSE42", "1" },
        .{ "X86_PCLMULQDQ_CRC", "1" },
        .{ "X86_AVX2", "1" },
        .{ "HASH_SIZE", "65536u" },
    };
    for (zng_macros) |m| mod.addCMacro(m[0], m[1]);

    const base_flags = &[_][]const u8{
        "-std=gnu11",
        "-Wno-unused-parameter",
        "-Wno-unused-function",
        "-Wno-implicit-fallthrough",
    };

    // Core sources — see SOURCES.md for the rationale on including
    // deflate-side files even though rind only inflates.
    mod.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &.{
            "adler32.c",
            "compress.c",
            "cpu_features.c",
            "crc32.c",
            "crc32_braid_comb.c",
            "deflate.c",
            "deflate_fast.c",
            "deflate_huff.c",
            "deflate_medium.c",
            "deflate_quick.c",
            "deflate_rle.c",
            "deflate_slow.c",
            "deflate_stored.c",
            "functable.c",
            "infback.c",
            "inflate.c",
            "inftrees.c",
            "insert_string.c",
            "insert_string_roll.c",
            "trees.c",
            "uncompr.c",
            "zutil.c",
        },
        .flags = base_flags,
    });

    // arch/generic — portable C fallbacks. functable.c initialises every
    // dispatch slot to these and overrides only the slots whose SIMD
    // counterpart was detected at runtime; missing them = unresolved symbols.
    mod.addCSourceFiles(.{
        .root = dep.path("arch/generic"),
        .files = &.{
            "adler32_c.c",
            "adler32_fold_c.c",
            "chunkset_c.c",
            "compare256_c.c",
            "crc32_braid_c.c",
            "crc32_fold_c.c",
            "slide_hash_c.c",
        },
        .flags = base_flags,
    });

    // arch/x86 — baseline (SSE2 is implicit on x86_64).
    mod.addCSourceFiles(.{
        .root = dep.path("arch/x86"),
        .files = &.{
            "x86_features.c",
            "chunkset_sse2.c",
            "compare256_sse2.c",
            "slide_hash_sse2.c",
        },
        .flags = base_flags,
    });

    // arch/x86 — SSSE3 group.
    mod.addCSourceFiles(.{
        .root = dep.path("arch/x86"),
        .files = &.{
            "adler32_ssse3.c",
            "chunkset_ssse3.c",
        },
        .flags = base_flags ++ &[_][]const u8{"-mssse3"},
    });

    // arch/x86 — SSE4.2.
    mod.addCSourceFiles(.{
        .root = dep.path("arch/x86"),
        .files = &.{"adler32_sse42.c"},
        .flags = base_flags ++ &[_][]const u8{"-msse4.2"},
    });

    // arch/x86 — PCLMUL (also needs SSE4.2 for the intrinsics it pulls).
    mod.addCSourceFiles(.{
        .root = dep.path("arch/x86"),
        .files = &.{"crc32_pclmulqdq.c"},
        .flags = base_flags ++ &[_][]const u8{ "-msse4.2", "-mpclmul" },
    });

    // arch/x86 — AVX2.
    mod.addCSourceFiles(.{
        .root = dep.path("arch/x86"),
        .files = &.{
            "adler32_avx2.c",
            "chunkset_avx2.c",
            "compare256_avx2.c",
            "slide_hash_avx2.c",
        },
        .flags = base_flags ++ &[_][]const u8{"-mavx2"},
    });

    // Hand-authored zconf-ng.h, zlib-ng.h, zlib_name_mangling-ng.h.
    mod.addIncludePath(b.path("cdeps/zlib-ng"));
    // Library private headers (zbuild.h, inflate.h, etc.) sit at the
    // tarball root.
    mod.addIncludePath(dep.path(""));
    // arch/x86 headers (x86_features.h, x86_functions.h) referenced
    // by cpu_features.h and arch_functions.h.
    mod.addIncludePath(dep.path("arch/x86"));

    return b.addLibrary(.{
        .name = "z-ng",
        .linkage = .static,
        .root_module = mod,
    });
}
