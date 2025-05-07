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

    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    try run(gpa);
}

pub fn run(allocator: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var diag: cli.Diag = .default_streams;

    const args = try std.process.argsAlloc(arena);
    const opts = try Options.parseFromArgs(args, &diag);

    var cfg_file = config.createOrOpen() catch |err| switch (err) {
        std.fs.File.OpenError.FileNotFound => abort("config base path not found\n", .{}),
        else => return err,
    };
    defer cfg_file.close();

    const cfg =
        if (opts.roots) |roots|
            try config.updateConfig(&arena_state, cfg_file, roots)
        else
            config.openConfig(&arena_state, cfg_file) catch |err| switch (err) {
                std.json.Error.UnexpectedEndOfInput => abort("no config file. configure by using the -p/--paths flag\n", .{}),
                std.json.Error.SyntaxError => abort("bad config file\n", .{}),
                else => return err,
            };

    if (cfg.roots.len == 0) {
        abort("config has no roots. configure by using the -p/--paths flag\n", .{});
    }

    try parseAndPrintRepos(arena, cfg.roots, opts.depth);
}

fn parseAndPrintRepos(allocator: Allocator, roots: []const []const u8, max_depth: ?usize) !void {
    var walker: Walker = .init(allocator, roots, max_depth);
    defer walker.deinit();

    const dirs = walker.parseRoots() catch |err| switch (err) {
        error.InvalidPath => abort("invalid config. bad path\n", .{}),
        else => return err,
    };

    var buf_writer = std.io.bufferedWriter(stdout);
    const writer = buf_writer.writer();

    for (dirs) |dir| {
        try writer.writeAll(dir);
        try writer.writeByte('\n');
    }

    try buf_writer.flush();
}

fn abort(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    std.process.exit(1);
}
