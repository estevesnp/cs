const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

/// parsed user command
pub const Command = union(enum) {
    /// print help
    help,
    /// print version
    version,
    // TODO: implement
    env,
    @"add-paths": []const []const u8,
    @"set-paths": []const []const u8,
    @"remove-paths": []const []const u8,
    /// search for projects
    search: SearchOpts,
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
pub fn parse(diag: *const Diagnostic, args: []const []const u8) ArgParseError!Command {
    var iter: ArgIterator = .init(args);
    assert(iter.next() != null);

    var search_opts: SearchOpts = .{};

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
    diag: *const Diagnostic,
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
    diag: *const Diagnostic,
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
    diag: *const Diagnostic,
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
    diag: *const Diagnostic,
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

pub const Diagnostic = struct {
    writer: *Writer,

    pub fn reportMessage(
        self: *const Diagnostic,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.writer.print(fmt ++ "\n", args) catch {};
        self.writer.flush() catch {};
    }

    pub fn report(
        self: *const Diagnostic,
        tag: Tag,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.writer.print("error parsing {t} flag: ", .{tag}) catch {};
        self.reportMessage(fmt, args);
    }
};

/// enum derived from the `Command` fields
/// used for tagging diagnostic messages
const Tag = blk: {
    const cmd_fields = @typeInfo(Command).@"union".fields;
    const search_fields = @typeInfo(SearchOpts).@"struct".fields;

    const num_fields = cmd_fields.len + search_fields.len;
    var fields: [num_fields]std.builtin.Type.EnumField = undefined;

    var idx = 0;
    for (cmd_fields) |field| {
        // 'search' isn't a flag
        if (@FieldType(Command, field.name) == SearchOpts) continue;

        fields[idx] = .{ .name = field.name, .value = idx };
        idx += 1;
    }

    for (search_fields) |field| {
        fields[idx] = .{ .name = field.name, .value = idx };
        idx += 1;
    }

    const enum_info: std.builtin.Type.Enum = .{
        .tag_type = u8,
        .fields = fields[0..idx],
        .decls = &.{},
        .is_exhaustive = true,
    };

    break :blk @Type(.{ .@"enum" = enum_info });
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

fn test_failure(args: []const []const u8, comptime expected_message: []const u8, expected_error: ArgParseError) !void {
    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    try std.testing.expectError(expected_error, parse(&diag, args));
    try std.testing.expectEqualStrings(expected_message, writer.written());
}

test "parse --help correctly" {
    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const help_flags: []const []const u8 = &.{ "--help", "-h" };
    for (help_flags) |flag| {
        try std.testing.expectEqual(.help, try parse(&diag, &.{ "cs", flag }));
        try std.testing.expectEqual(0, writer.written().len);
    }
}

test "correctly fails bad --help usage" {
    const help_flags: []const []const u8 = &.{ "--help", "-h" };
    for (help_flags) |flag| {
        try test_failure(
            &.{ "cs", "my-project", flag },
            "error parsing help flag: expected to be the first flag, was number 2\n",
            error.IllegalArgument,
        );

        try test_failure(
            &.{ "cs", flag, "my-project" },
            "error parsing help flag: expected to be the last argument, found: my-project\n",
            error.IllegalArgument,
        );
    }
}

test "parse --version correctly" {
    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const version_flags: []const []const u8 = &.{ "--version", "-v", "-V" };
    for (version_flags) |flag| {
        try std.testing.expectEqual(.version, try parse(&diag, &.{ "cs", flag }));
        try std.testing.expectEqual(0, writer.written().len);
    }
}

test "correctly fails bad --version usage" {
    const version_flags: []const []const u8 = &.{ "--version", "-v", "-V" };
    for (version_flags) |flag| {
        try test_failure(
            &.{ "cs", "my-project", flag },
            "error parsing version flag: expected to be the first flag, was number 2\n",
            error.IllegalArgument,
        );

        try test_failure(
            &.{ "cs", flag, "my-project" },
            "error parsing version flag: expected to be the last argument, found: my-project\n",
            error.IllegalArgument,
        );
    }
}

test "parse --env correctly" {
    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    try std.testing.expectEqual(.env, try parse(&diag, &.{ "cs", "--env" }));
    try std.testing.expectEqual(0, writer.written().len);
}

test "correctly fails bad --env usage" {
    try test_failure(
        &.{ "cs", "my-project", "--env" },
        "error parsing env flag: expected to be the first flag, was number 2\n",
        error.IllegalArgument,
    );

    try test_failure(
        &.{ "cs", "--env", "my-project" },
        "error parsing env flag: expected to be the last argument, found: my-project\n",
        error.IllegalArgument,
    );
}

fn test_paths(
    comptime tag: PathFlagSet.PathTag,
    args: []const []const u8,
    expected_paths: []const []const u8,
) !void {
    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const result = try parse(&diag, args);

    const paths = @field(result, @tagName(tag));

    try std.testing.expectEqual(expected_paths.len, paths.len);
    for (expected_paths, paths) |expected_path, path| {
        try std.testing.expectEqualStrings(expected_path, path);
    }
    try std.testing.expectEqual(0, writer.written().len);
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
                "error parsing " ++ flag_name ++ " flag: expected to be the first flag, was number 2\n",
                error.IllegalArgument,
            );

            try test_failure(
                &.{ "cs", flag },
                "error parsing " ++ flag_name ++ " flag: no path provided\n",
                error.MissingArgument,
            );

            try test_failure(
                &.{ "cs", flag, "a/b/c", "--action", "print" },
                "error parsing " ++ flag_name ++ " flag: illegal path: --action\n",
                error.IllegalArgument,
            );

            try test_failure(
                &.{ "cs", flag, "--help" },
                "error parsing " ++ flag_name ++ " flag: illegal path: --help\n",
                error.IllegalArgument,
            );

            try test_failure(
                &.{ "cs", flag, "" },
                "error parsing " ++ flag_name ++ " flag: empty path\n",
                error.IllegalArgument,
            );
        }
    }
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

fn test_searchCommand(args: []const []const u8, expected_search_opts: SearchOpts) !void {
    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    const diag: Diagnostic = .{ .writer = &writer.writer };

    const result = try parse(&diag, args);
    const search_opts = result.search;

    if (expected_search_opts.preview) |preview| {
        try std.testing.expectEqualStrings(preview, search_opts.preview.?);
    } else {
        try std.testing.expectEqual(null, search_opts.preview);
    }

    try std.testing.expectEqual(expected_search_opts.action, search_opts.action);
    try std.testing.expectEqualStrings(expected_search_opts.project, search_opts.project);

    try std.testing.expectEqual(0, writer.written().len);
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
            "error parsing preview flag: expected argument, none found\n",
            error.MissingArgument,
        );
        try test_failure(
            &.{ "cs", "--preview", "--help" },
            "error parsing preview flag: illegal argument, not expecting flag: --help\n",
            error.IllegalArgument,
        );
    }

    { // action
        try test_failure(
            &.{ "cs", "--action" },
            "error parsing action flag: expected argument, none found\n",
            error.MissingArgument,
        );
        try test_failure(
            &.{ "cs", "--action", "exec" },
            "error parsing action flag: illegal action: exec\n",
            error.IllegalArgument,
        );
    }
}
