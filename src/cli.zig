const std = @import("std");
const mem = std.mem;

/// options
pub const Command = union(enum) {
    /// print help
    help: void,

    /// print config content and path
    config: void,

    /// runs the actual tool
    run: struct {
        /// optional paths to search for, overrides config
        paths: ?[]const []const u8,

        /// optional repo to try to match
        repo: ?[]const u8,
    },

    /// set root paths
    set_paths: []const []const u8,

    /// add root paths
    add_paths: []const []const u8,
};

pub const Error = error{
    IllegalArgument,
    NoArguments,
    RepeatedArgument,
    UnknownFlag,
};

/// parses CLI args, assuming first arg is the executable name
/// returned Command union must have the same lifetime as passed in args
pub fn parseArgs(args: []const []const u8) Error!Command {
    var paths: ?[]const []const u8 = null;
    var repo: ?[]const u8 = null;

    var iter: Iterator([]const u8) = .init(args[1..]);

    while (iter.next()) |arg| {
        if (eqlAny(&.{ "-h", "--help" }, arg)) {
            if (paths != null or repo != null or !iter.isEmpty()) {
                return Error.IllegalArgument;
            }

            return .{ .help = {} };
        } else if (mem.eql(u8, arg, "--config")) {
            if (paths != null or repo != null or !iter.isEmpty()) {
                return Error.IllegalArgument;
            }

            return .{ .config = {} };
        } else if (eqlAny(&.{ "-s", "--set-paths" }, arg)) {
            if (paths != null or repo != null) {
                return Error.IllegalArgument;
            }

            const set_paths = parsePaths(&iter);

            if (set_paths.len == 0) {
                return Error.NoArguments;
            }
            if (!iter.isEmpty()) {
                return Error.IllegalArgument;
            }

            return .{ .set_paths = set_paths };
        } else if (eqlAny(&.{ "-a", "--add-paths" }, arg)) {
            if (paths != null or repo != null) {
                return Error.IllegalArgument;
            }

            const add_paths = parsePaths(&iter);

            if (add_paths.len == 0) {
                return Error.NoArguments;
            }
            if (!iter.isEmpty()) {
                return Error.IllegalArgument;
            }

            return .{ .add_paths = add_paths };
        } else if (eqlAny(&.{ "-p", "--paths" }, arg)) {
            if (paths != null) {
                return Error.RepeatedArgument;
            }

            paths = parsePaths(&iter);

            if (paths.?.len == 0) {
                return Error.NoArguments;
            }
        } else {
            if (isFlagArgument(arg)) {
                return Error.UnknownFlag;
            }

            if (repo != null) {
                return Error.RepeatedArgument;
            }

            repo = arg;
        }
    }

    return .{
        .run = .{
            .paths = paths,
            .repo = repo,
        },
    };
}

fn Iterator(T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        pos: usize = 0,

        fn init(slice: []const T) Self {
            return .{ .slice = slice };
        }

        fn next(self: *Self) ?T {
            const item = self.peek() orelse return null;
            self.pos += 1;
            return item;
        }

        fn peek(self: *Self) ?T {
            if (self.isEmpty()) return null;
            return self.slice[self.pos];
        }

        fn isEmpty(self: *Self) bool {
            return self.pos >= self.slice.len;
        }
    };
}

fn parsePaths(iter: *Iterator([]const u8)) []const []const u8 {
    const init_idx = iter.pos;
    while (iter.peek()) |arg| {
        if (isFlagArgument(arg)) break;
        _ = iter.next();
    }
    const final_idx = iter.pos;

    return iter.slice[init_idx..final_idx];
}

fn isFlagArgument(arg: []const u8) bool {
    if (arg.len == 0) return false;
    return arg[0] == '-';
}

