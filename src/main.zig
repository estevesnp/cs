const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const fs = std.fs;
const process = std.process;
const testing = std.testing;
const Io = std.Io;
const File = Io.File;
const Writer = Io.Writer;
const Reader = Io.Reader;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const config = @import("config.zig");
const cli = @import("cli.zig");
const walk = @import("walk.zig");
const tmux = @import("tmux.zig");

const ProjectQueue = Io.Queue(walk.ProjectMessage);

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
    \\  --env [--json]                   print config and environment information
    \\                                     accepts --json flag before or after --env
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

fn exit(reporter: *Writer, msg: []const u8) noreturn {
    reporter.writeAll(msg) catch {};
    process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const ctx: Context = .init(init, stderr);

    const args = try init.minimal.args.toSlice(ctx.arena);
    const command = try cli.parse(.{ .writer = stderr }, args);

    switch (command) {
        .help => try help(ctx.io),
        .version => try version(ctx.io),
        .env => |e| try env(ctx, e),
        .@"add-paths" => |paths| try addPaths(ctx, paths),
        .@"set-paths" => |paths| try setPaths(ctx, paths),
        .@"remove-paths" => |paths| try removePaths(ctx, paths),
        .shell => |shell| try shellIntegration(ctx, shell),
        .search => |opts| try search(ctx, opts),
    }
}

fn help(io: Io) File.Writer.Error!void {
    try File.stdout().writeStreamingAll(io, USAGE);
}

fn version(io: Io) Writer.Error!void {
    var buf: [16]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("{f}\n", .{options.cs_version});
    try stdout.flush();
}

const EnvError = config.OpenConfigError || Writer.Error;

fn env(ctx: Context, env_fmt: cli.EnvFmt) EnvError!void {
    var cfg_context = try config.openConfig(ctx.arena, ctx.io, ctx.environ_map);
    defer cfg_context.deinit(ctx.arena, ctx.io);

    const cfg = cfg_context.config;

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = File.stdout().writer(ctx.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    switch (env_fmt) {
        .txt => try printEnvTxt(stdout, cfg_context.config_path, cfg.project_roots),
        .json => try printEnvJson(stdout, cfg_context.config_path, cfg.project_roots),
    }

    try stdout.flush();
}

fn printEnvTxt(out: *Writer, cfg_path: []const u8, roots: []const []const u8) Writer.Error!void {
    try out.print("cs config path: {s}\n", .{cfg_path});
    if (roots.len > 0) {
        try out.writeAll("project roots:\n");
        for (roots) |root| {
            try out.print("  - {s}\n", .{root});
        }
    }
}

const EnvJson = struct {
    config_path: []const u8,
    project_roots: []const []const u8,
};

fn printEnvJson(out: *Writer, cfg_path: []const u8, roots: []const []const u8) Writer.Error!void {
    const schema: EnvJson = .{ .config_path = cfg_path, .project_roots = roots };
    try std.json.Stringify.value(schema, .{ .whitespace = .indent_2 }, out);
}

const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ_map: *const process.Environ.Map,
    reporter: Reporter,

    fn init(proc_init: process.Init, reporter: *Io.Writer) Context {
        return .{
            .gpa = proc_init.gpa,
            .arena = proc_init.arena.allocator(),
            .io = proc_init.io,
            .environ_map = proc_init.environ_map,
            .reporter = .{ .writer = reporter },
        };
    }
};

const Reporter = struct {
    writer: *Writer,

    fn report(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt ++ "\n", args) catch {};
        self.writer.flush() catch {};
    }
};

fn addPaths(ctx: Context, paths: []const []const u8) !void {
    assert(paths.len > 0);

    var cfg_context = try config.openConfig(ctx.arena, ctx.io, ctx.environ_map);
    defer cfg_context.deinit(ctx.arena, ctx.io);

    var cfg = cfg_context.config;

    var path_set: std.StringArrayHashMapUnmanaged(void) = try .init(ctx.arena, cfg.project_roots, &.{});
    defer path_set.deinit(ctx.arena);

    const cwd = Io.Dir.cwd();
    for (paths) |path| {
        if (path.len == 0) continue;
        const real_path = cwd.realPathFileAlloc(ctx.io, path, ctx.arena) catch |err| switch (err) {
            error.FileNotFound => {
                ctx.reporter.report("{s} not found", .{path});
                continue;
            },
            else => |e| return e,
        };
        const gop = try path_set.getOrPut(ctx.arena, real_path);
        if (gop.found_existing) {
            ctx.reporter.report("root {s} already exists", .{real_path});
        }
    }

    cfg.project_roots = path_set.keys();

    try config.updateConfig(ctx.io, cfg_context.config_file, cfg);
}

