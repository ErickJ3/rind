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
    // argp_standalone.a into the rind exe and wire a pure-C integration
    // test (tests/c/run_true.c) against tests/fixtures/bundle/true/.
    //
    // Phase A (this commit) lays the foundation: vendor/crun-1.23/ in
    // tree, build.zig.zon has lazy deps for the other three libs,
    // build/cdeps/<lib>/config.h is hand-authored, scripts/lgpl_audit.sh
    // is wired (above), tests/fixtures/bundle/true/ is in place.
    //
    // Phase B turns those pieces into a green static binary. Concretely:
    //   1. Add helpers `cLibcrun`, `cSeccomp`, `cLibcap`, `cArgpStandalone`
    //      that return *std.Build.Step.Compile via b.addLibrary
    //      (.linkage = .static). Source roots: vendor/crun-1.23/ for
    //      libcrun; b.lazyDependency("libseccomp" | "libcap" |
    //      "argp_standalone", .{}) orelse return for the others.
    //   2. exe_module.linkLibrary in order: libcrun → libseccomp →
    //      libcap → argp_standalone (link-order matters because libcrun
    //      references argp_parse).
    //   3. Add a `buildTrueBinary` helper that compiles tests/c/true_main.c
    //      statically (target = x86_64-linux-musl, link_libc = false) and
    //      installs the result into tests/fixtures/bundle/true/rootfs/bin/true.
    //   4. Add a `run_true` executable that compiles tests/c/run_true.c
    //      against the libcrun include path (vendor/crun-1.23/src and
    //      build/cdeps/crun/), links the four C libs, and is invoked
    //      via b.addRunArtifact with addArg(bundle_dir) and
    //      expectExitCode(0). Hook into test_step.
    //   5. Implement the cap_names.h codegen (see
    //      build/cdeps/cap/generated/PROVENANCE.md): a Zig Step.Run that
    //      compiles _makenames.c and writes cap_names.h into the build
    //      cache; cLibcap addIncludePath the cache dir.
    //
    // Acceptance criteria for phase B:
    //   - `rtk zig build` produces a static binary; `ldd zig-out/bin/rind`
    //     reports "not a dynamic executable".
    //   - `rtk zig build test` runs run_true; expectExitCode(0) holds.
    //   - The four lazy deps fetch on first build (one-time ~5MB).
    //
    // Common musl gotchas to address while wiring:
    //   - Define _GNU_SOURCE globally for libcrun + libseccomp targets.
    //   - argp-standalone link order is enforced via the linkLibrary
    //     call sequence above.
    //   - HAVE_FSCONFIG_CMD_CREATE_LINUX_MOUNT_H=1 in build/cdeps/crun/config.h
    //     is the musl-correct path; do not flip it to the sys/mount.h
    //     variant.
    //   - cgroup-systemd.c, criu.c, and the wasm/lua/krun handlers are
    //     compiled with their feature toggles set to 0 — this keeps the
    //     compile graph honest without pulling in disabled deps.
}
