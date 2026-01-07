const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const testing = std.testing;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

/// parsed user command
pub const Command = union(enum) {
    /// print help
    help,
    /// print version
    version,
    /// print config and search paths
    env: EnvFmt,
    /// add search paths
    @"add-paths": []const []const u8,
    /// set search paths
    @"set-paths": []const []const u8,
    /// remove search paths
    @"remove-paths": []const []const u8,
    /// shell integration
    shell: ?Shell,
    /// search for projects
    search: SearchOpts,
};

/// formats for printing env
pub const EnvFmt = enum {
    txt,
    json,
};

/// supported shell integration
pub const Shell = enum {
    bash,
    zsh,
};

pub const SearchAction = enum {
    /// open new tmux session with project. default option
    session,
    /// open new tmux window with project
    window,
    /// print project directory
    print,
};

pub const SearchOpts = struct {
    /// default project search
    project: []const u8 = "",
    /// fzf preview command. --no-preview sets this as an empty string
    preview: ?[]const u8 = null,
    /// action to take on project found
    action: ?SearchAction = null,
};

pub const ArgParseError = error{ IllegalArgument, MissingArgument };

/// parses args. assumes first argument is the program
/// doesn't own the memory, so is valid as long as the `args` argument
pub fn parse(diag: Diagnostic, args: []const []const u8) ArgParseError!Command {
    var iter: ArgIterator = .init(args);
    assert(iter.next() != null);

    var search_opts: SearchOpts = .{};

    while (iter.next()) |arg| {
        // help
        if (eqlAny(&.{ "--help", "-h" }, arg)) {
            try validateSingleArg(&iter, .help, diag);
            return .help;
        }
        // version
        if (eqlAny(&.{ "--version", "-v", "-V" }, arg)) {
            try validateSingleArg(&iter, .version, diag);
            return .version;
        }
        // env
        if (mem.eql(u8, "--env", arg)) {
            try validateFirstArg(&iter, .env, diag);

            const next = iter.next();
            if (next == null) {
                return .{ .env = .txt };
            }

            if (!mem.eql(u8, "--json", next.?)) {
                diag.report(.env, "expected '--json', found: {s}", .{next.?});
                return error.IllegalArgument;
            }

            try validateNoMoreArgs(&iter, .env, diag);
            return .{ .env = .json };
        }
        if (mem.eql(u8, "--json", arg)) {
            try validateFirstArg(&iter, .json, diag);

            const next = iter.next();
            if (next == null) {
                diag.report(.json, "flag cannot be used without '--env'", .{});
                return error.MissingArgument;
            }

            if (!mem.eql(u8, "--env", next.?)) {
                diag.report(.json, "expected '--env', found: {s}", .{next.?});
                return error.IllegalArgument;
            }

            try validateNoMoreArgs(&iter, .json, diag);
            return .{ .env = .json };
        }
        // paths
        if (eqlAny(&.{ "--add-paths", "-a" }, arg)) {
            try validateFirstArg(&iter, .@"add-paths", diag);
            return .{ .@"add-paths" = try getPaths(&iter, .@"add-paths", diag) };
        }
        if (eqlAny(&.{ "--set-paths", "-s" }, arg)) {
            try validateFirstArg(&iter, .@"set-paths", diag);
            return .{ .@"set-paths" = try getPaths(&iter, .@"set-paths", diag) };
        }
        if (eqlAny(&.{ "--remove-paths", "-r" }, arg)) {
            try validateFirstArg(&iter, .@"remove-paths", diag);
            return .{ .@"remove-paths" = try getPaths(&iter, .@"remove-paths", diag) };
        }
        //shell
        if (mem.eql(u8, "--shell", arg)) {
            try validateFirstArg(&iter, .shell, diag);

            if (iter.next()) |shell| {
                try validateNoMoreArgs(&iter, .shell, diag);
                const supported_shell = std.meta.stringToEnum(Shell, shell) orelse {
                    diag.report(.shell, "unsupported shell: {s}", .{shell});
                    return error.IllegalArgument;
                };
                return .{ .shell = supported_shell };
            }

            return .{ .shell = null };
        }
        // search opts
        if (mem.eql(u8, "--preview", arg)) {
            search_opts.preview = try getNextValidArg(&iter, .preview, diag);
        } else if (mem.eql(u8, "--no-preview", arg)) {
            search_opts.preview = "";
        } else if (mem.eql(u8, "--action", arg)) {
            const action = try getNextValidArg(&iter, .action, diag);
            search_opts.action = std.meta.stringToEnum(SearchAction, action) orelse {
                diag.report(.action, "illegal action: {s}", .{action});
                return error.IllegalArgument;
            };
        } else if (mem.eql(u8, "-w", arg)) {
            search_opts.action = .window;
        } else if (mem.startsWith(u8, arg, "--")) {
            // try find --{action}, skipping the '--'
            search_opts.action = std.meta.stringToEnum(SearchAction, arg[2..]) orelse {
                diag.reportMessage("illegal flag: {s}", .{arg});
                return error.IllegalArgument;
            };
        } else {
            search_opts.project = arg;
        }
    }

    return .{ .search = search_opts };
}

