const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const cfg = @import("config.zig");
const tmux = @import("tmux.zig");
const walk = @import("walk/lib.zig");

const mem = std.mem;
const process = std.process;

const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Action = cfg.Action;
const EditMode = cfg.EditMode;

const is_windows = builtin.os.tag == .windows;

pub fn main(init: process.Init) !void {
    var stdout_buf: [128]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buf);

    var stderr_buf: [128]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(init.io, &stderr_buf);

    const ctx: Ctx = .init(init, &stdout, &stderr);

    const args = try init.minimal.args.toSlice(ctx.arena);

    const cmd = parseArgs(&stderr.interface, args) catch |err| switch (err) {
        error.Help => try writeHelpAndExit(ctx.stdout),
        error.Usage => process.exit(1), // assumes usage error has already been printed
    };

    switch (cmd) {
        .version => try Io.File.stdout().writeStreamingAll(ctx.io, options.cs_version),
        .search => |opts| try search(ctx, opts),
        .env => |opts| try printEnv(ctx, opts),
        .edit => |opts| try editConfig(ctx, opts),
        .shell => |opts| try handleShell(ctx, opts),
        .add_roots => |opts| try addRoots(ctx, opts),
        .remove_roots => |opts| try removeRoots(ctx, opts),
    }

    return process.cleanExit(ctx.io);
}

const Ctx = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ_map: *process.Environ.Map,

    stdout: *Io.File.Writer,
    stderr: *Io.File.Writer,

    fn init(proc_init: process.Init, stdout: *Io.File.Writer, stderr: *Io.File.Writer) Ctx {
        return .{
            .io = proc_init.io,
            .gpa = proc_init.gpa,
            .arena = proc_init.arena.allocator(),
            .environ_map = proc_init.environ_map,
            .stdout = stdout,
            .stderr = stderr,
        };
    }

    fn report(ctx: Ctx, data: []const u8) !void {
        if (data.len == 0) return;
        ctx.stderr.interface.writeAll(data) catch return ctx.stderr.err.?;
        try ctx.stderr.flush();
    }

    fn reportf(ctx: Ctx, comptime fmt: []const u8, args: anytype) !void {
        ctx.stderr.interface.print(mem.trimEnd(u8, fmt, "\n") ++ "\n", args) catch
            return ctx.stderr.err.?;
        try ctx.stderr.flush();
    }

    fn exit(ctx: Ctx, comptime fmt: []const u8, args: anytype) !noreturn {
        try ctx.reportf(fmt, args);
        process.exit(1);
    }
};

fn writeHelpAndExit(writer: *Io.File.Writer) !noreturn {
    writer.interface.writeAll(usage) catch return writer.err.?;
    try writer.flush();
    process.exit(0);
}

const usage =
    \\usage: cs [action] [flags]
    \\
    \\subcommands:
    \\
    \\  search                      search for project
    \\  env                         print config and environment information
    \\  edit                        edit config
    \\  add                         add paths as roots
    \\  remove                      remove paths from roots
    \\  shell                       print shell integrations
    \\  version                     print version. also accepts --version and -v
    \\  help                        print this message. also accepts --help and -h
    \\
    \\search:
    \\
    \\  description: search for projects from configured roots
    \\
    \\  usage: cs [search] [flags] [project]
    \\
    \\  arguments:
    \\    project                   query to pre-fill picker. if it has an exact match
    \\                              to any project, instantly selects it
    \\
    \\  flags:
    \\    -a, --action <action>     select action to perform on project selection.
    \\                              can also choose the action directly, like --print.
    \\                              options: session, window, print
    \\
    \\    -m, --max-depth <depth>   how many directories deep to search for in each
    \\                              root. defaults to 5
    \\
    \\
    \\env:
    \\  description: display environment information about the program, such as the
    \\               config path, the config itself and what roots are configured
    \\               when searching
    \\
    \\  usage: cs env [flags]
    \\    -c, --config <display>    select how to display the config. either display
    \\                              all possible options (full), or only the ones that
    \\                              are configured (partial).
    \\                              can also choose the display directly, like --full.
    \\                              options: partial (default), full
    \\
    \\
    \\edit:
    \\  description: open the config inside your editor
    \\
    \\  usage: cs edit [flags]
    \\
    \\  flags:
    \\    -m, --mode                select what to open in the editor.
    \\                              options: config (default), roots, dir (config dir)
    \\
    \\    -e, --editor              select what editor to open the config with.
    \\                              if none is provided, defaults to the environment:
    \\                              CS_EDITOR -> VISUAL -> EDITOR
    \\
    \\
    \\add:
    \\  description: add a number of paths to roots used when searching for projects
    \\
    \\  usage: cs add [flags] <path> [paths...]
    \\
    \\  arguments:
    \\    paths                     paths to add. at least one must be provided
    \\
    \\  flags:
    \\    -r, --reset               remove all paths before adding the ones provided
    \\
    \\
    \\remove:
    \\  description: remove paths from roots used when searching for projects
    \\
    \\  usage: cs remove [flags] [paths...]
    \\
    \\  arguments:
    \\    paths                     paths to add. if flag --reset is not being used,
    \\                              at least one path must be provided
    \\
    \\  flags:
    \\    -r, --reset               remove all paths. when used, no paths can be
    \\                              provided.
    \\
    \\
    \\shell:
    \\  description: print shell integrations using cs to embed in scripts
    \\
    \\  usage : cs shell [shell]
    \\
    \\  arguments:
    \\    shell                     shell to print integrations for. if no shell is
    \\                              provided, tries using SHELL from the environment.
    \\                              supported shells: bash, zsh, fish
    \\
