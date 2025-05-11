const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const cfg = @import("cfg.zig");

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

    const cmd = cfg.parseArgs(args) catch |err| {
        stderr.print("error parsing arguments: {s}\n", .{@errorName(err)}) catch {};
        stderr.writeAll(USAGE) catch {};
        std.process.exit(1);
    };

    switch (cmd) {
        .help => try printHelp(),
        .config => try printConfig(),
        .set_paths => |p| try setPaths(p),
        .add_paths => |p| try addPaths(p),
        .run => |r| try run(r.paths, r.repo),
    }
}

fn printHelp() !void {
    try stdout.writeAll(USAGE);
}

fn printConfig() !void {
    std.debug.print("config\n", .{});
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