fn isFlag(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn getPaths(
    iter: *ArgIterator,
    tag: Tag,
    diag: Diagnostic,
) ArgParseError![]const []const u8 {
    const start = iter.pos;

    while (iter.next()) |arg| {
        // check if empty arg or flag is passed
        if (arg.len == 0) {
            diag.report(tag, "empty path", .{});
            return error.IllegalArgument;
        }
        if (arg.len == 0 or arg[0] == '-') {
            diag.report(tag, "illegal path: {s}", .{arg});
            return error.IllegalArgument;
        }
    }

    const end = iter.pos;
    if (start == end) {
        diag.report(tag, "no path provided", .{});
        return error.MissingArgument;
    }

    return iter.args[start..end];
}

/// returns `error.MissingArgument` if there is no next argument
/// returns `error.IllegalArgument` if the next argument is a flag (starts with -)
fn getNextValidArg(
    iter: *ArgIterator,
    tag: Tag,
    diag: Diagnostic,
) ArgParseError![]const u8 {
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
    diag: Diagnostic,
) error{IllegalArgument}!void {
    const arg_pos = iter.pos - 1;
    if (arg_pos != 1) {
        diag.report(tag, "expected to be the first flag, was in position {d}", .{arg_pos});
        return error.IllegalArgument;
    }
}

fn validateNoMoreArgs(
    iter: *ArgIterator,
    tag: Tag,
    diag: Diagnostic,
) error{IllegalArgument}!void {
    if (iter.next()) |arg| {
        diag.report(tag, "expected there to be no more arguments, found: {s}", .{arg});
        return error.IllegalArgument;
    }
}

fn validateSingleArg(
    iter: *ArgIterator,
    tag: Tag,
    diag: Diagnostic,
) error{IllegalArgument}!void {
    try validateFirstArg(iter, tag, diag);
    try validateNoMoreArgs(iter, tag, diag);
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

pub const Diagnostic = struct {
    writer: *Writer,

    pub fn reportMessage(
        self: Diagnostic,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.writer.print(fmt ++ "\n", args) catch {};
        self.writer.flush() catch {};
    }

    pub fn report(
        self: Diagnostic,
        tag: Tag,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.writer.print("error parsing '{t}' flag: ", .{tag}) catch {};
        self.reportMessage(fmt, args);
    }
};

/// enum derived from the `Command` fields
/// also contains the `SearchOpts` fields (except for `search`)
/// also contains `--json` from `--env`
/// used for tagging diagnostic messages
const Tag = blk: {
    const cmd_fields = @typeInfo(Command).@"union".fields;
    const search_fields = @typeInfo(SearchOpts).@"struct".fields;

    const num_fields = cmd_fields.len + search_fields.len;
    var field_names: [num_fields][]const u8 = undefined;
    var field_values: [num_fields]u8 = undefined;

    var idx = 0;
    for (cmd_fields) |field| {
        // 'search' isn't a flag
        if (@FieldType(Command, field.name) == SearchOpts) continue;

        field_names[idx] = field.name;
        field_values[idx] = idx;
        idx += 1;
    }

    for (search_fields) |field| {
        field_names[idx] = field.name;
        field_values[idx] = idx;
        idx += 1;
    }

    // since we skipped 'search', we have space for 'json'
    field_names[idx] = "json";
    field_values[idx] = idx;

    break :blk @Enum(
        u8,
        .exhaustive,
        &field_names,
        &field_values,
    );
};

test "ref all decls" {
    testing.refAllDeclsRecursive(@This());
}

test ArgIterator {
    {
        var iter: ArgIterator = .init(&.{ "a", "b", "c" });

        try testing.expectEqualStrings("a", iter.peek().?);
        try testing.expectEqualStrings("a", iter.peek().?);
        try testing.expectEqualStrings("a", iter.next().?);

        try testing.expectEqualStrings("b", iter.peek().?);
        try testing.expectEqualStrings("b", iter.peek().?);
        try testing.expectEqualStrings("b", iter.next().?);

        try testing.expectEqualStrings("c", iter.peek().?);
        try testing.expectEqualStrings("c", iter.peek().?);
        try testing.expectEqualStrings("c", iter.next().?);

        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.next());
        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.next());
    }

    {
        var iter: ArgIterator = .init(&.{});

        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.next());
        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.peek());
        try testing.expectEqual(null, iter.next());
    }
}