;

const CmdError = error{ Help, Usage };

const Cmd = union(enum) {
    search: SearchOpts,
    env: EnvOpts,
    edit: EditOpts,
    shell: ShellOpts,
    add_roots: PathOpts,
    remove_roots: PathOpts,
    version,
};

const SearchOpts = struct {
    query: ?[]const u8,
    preview: ?[]const u8,
    max_depth: ?usize,
    action: ?Action,
    // TODO - quiet: don't print diagnostics from walk
    // TODO - strategy: blocking (1st walk, then fzf), concurrent (race between fzf and walk)
    // TODO - stop iterating on marker match?
    // TODO - roots?
    // TODO - markers?
    // TODO - custom action to run with sh -c <templated string>, with option to replace
    // TODO - tmux script?
};

const ConfigDisplay = enum { full, partial };

const EnvOpts = struct {
    config_display: ?ConfigDisplay,
};

const EditOpts = struct {
    mode: ?EditMode,
    editor: ?[]const u8,
};

const PathOpts = struct {
    paths: ?[]const []const u8,
    reset: ?bool,
};

const Shell = enum {
    bash,
    zsh,
    fish,
};

const ShellOpts = struct {
    shell: ?Shell,
};

fn parseArgs(w: *Io.Writer, args: []const []const u8) CmdError!Cmd {
    var it: Iter = .init(args[1..]);

    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "help", "--help", "-h" })) return CmdError.Help;
        if (eqlAny(arg, &.{ "version", "--version", "-v" })) return .version;
        if (mem.eql(u8, arg, "env")) return .{ .env = try parseEnv(&it, w) };
        if (mem.eql(u8, arg, "edit")) return .{ .edit = try parseEdit(&it, w) };
        if (mem.eql(u8, arg, "add")) return .{ .add_roots = try parsePaths(&it, w) };
        if (mem.eql(u8, arg, "remove")) return .{ .remove_roots = try parsePaths(&it, w) };
        if (mem.eql(u8, arg, "shell")) return .{ .shell = try parseShell(&it, w) };

        if (mem.eql(u8, arg, "search")) return .{ .search = try parseSearch(&it, w) };

        // defaulting to search, so we need to un-consume the arg
        it.prev();
        return .{ .search = try parseSearch(&it, w) };
    }

    // default to search when no args are passed
    return .{ .search = try parseSearch(&it, w) };
}

