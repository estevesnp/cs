const std = @import("std");

const cs_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch
    @compileError("invalid version in build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "cs_version", getVersion(b));
    mod.addOptions("options", options);

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

    const walk_mod = b.addModule("walk", .{
        .root_source_file = b.path("src/walk/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_walk = b.option(bool, "libcswalk", "build libcswalk") orelse false;
    if (build_walk) {
        const lib = b.addLibrary(.{
            .name = "cswalk",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/walk/ffi/cswalk.zig"),
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

fn getVersion(b: *std.Build) std.SemanticVersion {
    const version_string = b.option([]const u8, "version-string", "override version. must be a semantic version");
    if (version_string) |semver_string| {
        return std.SemanticVersion.parse(semver_string) catch |err| {
            std.debug.panic("expected -Dversion-string={s} to be a semantic version: {}", .{ semver_string, err });
        };
    }

    const default_version: std.SemanticVersion = .{
        .major = cs_version.major,
        .minor = cs_version.minor,
        .patch = cs_version.patch,
        .pre = "dev",
    };

    if (!b.isRoot()) {
        return default_version;
    }

    b.dependOnFileContents(b.path(".git/logs/HEAD"));

    const res = b.runFallible(&.{ "git", "rev-parse", "--short", "HEAD" }, .{});
    if (res != .success) {
        std.log.err("error fetching git hash ({t}). defaulting to version from build.zig.zon", .{res});
        return default_version;
    }

    const hash = std.mem.trimEnd(u8, res.success, "\r\n");
    return .{
        .major = cs_version.major,
        .minor = cs_version.minor,
        .patch = cs_version.patch,
        .pre = "dev",
        .build = hash,
    };
}