fn test_failure(args: []const []const u8, comptime expected_message: []const u8, expected_error: ArgParseError) !void {
    var writer: Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    try testing.expectError(expected_error, parse(diag, args));
    try testing.expectEqualStrings(expected_message, writer.written());
}

test "correctly fails bad flag" {
    try test_failure(
        &.{ "cs", "--config" },
        "illegal flag: --config\n",
        error.IllegalArgument,
    );

    try test_failure(
        &.{ "cs", "my_repo", "--verbose" },
        "illegal flag: --verbose\n",
        error.IllegalArgument,
    );
}

test "parse --help correctly" {
    var writer: Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const help_flags: []const []const u8 = &.{ "--help", "-h" };
    for (help_flags) |flag| {
        try testing.expectEqual(.help, try parse(diag, &.{ "cs", flag }));
        try testing.expectEqual(0, writer.written().len);
    }
}

test "correctly fails bad --help usage" {
    const help_flags: []const []const u8 = &.{ "--help", "-h" };
    for (help_flags) |flag| {
        try test_failure(
            &.{ "cs", "my-project", flag },
            "error parsing 'help' flag: expected to be the first flag, was in position 2\n",
            error.IllegalArgument,
        );

        try test_failure(
            &.{ "cs", flag, "my-project" },
            "error parsing 'help' flag: expected there to be no more arguments, found: my-project\n",
            error.IllegalArgument,
        );
    }
}

test "parse --version correctly" {
    var writer: Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const version_flags: []const []const u8 = &.{ "--version", "-v", "-V" };
    for (version_flags) |flag| {
        try testing.expectEqual(.version, try parse(diag, &.{ "cs", flag }));
        try testing.expectEqual(0, writer.written().len);
    }
}

test "correctly fails bad --version usage" {
    const version_flags: []const []const u8 = &.{ "--version", "-v", "-V" };
    for (version_flags) |flag| {
        try test_failure(
            &.{ "cs", "my-project", flag },
            "error parsing 'version' flag: expected to be the first flag, was in position 2\n",
            error.IllegalArgument,
        );

        try test_failure(
            &.{ "cs", flag, "my-project" },
            "error parsing 'version' flag: expected there to be no more arguments, found: my-project\n",
            error.IllegalArgument,
        );
    }
}

fn test_env(expected_env_fmt: EnvFmt, args: []const []const u8) !void {
    var writer: Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const res = try parse(diag, args);

    try testing.expectEqual(expected_env_fmt, res.env);
    try testing.expectEqual(0, writer.written().len);
}

test "parse --env correctly" {
    try test_env(.txt, &.{ "cs", "--env" });
    try test_env(.json, &.{ "cs", "--env", "--json" });
    try test_env(.json, &.{ "cs", "--json", "--env" });
}

