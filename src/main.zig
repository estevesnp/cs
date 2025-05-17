const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const json = std.json;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const config = @import("config.zig");
const fzf = @import("fzf.zig");
const tmux = @import("tmux.zig");

const Walker = @import("Walker.zig");
const Config = config.Config;
const Source = config.Source;

const SourceSet = std.ArrayHashMapUnmanaged(Source, void, Source.Context, true);

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub const Diag = struct {
    stream: std.io.AnyWriter,

    pub const stderr_stream: Diag = .{ .stream = stderr.any() };

    pub fn init(stream: std.io.AnyWriter) Diag {
        return .{ .stream = stream };
    }

    pub fn report(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        self.stream.print(fmt, args) catch |err| {
            std.debug.print("couldn't write to stream: {s}\n", .{@errorName(err)});
        };
    }
};

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
    //defer std.debug.print("exiting main...\n", .{});
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var diag: Diag = .stderr_stream;

    try start(gpa, &diag);
}

fn start(allocator: Allocator, diag: ?*Diag) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    const args = try std.process.argsAlloc(gpa);

    const cmd = cli.parseArgs(args, diag) catch abortDiag(diag, "\n" ++ USAGE, .{});

    switch (cmd) {
        .help => try printHelp(),
        .config => try printConfig(&arena, diag),
        .set_paths => |p| try setPaths(&arena, p, diag),
        .add_paths => |p| try addPaths(&arena, p, diag),
        .run => |opts| try run(&arena, opts, diag),
    }
}

fn printHelp() !void {
    try stdout.writeAll(USAGE);
}

fn printConfig(arena: *std.heap.ArenaAllocator, diag: ?*Diag) !void {
    const gpa = arena.allocator();

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const file_path = try config.getConfigPath(gpa, &env_map);
    try stdout.print("config path: {s}\n", .{file_path});

    var buf_writer = std.io.bufferedWriter(stdout);
    const writer = buf_writer.writer();

    const cfg_file = fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => abortDiag(diag, "\nno config file found\n", .{}),
        else => abortDiag(diag, "\nerror opening config file: {s}\n", .{@errorName(err)}),
    };
    defer cfg_file.close();

    var json_reader = std.json.reader(gpa, cfg_file.reader());
    defer json_reader.deinit();

    const cfg = std.json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{}) catch |err|
        abortDiag(diag, "error parsing config: {s}\n", .{@errorName(err)});

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

fn populateSources(gpa: Allocator, source_set: *SourceSet, paths: []const []const u8) !void {
    const cwd = std.fs.cwd();
    for (paths) |path| {
        if (std.fs.path.isAbsolute(path)) {
            _ = try source_set.getOrPut(gpa, .{ .root = path });
        }

        const abs_path = try cwd.realpathAlloc(gpa, path);
        _ = try source_set.getOrPut(gpa, .{ .root = abs_path });
    }
}

fn setPaths(arena: *std.heap.ArenaAllocator, paths: []const []const u8, diag: ?*Diag) !void {
    assert(paths.len > 0);

    const gpa = arena.allocator();

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const cfg_file, var cfg = try config.getAndTruncateConfig(arena, &env_map, diag);
    defer cfg_file.close();

    var source_set: SourceSet = .empty;
    defer source_set.deinit(gpa);

    try populateSources(gpa, &source_set, paths);

    cfg.sources = source_set.keys();

    try std.json.stringify(cfg, .{ .whitespace = .indent_2 }, cfg_file.writer());

    try stdout.writeAll("paths successfully set\n");
}

fn addPaths(arena: *std.heap.ArenaAllocator, paths: []const []const u8, diag: ?*Diag) !void {
    assert(paths.len > 0);

    const gpa = arena.allocator();

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const cfg_file, var cfg = try config.getAndTruncateConfig(arena, &env_map, diag);
    defer cfg_file.close();

    var source_set: SourceSet = .empty;
    defer source_set.deinit(gpa);

    for (cfg.sources) |source| {
        _ = try source_set.getOrPut(gpa, source);
    }

    try populateSources(gpa, &source_set, paths);

    cfg.sources = source_set.keys();

    try std.json.stringify(cfg, .{ .whitespace = .indent_2 }, cfg_file.writer());

    try stdout.writeAll("paths successfully added\n");
}

fn run(arena: *std.heap.ArenaAllocator, opts: cli.RunOpts, diag: ?*Diag) !void {
    const gpa = arena.allocator();

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const cfg_file = try config.createOrOpen(&env_map);
    defer cfg_file.close();

    var json_reader = std.json.reader(gpa, cfg_file.reader());
    defer json_reader.deinit();

    const cfg = std.json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{}) catch |err|
        abortDiag(diag, "error parsing config: {s}\n", .{@errorName(err)});

    var source_set: SourceSet = .empty;
    defer source_set.deinit(gpa);

    const sources = if (opts.paths) |paths| blk: {
        assert(paths.len > 0);

        try populateSources(gpa, &source_set, paths);
        break :blk source_set.keys();
    } else cfg.sources;

    var walker: Walker = .init(gpa, sources);
    const repo_paths = try walker.parseRoots(diag);

    const repo_path: ?[]const u8 = blk: {
        if (opts.repo) |repo_name| {
            if (searchForBasename(repo_name, repo_paths)) |found| break :blk found;
        }
        break :blk try fzf.runProcess(gpa, repo_paths, opts.preview_cmd, opts.repo, diag);
    };

    if (repo_path == null) std.process.exit(1);

    try tmux.createSession(gpa, repo_path.?, fs.path.basename(repo_path.?), &env_map, diag);
}

/// searches for a path basename in a list of paths
/// returns null if it wasn't found or if there were more than one matching paths
fn searchForBasename(basename: []const u8, paths: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (paths) |path| {
        if (std.mem.eql(u8, fs.path.basename(path), basename)) {
            if (found == null) {
                found = path;
                continue;
            }
            return null;
        }
    }
    return found;
}

fn abortDiag(diag: ?*Diag, comptime fmt: []const u8, args: anytype) noreturn {
    if (diag) |d| d.report(fmt, args);
    std.process.exit(1);
}

fn abort(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    std.process.exit(1);
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test searchForBasename {
    const repos: []const []const u8 = &.{ "/a/b/c", "/a/b/d", "/a/b/e", "/c/d/e" };

    try std.testing.expectEqual("/a/b/c", searchForBasename("c", repos));
    try std.testing.expectEqual("/a/b/d", searchForBasename("d", repos));
    try std.testing.expectEqual(null, searchForBasename("b", repos));
    try std.testing.expectEqual(null, searchForBasename("e", repos));
}
