const std = @import("std");
const builtin = @import("builtin");

const mem = std.mem;

const assert = std.debug.assert;

const Diag = @import("Diag.zig");
const Tag = Diag.Tag;

const default_fzf_preview = switch (builtin.os.tag) {
    .windows => "type {}",
    else => "cat {}",
};

/// parsed user command
pub const Command = union(enum) {
    /// print help
    help,
    /// print version
    version,
    // TODO: do we want config location only? do we print the config as well?
    env,
    // TODO: do we want set_path and remove_path?
    add_paths: []const []const u8,
    run: RunOpts,
};

pub const RunAction = enum {
    /// open new tmux session with project. default option
    session,
    /// open new tmux window with project
    window,
    /// change directory to project
    cd,
    /// print project directory
    print,
};

pub const RunOpts = struct {
    /// default project search
    project: []const u8 = "",
    /// fzf preview command. --no-preview sets this as an empty string
    fzf_preview: []const u8 = default_fzf_preview,
    /// tmux script to run after a new session
    tmux_session_script: []const u8 = "",
    /// action to take on project found
    action: RunAction = .session,
};

pub const ArgParseError = error{ IllegalArgument, MissingArgument };

/// parses args. assumes first argument is the program
/// doesn't own the memory, so is valid as long as the `args` argument
pub fn parse(diag: *Diag, args: []const []const u8) ArgParseError!Command {
    var iter: ArgIterator = .init(args);
    assert(iter.next() != null);

    var run_opts: RunOpts = .{};

    while (iter.next()) |arg| {
        if (eqlAny(&.{ "--help", "-h" }, arg)) {
            try validateSingleArg(&iter, .help, diag);
            return .help;
        }
        if (eqlAny(&.{ "--version", "-v", "-V" }, arg)) {
            try validateSingleArg(&iter, .version, diag);
            return .version;
        }
        if (mem.eql(u8, "--env", arg)) {
            try validateSingleArg(&iter, .env, diag);
            return .env;
        }
        if (eqlAny(&.{ "--add-paths", "-a" }, arg)) {
            try validateFirstArg(&iter, .@"add-paths", diag);
            return .{ .add_paths = try getPaths(&iter, diag) };
        }
        // run opts
        if (mem.eql(u8, "--preview", arg)) {
            run_opts.fzf_preview = try getNextValidArg(&iter, .preview, diag);
        } else if (mem.eql(u8, "--no-preview", arg)) {
            run_opts.fzf_preview = "";
        } else if (mem.eql(u8, "--script", arg)) {
            run_opts.tmux_session_script = try getNextValidArg(&iter, .script, diag);
        } else if (mem.eql(u8, "--action", arg)) {
            const action = try getNextValidArg(&iter, .action, diag);
            run_opts.action = std.meta.stringToEnum(RunAction, action) orelse {
                diag.report(.action, "illegal action: {s}", .{action});
                return error.IllegalArgument;
            };
        } else if (mem.startsWith(u8, arg, "--")) {
            run_opts.action = std.meta.stringToEnum(RunAction, arg[2..]) orelse {
                diag.reportUntagged("illegal flag: {s}", .{arg});
                return error.IllegalArgument;
            };
        } else {
            run_opts.project = arg;
        }
    }

    return .{ .run = run_opts };
}

