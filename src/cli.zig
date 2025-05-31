const std = @import("std");
const root = @import("root");
const mem = std.mem;
const assert = std.debug.assert;

const Diag = @import("Diag.zig");

/// options
pub const Command = union(enum) {
    /// print help
    help: void,

    /// print version
    version: void,

    /// print config content and path
    config: void,

    /// runs the actual tool
    run: RunOpts,

    /// set root paths
    set_paths: []const []const u8,

    /// add root paths
    add_paths: []const []const u8,
};

/// options for running the tool
pub const RunOpts = struct {
    /// optional paths to search for, overrides config
    paths: ?[]const []const u8,

    /// optional repo to try to match
    repo: ?[]const u8,

    /// optional preview command, overrides config
    preview_cmd: ?[]const u8,

    /// optional script to run on new tmux session, overrides config
    tmux_script: ?[]const u8,
};

pub const Error = error{
    IllegalArgument,
    NoArguments,
    RepeatedArgument,
    UnknownFlag,
};

/// parses CLI args, assuming first arg is the executable name
/// returned Command union must have the same lifetime as passed in args
pub fn parseArgs(args: []const []const u8, diag: ?*Diag) Error!Command {
    assert(args.len > 0);

    var paths: ?[]const []const u8 = null;
    var repo: ?[]const u8 = null;
    var preview_cmd: ?[]const u8 = null;
    var tmux_script: ?[]const u8 = null;

    var iter: Iterator([]const u8) = .init(args[1..]);

    while (iter.next()) |arg| {
        if (eqlAny(&.{ "-h", "--help" }, arg)) {
            if (paths != null or repo != null or preview_cmd != null or tmux_script != null or !iter.isEmpty()) {
                if (diag) |d| d.report("can't pass arguments while using -h/--help flag\n", .{});
                return Error.IllegalArgument;
            }

            return .{ .help = {} };
        } else if (eqlAny(&.{ "-v", "--version" }, arg)) {
            if (paths != null or repo != null or preview_cmd != null or tmux_script != null or !iter.isEmpty()) {
                if (diag) |d| d.report("can't pass arguments while using -v/--version flag\n", .{});
                return Error.IllegalArgument;
            }

            return .{ .version = {} };
        } else if (mem.eql(u8, arg, "--config")) {
            if (paths != null or repo != null or preview_cmd != null or tmux_script != null or !iter.isEmpty()) {
                if (diag) |d| d.report("can't pass arguments while using --config flag\n", .{});
                return Error.IllegalArgument;
            }

            return .{ .config = {} };
        } else if (eqlAny(&.{ "-s", "--set-paths" }, arg)) {
            if (paths != null or repo != null or preview_cmd != null or tmux_script != null) {
                if (diag) |d| d.report("can't pass other arguments while using -s/--set-paths flag\n", .{});
                return Error.IllegalArgument;
            }

            const set_paths = parsePaths(&iter);

            if (set_paths.len == 0) {
                if (diag) |d| d.report("no arguments passed to -s/--set-paths flag\n", .{});
                return Error.NoArguments;
            }
            if (!iter.isEmpty()) {
                if (diag) |d| d.report("can't pass other arguments while using -s/--set-paths flag\n", .{});
                return Error.IllegalArgument;
            }

            return .{ .set_paths = set_paths };
        } else if (eqlAny(&.{ "-a", "--add-paths" }, arg)) {
            if (paths != null or repo != null or preview_cmd != null or tmux_script != null) {
                if (diag) |d| d.report("can't pass other arguments while using -a/--add-paths flag\n", .{});
                return Error.IllegalArgument;
            }

            const add_paths = parsePaths(&iter);

            if (add_paths.len == 0) {
                if (diag) |d| d.report("no arguments passed to -a/--add-paths flag\n", .{});
                return Error.NoArguments;
            }

            if (!iter.isEmpty()) {
                if (diag) |d| d.report("can't pass other arguments while using -a/--add-paths flag\n", .{});
                return Error.IllegalArgument;
            }

            return .{ .add_paths = add_paths };
        } else if (eqlAny(&.{ "-p", "--paths" }, arg)) {
            if (paths != null) {
                if (diag) |d| d.report("can't repeat -p/--paths flag\n", .{});
                return Error.RepeatedArgument;
            }

            paths = parsePaths(&iter);

            if (paths.?.len == 0) {
                if (diag) |d| d.report("no arguments passed to -p/--paths flag\n", .{});
                return Error.NoArguments;
            }
        } else if (std.mem.eql(u8, arg, "--preview")) {
            if (preview_cmd != null) {
                if (diag) |d| d.report("can't repeat --preview flag\n", .{});
                return Error.RepeatedArgument;
            }

            const prev = iter.next() orelse {
                if (diag) |d| d.report("no argument passed to --preview flag\n", .{});
                return Error.NoArguments;
            };
            if (isFlagArgument(prev)) {
                if (diag) |d| d.report("no argument passed to --preview flag\n", .{});
                return Error.NoArguments;
            }

            preview_cmd = prev;
        } else if (std.mem.eql(u8, arg, "--script")) {
            if (tmux_script != null) {
                if (diag) |d| d.report("can't repeat --script flag\n", .{});
                return Error.RepeatedArgument;
            }

            const script = iter.next() orelse {
                if (diag) |d| d.report("no argument passed to --script flag\n", .{});
                return Error.NoArguments;
            };
            if (isFlagArgument(script)) {
                if (diag) |d| d.report("no argument passed to --script flag\n", .{});
                return Error.NoArguments;
            }

            tmux_script = script;
        } else {
            if (isFlagArgument(arg)) {
                if (diag) |d| d.report("unkown flag: {s}\n", .{arg});
                return Error.UnknownFlag;
            }

            if (repo != null) {
                if (diag) |d| d.report("can't pass more than one repo to match\n", .{});
                return Error.RepeatedArgument;
            }

            repo = arg;
        }
    }

    return .{
        .run = .{
            .paths = paths,
            .repo = repo,
            .preview_cmd = preview_cmd,
            .tmux_script = tmux_script,
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
    try std.testing.expectEqual(Command{ .help = {} }, try parseArgs(&.{ "cs", "-h" }, null));
    try std.testing.expectEqual(Command{ .help = {} }, try parseArgs(&.{ "cs", "--help" }, null));

    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "--help", "a" }, null));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "a", "--help" }, null));
}

