const std = @import("std");
const fzf = @import("fzf.zig");
const json = std.json;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const cli = @import("cli.zig");
const Options = cli.Options;
const config = @import("config.zig");
const Config = config.Config;
const Walker = @import("Walker.zig");

const stdout = std.io.getStdOut();
const stderr = std.io.getStdErr();

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

fn run(allocator: Allocator) !void {
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

    var walker: Walker = .init(arena, cfg.roots, opts.depth);
    defer walker.deinit();

    const dirs = walker.parseRoots() catch |err| switch (err) {
        error.InvalidPath => abort("invalid config. bad path\n", .{}),
        else => return err,
    };

    var buf: [std.fs.max_path_bytes]u8 = undefined;

    const path = try fzf.runProcess(allocator, dirs, &buf) orelse return;

    try stdout.writer().print("selected path: {s}\n", .{path});
}

fn abort(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.writer().print(fmt, args) catch {};
    std.process.exit(1);
}