fn isFlag(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn getPaths(iter: *ArgIterator, diag: *Diag) ![]const []const u8 {
    const start = iter.pos;

    while (iter.next()) |arg| {
        // check if empty arg or flag is passed
        if (arg.len == 0) {
            diag.report(.@"add-paths", "empty path", .{});
            return error.IllegalArgument;
        }
        if (arg.len == 0 or arg[0] == '-') {
            diag.report(.@"add-paths", "illegal path: {s}", .{arg});
            return error.IllegalArgument;
        }
    }

    const end = iter.pos;
    if (start == end) {
        diag.report(.@"add-paths", "no path provided", .{});
        return error.MissingArgument;
    }

    return iter.args[start..end];
}

/// returns `error.MissingArgument` if there is no next argument
/// returns `error.IllegalArgument` if the next argument is a flag (starts with -)
fn getNextValidArg(
    iter: *ArgIterator,
    tag: Tag,
    diag: *Diag,
) error{ MissingArgument, IllegalArgument }![]const u8 {
    const arg = iter.next() orelse {
        diag.report(tag, "expected argument, none found", .{});
        return error.MissingArgument;
    };
    if (isFlag(arg)) {
        diag.report(tag, "illegal argument, not expecting flag: {s}", .{arg});
        return error.IllegalArgument;
    }
    return arg;
}

fn validateFirstArg(
    iter: *ArgIterator,
    tag: Tag,
    diag: *Diag,
) error{IllegalArgument}!void {
    const arg_pos = iter.pos - 1;
    if (arg_pos != 1) {
        diag.report(tag, "expected to be the first flag, was number {d}", .{arg_pos});
        return error.IllegalArgument;
    }
}

fn validateSingleArg(
    iter: *ArgIterator,
    tag: Tag,
    diag: *Diag,
) error{IllegalArgument}!void {
    try validateFirstArg(iter, tag, diag);
    if (iter.next()) |arg| {
        diag.report(tag, "expected to be the last argument, found: {s}", .{arg});
        return error.IllegalArgument;
    }
}

fn eqlAny(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |elem| {
        if (mem.eql(u8, elem, needle)) return true;
    }
    return false;
}

const ArgIterator = struct {
    args: []const []const u8,
    pos: usize = 0,

    fn init(args: []const []const u8) ArgIterator {
        return .{ .args = args };
    }

    fn peek(self: *ArgIterator) ?[]const u8 {
        if (self.pos >= self.args.len) return null;
        return self.args[self.pos];
    }

    fn next(self: *ArgIterator) ?[]const u8 {
        const item = self.peek() orelse return null;
        self.pos += 1;
        return item;
    }
};

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test ArgIterator {
    {
        var iter: ArgIterator = .init(&.{ "a", "b", "c" });

        try std.testing.expectEqualStrings("a", iter.peek().?);
        try std.testing.expectEqualStrings("a", iter.peek().?);
        try std.testing.expectEqualStrings("a", iter.next().?);

        try std.testing.expectEqualStrings("b", iter.peek().?);
        try std.testing.expectEqualStrings("b", iter.peek().?);
        try std.testing.expectEqualStrings("b", iter.next().?);

        try std.testing.expectEqualStrings("c", iter.peek().?);
        try std.testing.expectEqualStrings("c", iter.peek().?);
        try std.testing.expectEqualStrings("c", iter.next().?);

        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.next());
        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.next());
    }

    {
        var iter: ArgIterator = .init(&.{});

        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.next());
        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.peek());
        try std.testing.expectEqual(null, iter.next());
    }
}

fn testFailure(args: []const []const u8, comptime expected_message: []const u8, expected_error: ArgParseError) !void {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var diag: Diag = .init(&writer.writer);

    try std.testing.expectError(expected_error, parse(&diag, args));
    try std.testing.expectEqualStrings(expected_message, writer.written());
}

test "parse --help correctly" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var diag: Diag = .init(&writer.writer);

    const help_flags: []const []const u8 = &.{ "--help", "-h" };
    for (help_flags) |flag| {
        try std.testing.expectEqual(.help, try parse(&diag, &.{ "cs", flag }));
        try std.testing.expectEqual(0, writer.written().len);
    }
}

test "correctly fails bad --help usage" {
    const help_flags: []const []const u8 = &.{ "--help", "-h" };
    for (help_flags) |flag| {
        try testFailure(
            &.{ "cs", "my-project", flag },
            "error parsing help flag: expected to be the first flag, was number 2\n",
            error.IllegalArgument,
        );

        try testFailure(
            &.{ "cs", flag, "my-project" },
            "error parsing help flag: expected to be the last argument, found: my-project\n",
            error.IllegalArgument,
        );
    }
}

test "parse --version correctly" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var diag: Diag = .init(&writer.writer);

    const version_flags: []const []const u8 = &.{ "--version", "-v", "-V" };
    for (version_flags) |flag| {
        try std.testing.expectEqual(.version, try parse(&diag, &.{ "cs", flag }));
        try std.testing.expectEqual(0, writer.written().len);
    }
}