fn parseSearch(it: *Iter, w: *Io.Writer) CmdError!SearchOpts {
    var opts: SearchOpts = .{
        .query = null,
        .preview = null,
        .max_depth = null,
        .action = null,
    };

    var parsing_args = true;
    while (it.next()) |arg| {
        if (parsing_args) {
            if (mem.eql(u8, arg, "--")) {
                parsing_args = false;
                continue;
            }
            if (eqlAny(arg, &.{ "help", "--help", "-h" })) return CmdError.Help;

            if (try getNamedArg(w, it, arg, &.{ "--action", "-a" })) |named| {
                opts.action = std.meta.stringToEnum(Action, named) orelse
                    return usageError(w, "invalid action value: {q}", .{named});
                continue;
            }

            if (try getNamedArg(w, it, arg, &.{ "--preview", "-p" })) |named| {
                opts.preview = named;
                continue;
            }

            if (try getNamedArg(w, it, arg, &.{ "--max-depth", "-m" })) |named| {
                opts.max_depth = std.fmt.parseInt(usize, named, 0) catch
                    return usageError(w, "invalid max-depth value: {q}", .{named});
                continue;
            }

            if (mem.startsWith(u8, arg, "-")) {
                if (mem.startsWith(u8, arg, "--")) {
                    if (std.meta.stringToEnum(Action, arg[2..])) |action| {
                        opts.action = action;
                        continue;
                    }
                }
                return usageError(w, "invalid flag: {q}", .{arg});
            }
        }
        opts.query = arg;
    }

    return opts;
}

fn parseEnv(it: *Iter, w: *Io.Writer) CmdError!EnvOpts {
    var opts: EnvOpts = .{
        .config_display = null,
    };

    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "help", "--help", "-h" })) return CmdError.Help;

        if (try getNamedArg(w, it, arg, &.{ "--config", "-c" })) |named| {
            opts.config_display = std.meta.stringToEnum(ConfigDisplay, named) orelse
                return usageError(w, "invalid config display: {q}", .{named});
            continue;
        }

        if (mem.startsWith(u8, arg, "--")) {
            if (std.meta.stringToEnum(ConfigDisplay, arg[2..])) |display| {
                opts.config_display = display;
                continue;
            }
        }

        return usageError(w, "invalid option: {q}", .{arg});
    }

    return opts;
}

fn parseEdit(it: *Iter, w: *Io.Writer) CmdError!EditOpts {
    var opts: EditOpts = .{
        .mode = null,
        .editor = null,
    };

    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "help", "--help", "-h" })) return CmdError.Help;

        if (try getNamedArg(w, it, arg, &.{ "--mode", "-m" })) |named| {
            opts.mode = std.meta.stringToEnum(EditMode, named) orelse
                return usageError(w, "invalid edit mode: {q}", .{named});
            continue;
        }

        if (try getNamedArg(w, it, arg, &.{ "--editor", "-e" })) |named| {
            opts.editor = named;
            continue;
        }

        if (mem.startsWith(u8, arg, "--")) {
            if (std.meta.stringToEnum(EditMode, arg[2..])) |mode| {
                opts.mode = mode;
                continue;
            }
        }

        return usageError(w, "invalid option: {q}", .{arg});
    }

    return opts;
}

fn parsePaths(it: *Iter, w: *Io.Writer) CmdError!PathOpts {
    var opts: PathOpts = .{
        .paths = null,
        .reset = null,
    };

    var parsing_flags = true;
    while (it.next()) |arg| {
        if (parsing_flags) {
            if (mem.eql(u8, arg, "--")) {
                parsing_flags = false;
                continue;
            }
            if (eqlAny(arg, &.{ "help", "--help", "-h" })) return CmdError.Help;

            if (eqlAny(arg, &.{ "--reset", "-r" })) {
                opts.reset = true;
                continue;
            }
            if (mem.eql(u8, arg, "--no-reset")) {
                opts.reset = false;
                continue;
            }

            if (mem.startsWith(u8, arg, "-")) return usageError(w, "invalid flag: {q}", .{arg});
        }

        // get the index of the argument and slice until the end
        it.prev();
        opts.paths = it.slice[it.idx..];
        break;
    }

    return opts;
}

fn parseShell(it: *Iter, w: *Io.Writer) CmdError!ShellOpts {
    var opts: ShellOpts = .{
        .shell = null,
    };

    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "help", "--help", "-h" })) return CmdError.Help;

        if (opts.shell != null) return usageError(w, "multiple shells provided", .{});

        const stripped_shell = mem.cutPrefix(u8, arg, "--") orelse arg;
        opts.shell = std.meta.stringToEnum(Shell, stripped_shell) orelse
            return usageError(w, "unsupported shell: {q}", .{arg});
    }

    return opts;
}

fn eqlAny(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |elem| if (mem.eql(u8, needle, elem)) return true;
    return false;
}

fn usageError(w: *Io.Writer, comptime fmt: []const u8, args: anytype) CmdError {
    w.print("error: " ++ fmt ++ "\n", args) catch {};
    w.flush() catch {};
    return CmdError.Usage;
}

