const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const fs = std.fs;
const process = std.process;
const testing = std.testing;
const File = std.fs.File;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
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
    \\  project                          project to automatically open if found
    \\
    \\
    \\flags:
    \\
    \\  -h, --help                       print this message
    \\  -v, -V, --version                print version
    \\  --env                            print config and environment information
    \\  -a, --add-paths <path> [...]     update config adding search paths
    \\  -s, --set-paths <path> [...]     update config overriding search paths
    \\  -r, --remove-paths <path> [...]  update config removing search paths
    \\  --no-preview                     disables fzf preview
    \\  --preview <str>                  preview command to pass to fzf
    \\  --script  <str>                  script to run on new tmux session
    \\  --action  <action>               action to execute after finding repository.
    \\                                     options: session, window, print
    \\                                     can call the action directly, e.g. --print
    \\
    \\
    \\description:
    \\
    \\  search configured paths for git repositories and run an action on them,
    \\  such as creating a new tmux session or changing directory to the project
    \\
;

fn exit(msg: []const u8) noreturn {
    File.stderr().writeAll(msg) catch {};
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
    var stderr = File.stderr().writer(&stderr_buf);

    const diag: cli.Diagnostic = .{ .writer = &stderr.interface };

    const args = try process.argsAlloc(arena);

    const command = try cli.parse(&diag, args);

    switch (command) {
        .help => try help(),
        .version => try version(),
        .env => try env(),
        .@"add-paths" => |paths| try addPaths(arena, paths),
        .@"set-paths" => |paths| try setPaths(arena, paths),
        .@"remove-paths" => |paths| try removePaths(arena, paths),
        .search => |opts| try search(arena, opts),
    }
}

fn help() File.WriteError!void {
    try File.stdout().writeAll(USAGE);
}

fn version() Writer.Error!void {
    var buf: [100]u8 = undefined;
    var stdout_writer = File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("{f}\n", .{options.cs_version});
    try stdout.flush();
}

fn env() File.WriteError!void {
    try File.stdout().writeAll("env\n");
}

fn updateConfig(cfg_file: File, cfg: config.Config) !void {
    try cfg_file.setEndPos(0);
    try cfg_file.seekTo(0);

    var buf: [1024]u8 = undefined;
    var file_bw = cfg_file.writer(&buf);

    const file_writer = &file_bw.interface;

    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, file_writer);
    try file_writer.flush();
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

    try updateConfig(cfg_context.config_file, cfg);
}

fn setPaths(arena: Allocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    const env_map = try process.getEnvMap(arena);

    var cfg_context = try config.openConfig(arena, &env_map);
    defer cfg_context.deinit();

    var cfg = cfg_context.config;

    var path_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer path_set.deinit(arena);

    const cwd = fs.cwd();
    for (paths) |path| {
        if (path.len == 0) continue;
        const real_path = try cwd.realpathAlloc(arena, path);
        try path_set.put(arena, real_path, {});
    }

    cfg.project_roots = path_set.keys();

    try updateConfig(cfg_context.config_file, cfg);
}

fn removePaths(arena: Allocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    const env_map = try process.getEnvMap(arena);

    var cfg_context = try config.openConfig(arena, &env_map);
    defer cfg_context.deinit();

    var cfg = cfg_context.config;

    var path_set: std.StringArrayHashMapUnmanaged(void) = try .init(arena, cfg.project_roots, &.{});
    defer path_set.deinit(arena);

    const cwd = fs.cwd();
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    for (paths) |path| {
        if (path.len == 0) continue;
        const real_path = try cwd.realpath(path, &path_buf);
        _ = path_set.swapRemove(real_path);
    }

    cfg.project_roots = path_set.keys();

    try updateConfig(cfg_context.config_file, cfg);
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

    // +1 for the new line
    var path_buf: [fs.max_path_bytes + 1]u8 = undefined;
    const path = searchProject(
        arena,
        cfg.project_roots,
        search_opts.project,
        preview,
        &path_buf,
    ) catch |err| switch (err) {
        error.FzfNotFound => exit("fzf binary not found in path\n"),
        error.NoProjectsFound => exit("no projects found\n"),
        else => return err,
    } orelse return;

    const action = search_opts.action orelse cfg.action;
    switch (action) {
        .print => try File.stdout().writeAll(path),

        inline else => |a| {
            const err = handleTmux(
                arena,
                &env_map,
                @field(TmuxAction, @tagName(a)),
                path,
            );
            switch (err) {
                error.TmuxNotFound => exit("tmux binary not found in path\n"),
                else => return err,
            }
        },
    }
}