test "correctly fails bad --version usage" {
    const version_flags: []const []const u8 = &.{ "--version", "-v", "-V" };
    for (version_flags) |flag| {
        try testFailure(
            &.{ "cs", "my-project", flag },
            "error parsing version flag: expected to be the first flag, was number 2\n",
            error.IllegalArgument,
        );

        try testFailure(
            &.{ "cs", flag, "my-project" },
            "error parsing version flag: expected to be the last argument, found: my-project\n",
            error.IllegalArgument,
        );
    }
}

test "parse --env correctly" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var diag: Diag = .init(&writer.writer);

    try std.testing.expectEqual(.env, try parse(&diag, &.{ "cs", "--env" }));
    try std.testing.expectEqual(0, writer.written().len);
}

test "correctly fails bad --env usage" {
    try testFailure(
        &.{ "cs", "my-project", "--env" },
        "error parsing env flag: expected to be the first flag, was number 2\n",
        error.IllegalArgument,
    );

    try testFailure(
        &.{ "cs", "--env", "my-project" },
        "error parsing env flag: expected to be the last argument, found: my-project\n",
        error.IllegalArgument,
    );
}

fn testPaths(args: []const []const u8, expected_paths: []const []const u8) !void {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var diag: Diag = .init(&writer.writer);

    const result = try parse(&diag, args);
    const paths = result.add_paths;

    try std.testing.expectEqual(expected_paths.len, paths.len);
    for (expected_paths, paths) |expected_path, path| {
        try std.testing.expectEqualStrings(expected_path, path);
    }
    try std.testing.expectEqual(0, writer.written().len);
}

test "parse --add-paths correctly" {
    const add_paths_flags: []const []const u8 = &.{ "--add-paths", "-a" };
    for (add_paths_flags) |flag| {
        try testPaths(&.{ "cs", flag, "a/b/c", "../../tmp" }, &.{ "a/b/c", "../../tmp" });
        try testPaths(&.{ "cs", flag, "." }, &.{"."});
        try testPaths(&.{ "cs", flag, "..", "../..", "../../.." }, &.{ "..", "../..", "../../.." });
    }
}

test "correctly fails bad --add-paths usage" {
    const add_paths_flags: []const []const u8 = &.{ "--add-paths", "-a" };
    for (add_paths_flags) |flag| {
        try testFailure(
            &.{ "cs", "my-project", flag, "a/b/c" },
            "error parsing add-paths flag: expected to be the first flag, was number 2\n",
            error.IllegalArgument,
        );

        try testFailure(
            &.{ "cs", flag },
            "error parsing add-paths flag: no path provided\n",
            error.MissingArgument,
        );

        try testFailure(
            &.{ "cs", flag, "a/b/c", "--action", "cd" },
            "error parsing add-paths flag: illegal path: --action\n",
            error.IllegalArgument,
        );

        try testFailure(
            &.{ "cs", flag, "--help" },
            "error parsing add-paths flag: illegal path: --help\n",
            error.IllegalArgument,
        );

        try testFailure(
            &.{ "cs", flag, "" },
            "error parsing add-paths flag: empty path\n",
            error.IllegalArgument,
        );
    }
}

test "correctly fails bad flag" {
    try testFailure(
        &.{ "cs", "--config" },
        "illegal flag: --config\n",
        error.IllegalArgument,
    );

    try testFailure(
        &.{ "cs", "my_repo", "--verbose" },
        "illegal flag: --verbose\n",
        error.IllegalArgument,
    );
}

fn testRunCommand(args: []const []const u8, expected_run_opts: RunOpts) !void {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var diag: Diag = .init(&writer.writer);

    const result = try parse(&diag, args);
    const run_opts = result.run;

    try std.testing.expectEqualStrings(expected_run_opts.project, run_opts.project);
    try std.testing.expectEqualStrings(expected_run_opts.fzf_preview, run_opts.fzf_preview);
    try std.testing.expectEqualStrings(expected_run_opts.tmux_session_script, run_opts.tmux_session_script);
    try std.testing.expectEqual(expected_run_opts.action, run_opts.action);

    try std.testing.expectEqual(0, writer.written().len);
}