test "correctly fails bad --env usage" {
    try test_failure(
        &.{ "cs", "my-project", "--env" },
        "error parsing 'env' flag: expected to be the first flag, was in position 2\n",
        error.IllegalArgument,
    );

    try test_failure(
        &.{ "cs", "--env", "my-project" },
        "error parsing 'env' flag: expected '--json', found: my-project\n",
        error.IllegalArgument,
    );

    try test_failure(
        &.{ "cs", "--json" },
        "error parsing 'json' flag: flag cannot be used without '--env'\n",
        error.MissingArgument,
    );

    try test_failure(
        &.{ "cs", "my-project", "--json" },
        "error parsing 'json' flag: expected to be the first flag, was in position 2\n",
        error.IllegalArgument,
    );

    try test_failure(
        &.{ "cs", "--json", "my-project" },
        "error parsing 'json' flag: expected '--env', found: my-project\n",
        error.IllegalArgument,
    );

    try test_failure(
        &.{ "cs", "--env", "--json", "my-project" },
        "error parsing 'env' flag: expected there to be no more arguments, found: my-project\n",
        error.IllegalArgument,
    );

    try test_failure(
        &.{ "cs", "--json", "--env", "my-project" },
        "error parsing 'json' flag: expected there to be no more arguments, found: my-project\n",
        error.IllegalArgument,
    );
}

fn test_paths(
    comptime tag: PathFlagSet.PathTag,
    args: []const []const u8,
    expected_paths: []const []const u8,
) !void {
    var writer: Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const result = try parse(diag, args);

    const paths = @field(result, @tagName(tag));

    try testing.expectEqual(expected_paths.len, paths.len);
    for (expected_paths, paths) |expected_path, path| {
        try testing.expectEqualStrings(expected_path, path);
    }
    try testing.expectEqual(0, writer.written().len);
}

const PathFlagSet = struct {
    const PathTag = enum { @"add-paths", @"set-paths", @"remove-paths" };

    const values: []const PathFlagSet = &.{
        .{ .tag = .@"add-paths", .flags = &.{ "--add-paths", "-a" } },
        .{ .tag = .@"set-paths", .flags = &.{ "--set-paths", "-s" } },
        .{ .tag = .@"remove-paths", .flags = &.{ "--remove-paths", "-r" } },
    };

    tag: PathTag,
    flags: []const []const u8,
};

test "parse path flags correctly" {
    inline for (PathFlagSet.values) |flag_set| {
        const tag = flag_set.tag;
        for (flag_set.flags) |flag| {
            try test_paths(tag, &.{ "cs", flag, "a/b/c", "../../tmp" }, &.{ "a/b/c", "../../tmp" });
            try test_paths(tag, &.{ "cs", flag, "." }, &.{"."});
            try test_paths(tag, &.{ "cs", flag, "..", "../..", "../../.." }, &.{ "..", "../..", "../../.." });
        }
    }
}

test "correctly fails bad --add-paths usage" {
    inline for (PathFlagSet.values) |flag_set| {
        const flag_name = @tagName(flag_set.tag);
        for (flag_set.flags) |flag| {
            try test_failure(
                &.{ "cs", "my-project", flag, "a/b/c" },
                "error parsing '" ++ flag_name ++ "' flag: expected to be the first flag, was in position 2\n",
                error.IllegalArgument,
            );

            try test_failure(
                &.{ "cs", flag },
                "error parsing '" ++ flag_name ++ "' flag: no path provided\n",
                error.MissingArgument,
            );

            try test_failure(
                &.{ "cs", flag, "a/b/c", "--action", "print" },
                "error parsing '" ++ flag_name ++ "' flag: illegal path: --action\n",
                error.IllegalArgument,
            );

            try test_failure(
                &.{ "cs", flag, "--help" },
                "error parsing '" ++ flag_name ++ "' flag: illegal path: --help\n",
                error.IllegalArgument,
            );

            try test_failure(
                &.{ "cs", flag, "" },
                "error parsing '" ++ flag_name ++ "' flag: empty path\n",
                error.IllegalArgument,
            );
        }
    }
}

fn test_shell(shell: ?Shell, args: []const []const u8) !void {
    var writer: Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const result = try parse(diag, args);

    try testing.expectEqual(shell, result.shell);
    try testing.expectEqual(0, writer.written().len);
}