fn setPaths(ctx: Context, paths: []const []const u8) !void {
    assert(paths.len > 0);

    var cfg_context = try config.openConfig(ctx.arena, ctx.io, ctx.environ_map);
    defer cfg_context.deinit(ctx.arena, ctx.io);

    var cfg = cfg_context.config;

    var path_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer path_set.deinit(ctx.arena);

    const cwd = Io.Dir.cwd();
    for (paths) |path| {
        if (path.len == 0) continue;
        const real_path = cwd.realPathFileAlloc(ctx.io, path, ctx.arena) catch |err| switch (err) {
            error.FileNotFound => {
                ctx.reporter.report("{s} not found", .{path});
                continue;
            },
            else => |e| return e,
        };

        const gop = try path_set.getOrPut(ctx.arena, real_path);
        if (gop.found_existing) {
            ctx.reporter.report("root {s} was already added", .{real_path});
        }
    }

    if (path_set.count() == 0) {
        ctx.reporter.report("no roots were added, aborting", .{});
        return;
    }

    cfg.project_roots = path_set.keys();

    try config.updateConfig(ctx.io, cfg_context.config_file, cfg);
}

fn removePaths(ctx: Context, paths: []const []const u8) !void {
    assert(paths.len > 0);

    var cfg_context = try config.openConfig(ctx.arena, ctx.io, ctx.environ_map);
    defer cfg_context.deinit(ctx.arena, ctx.io);

    var cfg = cfg_context.config;

    var path_set: std.StringArrayHashMapUnmanaged(void) = try .init(ctx.arena, cfg.project_roots, &.{});
    defer path_set.deinit(ctx.arena);

    const cwd = try process.getCwdAlloc(ctx.arena);
    for (paths) |path| {
        if (path.len == 0) continue;

        const resolved = try Io.Dir.path.resolve(ctx.arena, &.{ cwd, path });
        const removed = path_set.orderedRemove(resolved);

        if (!removed) {
            ctx.reporter.report("root {s} not configured", .{resolved});
        }
    }

    cfg.project_roots = path_set.keys();

    try config.updateConfig(ctx.io, cfg_context.config_file, cfg);
}

const ShellIntegrationError = error{ UnsupportedShell, ShellNotFound } || File.Writer.Error;

fn shellIntegration(ctx: Context, shell: ?cli.Shell) ShellIntegrationError!void {
    const shell_tag = shell orelse blk: {
        const shell_path = ctx.environ_map.get("SHELL") orelse return error.ShellNotFound;
        const shell_name = Io.Dir.path.basename(shell_path);

        break :blk std.meta.stringToEnum(cli.Shell, shell_name) orelse return error.UnsupportedShell;
    };

    const csd_integration = switch (shell_tag) {
        .zsh, .bash => @embedFile("shell-integration/shell.bash.zsh"),
    };

    try File.stdout().writeStreamingAll(ctx.io, csd_integration);
}

const SearchError = SearchProjectError || config.OpenConfigError || tmux.Error || File.Writer.Error;

fn search(ctx: Context, search_opts: cli.SearchOpts) SearchError!void {
    var cfg_context = try config.openConfig(ctx.arena, ctx.io, ctx.environ_map);
    cfg_context.deinit(ctx.arena, ctx.io);

    const cfg = cfg_context.config;

    if (cfg.project_roots.len == 0) {
        exit(ctx.reporter.writer, "no project roots found. add one using the '--add-paths' flag\n");
    }

    const preview = search_opts.preview orelse cfg.preview;

    var walk_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer walk_arena.deinit();

    const walk_opts: WalkOpts = .{
        .roots = cfg.project_roots,
        .project_markers = cfg.project_markers,
        .reporter = ctx.reporter.writer,
        .arena = walk_arena.allocator(),
    };
    const fzf_opts: FzfOpts = .{
        .project_query = search_opts.project,
        .preview = preview,
    };

    const path = searchProject(ctx, walk_opts, fzf_opts) catch |err| switch (err) {
        error.FzfNotFound => exit(ctx.reporter.writer, "fzf binary not found in path\n"),
        error.NoProjectsFound => exit(ctx.reporter.writer, "no projects found\n"),
        else => return err,
    } orelse return;

    const action = search_opts.action orelse cfg.action;
    switch (action) {
        .print => try File.stdout().writeStreamingAll(ctx.io, path),

        inline else => |tmux_action| {
            if (builtin.os.tag == .windows) exit(ctx.reporter.writer, "tmux is not supported on windows\n");

            const err = tmux.handleTmux(
                ctx.arena,
                ctx.io,
                ctx.environ_map,
                @field(tmux.Action, @tagName(tmux_action)),
                path,
            );
            switch (err) {
                error.TmuxNotFound => exit(ctx.reporter.writer, "tmux binary not found in path\n"),
                else => return err,
            }
        },
    }
}

const WalkOpts = struct {
    roots: []const []const u8,
    project_markers: []const []const u8,
    reporter: *Writer,
    arena: Allocator,
};

const FzfOpts = struct {
    project_query: []const u8,
    preview: []const u8,
};

const SearchProjectError = ExtractError || WalkError || SpawnFzfError || Io.ConcurrentError ||
    error{NoProjectsFound};