test "parse run command correctly" {
    { // project
        try testRunCommand(&.{"cs"}, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "my-project" }, .{
            .project = "my-project",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "my-project", "other-project" }, .{
            .project = "other-project",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "my-project", "" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .session,
        });
    }
    { // preview
        try testRunCommand(&.{ "cs", "--preview", "bat {}" }, .{
            .project = "",
            .fzf_preview = "bat {}",
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "--preview", "" }, .{
            .project = "",
            .fzf_preview = "",
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "--preview", "bat {}", "--no-preview" }, .{
            .project = "",
            .fzf_preview = "",
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "proj", "--preview", "bat {}" }, .{
            .project = "proj",
            .fzf_preview = "bat {}",
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "--preview", "bat {}", "proj" }, .{
            .project = "proj",
            .fzf_preview = "bat {}",
            .tmux_session_script = "",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "one", "--preview", "bat {}", "two" }, .{
            .project = "two",
            .fzf_preview = "bat {}",
            .tmux_session_script = "",
            .action = .session,
        });
    }
    { // script
        try testRunCommand(&.{ "cs", "--script", "echo hi" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "echo hi",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "--script", "" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .session,
        });

        try testRunCommand(&.{ "cs", "--script", "echo hi", "--script", "echo bye" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "echo bye",
            .action = .session,
        });
        try testRunCommand(&.{ "cs", "proj", "--script", "echo hi" }, .{
            .project = "proj",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "echo hi",
            .action = .session,
        });

        try testRunCommand(&.{ "cs", "--script", "echo hi", "proj" }, .{
            .project = "proj",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "echo hi",
            .action = .session,
        });
    }
    { // action
        try testRunCommand(&.{ "cs", "--action", "cd" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .cd,
        });
        try testRunCommand(&.{ "cs", "--cd" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .cd,
        });
        try testRunCommand(&.{ "cs", "--action", "print" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .print,
        });
        try testRunCommand(&.{ "cs", "--print" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .print,
        });
        try testRunCommand(&.{ "cs", "--action", "cd", "--window" }, .{
            .project = "",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .window,
        });
        try testRunCommand(&.{ "cs", "--cd", "proj", "--session" }, .{
            .project = "proj",
            .fzf_preview = default_fzf_preview,
            .tmux_session_script = "",
            .action = .session,
        });
    }
    { // mix
        try testRunCommand(&.{ "cs", "proj", "--preview", "bat {}", "--script", "echo hi", "--action", "cd" }, .{
            .project = "proj",
            .fzf_preview = "bat {}",
            .tmux_session_script = "echo hi",
            .action = .cd,
        });
        try testRunCommand(&.{ "cs", "--session", "--preview", "bat {}", "proj" }, .{
            .project = "proj",
            .fzf_preview = "bat {}",
            .tmux_session_script = "",
            .action = .session,
        });
    }
}

test "correctly fails bad run command" {
    { // preview
        try testFailure(
            &.{ "cs", "--preview" },
            "error parsing preview flag: expected argument, none found\n",
            error.MissingArgument,
        );
        try testFailure(
            &.{ "cs", "--preview", "--help" },
            "error parsing preview flag: illegal argument, not expecting flag: --help\n",
            error.IllegalArgument,
        );
    }

    { // script
        try testFailure(
            &.{ "cs", "--script" },
            "error parsing script flag: expected argument, none found\n",
            error.MissingArgument,
        );
        try testFailure(
            &.{ "cs", "--script", "--help" },
            "error parsing script flag: illegal argument, not expecting flag: --help\n",
            error.IllegalArgument,
        );
    }

    { // script
        try testFailure(
            &.{ "cs", "--action" },
            "error parsing action flag: expected argument, none found\n",
            error.MissingArgument,
        );
        try testFailure(
            &.{ "cs", "--action", "exec" },
            "error parsing action flag: illegal action: exec\n",
            error.IllegalArgument,
        );
    }
}