const SearchError = error{NoProjectsFound} ||
    ExtractError || walk.SearchError || process.Child.SpawnError;

/// searches for project. returned slice may or may not be the buffer passed in.
fn searchProject(
    arena: Allocator,
    roots: []const []const u8,
    project_query: []const u8,
    preview: []const u8,
    path_buf: []u8,
) SearchError!?[]const u8 {
    var fzf_proc = try spawnFzf(arena, project_query, preview);
    errdefer _ = fzf_proc.kill() catch {};

    var buf: [256]u8 = undefined;
    var fzf_bw = fzf_proc.stdin.?.writer(&buf);
    const fzf_stdin = &fzf_bw.interface;

    const project_set = walk.searchProjects(arena, roots, .{
        .writer = fzf_stdin,
        .flush_after = .project,
    }) catch |err| switch (err) {
        // most likely failed due to selecting a project before finishing search
        error.WriteFailed => return extractProject(&fzf_proc, path_buf),
        else => return err,
    };

    const projects = project_set.keys();

    if (projects.len == 0) {
        _ = fzf_proc.kill() catch {};
        return error.NoProjectsFound;
    }

    fzf_proc.stdin.?.close();
    fzf_proc.stdin = null;

    if (matchProject(project_query, projects)) |matched_path| {
        // found singular exact project match, abort fzf and return
        _ = fzf_proc.kill() catch {};
        // TODO: should we fill the path_buf and return it for consistency?
        return matched_path;
    }

    return extractProject(&fzf_proc, path_buf);
}

const ExtractError = error{
    FzfNotFound,
    FzfNonZeroExitCode,
    FzfBadTermination,
} || Reader.DelimiterError || process.Child.WaitError;

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
            else => error.FzfNonZeroExitCode,
        },
        else => error.FzfBadTermination,
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

const TmuxAction = enum { session, window };

fn handleTmux(
    arena: Allocator,
    env_map: *const process.EnvMap,
    action: TmuxAction,
    project_path: []const u8,
) TmuxSessionError {
    var basename_buf: [256]u8 = undefined;
    const session_name = normalizeBasename(fs.path.basename(project_path), &basename_buf);

    switch (action) {
        .session => return handleTmuxSession(
            arena,
            env_map,
            project_path,
            session_name,
        ),
        .window => return handleTmuxWindow(
            arena,
            env_map,
            project_path,
            session_name,
        ),
    }
}

fn spawnTmuxControlMode(gpa: Allocator) process.Child.SpawnError!process.Child {
    var tmux_proc = std.process.Child.init(&.{
        "tmux",
        "-C",
        "new-session",
    }, gpa);

    tmux_proc.stdin_behavior = .Pipe;
    tmux_proc.stdout_behavior = .Pipe;

    try tmux_proc.spawn();

    return tmux_proc;
}

const TmuxSessionError = error{
    TmuxNotFound,
    TmuxNonZeroExitCode,
    TmuxBadTermination,
} || process.Child.SpawnError || Writer.Error || Reader.DelimiterError;

