const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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

    const build_options = b.addOptions();
    build_options.addOption(bool, "e2e_enabled", enable_e2e);

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("rind", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = dev_libc,
        .imports = &.{
            .{ .name = "rind", .module = mod },
            .{ .name = "clap", .module = clap_dep.module("clap") },
            .{ .name = "build_options", .module = build_options.createModule() },
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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // T17 phase A — audit step. Walks vendor/crun-1.23/src/ and prints a
    // Markdown table of SPDX licenses for every translation unit. Exits
    // non-zero if a GPL-only file is found in the compile set
    // (build/cdeps/crun/SOURCES.md). Run with `rtk zig build audit`.
    const audit_step = b.step("audit", "Walk vendored libcrun source for non-LGPL files");
    const run_audit = b.addSystemCommand(&.{
        b.pathFromRoot("scripts/lgpl_audit.sh"),
        b.pathFromRoot("vendor/crun-1.23/src"),
    });
    audit_step.dependOn(&run_audit.step);

    // T17 phase B — static-link libcrun.a + libseccomp.a + libcap.a +
    // argp_standalone.a into the rind exe (helpers below). Link order
    // matters: libcrun → libseccomp → libcap → argp_standalone (libcrun
    // references argp_parse, which resolves last).

    const crun_lib = cLibcrun(b, target, optimize);
    const seccomp_lib = cSeccomp(b, target, optimize);
    const cap_lib = cLibcap(b, target, optimize);
    const argp_lib = cArgpStandalone(b, target, optimize);

    if (crun_lib) |l| exe_module.linkLibrary(l);
    if (seccomp_lib) |l| exe_module.linkLibrary(l);
    if (cap_lib) |l| exe_module.linkLibrary(l);
    if (argp_lib) |l| exe_module.linkLibrary(l);

    // T17 phase B step 5 — pure-C integration test driving
    // libcrun_container_run() against a synthesized OCI bundle.
    // Gated behind -Dintegration=true because the test needs
    // CAP_SYS_ADMIN or unprivileged user namespaces.
    const integration = b.option(
        bool,
        "integration",
        "Run libcrun integration tests (require CAP_SYS_ADMIN or unprivileged userns).",
    ) orelse false;

    if (integration and crun_lib != null and seccomp_lib != null and cap_lib != null and argp_lib != null) {
        const bundle_dir = synthesizeTrueBundle(b, target);

        const run_true_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        run_true_mod.addCSourceFile(.{
            .file = b.path("tests/c/run_true.c"),
            .flags = &.{"-D_GNU_SOURCE"},
        });
        run_true_mod.addIncludePath(b.path("vendor/crun-1.23/src"));
        run_true_mod.addIncludePath(b.path("vendor/crun-1.23/libocispec/src"));
        run_true_mod.addIncludePath(b.path("build/cdeps/crun"));

        run_true_mod.linkLibrary(crun_lib.?);
        run_true_mod.linkLibrary(seccomp_lib.?);
        run_true_mod.linkLibrary(cap_lib.?);
        run_true_mod.linkLibrary(argp_lib.?);

        const run_true_exe = b.addExecutable(.{
            .name = "run_true",
            .root_module = run_true_mod,
        });

        const run = b.addRunArtifact(run_true_exe);
        run.addDirectoryArg(bundle_dir);
        run.expectExitCode(0);
        test_step.dependOn(&run.step);
    }
}

// synthesizeTrueBundle — composes a minimal OCI bundle into a single
// LazyPath directory. config.json comes from tests/fixtures/bundle/true/;
// rootfs/bin/true is a freshly-built static executable from
// tests/c/true_main.c (so the runtime dynamic linker doesn't need to
// resolve anything from inside the container). Returns the bundle
// directory's LazyPath, suitable as argv to run_true.
fn synthesizeTrueBundle(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    _ = target;

    // /bin/true: must be statically linked because the container has
    // no libc or dynamic linker visible. Uses the same x86_64-linux-musl
    // target as the rest of the build (regardless of the outer target,
    // because the bundle is consumed inside a container that always
    // runs on Linux).
    const true_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    // link_libc=true even though true_main.c only defines `int main()` —
    // musl's CRT supplies _start; without it ld.lld errors out with
    // "cannot find entry symbol _start".
    const true_mod = b.createModule(.{
        .target = true_target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
        .strip = true,
    });
    true_mod.addCSourceFile(.{
        .file = b.path("tests/c/true_main.c"),
        .flags = &.{},
    });
    const true_exe = b.addExecutable(.{
        .name = "true",
        .root_module = true_mod,
    });

    // Compose the bundle dir: copy config.json + drop the freshly-
    // built true binary at rootfs/bin/true. WriteFile gives us a
    // synthesized dir LazyPath in the build cache.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("tests/fixtures/bundle/true/config.json"), "config.json");
    _ = wf.addCopyFile(true_exe.getEmittedBin(), "rootfs/bin/true");

    return wf.getDirectory();
}

// cArgpStandalone — argp-standalone 1.5.0 as a static lib. argp is
// part of glibc but absent from musl; libcrun calls argp_parse, so we
// link this in last on the chain. Lazy dep: first build fetches the
// tarball declared in build.zig.zon. Returns null when the dep is
// resolved-but-unavailable (Zig 0.16 lazy contract).
//
// File list per build/cdeps/argp/SOURCES.md. Hand-authored config.h
// at build/cdeps/argp/config.h pins HAVE_* knobs for x86_64-linux-musl.
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
    mod.addIncludePath(b.path("build/cdeps/argp"));
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
// UAPI snapshot under build/cdeps/cap/uapi/ is the reproducible
// alternative documented at build/cdeps/cap/generated/PROVENANCE.md).
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
// of the source list lives at build/cdeps/cap/SOURCES.md.
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
    mod.addIncludePath(b.path("build/cdeps/cap"));
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
// build/cdeps/seccomp/SOURCES.md (x86_64 arch only). Hand-authored
// configure.h at build/cdeps/seccomp/ (note: the file MUST be named
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
    mod.addIncludePath(b.path("build/cdeps/seccomp"));
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
// File list per build/cdeps/crun/SOURCES.md:
//   - libcrun core (src/*.c)
//   - libcrun handlers (src/handlers/handler-utils.c + exec.c only —
//     wasm/lua/krun/spin/mono handlers excluded; their feature toggles
//     are 0 in build/cdeps/crun/config.h)
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
    // they aren't in build/cdeps/crun/config.h. (No handlers/exec.c
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
    mod.addIncludePath(b.path("build/cdeps/crun")); // config.h, git-version.h
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
