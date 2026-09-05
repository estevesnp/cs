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

const is_windows = builtin.os.tag == .windows;

pub fn main(init: process.Init) !void {
    var stdout_buf: [128]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buf);

    var stderr_buf: [128]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(init.io, &stderr_buf);

    const ctx: Ctx = .init(init, &stdout, &stderr);

    const args = try init.minimal.args.toSlice(ctx.arena);

    const cmd = parseArgs(args) catch |err| switch (err) {
        error.Help => writeHelpAndExit(&ctx.stdout.interface, 0),
        error.Usage => writeHelpAndExit(&ctx.stderr.interface, 1),
    };

    switch (cmd) {
        .search => |opts| try search(ctx, opts),
        .version => try Io.File.stdout().writeStreamingAll(ctx.io, options.cs_version),
        else => std.debug.print("{t}\n", .{cmd}),
    }

    return process.cleanExit(ctx.io);
}

const Ctx = struct {
    io: Io,
    arena: Allocator,
    environ_map: *process.Environ.Map,

    stdout: *Io.File.Writer,
    stderr: *Io.File.Writer,

    fn init(proc_init: process.Init, stdout: *Io.File.Writer, stderr: *Io.File.Writer) Ctx {
        return .{
            .io = proc_init.io,
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

    fn exit(ctx: Ctx, data: []const u8) !noreturn {
        try ctx.report(data);
        process.exit(1);
    }
};

fn writeHelpAndExit(writer: *Io.Writer, status: u8) noreturn {
    writer.writeAll(usage) catch {};
    writer.flush() catch {};
    process.exit(status);
}

const usage =
    \\usage: cs [action] [flags]
    \\
    \\subcommands:
    \\
    \\  search                     search for project
    \\  env                        print config and environment information
    \\  edit                       edit config
    \\  version                    print version. also accepts --version and -v
    \\  help                       print this message. also accepts --help and -h
    \\
    \\search:
    \\
    \\  usage: cs [search] [flags] [project]
    \\
    \\  arguments:
    \\    project                  query to pre-fill picker. if it has an exact match
    \\                             to any project, instantly selects it
    \\
    \\  flags:
    \\    -a, --action <action>    select action to perform on project selection.
    \\                             can also choose the action directly, like --print.
    \\                             options: session, window, print
    \\
;

const CmdError = error{ Help, Usage };

const Cmd = union(enum) {
    search: SearchOpts,
    env,
    edit,
    version,
};

// TODO - custom action to run with sh -c <templated string>, with option to replace
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
};
fn parseArgs(args: []const []const u8) CmdError!Cmd {
    var it: Iter = .init(args[1..]);

    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "help", "--help", "-h" })) return CmdError.Help;
        if (eqlAny(arg, &.{ "version", "--version", "-v" })) return .version;
        if (mem.eql(u8, arg, "env")) return .env;
        if (mem.eql(u8, arg, "edit")) return .edit;

        if (mem.eql(u8, arg, "search")) return .{ .search = try parseSearch(&it) };

        // defaulting to search, so need to un-consume the arg
        it.prev();
        return .{ .search = try parseSearch(&it) };
    }

    // default to search when no args are passed
    return .{ .search = try parseSearch(&it) };
}

fn parseSearch(it: *Iter) CmdError!SearchOpts {
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

            if (try getNamedArg(it, arg, &.{ "--action", "-a" })) |named| {
                opts.action = std.meta.stringToEnum(Action, named) orelse
                    return usageError("invalid action value: {q}", .{named});
                continue;
            }

            if (try getNamedArg(it, arg, &.{ "--preview", "-p" })) |named| {
                opts.preview = named;
                continue;
            }

            if (try getNamedArg(it, arg, &.{ "--max-depth", "-m" })) |named| {
                opts.max_depth = std.fmt.parseInt(usize, named, 0) catch
                    return usageError("invalid max-depth value: {q}", .{named});
                continue;
            }

            if (mem.startsWith(u8, arg, "-")) {
                if (mem.startsWith(u8, arg, "--")) {
                    if (std.meta.stringToEnum(Action, arg[2..])) |action| {
                        opts.action = action;
                        continue;
                    }
                }
                return usageError("invalid flag: {q}", .{arg});
            }
        }

        opts.query = arg;
    }

    return opts;
}

fn eqlAny(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |elem| if (mem.eql(u8, needle, elem)) return true;
    return false;
}

// TODO - use stderr
fn usageError(comptime fmt: []const u8, args: anytype) CmdError {
    std.log.err(fmt, args);
    return CmdError.Usage;
}

/// if `arg` matches any of the `flags`, gets a named arg, either from the
/// argument itself (`--foo=bar`) or from the iterator (`--foo bar`)
///
/// if no flag matches, `null` is returned
///
/// if any flag matches and no argument is provided, prints explanation and
/// returns `error.UsageError`
fn getNamedArg(it: *Iter, arg: []const u8, flags: []const []const u8) CmdError!?[]const u8 {
    assert(flags.len > 0);

    for (flags) |flag| {
        if (!mem.startsWith(u8, arg, flag)) continue;

        // exact flag, requires arg
        if (arg.len == flag.len) return it.next() orelse
            usageError("flag {q} requires an argument", .{flag});

        // no match
        if (arg[flag.len] != '=') continue;

        const named_arg = arg[flag.len + 1 ..];

        // no arg after =
        if (named_arg.len == 0)
            return usageError("flag {q} requires an argument", .{flag});

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

    const config_with_roots = try cfg.readConfig(io, arena, ctx.environ_map);
    const config = config_with_roots.config;
    const roots = config_with_roots.roots;

    const preview = opts.preview orelse config.preview;
    const query = opts.query orelse "";

    var fzf_proc = spawnFzf(io, preview, query) catch |err| switch (err) {
        error.FileNotFound => try ctx.exit("fzf binary not found in path\n"),
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
            error.NoProjectsFound => try ctx.exit("no projects found\n"),
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
            if (is_windows) try ctx.exit("tmux is not supported on windows\n");

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
                error.TmuxNotFound => try ctx.exit("tmux binary not found in path\n"),
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

test {
    std.testing.refAllDecls(@This());
}
