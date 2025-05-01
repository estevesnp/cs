const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const cli = @import("cli.zig");
const Options = cli.Options;
const config = @import("config.zig");
const Config = config.Config;
const Walker = @import("Walker.zig");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    try start(gpa);
}

pub fn start(allocator: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var diag: cli.Diag = .default_streams;

    const args = try std.process.argsAlloc(arena);
    const opts = try Options.parseFromArgs(args, &diag);

    printOpts(opts);

    const cfg = try getConfig(arena);
    defer cfg.deinit();
    try run(arena, cfg.value);
}

fn getConfig(allocator: Allocator) !json.Parsed(Config) {
    const cfg_path = try config.getDefaultConfigPath(allocator);
    defer allocator.free(cfg_path);

    const cfg_file = std.fs.openFileAbsolute(cfg_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("config file not found. please create one at {s}\n", .{cfg_path});
            std.process.exit(1);
        },
        else => return err,
    };
    defer cfg_file.close();

    return config.parseConfig(allocator, cfg_file);
}

fn printOpts(opts: cli.Options) void {
    if (opts.depth) |d| {
        std.debug.print("depth: {d}\n", .{d});
    }

    if (opts.roots) |roots| {
        std.debug.print("roots:\n", .{});
        for (roots) |root| {
            std.debug.print("\t{s}\n", .{root});
        }
    }
}

fn run(allocator: Allocator, cfg: Config) !void {
    var walker: Walker = .init(allocator, cfg.roots);
    defer walker.deinit();

    const dirs = try walker.parseRoots();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (dirs) |dir| {
        try out.appendSlice(allocator, dir);
        try out.append(allocator, '\n');
    }

    try stdout.writeAll(out.items);
}
