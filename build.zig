const std = @import("std");

const walk = @import("src/walk.zig");
const build_zig_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();

    const version = try std.SemanticVersion.parse(build_zig_zon.version);
    options.addOption(std.SemanticVersion, "cs_version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addOptions("options", options);

    const exe = b.addExecutable(.{
        .name = "cs",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    { // docs
        const docs_install = b.addInstallDirectory(.{
            .source_dir = exe.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const docs_step = b.step("docs", "Generate docs");
        docs_step.dependOn(&docs_install.step);
    }

    const filters = b.option([]const []const u8, "test-filter", "Test filters") orelse &.{};
    const exe_tests = b.addTest(.{
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe_tests.root_module.addOptions("options", options);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const check_exe = b.addExecutable(.{
        .name = "cs",
        .root_module = mod,
    });

    const check_step = b.step("check", "Check that app compiles");
    check_step.dependOn(&check_exe.step);
    check_step.dependOn(&exe_tests.step);
}