/// if `arg` matches any of the `flags`, gets a named arg, either from the
/// argument itself (`--foo=bar`) or from the iterator (`--foo bar`)
///
/// if no flag matches, `null` is returned
///
/// if any flag matches and no argument is provided, prints explanation and
/// returns `error.UsageError` and reports it to `w`
fn getNamedArg(w: *Io.Writer, it: *Iter, arg: []const u8, flags: []const []const u8) CmdError!?[]const u8 {
    assert(flags.len > 0);

    for (flags) |flag| {
        if (!mem.startsWith(u8, arg, flag)) continue;

        // exact flag, requires arg
        if (arg.len == flag.len) return it.next() orelse
            return usageError(w, "flag {q} requires an argument", .{flag});

        // no match
        if (arg[flag.len] != '=') continue;

        const named_arg = arg[flag.len + 1 ..];

        // no arg after =
        if (named_arg.len == 0)
            return usageError(w, "flag {q} requires an argument", .{flag});

        return named_arg;
    }

    // no flag match
    return null;
}

const Iter = struct {
    slice: []const []const u8,
    idx: usize,

    fn init(slice: []const []const u8) Iter {
        return .{ .idx = 0, .slice = slice };
    }

    fn next(self: *Iter) ?[]const u8 {
        if (self.idx >= self.slice.len) return null;
        const elem = self.slice[self.idx];
        self.idx += 1;
        return elem;
    }

    fn prev(self: *Iter) void {
        if (self.idx > 0) self.idx -= 1;
    }
};

fn search(ctx: Ctx, opts: SearchOpts) !void {
    const arena = ctx.arena;
    const io = ctx.io;

    const config_with_roots = try cfg.readConfigWithRoots(io, arena, ctx.environ_map);
    const config = cfg.normalizeConfig(config_with_roots.config);
    const roots = config_with_roots.roots;

    const preview = opts.preview orelse config.preview;
    const query = opts.query orelse "";

    var fzf_proc = spawnFzf(io, preview, query) catch |err| switch (err) {
        error.FileNotFound => try ctx.exit("fzf binary not found in path", .{}),
        else => |e| return e,
    };

    var fzf_w_buf: [64]u8 = undefined;
    var fzf_writer = fzf_proc.stdin.?.writerStreaming(io, &fzf_w_buf);
    fzf_proc.stdin = null;

    var fzf_r_buf: [Io.Dir.max_path_bytes + 1]u8 = undefined;
    var fzf_reader = fzf_proc.stdout.?.readerStreaming(io, &fzf_r_buf);

    // needed so that we don't print to screen while fzf is running
    var walk_reporter: Io.Writer.Allocating = .init(arena);

    const walk_opts: WalkOpts = .{
        .reporter = &walk_reporter.writer,
        .query = query,
        .roots = roots,
        .markers = config.markers,
        .max_depth = opts.max_depth orelse config.max_depth,
    };
    const fzf_proc_rw: FzfProc = .{
        .proc = &fzf_proc,
        .stdin = &fzf_writer,
        .stdout = &fzf_reader,
    };
    const selection_opt = searchProject(ctx, walk_opts, fzf_proc_rw) catch |err| {
        try ctx.report(walk_reporter.written());
        switch (err) {
            error.NoProjectsFound => try ctx.exit("no projects found", .{}),
            else => |e| return e,
        }
    };

    try ctx.report(walk_reporter.written());

    const selection = selection_opt orelse return;

    const action = opts.action orelse config.action;

    switch (action) {
        .print => {
            ctx.stdout.interface.writeAll(selection) catch return ctx.stdout.err.?;
            try ctx.stdout.flush();
        },
        inline .session, .window => |a| {
            if (is_windows) try ctx.exit("tmux is not supported on windows", .{});

            const tmux_action = @field(tmux.Action, @tagName(a));
            const err = tmux.handleTmux(
                arena,
                io,
                ctx.environ_map,
                &ctx.stderr.interface,
                tmux_action,
                selection,
            );
            switch (err) {
                error.TmuxNotFound => try ctx.exit("tmux binary not found in path", .{}),
                else => return err,
            }
        },
    }
}

const SearchError = WalkError || FzfExtractError || Io.ConcurrentError;

