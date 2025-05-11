const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const config = @import("config.zig");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const USAGE =
    \\usage: cs [repo] [flags]
    \\
    \\arguments:
    \\
    \\  repo                          repository to automatically open if found
    \\
    \\
    \\flags:
    \\
    \\  -h, --help                    print this message
    \\  --config                      print config and config path
    \\  -p, --paths     <path> [...]  choose paths to search for in this run
    \\  -s, --set-paths <path> [...]  update config setting paths to search for
    \\  -a, --add-paths <path> [...]  update config adding to paths to search for
    \\
    \\
    \\description:
    \\
    \\  search for git repositories in a list of configured paths and prompt user to
    \\  either create a new tmux session or open an existing one inside that directory
    \\
;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    try start(gpa);
}

fn start(allocator: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    const gpa = arena_state.allocator();

    const args = try std.process.argsAlloc(gpa);

    const cmd = cli.parseArgs(args) catch |err| {
        stderr.print("error parsing arguments: {s}\n", .{@errorName(err)}) catch {};
        stderr.writeAll(USAGE) catch {};
        std.process.exit(1);
    };

    switch (cmd) {
        .help => try printHelp(),
        .config => try printConfig(&arena_state),
        .set_paths => |p| try setPaths(p),
        .add_paths => |p| try addPaths(p),
        .run => |r| try run(r.paths, r.repo),
    }
}

fn printHelp() !void {
    try stdout.writeAll(USAGE);
}

fn printConfig(arena: *std.heap.ArenaAllocator) !void {
    const gpa = arena.allocator();
    const cfg_path = config.getConfigPaths();

    var buf_writer = std.io.bufferedWriter(stdout);

    const writer = buf_writer.writer();

    const file_path = try std.fs.path.join(gpa, &.{ cfg_path.base_path, cfg_path.sub_path, "config.json" });

    try writer.print("config path: {s}\n", .{file_path});

    const cfg_file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
        try buf_writer.flush();
        switch (err) {
            error.FileNotFound => abort("no config file found\n", .{}),
            else => abort("error opening config file: {s}\n", .{@errorName(err)}),
        }
    };
    defer cfg_file.close();

    var reader = std.json.reader(gpa, cfg_file.reader());
    const cfg = std.json.parseFromTokenSourceLeaky(config.Config, gpa, &reader, .{}) catch |err|
        abort("error parsing config: {s}\n", .{@errorName(err)});

    if (cfg.sources.len == 0) {
        try writer.writeAll("\nno search sources\n");
    } else {
        try writer.writeAll("\nsearch sources:\n");
        for (cfg.sources) |src| {
            try writer.print("  - path: {s}\n", .{src.root});
            try writer.print("    depth: {d}\n", .{src.depth});
        }
    }

    if (cfg.preview_cmd) |preview| {
        try writer.print("\npreview command: '{s}'\n", .{preview});
    } else {
        try writer.writeAll("\nno preview command\n");
    }

    try buf_writer.flush();
}

fn setPaths(paths: []const []const u8) !void {
    std.debug.print("setting paths: |", .{});
    for (paths) |p| {
        std.debug.print(" {s} |", .{p});
    }
    std.debug.print("\n", .{});
}

fn addPaths(paths: []const []const u8) !void {
    std.debug.print("adding paths: |", .{});
    for (paths) |p| {
        std.debug.print(" {s} |", .{p});
    }
    std.debug.print("\n", .{});
}

fn run(paths: ?[]const []const u8, repo: ?[]const u8) !void {
    std.debug.print("running\n", .{});
    if (paths) |ps| {
        std.debug.print("paths: |", .{});
        for (ps) |p| {
            std.debug.print(" {s} |", .{p});
        }
        std.debug.print("\n", .{});
    }
    if (repo) |r| std.debug.print("repo: {s}\n", .{r});
}

fn abort(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    std.process.exit(1);
}
