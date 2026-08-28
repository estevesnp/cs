const std = @import("std");
const mem = std.mem;

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
        .version => try Io.File.stdout().writeStreamingAll(ctx.io, options.cs_version),
        else => {},
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

        if (mem.eql(u8, arg, "search")) return .{ .search = try parseSearch(&it) };

        if (!mem.eql(u8, arg, "--") and mem.startsWith(u8, arg, "-")) return CmdError.Usage;

        // defaulting to search, so need to un-consume the arg
        it.prev();
        return .{ .search = try parseSearch(&it) };
    }

    // default to search when no args are passed
    return .{ .search = try parseSearch(&it) };
}

fn parseSearch(it: *Iter) CmdError!SearchOpts {
    std.debug.print("parsing search\n", .{});
    while (it.next()) |arg| {
        std.debug.print("  {s}\n", .{arg});
    }
    return CmdError.Help;
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
};

const SearchOpts = struct {
    path: []const u8,
};

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