fn ReturnType(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

fn searchProject(ctx: Ctx, walk_opts: WalkOpts, fzf_proc: FzfProc) SearchError!?[]const u8 {
    const arena = ctx.arena;
    const io = ctx.io;

    var queue_buf: [10][]const u8 = undefined;
    var project_queue: Io.Queue([]const u8) = .init(&queue_buf);

    const U = union(enum) {
        walk: ReturnType(walkAndMatch),
        extract: ReturnType(extractFzfSelection),
    };

    var select_buf: [std.meta.fieldNames(U).len]U = undefined;
    var select: Io.Select(U) = .init(io, &select_buf);
    defer select.cancelDiscard();

    var feed_future = try io.concurrent(feedToFzf, .{ io, &project_queue, fzf_proc.stdin });
    defer feed_future.cancel(io);

    try select.concurrent(.walk, walkAndMatch, .{ io, arena, &project_queue, walk_opts });
    try select.concurrent(.extract, extractFzfSelection, .{ io, fzf_proc.proc, fzf_proc.stdout });

    switch (try select.await()) {
        .walk => |walk_match| {
            const match = try walk_match;
            if (match) |m| return m;
            // fallback to fzf selection if no project matches exactly
            const fzf_selection = try select.await();
            return fzf_selection.extract;
        },
        .extract => |extracted| return try extracted,
    }
}

const WalkOpts = struct {
    reporter: *Io.Writer,
    query: []const u8,
    roots: []const []const u8,
    markers: []const []const u8,
    max_depth: usize,
};

const WalkError = error{NoProjectsFound} || walk.SearchError;

fn walkAndMatch(
    io: Io,
    arena: Allocator,
    project_queue: *Io.Queue([]const u8),
    opts: WalkOpts,
) WalkError!?[]const u8 {
    const project_set = try walk.searchProjects(arena, io, opts.roots, .{
        .queue = project_queue,
        .reporter = opts.reporter,
        .project_markers = opts.markers,
        .max_depth = opts.max_depth,
    });
    const projects = project_set.keys();

    if (projects.len == 0) {
        return error.NoProjectsFound;
    }

    return matchProject(opts.query, projects);
}

fn matchProject(query: []const u8, project_paths: []const []const u8) ?[]const u8 {
    if (query.len == 0) return null;

    var match: ?[]const u8 = null;

    for (project_paths) |path| {
        if (std.mem.eql(u8, Io.Dir.path.basename(path), query)) {
            if (match != null) return null;
            match = path;
        }
    }

    return match;
}

test matchProject {
    try std.testing.expectEqualStrings("/foo/bar/abc", matchProject("abc", &.{
        "/foo/bar/123",
        "/foo/bar/abc",
        "/bar/bar/bar",
    }).?);

    try std.testing.expectEqualStrings("/foo/bar/abc", matchProject("abc", &.{"/foo/bar/abc"}).?);

    try std.testing.expectEqual(null, matchProject("abc", &.{
        "/foo/bar/123",
        "/foo/bar/baz",
        "/bar/bar/bar",
    }));

    try std.testing.expectEqual(null, matchProject("abc", &.{
        "/foo/bar/123",
        "/foo/bar/abc",
        "/bar/bar/bar",
        "/foo/baz/abc",
    }));

    try std.testing.expectEqual(null, matchProject("bar", &.{"/foo-bar"}));

    try std.testing.expectEqual(null, matchProject("", &.{"/foo/bar/123"}));
}

const FzfProc = struct {
    proc: *process.Child,
    stdin: *Io.File.Writer,
    stdout: *Io.File.Reader,
};

fn feedToFzf(io: Io, project_queue: *Io.Queue([]const u8), fzf_stdin: *Io.File.Writer) void {
    defer fzf_stdin.file.close(io);
    while (true) {
        const project = project_queue.getOne(io) catch return;
        // if write fails, it's likely due to fzf exiting early
        fzf_stdin.interface.writeAll(project) catch return;
        fzf_stdin.interface.writeByte('\n') catch return;
        fzf_stdin.flush() catch return;
    }
}

fn spawnFzf(io: Io, preview: []const u8, query: []const u8) !process.Child {
    return try process.spawn(io, .{
        .argv = &.{
            "fzf",
            "--header=choose a repo",
            "--reverse",
            "--scheme=path",
            "--preview-label=[ project files ]",
            "--preview",
            preview,
            "--query",
            query,
        },
        .stdin = .pipe,
        .stdout = .pipe,
    });
}

const fzf_no_match_sc: u8 = 1;
const fzf_interrupt_sc: u8 = 130;

const FzfExtractError = error{FzfBadTermination} ||
    Io.File.Reader.Error || Io.Reader.DelimiterError || process.Child.WaitError;

fn extractFzfSelection(
    io: Io,
    fzf_proc: *process.Child,
    fzf_stdout: *Io.File.Reader,
) FzfExtractError!?[]const u8 {
    errdefer fzf_proc.kill(io);

    const selection = fzf_stdout.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => null,
        error.ReadFailed => return fzf_stdout.err.?,
        else => |e| return e,
    };

    return switch (try fzf_proc.wait(io)) {
        .exited => |code| switch (code) {
            0 => selection,
            fzf_no_match_sc, fzf_interrupt_sc => null,
            else => error.FzfBadTermination,
        },
        else => error.FzfBadTermination,
    };
}

