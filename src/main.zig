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
const tmux = @import("tmux.zig");

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
    \\  --shell [shell]                  print out shell completions.
    \\                                     options: zsh, bash
    \\                                     tries to detect shell if none is provided
    \\  --no-preview                     disables fzf preview
    \\  --preview <str>                  preview command to pass to fzf
    \\  --action  <action>               action to execute after finding repository.
    \\                                     options: session, window, print
    \\                                     can call the action directly, e.g. --print
    \\                                     can also do -w instead of --window
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
        .env => try env(arena),
        .@"add-paths" => |paths| try addPaths(arena, paths),
        .@"set-paths" => |paths| try setPaths(arena, paths),
        .@"remove-paths" => |paths| try removePaths(arena, paths),
        .shell => |shell| try shellIntegration(arena, shell),
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

const EnvError = config.OpenConfigError || Writer.Error;

fn env(arena: Allocator) EnvError!void {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = try config.getConfigPath(&path_buf);

    var cfg_context = try config.openConfigFromPath(arena, path);
    cfg_context.deinit();

    const cfg = cfg_context.config;

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("cs config path: {s}\n", .{path});

    if (cfg.project_roots.len > 0) {
        try stdout.writeAll("project roots:\n");
        for (cfg.project_roots) |root| {
            try stdout.print("  - {s}\n", .{root});
        }
    }

    try stdout.flush();
}

fn addPaths(arena: Allocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    var cfg_context = try config.openConfig(arena);
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

    try config.updateConfig(cfg_context.config_file, cfg);
}

fn setPaths(arena: Allocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    var cfg_context = try config.openConfig(arena);
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

    try config.updateConfig(cfg_context.config_file, cfg);
}

fn removePaths(arena: Allocator, paths: []const []const u8) !void {
    assert(paths.len > 0);

    var cfg_context = try config.openConfig(arena);
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

    try config.updateConfig(cfg_context.config_file, cfg);
}

fn shellIntegration(arena: Allocator, shell: ?cli.Shell) !void {
    const shell_tag = shell orelse blk: {
        const shell_path = try process.getEnvVarOwned(arena, "SHELL");
        const shell_name = fs.path.basename(shell_path);

        break :blk std.meta.stringToEnum(cli.Shell, shell_name) orelse return error.UnsupportedShell;
    };

    const csd_integration = switch (shell_tag) {
        .zsh, .bash =>
        \\csd() {
        \\    local cspath
        \\    cspath=$(cs --print "$1") || return
        \\    [ -n "$cspath" ] || return
        \\    builtin cd -- "$cspath" || return
        \\}
        \\
    };

    try fs.File.stdout().writeAll(csd_integration);
}

fn search(arena: Allocator, search_opts: cli.SearchOpts) !void {
    var cfg_context = try config.openConfig(arena);
    cfg_context.deinit();

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

        inline else => |tmux_action| {
            if (builtin.os.tag == .windows) exit("tmux is not supported on windows\n");

            const err = tmux.handleTmux(
                arena,
                @field(tmux.Action, @tagName(tmux_action)),
                path,
            );
            switch (err) {
                error.TmuxNotFound => exit("tmux binary not found in path\n"),
                else => return err,
            }
        },
    }
}

const SearchError = ExtractError || walk.SearchError || process.Child.SpawnError ||
    error{NoProjectsFound};

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

    // needed since the compiler creates a new enum when building `options`
    const flush_after = @field(walk.FlushAfter, @tagName(options.fzf_flush_after));

    const project_set = walk.searchProjects(arena, roots, .{
        .writer = fzf_stdin,
        .flush_after = flush_after,
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

const ExtractError = Reader.DelimiterError || process.Child.WaitError || error{
    FzfNotFound,
    FzfNonZeroExitCode,
    FzfBadTermination,
};

fn extractProject(fzf_proc: *process.Child, buf: []u8) ExtractError!?[]const u8 {
    var br = fzf_proc.stdout.?.reader(buf);
    const fzf_reader = &br.interface;

    const path = fzf_reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        else => {
            _ = fzf_proc.kill() catch {};
            return err;
        },
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

const SpawnFzfError = process.Child.SpawnError || error{FzfNotFound};

fn spawnFzf(gpa: Allocator, project: []const u8, preview: []const u8) SpawnFzfError!process.Child {
    var fzf_proc = process.Child.init(&.{
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

    fzf_proc.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.FzfNotFound,
        else => return err,
    };

    return fzf_proc;
}

fn matchProject(project: []const u8, project_paths: []const []const u8) ?[]const u8 {
    if (project.len == 0) return null;

    var match: ?[]const u8 = null;

    for (project_paths) |path| {
        if (std.mem.eql(u8, fs.path.basename(path), project)) {
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

    try testing.expectEqual(null, matchProject("bar", &.{"/foo-bar"}));

    try testing.expectEqual(null, matchProject("", &.{"/foo/bar/123"}));
}

test "ref all decls" {
    testing.refAllDeclsRecursive(@This());
}