fn searchProject(ctx: Context, walk_opts: WalkOpts, fzf_opts: FzfOpts) SearchProjectError!?[]const u8 {
    var project_queue_buf: [10]walk.ProjectMessage = undefined;
    var project_queue: ProjectQueue = .init(&project_queue_buf);
    defer project_queue.close(ctx.io);

    var fzf_out_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    var fzf_proc = try spawnFzf(ctx.io, fzf_opts.project_query, fzf_opts.preview);
    defer fzf_proc.kill(ctx.io);

    const fzf_stdin_file = fzf_proc.stdin.?;
    fzf_proc.stdin = null;

    var walk_future = try ctx.io.concurrent(walkAndMatch, .{ walk_opts.arena, ctx.io, &project_queue, walk_opts, fzf_opts.project_query });
    defer _ = walk_future.cancel(ctx.io) catch {};

    var extract_future = try ctx.io.concurrent(extractFzf, .{ ctx.io, &fzf_out_buf, &fzf_proc });
    defer _ = extract_future.cancel(ctx.io) catch {};

    var write_future = try ctx.io.concurrent(writeToFzf, .{ ctx.io, fzf_stdin_file, &project_queue });
    defer write_future.cancel(ctx.io);

    const select = try ctx.io.select(.{
        .walk = &walk_future,
        .extract = &extract_future,
    });

    return switch (select) {
        // if no match found, default to fzf selection
        .walk => |walk_res| try walk_res orelse {
            const extracted = try extract_future.await(ctx.io) orelse return null;
            return try ctx.arena.dupe(u8, extracted);
        },
        .extract => |extract_res| {
            const extracted = try extract_res orelse return null;
            return try ctx.arena.dupe(u8, extracted);
        },
    };
}

const WalkError = walk.SearchError || error{NoProjectsFound};

fn walkAndMatch(
    arena: Allocator,
    io: Io,
    project_queue: *ProjectQueue,
    walk_opts: WalkOpts,
    project_query: []const u8,
) WalkError!?[]const u8 {
    const project_set = try walk.searchProjects(arena, io, walk_opts.roots, .{
        .queue = project_queue,
        .reporter = walk_opts.reporter,
        .project_markers = walk_opts.project_markers,
    });
    const projects = project_set.keys();

    if (projects.len == 0) {
        return error.NoProjectsFound;
    }

    return matchProject(project_query, projects);
}

const ExtractError = Reader.DelimiterError || process.Child.WaitError || Io.Cancelable || Io.QueueClosedError ||
    error{ FzfNotFound, FzfNonZeroExitCode, FzfBadTermination };

fn extractFzf(io: Io, out_buf: []u8, fzf_proc: *process.Child) ExtractError!?[]const u8 {
    // +1 for the new line
    var stdout_buf: [Io.Dir.max_path_bytes + 1]u8 = undefined;
    var fzf_br = fzf_proc.stdout.?.reader(io, &stdout_buf);
    const fzf_reader = &fzf_br.interface;

    const extracted_path = fzf_reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        else => return err,
    };

    return switch (try fzf_proc.wait(io)) {
        .exited => |code| switch (code) {
            0 => {
                const path = extracted_path orelse return null;
                @memcpy(out_buf[0..path.len], path);
                return out_buf[0..path.len];
            },
            FZF_NO_MATCH_EXIT_CODE, FZF_INTERRUPT_EXIT_CODE => null,
            else => error.FzfNonZeroExitCode,
        },
        else => error.FzfBadTermination,
    };
}

fn writeToFzf(io: Io, fzf_stdin_file: Io.File, project_queue: *ProjectQueue) void {
    var stdin_buf: [256]u8 = undefined;
    var fzf_bw = fzf_stdin_file.writer(io, &stdin_buf);
    const fzf_stdin = &fzf_bw.interface;

    while (true) {
        switch (project_queue.getOne(io) catch return) {
            .project => |project| {
                // if write fails, it's likely due to fzf exiting early
                fzf_stdin.writeAll(project) catch return;
                fzf_stdin.writeByte('\n') catch return;
            },
            .end => break,
        }
    }

    fzf_stdin.flush() catch return;
    fzf_stdin_file.close(io);
}

const SpawnFzfError = process.SpawnError || error{FzfNotFound};

fn spawnFzf(io: Io, project: []const u8, preview: []const u8) SpawnFzfError!process.Child {
    return process.spawn(io, .{
        .argv = &.{
            "fzf",
            "--header=choose a repo",
            "--reverse",
            "--scheme=path",
            "--preview-label=[ repository files ]",
            "--preview",
            preview,
            "--query",
            project,
        },
        .stdin = .pipe,
        .stdout = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FzfNotFound,
        else => return err,
    };
}

fn matchProject(project: []const u8, project_paths: []const []const u8) ?[]const u8 {
    if (project.len == 0) return null;

    var match: ?[]const u8 = null;

    for (project_paths) |path| {
        if (std.mem.eql(u8, Io.Dir.path.basename(path), project)) {
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