fn printEnv(ctx: Ctx, opts: EnvOpts) !void {
    const io = ctx.io;
    const arena = ctx.arena;

    const config_with_roots = try cfg.readConfigWithRoots(io, arena, ctx.environ_map);

    const json_opts: std.json.Stringify.Options = .{
        .emit_null_optional_fields = false,
        .whitespace = .indent_2,
    };

    const config_display = opts.config_display orelse .partial;

    switch (config_display) {
        inline else => |display| {
            const env: Env(display) = .init(config_with_roots, ctx.environ_map);
            std.json.Stringify.value(env, json_opts, &ctx.stdout.interface) catch
                return ctx.stdout.err.?;
        },
    }
    try ctx.stdout.flush();
}

fn Env(comptime config_display: ConfigDisplay) type {
    const ConfigType = switch (config_display) {
        .partial => cfg.PartialConfig,
        .full => cfg.Config,
    };

    return struct {
        env: std.enums.EnumFieldStruct(cfg.Env, []const u8, null),
        config: ConfigType,
        roots: []const []const u8,

        fn init(config_with_roots: cfg.ConfigWithRoots, environ_map: *const process.Environ.Map) @This() {
            const config = switch (config_display) {
                .partial => config_with_roots.config,
                .full => cfg.normalizeConfig(config_with_roots.config),
            };
            return .{
                .env = .{
                    .CS_CONFIG_PATH = config_with_roots.path,
                    .CS_EDITOR = getCsEditor(environ_map) orelse "",
                },
                .config = config,
                .roots = config_with_roots.roots,
            };
        }
    };
}

