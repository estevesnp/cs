const std = @import("std");

const build_zig_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "cs_version", getCsVersion(b));
    mod.addOptions("options", options);

    const walk_mod = b.addModule("walk", .{
        .root_source_file = b.path("src/walk/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("walk", walk_mod);

    const exe = b.addExecutable(.{
        .name = "cs",
        .root_module = mod,
        .use_llvm = b.option(bool, "llvm", "use llvm for executable"),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "run the app");
    run_step.dependOn(&run_cmd.step);

    const build_walk = b.option(bool, "libwalk", "build lib for walk.zig") orelse false;
    if (build_walk) {
        const lib = b.addLibrary(.{
            .name = "walk",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/walk/ffi/walk.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "walk", .module = walk_mod }},
            }),
        });
        b.installArtifact(lib);
    }

    const filters = b.option([]const []const u8, "test-filter", "test filters") orelse &.{};
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

    const test_step = b.step("test", "run tests");
    test_step.dependOn(&run_exe_tests.step);

    const check_exe = b.addExecutable(.{
        .name = "cs",
        .root_module = mod,
    });

    const check_step = b.step("check", "check that app compiles");
    check_step.dependOn(&check_exe.step);
    check_step.dependOn(&exe_tests.step);
}

fn getCsVersion(b: *std.Build) []const u8 {
    const tagged_version = b.option(bool, "tagged-version", "use tagged version") orelse false;
    if (tagged_version) return build_zig_zon.version;

    const res = b.runFallible(&.{ "git", "rev-parse", "--short", "HEAD" }, .{});
    switch (res) {
        .success => |hash| {
            const trimmed = std.mem.trimEnd(u8, hash, "\r\n");
            return b.fmt("{s}-dev.{s}", .{ build_zig_zon.version, trimmed });
        },
        else => {
            std.log.err("error fetching git hash ({t}). defaulting to version from build.zig.zon", .{res});
            return build_zig_zon.version;
        },
    }
}
