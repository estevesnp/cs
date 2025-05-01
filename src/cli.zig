const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    depth: ?usize = null,
    roots: ?[]const []const u8 = null,

    pub const empty: Options = .{ .depth = null, .roots = null };

    pub const Error = Flag.Error;

    pub fn parseFromArgs(args: []const []const u8, diag: ?*Diag) !Options {
        var iter: Iterator([]const u8) = .init(args[1..]);

        var opts: Options = .empty;

        while (iter.next()) |arg| {
            const flag = Flag.fromArg(arg) catch |err| {
                if (diag) |d| try d.write_err("illegal argument: {s}", .{arg});
                return err;
            };
            try flag.handleArgs(&opts, &iter, diag);
        }

        return opts;
    }
};

pub const Diag = struct {
    out_writer: ?std.io.AnyWriter,
    err_writer: ?std.io.AnyWriter,

    pub const default_streams: Diag = .{
        .out_writer = std.io.getStdOut().writer().any(),
        .err_writer = std.io.getStdErr().writer().any(),
    };

    pub fn write_out(self: *Diag, comptime fmt: []const u8, args: anytype) !void {
        if (self.out_writer) |out| try out.print(fmt ++ "\n", args);
    }

    pub fn write_err(self: *Diag, comptime fmt: []const u8, args: anytype) !void {
        if (self.err_writer) |err| try err.print(fmt ++ "\n", args);
    }
};

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
            if (self.pos >= self.slice.len) return null;
            return self.slice[self.pos];
        }
    };
}

const Flag = union(enum) {
    const Error = error{
        RepeatedFlag,
        MissingArgument,
        IllegalArgument,
    };

    pub const Help = struct {
        const flags: []const []const u8 = &.{ "-h", "--help" };

        const usage =
            \\usage: zig [flag] [options]
            \\
            \\flags:
            \\
            \\  -h, --help                  print this message
            \\  -d, --depth <uint>          set max depth during search (default: 5)
            \\  -p, --paths <path> [...]    configure paths to search for
            \\
            \\description:
            \\
            \\  search for git repositories in a list of configured paths and prompt user to
            \\  either create a new tmux session or open an existing one inside that directory
        ;

        fn asFlag() Flag {
            return .{ .help = .{} };
        }

        fn handleArgs(
            self: @This(),
            opts: *Options,
            args_iter: *Iterator([]const u8),
            diag: ?*Diag,
        ) !void {
            _ = self;
            _ = opts;
            _ = args_iter;

            if (diag) |d| try d.write_out(usage, .{});
            std.process.cleanExit();
        }
    };

    pub const Depth = struct {
        const flags: []const []const u8 = &.{ "-d", "--depth" };

        fn asFlag() Flag {
            return .{ .depth = .{} };
        }

        fn handleArgs(
            self: @This(),
            opts: *Options,
            args_iter: *Iterator([]const u8),
            diag: ?*Diag,
        ) !void {
            _ = self;

            if (opts.depth != null) {
                if (diag) |d| try d.write_err("the -d/--depth flag is present more than once", .{});
                return Error.RepeatedFlag;
            }

            const depth_arg = args_iter.next() orelse {
                if (diag) |d| try d.write_err("no argument provided to the -d/--depth flag", .{});
                return Error.MissingArgument;
            };

            opts.depth = std.fmt.parseInt(usize, depth_arg, 10) catch {
                if (diag) |d|
                    try d.write_err("illegal argument provided to the -d/--depth flag: {s}", .{depth_arg});
                return Error.IllegalArgument;
            };
        }
    };

    pub const Paths = struct {
        const flags: []const []const u8 = &.{ "-p", "--paths" };

        fn asFlag() Flag {
            return .{ .paths = .{} };
        }

        fn handleArgs(
            self: @This(),
            opts: *Options,
            args_iter: *Iterator([]const u8),
            diag: ?*Diag,
        ) !void {
            _ = self;

            if (opts.roots != null) {
                if (diag) |d| try d.write_err("the -p/--paths flag is present more than once", .{});
                return Error.RepeatedFlag;
            }

            const init_idx = args_iter.pos;
            while (args_iter.peek()) |arg| {
                if (isFlagArgument(arg)) break;
                _ = args_iter.next();
            }
            const final_idx = args_iter.pos;

            if (init_idx == final_idx) {
                if (diag) |d| try d.write_err("no paths provided to the -p/--paths flag", .{});
                return Error.MissingArgument;
            }

            opts.roots = args_iter.slice[init_idx..final_idx];
        }
    };

    help: Help,
    depth: Depth,
    paths: Paths,

    fn handleArgs(
        self: Flag,
        opts: *Options,
        args_iter: *Iterator([]const u8),
        diag: ?*Diag,
    ) anyerror!void {
        switch (self) {
            inline else => |f| return f.handleArgs(opts, args_iter, diag),
        }
    }

    fn fromArg(flag: []const u8) Error!Flag {
        inline for (@typeInfo(Flag).@"union".decls) |decl| {
            const flag_type = @field(Flag, decl.name);

            if (contains(flag_type.flags, flag)) {
                return flag_type.asFlag();
            }
        }

        return Error.IllegalArgument;
    }
};

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |match| {
        if (std.mem.eql(u8, needle, match)) return true;
    }
    return false;
}

