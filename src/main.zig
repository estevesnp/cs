const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const config = @import("config.zig");

const Walker = @import("Walker.zig");
const Config = config.Config;
const Source = config.Source;

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
    \\  --preview <str>               preview command to pass to fzf
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
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    const args = try std.process.argsAlloc(gpa);

    const cmd = cli.parseArgs(args) catch |err| {
        stderr.print("error parsing arguments: {s}\n\n", .{@errorName(err)}) catch {};
        stderr.writeAll(USAGE) catch {};
        std.process.exit(1);
    };

    switch (cmd) {
        .help => try printHelp(),
        .config => try printConfig(&arena),
        .set_paths => |p| try setPaths(&arena, p),
        .add_paths => |p| try addPaths(&arena, p),
        .run => |opts| try run(&arena, opts),
    }
}

fn printHelp() !void {
    try stdout.writeAll(USAGE);
}

fn printConfig(arena: *std.heap.ArenaAllocator) !void {
    const gpa = arena.allocator();

    const file_path = try config.getConfigPath(gpa);
    try stdout.print("config path: {s}\n", .{file_path});

    var buf_writer = std.io.bufferedWriter(stdout);
    const writer = buf_writer.writer();

    const cfg_file = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => abort("\nno config file found\n", .{}),
        else => abort("\nerror opening config file: {s}\n", .{@errorName(err)}),
    };
    defer cfg_file.close();

    var json_reader = std.json.reader(gpa, cfg_file.reader());
    defer json_reader.deinit();

    const cfg = std.json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{}) catch |err|
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

fn populateSources(gpa: Allocator, sources: []Source, paths: []const []const u8) !void {
    const cwd = std.fs.cwd();

    for (paths, 0..) |path, idx| {
        if (std.fs.path.isAbsolute(path)) {
            sources[idx] = .{ .root = path };
            continue;
        }

        const abs_path = try cwd.realpathAlloc(gpa, path);
        sources[idx] = .{ .root = abs_path };
    }
}

fn setPaths(arena: *std.heap.ArenaAllocator, paths: []const []const u8) !void {
    const gpa = arena.allocator();

    const cfg_file, var cfg = config.getAndTruncateConfig(arena) catch |err|
        abort("error parsing config: {s}\n", .{@errorName(err)});
    defer cfg_file.close();

    const sources = try gpa.alloc(Source, paths.len);

    populateSources(gpa, sources, paths) catch |err|
        abort("error resolving path: {s}\n", .{@errorName(err)});

    cfg.sources = sources;

    try std.json.stringify(cfg, .{ .whitespace = .indent_2 }, cfg_file.writer());

    try stdout.writeAll("paths successfully set\n");
}

fn addPaths(arena: *std.heap.ArenaAllocator, paths: []const []const u8) !void {
    const gpa = arena.allocator();

    const cfg_file, var cfg = config.getAndTruncateConfig(arena) catch |err|
        abort("error parsing config: {s}\n", .{@errorName(err)});
    defer cfg_file.close();

    const sources = try gpa.alloc(Source, cfg.sources.len + paths.len);
    @memcpy(sources[0..cfg.sources.len], cfg.sources);

    populateSources(gpa, sources[cfg.sources.len..], paths) catch |err|
        abort("error resolving path: {s}\n", .{@errorName(err)});

    cfg.sources = sources;

    try std.json.stringify(cfg, .{ .whitespace = .indent_2 }, cfg_file.writer());

    try stdout.writeAll("paths successfully added\n");
}

fn run(arena: *std.heap.ArenaAllocator, opts: cli.RunOpts) !void {
    const gpa = arena.allocator();

    const cfg_file = try config.createOrOpen();
    defer cfg_file.close();

    var json_reader = std.json.reader(gpa, cfg_file.reader());
    defer json_reader.deinit();

    const cfg = std.json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{}) catch |err|
        abort("error parsing config: {s}\n", .{@errorName(err)});

    const sources = if (opts.paths) |paths| blk: {
        const s = try gpa.alloc(Source, paths.len);
        for (paths, 0..) |path, idx| {
            s[idx] = .{ .root = path };
        }
        break :blk s;
    } else cfg.sources;

    var walker: Walker = .init(gpa, sources);
    const repos = try walker.parseRoots();

    for (repos) |repo| {
        std.debug.print("{s}\n", .{repo});
    }
}

fn abort(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    std.process.exit(1);
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
