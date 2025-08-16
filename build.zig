const std = @import("std");

const build_zig_zon: Z = @import("build.zig.zon");

const Z = struct {
    name: enum { cs },
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {},
    paths: []const []const u8,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = try std.SemanticVersion.parse(build_zig_zon.version);

    const options = b.addOptions();
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

    { // test
        const exe_tests = b.addTest(.{
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
    }

    { // check
        const check_exe = b.addExecutable(.{
            .name = "cs",
            .root_module = mod,
        });

        const check_step = b.step("check", "Check that app compiles");
        check_step.dependOn(&check_exe.step);
    }
}