fn isFlagArgument(arg: []const u8) bool {
    if (arg.len == 0) return false;
    return arg[0] == '-';
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test Iterator {
    {
        var iter = Iterator(u8).init(&.{ 1, 2, 3 });

        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.next(), 1);

        try std.testing.expectEqual(iter.peek(), 2);
        try std.testing.expectEqual(iter.peek(), 2);
        try std.testing.expectEqual(iter.next(), 2);

        try std.testing.expectEqual(iter.peek(), 3);
        try std.testing.expectEqual(iter.peek(), 3);
        try std.testing.expectEqual(iter.next(), 3);

        try std.testing.expectEqual(iter.peek(), null);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }

    {
        var iter = Iterator(u8).init(&.{1});

        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.peek(), 1);
        try std.testing.expectEqual(iter.next(), 1);

        try std.testing.expectEqual(iter.peek(), null);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }

    {
        var iter = Iterator(u8).init(&.{});

        try std.testing.expectEqual(iter.peek(), null);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }
}

test "handle help" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{"--help"});

    try Flag.Help.asFlag().handleArgs(&opts, &iter, &diag);

    try std.testing.expectEqual(0, err_list.items.len);
    try std.testing.expectEqualStrings(Flag.Help.usage ++ "\n", out_list.items);

    try std.testing.expectEqual(null, opts.roots);
    try std.testing.expectEqual(null, opts.depth);
}

test "handle depth" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{"1"});

    try Flag.Depth.asFlag().handleArgs(&opts, &iter, &diag);

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqual(0, err_list.items.len);

    try std.testing.expectEqual(null, opts.roots);
    try std.testing.expectEqual(1, opts.depth);
}

test "handle depth no args" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{});

    try std.testing.expectError(
        error.MissingArgument,
        Flag.Depth.asFlag().handleArgs(&opts, &iter, &diag),
    );

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqualStrings(
        "no argument provided to the -d/--depth flag\n",
        err_list.items,
    );
}

test "handle depth illegal arg" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{"foo"});

    try std.testing.expectError(
        error.IllegalArgument,
        Flag.Depth.asFlag().handleArgs(&opts, &iter, &diag),
    );

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqualStrings(
        "illegal argument provided to the -d/--depth flag: foo\n",
        err_list.items,
    );
}

test "handle paths" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{ "/tmp/1", "/tmp/2" });

    try Flag.Paths.asFlag().handleArgs(&opts, &iter, &diag);

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqual(0, err_list.items.len);

    try std.testing.expectEqual(null, opts.depth);
    try std.testing.expectEqual(2, opts.roots.?.len);
    try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
    try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
}

test "handle paths one arg" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{"/tmp/1"});

    try Flag.Paths.asFlag().handleArgs(&opts, &iter, &diag);

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqual(0, err_list.items.len);

    try std.testing.expectEqual(null, opts.depth);
    try std.testing.expectEqual(1, opts.roots.?.len);
    try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
}
test "handle paths with flag args" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{ "/tmp/1", "/tmp/2", "-d", "1" });

    try Flag.Paths.asFlag().handleArgs(&opts, &iter, &diag);

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqual(0, err_list.items.len);

    try std.testing.expectEqual(null, opts.depth);
    try std.testing.expectEqual(2, opts.roots.?.len);
    try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
    try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
}

test "handle paths no args" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{});

    try std.testing.expectError(
        error.MissingArgument,
        Flag.Paths.asFlag().handleArgs(&opts, &iter, &diag),
    );

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqualStrings(
        "no paths provided to the -p/--paths flag\n",
        err_list.items,
    );
}

test "handle paths no path args with flag arg" {
    var opts: Options = .empty;

    var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer out_list.deinit();

    var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
    defer err_list.deinit();

    var diag: Diag = .{
        .out_writer = out_list.writer().any(),
        .err_writer = err_list.writer().any(),
    };

    var iter: Iterator([]const u8) = .init(&.{ "--depth", "1" });

    try std.testing.expectError(
        error.MissingArgument,
        Flag.Paths.asFlag().handleArgs(&opts, &iter, &diag),
    );

    try std.testing.expectEqual(0, out_list.items.len);
    try std.testing.expectEqualStrings(
        "no paths provided to the -p/--paths flag\n",
        err_list.items,
    );
}

