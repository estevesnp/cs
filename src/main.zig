const std = @import("std");
const mem = std.mem;

const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const options = @import("options");

pub fn main(init: std.process.Init) !void {
    const ctx: Ctx = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
    };

    const args = try init.minimal.args.toSlice(ctx.arena);

    const cmd = try parseArgs(args);

    switch (cmd) {
        .search => |s| std.debug.print("{f}\n", .{std.json.fmt(s, .{ .whitespace = .indent_2 })}),
        .version => try Io.File.stdout().writeStreamingAll(ctx.io, options.cs_version),
        else => std.debug.print("{t}\n", .{cmd}),
    }
}

const Ctx = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
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
        .path = null,
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

        opts.path = arg;
    }

    return opts;
}

fn eqlAny(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |elem| if (mem.eql(u8, needle, elem)) return true;
    return false;
}

const CmdError = error{ Help, Usage };

const Cmd = union(enum) {
    search: SearchOpts,
    env,
    version,
    edit,
};

// TODO - custom action to run with sh -c <templated string>, with option to replace
const Action = enum {
    session,
    window,
    print,
};

const SearchOpts = struct {
    path: ?[]const u8,
    action: ?Action,
    // TODO - preview?
    // TODO - max_depth?
    // TODO - stop iterating on marker match?
    // TODO - markers?
};

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
