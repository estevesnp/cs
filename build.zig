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

    // tests
    {
        const test_step = b.step("test", "Run unit tests");

        registerTests(b, test_step) catch |err|
            std.debug.panic("error registering tests: {s}", .{@errorName(err)});
    }

    // check
    {
        const check_exe = b.addExecutable(.{
            .name = "cs",
            .root_module = exe_mod,
        });

        const check_step = b.step("check", "Check if app compiles");
        check_step.dependOn(&check_exe.step);
    }
}

fn registerTests(b: *std.Build, test_step: *std.Build.Step) !void {
    var src_dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    defer src_dir.close();

    var walker = try src_dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const unit_test = b.addTest(.{
            .root_source_file = b.path(b.pathJoin(&.{ "src", entry.path })),
        });

        const run_exe_unit_tests = b.addRunArtifact(unit_test);

        test_step.dependOn(&run_exe_unit_tests.step);
    }
}
