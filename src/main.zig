const std = @import("std");
const options = @import("options");
const cfg = @import("config.zig");
const walk = @import("walk/lib.zig");

const mem = std.mem;
const process = std.process;

const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Action = cfg.Action;

pub fn main(init: process.Init) !void {
    var stdout_buf: [128]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buf);

    var stderr_buf: [128]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(init.io, &stderr_buf);

    const ctx: Ctx = .init(init, &stdout.interface, &stderr.interface);

    const args = try init.minimal.args.toSlice(ctx.arena);

    const cmd = parseArgs(args) catch |err| switch (err) {
        error.Help => writeHelpAndExit(ctx.stdout, 0),
        error.Usage => writeHelpAndExit(ctx.stderr, 1),
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
    gpa: Allocator,
    arena: Allocator,
    environ_map: *process.Environ.Map,

    stdout: *Io.Writer,
    stderr: *Io.Writer,

    fn init(proc_init: process.Init, stdout: *Io.Writer, stderr: *Io.Writer) Ctx {
        return .{
            .io = proc_init.io,
            .gpa = proc_init.gpa,
            .arena = proc_init.arena.allocator(),
            .environ_map = proc_init.environ_map,
            .stdout = stdout,
            .stderr = stderr,
        };
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

pub fn search(ctx: Ctx, opts: SearchOpts) !void {
    const gpa = ctx.gpa;
    const arena = ctx.arena;
    const io = ctx.io;

    const config_with_roots = try cfg.readConfig(io, arena, ctx.environ_map);
    const config = cfg.normalizeConfig(config_with_roots.config);
    const roots = config_with_roots.roots;

    var projects = try walk.searchProjects(gpa, io, roots, .{
        .max_depth = opts.max_depth orelse config.max_depth,
        .reporter = ctx.stderr,
    });
    defer walk.freeProjects(gpa, &projects);

    const found_projects = projects.keys();

    var fzf_proc = try spawnFzf(io, opts.preview orelse config.preview, opts.query orelse "");
    defer fzf_proc.kill(io);

    var fzf_w_buf: [64]u8 = undefined;
    var fzf_writer = fzf_proc.stdin.?.writerStreaming(io, &fzf_w_buf);

    for (found_projects) |proj| {
        const nt_proj = proj[0 .. proj.len + 1];
        fzf_writer.interface.writeAll(nt_proj) catch return fzf_writer.err.?;
    }
    try fzf_writer.flush();
    fzf_proc.stdin.?.close(io);
    fzf_proc.stdin = null;

    var fzf_r_buf: [64]u8 = undefined;
    var fzf_reader = fzf_proc.stdout.?.readerStreaming(io, &fzf_r_buf);

    const selection = fzf_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.ReadFailed => return fzf_reader.err.?,
        else => |e| return e,
    };

    _ = try fzf_proc.wait(io);

    const action = opts.action orelse config.action;
    try ctx.stdout.print("selection: {s}\naction: {t}\n", .{ selection, action });
    try ctx.stdout.flush();
}

const FzfSpawnError = error{FzfNotInPath} || process.SpawnError;

fn spawnFzf(io: Io, preview: []const u8, query: []const u8) FzfSpawnError!process.Child {
    return process.spawn(io, .{
        .argv = &.{
            "fzf",
            "--read0",
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
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FzfNotInPath,
        else => |e| return e,
    };
}

test {
    std.testing.refAllDecls(@This());
}
