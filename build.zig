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
}
