const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const config = @import("config.zig");
const fzf = @import("fzf.zig");

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

fn setPaths(arena: *std.heap.ArenaAllocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    const gpa = arena.allocator();

    const cfg_file, var cfg = config.getAndTruncateConfig(arena) catch |err|
        abort("error parsing config: {s}\n", .{@errorName(err)});
    defer cfg_file.close();

    var source_map: std.ArrayHashMapUnmanaged(Source, void, Source.Context, false) = .empty;
    defer source_map.deinit(gpa);

    const cwd = std.fs.cwd();
    for (paths) |path| {
        if (std.fs.path.isAbsolute(path)) {
            _ = try source_map.getOrPut(gpa, .{ .root = path });
        }

        const abs_path = try cwd.realpathAlloc(gpa, path);
        _ = try source_map.getOrPut(gpa, .{ .root = abs_path });
    }

    cfg.sources = source_map.keys();

    try std.json.stringify(cfg, .{ .whitespace = .indent_2 }, cfg_file.writer());

    try stdout.writeAll("paths successfully set\n");
}

fn addPaths(arena: *std.heap.ArenaAllocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    const gpa = arena.allocator();

    const cfg_file, var cfg = config.getAndTruncateConfig(arena) catch |err|
        abort("error parsing config: {s}\n", .{@errorName(err)});
    defer cfg_file.close();

    var source_map: std.ArrayHashMapUnmanaged(Source, void, Source.Context, false) = .empty;
    defer source_map.deinit(gpa);

    for (cfg.sources) |source| {
        _ = try source_map.getOrPut(gpa, source);
    }

    const cwd = std.fs.cwd();
    for (paths) |path| {
        if (std.fs.path.isAbsolute(path)) {
            _ = try source_map.getOrPut(gpa, .{ .root = path });
        }

        const abs_path = try cwd.realpathAlloc(gpa, path);
        _ = try source_map.getOrPut(gpa, .{ .root = abs_path });
    }

    cfg.sources = source_map.keys();

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
        assert(paths.len > 0);

        const s = try gpa.alloc(Source, paths.len);
        for (paths, 0..) |path, idx| {
            s[idx] = .{ .root = path };
        }
        break :blk s;
    } else cfg.sources;

    var walker: Walker = .init(gpa, sources);
    const repos = try walker.parseRoots();

    if (opts.repo) |repo_name| {
        for (repos) |repo_path| {
            if (std.mem.endsWith(u8, repo_path, repo_name)) {
                try stdout.print("found: {s}\n", .{repo_path});
                return;
            }
        }
    }

    const resp = try fzf.runProcess(gpa, repos, opts.preview_cmd);

    if (resp) |r| {
        try stdout.print("chose: {s}\n", .{r});
    }
}

fn abort(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    std.process.exit(1);
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
