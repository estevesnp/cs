const std = @import("std");
const builtin = @import("builtin");

const build_zig_zon: Z = @import("build.zig.zon");

const Z = struct {
    version: []const u8,
    name: enum { cs },
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {},
    paths: []const []const u8,
};

pub fn build(b: *std.Build) void {
    if (builtin.os.tag == .windows) @compileError("tmux is not available on windows");
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const version = std.SemanticVersion.parse(build_zig_zon.version) catch @panic("invalid build.zig.zon version");

    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "cs_version", version);

    exe_mod.addOptions("options", options);

    const exe = b.addExecutable(.{
        .name = "cs",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    { // tests
        const unit_tests = b.addTest(.{
            .root_source_file = b.path("src/tests.zig"),
        });

        unit_tests.root_module.addOptions("options", options);

        const run_exe_unit_tests = b.addRunArtifact(unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    { // check
        const check_exe = b.addExecutable(.{
            .name = "cs",
            .root_module = exe_mod,
        });

        const check_step = b.step("check", "Check if app compiles");
        check_step.dependOn(&check_exe.step);
    }
}