test "parse --shell correctly " {
    try test_shell(.zsh, &.{ "cs", "--shell", "zsh" });
    try test_shell(.bash, &.{ "cs", "--shell", "bash" });
    try test_shell(null, &.{ "cs", "--shell" });
}

test "correctly fails bad --shell usage" {
    try test_failure(
        &.{ "cs", "--shell", "powershell" },
        "error parsing 'shell' flag: unsupported shell: powershell\n",
        error.IllegalArgument,
    );
    try test_failure(
        &.{ "cs", "--shell", "zsh", "--json" },
        "error parsing 'shell' flag: expected there to be no more arguments, found: --json\n",
        error.IllegalArgument,
    );
}

fn test_searchCommand(args: []const []const u8, expected_search_opts: SearchOpts) !void {
    var writer: Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const result = try parse(diag, args);
    const search_opts = result.search;

    if (expected_search_opts.preview) |preview| {
        try testing.expectEqualStrings(preview, search_opts.preview.?);
    } else {
        try testing.expectEqual(null, search_opts.preview);
    }

    try testing.expectEqual(expected_search_opts.action, search_opts.action);
    try testing.expectEqualStrings(expected_search_opts.project, search_opts.project);

    try testing.expectEqual(0, writer.written().len);
}

test "parse search command correctly" {
    { // project
        try test_searchCommand(&.{"cs"}, .{
            .project = "",
            .preview = null,
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "my-project" }, .{
            .project = "my-project",
            .preview = null,
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "my-project", "other-project" }, .{
            .project = "other-project",
            .preview = null,
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "my-project", "" }, .{
            .project = "",
            .preview = null,
            .action = null,
        });
    }
    { // preview
        try test_searchCommand(&.{ "cs", "--preview", "bat {}" }, .{
            .project = "",
            .preview = "bat {}",
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "--preview", "" }, .{
            .project = "",
            .preview = "",
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "--preview", "bat {}", "--no-preview" }, .{
            .project = "",
            .preview = "",
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "proj", "--preview", "bat {}" }, .{
            .project = "proj",
            .preview = "bat {}",
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "--preview", "bat {}", "proj" }, .{
            .project = "proj",
            .preview = "bat {}",
            .action = null,
        });
        try test_searchCommand(&.{ "cs", "one", "--preview", "bat {}", "two" }, .{
            .project = "two",
            .preview = "bat {}",
            .action = null,
        });
    }
    { // action
        try test_searchCommand(&.{ "cs", "--action", "print" }, .{
            .project = "",
            .preview = null,
            .action = .print,
        });
        try test_searchCommand(&.{ "cs", "--print" }, .{
            .project = "",
            .preview = null,
            .action = .print,
        });
        try test_searchCommand(&.{ "cs", "--action", "print", "--window" }, .{
            .project = "",
            .preview = null,
            .action = .window,
        });
        try test_searchCommand(&.{ "cs", "--print", "proj", "--session" }, .{
            .project = "proj",
            .preview = null,
            .action = .session,
        });
        try test_searchCommand(&.{ "cs", "-w" }, .{
            .project = "",
            .preview = null,
            .action = .window,
        });
    }
    { // mix
        try test_searchCommand(&.{ "cs", "proj", "--preview", "bat {}", "--action", "print" }, .{
            .project = "proj",
            .preview = "bat {}",
            .action = .print,
        });
        try test_searchCommand(&.{ "cs", "--session", "--preview", "bat {}", "proj" }, .{
            .project = "proj",
            .preview = "bat {}",
            .action = .session,
        });
    }
}

test "correctly fails bad search command" {
    { // preview
        try test_failure(
            &.{ "cs", "--preview" },
            "error parsing 'preview' flag: expected argument, none found\n",
            error.MissingArgument,
        );
        try test_failure(
            &.{ "cs", "--preview", "--help" },
            "error parsing 'preview' flag: illegal argument, not expecting flag: --help\n",
            error.IllegalArgument,
        );
    }

    { // action
        try test_failure(
            &.{ "cs", "--action" },
            "error parsing 'action' flag: expected argument, none found\n",
            error.MissingArgument,
        );
        try test_failure(
            &.{ "cs", "--action", "exec" },
            "error parsing 'action' flag: illegal action: exec\n",
            error.IllegalArgument,
        );
    }
}
