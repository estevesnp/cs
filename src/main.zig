const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const fs = std.fs;
const process = std.process;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const config = @import("config.zig");
const cli = @import("cli.zig");

const USAGE =
    \\usage: cs [project] [flags]
    \\
    \\arguments:
    \\
    \\  project                       project to automatically open if found
    \\
    \\
    \\flags:
    \\
    \\  -h, --help                    print this message
    \\  -v, -V, --version             print version
    \\  --env                         print config and environment information
    \\  -a, --add-paths <path> [...]  update config adding search paths
    \\  --no-preview                  disables fzf preview
    \\  --preview <str>               preview command to pass to fzf
    \\  --script  <str>               script to run on new tmux session
    \\  --action  <action>            action to execute after finding repository.
    \\                                  options: session, window, cd, print
    \\                                  can also call the action directly, e.g. --cd
    \\
    \\
    \\description:
    \\
    \\  search configured paths for git repositories and run an action on them,
    \\  such as creating a new tmux session or changing directory to the project
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

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var stderr_buf: [1024]u8 = undefined;
    var stderr = fs.File.stderr().writer(&stderr_buf);

    const diag: cli.Diagnostic = .{ .writer = &stderr.interface };

    const args = try process.argsAlloc(arena);

    const command = try cli.parse(&diag, args);

    switch (command) {
        .help => try help(),
        .version => try version(),
        .env => try env(),
        .@"add-paths" => |paths| try addPaths(arena, paths),
        .search => |opts| try search(arena, opts),
    }
}

fn help() !void {
    try fs.File.stdout().writeAll(USAGE);
}

fn version() !void {
    var buf: [100]u8 = undefined;
    var stdout_writer = fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("{f}\n", .{options.cs_version});
    try stdout.flush();
}

fn env() !void {
    try fs.File.stdout().writeAll("env\n");
}

fn addPaths(arena: Allocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    const env_map = try process.getEnvMap(arena);

    var cfg_context = try config.openConfig(arena, &env_map);
    defer cfg_context.deinit();

    var cfg = cfg_context.config;

    var path_set: std.StringArrayHashMapUnmanaged(void) = try .init(arena, cfg.project_roots, &.{});
    defer path_set.deinit(arena);

    const cwd = fs.cwd();
    for (paths) |path| {
        if (path.len == 0) continue;
        const real_path = try cwd.realpathAlloc(arena, path);
        try path_set.put(arena, real_path, {});
    }

    cfg.project_roots = path_set.keys();

    var cfg_file = cfg_context.config_file;

    try cfg_file.setEndPos(0);
    try cfg_file.seekTo(0);

    var buf: [1024]u8 = undefined;
    var file_bw = cfg_file.writer(&buf);

    const file_writer = &file_bw.interface;

    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, file_writer);
    try file_writer.flush();
}

fn search(arena: Allocator, search_opts: cli.SearchOpts) !void {
    _ = search_opts;

    const env_map = try process.getEnvMap(arena);

    var cfg_context = try config.openConfig(arena, &env_map);
    cfg_context.config_file.close();

    const cfg = cfg_context.config;

    if (cfg.project_roots.len == 0) {
        try fs.File.stderr().writeAll("no project roots found. add one using the '--add-paths' flag");
        process.exit(1);
    }

    const walk = @import("walk.zig");
    for (cfg.project_roots) |root| {
        std.debug.print("searching {s}...\n", .{root});
        try walk.search(arena, root);
        std.debug.print("\n", .{});
    }
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
