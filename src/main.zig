const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const fs = std.fs;
const process = std.process;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const config = @import("config.zig");
const cli = @import("cli.zig");
const walk = @import("walk.zig");

const FZF_NO_MATCH_EXIT_CODE: u8 = 1;
const FZF_INTERRUPT_EXIT_CODE: u8 = 130;

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

fn exit(msg: []const u8) noreturn {
    fs.File.stderr().writeAll(msg) catch {};
    process.exit(1);
}

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
    const env_map = try process.getEnvMap(arena);

    var cfg_context = try config.openConfig(arena, &env_map);
    cfg_context.config_file.close();

    const cfg = cfg_context.config;

    if (cfg.project_roots.len == 0) {
        exit("no project roots found. add one using the '--add-paths' flag\n");
    }

    const preview = search_opts.preview orelse cfg.preview;

    var fzf_proc = try spawnFzf(arena, search_opts.project, preview);

    // +1 for the new line
    var path_buf: [fs.max_path_bytes + 1]u8 = undefined;
    const path = searchProject(
        arena,
        &fzf_proc,
        cfg.project_roots,
        search_opts.project,
        &path_buf,
    ) catch |err| switch (err) {
        error.FzfNotFound => exit("fzf binary not found in path\n"),
        error.NoProjectsFound => exit("no projects found\n"),
        else => return err,
    };

    if (path) |p| {
        std.debug.print("found {s}\n", .{p});
    } else {
        std.debug.print("search aborted\n", .{});
    }
}

const SearchError =
    error{
        NoProjectsFound,
        // from killing the process
        AlreadyTerminated,
    } ||
    ExtractError || walk.SearchError || process.Child.SpawnError;

/// searches for project. returned slice may or may not be the buffer passed in.
/// always terminates the passed-in process
fn searchProject(
    arena: Allocator,
    fzf_proc: *process.Child,
    roots: []const []const u8,
    project_query: []const u8,
    path_buf: []u8,
) SearchError!?[]const u8 {
    var buf: [256]u8 = undefined;
    var fzf_bw = fzf_proc.stdin.?.writer(&buf);
    const fzf_stdin = &fzf_bw.interface;

    const project_set = walk.searchProjects(arena, roots, .{
        .writer = fzf_stdin,
        .flush_after = .project,
    }) catch |err| return switch (err) {
        // most likely failed due to selecting a project before finishing search
        error.WriteFailed => extractProject(fzf_proc, path_buf),
        else => err,
    };

    const projects = project_set.keys();

    if (projects.len == 0) {
        _ = try fzf_proc.kill();
        return error.NoProjectsFound;
    }

    fzf_proc.stdin.?.close();
    fzf_proc.stdin = null;

    if (matchProject(project_query, projects)) |matched_path| {
        // found singular exact project match, abort fzf and return
        _ = try fzf_proc.kill();
        // TODO: should we fill the path_buf and return it for consistency?
        return matched_path;
    }

    return extractProject(fzf_proc, path_buf);
}

const ExtractError = error{
    FzfNotFound,
    NonZeroExitCode,
    BadTermination,
} || std.Io.Reader.DelimiterError || process.Child.WaitError;

fn extractProject(fzf_proc: *process.Child, buf: []u8) ExtractError!?[]const u8 {
    var br = fzf_proc.stdout.?.reader(buf);
    const fzf_reader = &br.interface;

    const path = fzf_reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };

    const term = fzf_proc.wait() catch |err| switch (err) {
        error.FileNotFound => return error.FzfNotFound,
        else => return err,
    };

    return switch (term) {
        .Exited => |code| switch (code) {
            0 => path,
            FZF_NO_MATCH_EXIT_CODE, FZF_INTERRUPT_EXIT_CODE => null,
            else => error.NonZeroExitCode,
        },
        else => error.BadTermination,
    };
}

fn spawnFzf(gpa: Allocator, project: []const u8, preview: []const u8) process.Child.SpawnError!process.Child {
    var fzf_proc = std.process.Child.init(&.{
        "fzf",
        "--header=choose a repo",
        "--reverse",
        "--scheme=path",
        "--preview-label=[ repository files ]",
        "--preview",
        preview,
        "--query",
        project,
    }, gpa);

    fzf_proc.stdin_behavior = .Pipe;
    fzf_proc.stdout_behavior = .Pipe;

    try fzf_proc.spawn();

    return fzf_proc;
}

fn matchProject(project: []const u8, project_paths: []const []const u8) ?[]const u8 {
    if (project.len == 0) return null;

    var match: ?[]const u8 = null;

    for (project_paths) |path| {
        if (std.mem.endsWith(u8, path, project)) {
            if (match != null) return null;
            match = path;
        }
    }

    return match;
}

test matchProject {
    try testing.expectEqualStrings("/foo/bar/abc", matchProject("abc", &.{
        "/foo/bar/123",
        "/foo/bar/abc",
        "/bar/bar/bar",
    }).?);

    try testing.expectEqualStrings("/foo/bar/abc", matchProject("abc", &.{"/foo/bar/abc"}).?);

    try testing.expectEqual(null, matchProject("abc", &.{
        "/foo/bar/123",
        "/foo/bar/baz",
        "/bar/bar/bar",
    }));

    try testing.expectEqual(null, matchProject("abc", &.{
        "/foo/bar/123",
        "/foo/bar/abc",
        "/bar/bar/bar",
        "/foo/baz/abc",
    }));

    try testing.expectEqual(null, matchProject("", &.{"/foo/bar/123"}));
}

test "ref all decls" {
    testing.refAllDeclsRecursive(@This());
}