fn eqlAny(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |val| {
        if (mem.eql(u8, val, needle)) return true;
    }
    return false;
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test Iterator {
    {
        var iter = Iterator(u8).init(&.{ 1, 2, 3 });

        try std.testing.expect(!iter.isEmpty());
        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.next(), 1);

        try std.testing.expect(!iter.isEmpty());
        try std.testing.expectEqual(iter.peek(), 2);
        try std.testing.expectEqual(iter.peek(), 2);
        try std.testing.expectEqual(iter.next(), 2);

        try std.testing.expect(!iter.isEmpty());
        try std.testing.expectEqual(iter.peek(), 3);
        try std.testing.expectEqual(iter.peek(), 3);
        try std.testing.expectEqual(iter.next(), 3);

        try std.testing.expect(iter.isEmpty());
        try std.testing.expectEqual(iter.peek(), null);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }

    {
        var iter = Iterator(u8).init(&.{1});

        try std.testing.expect(!iter.isEmpty());
        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.next(), 1);

        try std.testing.expect(iter.isEmpty());
        try std.testing.expectEqual(iter.peek(), null);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }

    {
        var iter = Iterator(u8).init(&.{});

        try std.testing.expect(iter.isEmpty());
        try std.testing.expectEqual(iter.peek(), null);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }
}

test parsePaths {
    try testParsePaths(&.{ "a", "b" }, &.{ "a", "b" });
    try testParsePaths(&.{"a"}, &.{"a"});
    try testParsePaths(&.{}, &.{});
    try testParsePaths(&.{ "a", "b", "-c" }, &.{ "a", "b" });
    try testParsePaths(&.{ "a", "b", "-c", "d" }, &.{ "a", "b" });
    try testParsePaths(&.{ "-a", "b" }, &.{});
    try testParsePaths(&.{"-a"}, &.{});
}

fn testParsePaths(args: []const []const u8, expected: []const []const u8) !void {
    var iter: Iterator([]const u8) = .init(args);
    try std.testing.expectEqualSlices([]const u8, expected, parsePaths(&iter));
}

test "parseArgs help" {
    try std.testing.expectEqual(Command{ .help = {} }, try parseArgs(&.{ "cs", "-h" }));
    try std.testing.expectEqual(Command{ .help = {} }, try parseArgs(&.{ "cs", "--help" }));

    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "--help", "a" }));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "a", "--help" }));
}

test "parseArgs config" {
    try std.testing.expectEqual(Command{ .config = {} }, try parseArgs(&.{ "cs", "--config" }));

    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "--config", "a" }));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "a", "--config" }));
}

test "parseArgs set_paths" {
    {
        const cmd = try parseArgs(&.{ "cs", "-s", "a", "b", "c" });
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.set_paths);
    }
    {
        const cmd = try parseArgs(&.{ "cs", "--set-paths", "a" });
        try std.testing.expectEqualSlices([]const u8, &.{"a"}, cmd.set_paths);
    }

    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-s" }));
    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-s", "-h" }));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "-s", "a", "-h" }));
}

test "parseArgs add_paths" {
    {
        const cmd = try parseArgs(&.{ "cs", "-a", "a", "b", "c" });
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.add_paths);
    }
    {
        const cmd = try parseArgs(&.{ "cs", "--add-paths", "a" });
        try std.testing.expectEqualSlices([]const u8, &.{"a"}, cmd.add_paths);
    }

    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-a" }));
    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-a", "-h" }));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "-a", "a", "-h" }));
}

test "parseArgs run" {
    {
        const cmd = try parseArgs(&.{ "cs", "repo", "-p", "a", "b", "c" });
        try std.testing.expectEqualStrings("repo", cmd.run.repo.?);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.run.paths.?);
    }
    {
        const cmd = try parseArgs(&.{ "cs", "--paths", "a", "b", "c" });
        try std.testing.expectEqual(null, cmd.run.repo);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.run.paths.?);
    }
    {
        const cmd = try parseArgs(&.{ "cs", "repo" });
        try std.testing.expectEqualStrings("repo", cmd.run.repo.?);
        try std.testing.expectEqual(null, cmd.run.paths);
    }
    {
        const cmd = try parseArgs(&.{"cs"});
        try std.testing.expectEqual(null, cmd.run.repo);
        try std.testing.expectEqual(null, cmd.run.paths);
    }

    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-p" }));
    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "repo", "-p" }));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "repo1", "repo2" }));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "repo1", "repo2", "-p", "a" }));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "-p", "a", "-p", "b" }));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "-p", "a", "-p" }));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "repo", "-p", "a", "-p", "b" }));

    try std.testing.expectError(Error.UnknownFlag, parseArgs(&.{ "cs", "-q" }));
    try std.testing.expectError(Error.UnknownFlag, parseArgs(&.{ "cs", "--idk" }));
    try std.testing.expectError(Error.UnknownFlag, parseArgs(&.{ "cs", "repo", "--idk" }));
}