/// creates a new session called `session_name` if one doesn't already exist.
/// then attaches to that session.
fn handleTmuxSession(
    arena: Allocator,
    env_map: *const process.EnvMap,
    project_path: []const u8,
    session_name: []const u8,
) TmuxSessionError {
    var tmux_proc = try spawnTmuxControlMode(arena);
    errdefer _ = tmux_proc.kill() catch {};

    var stdin_buf: [256]u8 = undefined;
    var tmux_stdin_bw = tmux_proc.stdin.?.writer(&stdin_buf);
    const tmux_writer = &tmux_stdin_bw.interface;

    var stdout_buf: [1024]u8 = undefined;
    var tmux_stdout_br = tmux_proc.stdout.?.reader(&stdout_buf);
    const tmux_reader = &tmux_stdout_br.interface;

    createSession(tmux_writer, tmux_reader, project_path, session_name) catch |err| switch (err) {
        error.TmuxReadError => return error.TmuxNotFound,
        // inline else should work here, but due to limitations in error resolutions
        // it is needed to explicitly list the possible errors.
        error.EndOfStream, error.ReadFailed, error.StreamTooLong, error.WriteFailed => |e| return e,
    };

    const term = tmux_proc.wait() catch |err| switch (err) {
        error.FileNotFound => return error.TmuxNotFound,
        else => return err,
    };

    switch (term) {
        .Exited => |code| switch (code) {
            0 => {},
            else => return error.TmuxNonZeroExitCode,
        },
        else => return error.TmuxBadTermination,
    }

    const session_command = if (isInsideTmuxSession(env_map)) "switch-client" else "attach-session";
    const args = &.{ "tmux", session_command, "-t", session_name };

    const err = process.execve(arena, args, env_map);
    return switch (err) {
        error.FileNotFound => error.TmuxNotFound,
        else => err,
    };
}

const TmuxWriteReadError = error{TmuxReadError} || Writer.Error || Reader.DelimiterError;

fn createSession(
    tmux_stdin: *Writer,
    tmux_stdout: *Reader,
    project_path: []const u8,
    session_name: []const u8,
) TmuxWriteReadError!void {
    const session_exists = try sessionExists(tmux_stdin, tmux_stdout, session_name);
    if (!session_exists) {
        try tmux_stdin.print(
            \\new-session -s '{s}' -c '{s}'
            \\switch-client -l
            \\
        , .{ session_name, project_path });
    }

    try tmux_stdin.writeAll("kill-session\n\n");
    try tmux_stdin.flush();
}

fn sessionExists(
    tmux_stdin: *Writer,
    tmux_stdout: *Reader,
    session_name: []const u8,
) TmuxWriteReadError!bool {
    try tmux_stdin.writeAll("list-sessions -F '#{session_name}'\n");
    try tmux_stdin.flush();

    var reading_lines = false;
    while (true) {
        const line = tmux_stdout.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.TmuxReadError,
            else => return err,
        };

        if (line.len == 0) continue;
        if (line[0] == '%') {
            if (reading_lines) return false;
            continue;
        }

        reading_lines = true;
        if (std.mem.eql(u8, line, session_name)) {
            return true;
        }
    }
}

/// if inside a session, creates a new window called `session_name`.
/// if not, just calls `handleTmuxSession`, creating a new session
fn handleTmuxWindow(
    arena: Allocator,
    env_map: *const process.EnvMap,
    project_path: []const u8,
    session_name: []const u8,
) TmuxSessionError {
    if (!isInsideTmuxSession(env_map)) {
        return handleTmuxSession(arena, env_map, project_path, session_name);
    }

    const args = &.{ "tmux", "new-window", "-c", project_path, "-n", session_name };

    const err = process.execve(arena, args, env_map);
    return switch (err) {
        error.FileNotFound => error.TmuxNotFound,
        else => err,
    };
}

fn isInsideTmuxSession(env_map: *const process.EnvMap) bool {
    return env_map.get("TMUX") != null;
}

fn normalizeBasename(basename: []const u8, buf: []u8) []u8 {
    assert(buf.len >= basename.len);

    const trimmed = std.mem.trim(u8, basename, ".");
    const normalized = buf[0..trimmed.len];

    for (trimmed, 0..) |char, idx| {
        normalized[idx] = if (char == '.') '_' else char;
    }

    return normalized;
}

test normalizeBasename {
    try testNormalizeBasename("..foo.bar..", "foo_bar");
    try testNormalizeBasename("foo.bar..", "foo_bar");
    try testNormalizeBasename("..foo.bar", "foo_bar");
    try testNormalizeBasename("..foobar..", "foobar");
    try testNormalizeBasename("foobar", "foobar");
}

fn testNormalizeBasename(input: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, normalizeBasename(input, &buf));
}