test "Option.parseFromArgs" {
    { // depth and paths
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--depth",
            "1",
            "--paths",
            "/tmp/2",
            "/tmp/3",
        };

        const opts = try Options.parseFromArgs(args, &diag);

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqual(0, err_list.items.len);

        try std.testing.expectEqual(1, opts.depth.?);
        try std.testing.expectEqual(2, opts.roots.?.len);
        try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[0]);
        try std.testing.expectEqualStrings("/tmp/3", opts.roots.?[1]);
    }

    { // paths and depth
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "/tmp/2",
            "--depth",
            "3",
        };

        const opts = try Options.parseFromArgs(args, &diag);

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqual(0, err_list.items.len);

        try std.testing.expectEqual(3, opts.depth.?);
        try std.testing.expectEqual(2, opts.roots.?.len);
        try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
        try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
    }

    { // depth
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--depth",
            "42",
        };

        const opts = try Options.parseFromArgs(args, &diag);

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqual(0, err_list.items.len);

        try std.testing.expectEqual(42, opts.depth.?);
        try std.testing.expectEqual(null, opts.roots);
    }

    { // paths
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "/tmp/2",
        };

        const opts = try Options.parseFromArgs(args, &diag);

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqual(0, err_list.items.len);

        try std.testing.expectEqual(null, opts.depth);
        try std.testing.expectEqual(2, opts.roots.?.len);
        try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
        try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
    }
}

test "Option.parseFromArgs fails" {
    { // no depth, paths
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--depth",
            "--paths",
            "/tmp/1",
            "/tmp/2",
        };

        try std.testing.expectError(
            error.IllegalArgument,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "illegal argument provided to the -d/--depth flag: --paths\n",
            err_list.items,
        );
    }

    { // no paths, depth
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "--depth",
            "1",
        };

        try std.testing.expectError(
            error.MissingArgument,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "no paths provided to the -p/--paths flag\n",
            err_list.items,
        );
    }

    { // paths, no depth
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "/tmp/2",
            "--depth",
        };

        try std.testing.expectError(
            error.MissingArgument,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "no argument provided to the -d/--depth flag\n",
            err_list.items,
        );
    }

    { // depth, no paths
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--depth",
            "3",
            "--paths",
        };

        try std.testing.expectError(
            error.MissingArgument,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "no paths provided to the -p/--paths flag\n",
            err_list.items,
        );
    }

    { // multiple depth args
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--depth",
            "1",
            "2",
        };

        try std.testing.expectError(
            error.IllegalArgument,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "illegal argument: 2\n",
            err_list.items,
        );
    }

    { // path args, multiple depth args
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "--depth",
            "2",
            "3",
        };

        try std.testing.expectError(
            error.IllegalArgument,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "illegal argument: 3\n",
            err_list.items,
        );
    }

    { // repeated depth flag
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--depth",
            "1",
            "-d",
            "2",
        };

        try std.testing.expectError(
            error.RepeatedFlag,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "the -d/--depth flag is present more than once\n",
            err_list.items,
        );
    }

    { // repeated paths flag
        var out_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer out_list.deinit();

        var err_list: std.ArrayList(u8) = .init(std.testing.allocator);
        defer err_list.deinit();

        var diag: Diag = .{
            .out_writer = out_list.writer().any(),
            .err_writer = err_list.writer().any(),
        };

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "-p",
            "/tmp/2",
        };

        try std.testing.expectError(
            error.RepeatedFlag,
            Options.parseFromArgs(args, &diag),
        );

        try std.testing.expectEqual(0, out_list.items.len);
        try std.testing.expectEqualStrings(
            "the -p/--paths flag is present more than once\n",
            err_list.items,
        );
    }
}

test "repeated flag configuration" {
    const decls = @typeInfo(Flag).@"union".decls;

    var flag_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer flag_map.deinit(std.testing.allocator);

    inline for (decls) |decl| {
        const flag_type = @field(Flag, decl.name);
        if (@typeInfo(flag_type) != .@"struct") continue;

        for (flag_type.flags) |flag| {
            const gop = try flag_map.getOrPut(std.testing.allocator, flag);
            if (gop.found_existing) {
                std.debug.print(
                    "found repeated flag '{s}' for types '{s}.{s}' and '{s}.{s}'\n",
                    .{ flag, @typeName(Flag), decl.name, @typeName(Flag), gop.value_ptr.* },
                );
                return error.RepeatedFlag;
            }

            gop.value_ptr.* = decl.name;
        }
    }
}
