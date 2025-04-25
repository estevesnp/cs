const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const test_files: []const []const u8 = &.{ "src/main.zig", "src/Walker.zig" };

    const test_step = b.step("test", "Run unit tests");

    for (test_files) |test_file| {
        const exe_unit_tests = b.addTest(.{
            .root_source_file = b.path(test_file),
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        test_step.dependOn(&run_exe_unit_tests.step);
    }

    const check_exe = b.addExecutable(.{
        .name = "cs",
        .root_module = exe_mod,
    });

    const check_step = b.step("check", "Check if app compiles");
    check_step.dependOn(&check_exe.step);
}