fn getEnv(environ_map: *const process.Environ.Map, key: []const u8) ?[]const u8 {
    if (environ_map.get(key)) |value| {
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

fn getCsEditor(environ_map: *const process.Environ.Map) ?[]const u8 {
    return cfg.Env.CS_EDITOR.get(environ_map) orelse
        getEnv(environ_map, "VISUAL") orelse
        getEnv(environ_map, "EDITOR");
}

fn editConfig(ctx: Ctx, opts: EditOpts) !void {
    const io = ctx.io;
    const arena = ctx.arena;

    const config_dir_path = try cfg.configDirPath(arena, ctx.environ_map);
    var config_dir = try Io.Dir.cwd().createDirPathOpen(io, config_dir_path, .{});
    defer config_dir.close(io);

    try writeFileIfNotExists(io, config_dir, cfg.config_filename, "{}");
    try writeFileIfNotExists(io, config_dir, cfg.roots_filename, "[]");

    const config = try cfg.readConfigFromDir(io, arena, config_dir);

    const editor = opts.editor orelse
        getCsEditor(ctx.environ_map) orelse
        try ctx.exit(
            "no editor found. either configure the CS_EDITOR, EDITOR or VISUAL environment variables, or use the --editor flag",
            .{},
        );

    const mode = opts.mode orelse config.edit_mode;

    const filepath = switch (mode) {
        .config => try Io.Dir.path.join(arena, &.{ config_dir_path, cfg.config_filename }),
        .roots => try Io.Dir.path.join(arena, &.{ config_dir_path, cfg.roots_filename }),
        .dir => config_dir_path,
    };

    var proc = process.spawn(io, .{
        .argv = &.{ editor, filepath },
    }) catch |err| switch (err) {
        error.FileNotFound => try ctx.exit("editor {q} not found in path", .{editor}),
        else => |e| return e,
    };
    defer proc.kill(io);

    const term = try proc.wait(io);
    if (term.success()) return;

    ctx.stderr.interface.print("bad termination while editing: {s} ", .{editor}) catch
        return ctx.stderr.err.?;
    term.format(&ctx.stderr.interface) catch return ctx.stderr.err.?;
    ctx.stderr.interface.writeByte('\n') catch return ctx.stderr.err.?;
    try ctx.stderr.flush();
}

fn writeFileIfNotExists(
    io: Io,
    dir: Io.Dir,
    filename: []const u8,
    default_data: []const u8,
) !void {
    dir.writeFile(io, .{
        .sub_path = filename,
        .data = default_data,
        .flags = .{
            .truncate = false,
            .exclusive = true,
        },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

const StringSet = std.array_hash_map.String(void);

fn addRoots(ctx: Ctx, opts: PathOpts) !void {
    const io = ctx.io;
    const arena = ctx.arena;

    const paths = opts.paths orelse &.{};
    if (paths.len == 0) try ctx.exit("must provide paths to add", .{});
    const reset = opts.reset orelse false;

    const config_dir_path = try cfg.configDirPath(arena, ctx.environ_map);
    var config_dir = try Io.Dir.cwd().createDirPathOpen(io, config_dir_path, .{});
    defer config_dir.close(io);

    const roots = if (reset) &.{} else try cfg.readRootsFromDir(io, arena, config_dir);

    const cwd = try process.currentPathAlloc(io, arena);
    var roots_set: StringSet = try .init(arena, roots, &.{});

    for (paths) |path| {
        const resolved = try Io.Dir.path.resolve(arena, &.{ cwd, path });

        const gop = try roots_set.getOrPut(arena, resolved);
        if (gop.found_existing) try ctx.reportf("path {s} already exists", .{resolved});
    }

    try writeRoots(io, config_dir, roots_set.keys());
}

fn removeRoots(ctx: Ctx, opts: PathOpts) !void {
    const io = ctx.io;
    const arena = ctx.arena;

    const reset = opts.reset orelse false;
    const paths = opts.paths orelse &.{};

    const config_dir_path = try cfg.configDirPath(arena, ctx.environ_map);
    var config_dir = try Io.Dir.cwd().createDirPathOpen(io, config_dir_path, .{});
    defer config_dir.close(io);

    if (reset) {
        if (paths.len != 0) try ctx.exit("when using the --reset flag, no paths must be provided", .{});

        try config_dir.writeFile(io, .{
            .sub_path = cfg.roots_filename,
            .data = "[]",
            .flags = .{},
        });
        return;
    }

    if (paths.len == 0) try ctx.exit("must provide paths to remove", .{});

    const roots = try cfg.readRootsFromDir(io, arena, config_dir);

    const cwd = try process.currentPathAlloc(io, arena);
    var roots_set: StringSet = try .init(arena, roots, &.{});

    for (paths) |path| {
        const resolved = try Io.Dir.path.resolve(arena, &.{ cwd, path });

        const existed = roots_set.orderedRemove(resolved);
        if (!existed) try ctx.reportf("path {s} didn't exist", .{resolved});
    }

    try writeRoots(io, config_dir, roots_set.keys());
}

fn writeRoots(io: Io, config_dir: Io.Dir, roots: []const []const u8) !void {
    var root_file = try config_dir.createFile(io, cfg.roots_filename, .{});
    defer root_file.close(io);

    var root_buf: [512]u8 = undefined;
    var root_writer = root_file.writer(io, &root_buf);
    std.json.Stringify.value(roots, .{ .whitespace = .indent_2 }, &root_writer.interface) catch
        return root_writer.err.?;
    try root_writer.flush();
}

fn handleShell(ctx: Ctx, opts: ShellOpts) !void {
    const shell = opts.shell orelse
        determineShell(ctx.environ_map) orelse
        try ctx.exit("could not determine shell. provide one after the 'shell' subcommand", .{});

    const data = switch (shell) {
        .bash, .zsh => @embedFile("shell-integration/shell.bash.zsh"),
        .fish => @embedFile("shell-integration/shell.fish"),
    };

    ctx.stdout.interface.writeAll(data) catch return ctx.stdout.err.?;
    try ctx.stdout.flush();
}

fn determineShell(environ_map: *const process.Environ.Map) ?Shell {
    if (environ_map.get("SHELL")) |shell_path| {
        const env_shell = Io.Dir.path.basename(shell_path);
        return std.meta.stringToEnum(Shell, env_shell);
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