test "parseArgs config" {
    try std.testing.expectEqual(Command{ .config = {} }, try parseArgs(&.{ "cs", "--config" }, null));

    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "--config", "a" }, null));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "a", "--config" }, null));
}

test "parseArgs set_paths" {
    {
        const cmd = try parseArgs(&.{ "cs", "-s", "a", "b", "c" }, null);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.set_paths);
    }
    {
        const cmd = try parseArgs(&.{ "cs", "--set-paths", "a" }, null);
        try std.testing.expectEqualSlices([]const u8, &.{"a"}, cmd.set_paths);
    }

    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-s" }, null));
    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-s", "-h" }, null));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "-s", "a", "-h" }, null));
}

test "parseArgs add_paths" {
    {
        const cmd = try parseArgs(&.{ "cs", "-a", "a", "b", "c" }, null);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.add_paths);
    }
    {
        const cmd = try parseArgs(&.{ "cs", "--add-paths", "a" }, null);
        try std.testing.expectEqualSlices([]const u8, &.{"a"}, cmd.add_paths);
    }

    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-a" }, null));
    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-a", "-h" }, null));
    try std.testing.expectError(Error.IllegalArgument, parseArgs(&.{ "cs", "-a", "a", "-h" }, null));
}

test "parseArgs run" {
    { // repo, paths, preview
        const cmd = try parseArgs(&.{ "cs", "repo", "-p", "a", "b", "c", "--preview", "ls {}" }, null);
        try std.testing.expectEqualStrings("repo", cmd.run.repo.?);
        try std.testing.expectEqualStrings("ls {}", cmd.run.preview_cmd.?);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.run.paths.?);
    }
    { // repo, paths
        const cmd = try parseArgs(&.{ "cs", "repo", "-p", "a", "b", "c" }, null);
        try std.testing.expectEqualStrings("repo", cmd.run.repo.?);
        try std.testing.expectEqual(null, cmd.run.preview_cmd);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.run.paths.?);
    }
    { // preview, paths
        const cmd = try parseArgs(&.{ "cs", "--preview", "ls {}", "--paths", "a", "b", "c" }, null);
        try std.testing.expectEqual(null, cmd.run.repo);
        try std.testing.expectEqualStrings("ls {}", cmd.run.preview_cmd.?);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.run.paths.?);
    }
    { // paths
        const cmd = try parseArgs(&.{ "cs", "--paths", "a", "b", "c" }, null);
        try std.testing.expectEqual(null, cmd.run.repo);
        try std.testing.expectEqual(null, cmd.run.preview_cmd);
        try std.testing.expectEqualSlices([]const u8, &.{ "a", "b", "c" }, cmd.run.paths.?);
    }
    { // repo
        const cmd = try parseArgs(&.{ "cs", "repo" }, null);
        try std.testing.expectEqualStrings("repo", cmd.run.repo.?);
        try std.testing.expectEqual(null, cmd.run.preview_cmd);
        try std.testing.expectEqual(null, cmd.run.paths);
    }
    { // preview
        const cmd = try parseArgs(&.{ "cs", "--preview", "ls {}" }, null);
        try std.testing.expectEqual(null, cmd.run.repo);
        try std.testing.expectEqualStrings("ls {}", cmd.run.preview_cmd.?);
        try std.testing.expectEqual(null, cmd.run.paths);
    }
    { // null
        const cmd = try parseArgs(&.{"cs"}, null);
        try std.testing.expectEqual(null, cmd.run.repo);
        try std.testing.expectEqual(null, cmd.run.preview_cmd);
        try std.testing.expectEqual(null, cmd.run.paths);
    }

    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "-p" }, null));
    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "repo", "-p" }, null));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "repo1", "repo2" }, null));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "repo1", "repo2", "-p", "a" }, null));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "-p", "a", "-p", "b" }, null));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "-p", "a", "-p" }, null));
    try std.testing.expectError(Error.RepeatedArgument, parseArgs(&.{ "cs", "repo", "-p", "a", "-p", "b" }, null));

    try std.testing.expectError(Error.UnknownFlag, parseArgs(&.{ "cs", "-q" }, null));
    try std.testing.expectError(Error.UnknownFlag, parseArgs(&.{ "cs", "--idk" }, null));
    try std.testing.expectError(Error.UnknownFlag, parseArgs(&.{ "cs", "repo", "--idk" }, null));

    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "--preview" }, null));
    try std.testing.expectError(Error.NoArguments, parseArgs(&.{ "cs", "--preview", "-p", "a" }, null));
}
