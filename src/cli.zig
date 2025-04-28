const std = @import("std");

pub const Options = struct {
    roots: ?[]const []const u8 = null,
    config_path: ?[]const u8 = null,

    const empty: Options = .{ .roots = null, .config_path = null };

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        if (self.roots) |roots| allocator.free(roots);
        if (self.config_path) |cfg| allocator.free(cfg);
    }
};

pub const Diag = struct {
    msg: ?[]const u8 = null,
    owns_mem: bool = false,

    pub const empty: Diag = .{ .msg = null, .owns_mem = false };

    pub fn register(self: *Diag, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        self.msg = try std.fmt.allocPrint(allocator, fmt, args);
        self.owns_mem = true;
    }

    pub fn deinit(self: *Diag, allocator: std.mem.Allocator) void {
        if (self.owns_mem) {
            allocator.free(self.msg.?);
        }
    }
};

fn Iterator(T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        pos: usize = 0,

        const empty: Iterator(T) = .{ .slice = &.{} };

        fn init(slice: []const T) Self {
            return .{ .slice = slice };
        }

        fn next(self: *Self) ?T {
            if (self.pos >= self.slice.len) return null;

            const item = self.slice[self.pos];
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
    pub const Config = struct {
        const flags: []const []const u8 = &.{ "-c", "--config" };

        fn asFlag() Flag {
            return .{ .config = .{} };
        }

        fn handleArgs(
            self: @This(),
            allocator: std.mem.Allocator,
            opts: *Options,
            args_iter: *Iterator([]const u8),
            diag: ?*Diag,
        ) !void {
            _ = self;

            const cfg_path = args_iter.next() orelse {
                if (diag) |d| {
                    d.msg = "no config path provided after the -c/--config flag";
                }
                return error.MissingArgument;
            };

            if (isFlagArgument(cfg_path)) {
                if (diag) |d| {
                    try d.register(allocator, "illegal argument after the -c/--config flag: {s}", .{cfg_path});
                }
                return error.IllegalArgument;
            }

            opts.config_path = try allocator.dupe(u8, cfg_path);
        }
    };

    pub const Paths = struct {
        const flags: []const []const u8 = &.{ "-p", "--paths" };

        fn asFlag() Flag {
            return .{ .paths = .{} };
        }

        fn handleArgs(
            self: @This(),
            allocator: std.mem.Allocator,
            opts: *Options,
            args_iter: *Iterator([]const u8),
            diag: ?*Diag,
        ) !void {
            _ = self;

            var paths: std.ArrayListUnmanaged([]const u8) = .empty;
            defer paths.deinit(allocator);

            while (args_iter.peek()) |arg| {
                if (isFlagArgument(arg)) break;

                try paths.append(allocator, arg);
                _ = args_iter.next();
            }

            if (paths.items.len == 0) {
                if (diag) |d| {
                    d.msg = "no paths provided to the -p/--paths flag";
                }
                return error.MissingArgument;
            }

            opts.roots = try paths.toOwnedSlice(allocator);
        }
    };

    config: Config,
    paths: Paths,

    fn handleArgs(
        self: Flag,
        allocator: std.mem.Allocator,
        opts: *Options,
        args_iter: *Iterator([]const u8),
        diag: ?*Diag,
    ) !void {
        switch (self) {
            inline else => |f| return f.handleArgs(allocator, opts, args_iter, diag),
        }
    }

    fn fromArg(flag: []const u8) !Flag {
        inline for (@typeInfo(Flag).@"union".decls) |decl| {
            const flagType = @field(Flag, decl.name);
            if (contains(flag, flagType.flags)) {
                return flagType.asFlag();
            }
        }

        return error.IllegalArgument;
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8, diag: ?*Diag) !Options {
    var iter: Iterator([]const u8) = .init(args);

    var opts: Options = .empty;
    errdefer opts.deinit(allocator);

    // discard program name
    _ = iter.next();

    while (iter.next()) |arg| {
        const flag = Flag.fromArg(arg) catch |err| {
            if (diag) |d| {
                try d.register(allocator, "illegal argument: {s}", .{arg});
            }
            return err;
        };
        try flag.handleArgs(allocator, &opts, &iter, diag);
    }

    return opts;
}

fn contains(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |match| {
        if (std.mem.eql(u8, needle, match)) return true;
    }
    return false;
}

fn isFlagArgument(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
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

test "handle config" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{"/tmp/1"});

    try Flag.Config.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag);

    try std.testing.expectEqual(null, diag.msg);

    try std.testing.expectEqual(null, opts.roots);
    try std.testing.expectEqualStrings("/tmp/1", opts.config_path.?);
}

test "handle config no args" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .empty;

    try std.testing.expectError(
        error.MissingArgument,
        Flag.Config.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag),
    );

    try std.testing.expectEqualStrings(
        "no config path provided after the -c/--config flag",
        diag.msg.?,
    );
}

test "handle config path args" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{ "-p", "/tmp/1" });

    try std.testing.expectError(
        error.IllegalArgument,
        Flag.Config.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag),
    );

    try std.testing.expectEqualStrings(
        "illegal argument after the -c/--config flag: -p",
        diag.msg.?,
    );
}

test "handle paths" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{ "/tmp/1", "/tmp/2" });

    try Flag.Paths.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag);

    try std.testing.expectEqual(null, diag.msg);

    try std.testing.expectEqual(null, opts.config_path);
    try std.testing.expectEqual(2, opts.roots.?.len);
    try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
    try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
}

test "handle paths one arg" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{"/tmp/1"});

    try Flag.Paths.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag);

    try std.testing.expectEqual(null, diag.msg);

    try std.testing.expectEqual(null, opts.config_path);
    try std.testing.expectEqual(1, opts.roots.?.len);
    try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
}

test "handle paths with flag args" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{ "/tmp/1", "/tmp/2", "--config", "/tmp/3" });

    try Flag.Paths.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag);

    try std.testing.expectEqual(null, diag.msg);

    try std.testing.expectEqual(null, opts.config_path);
    try std.testing.expectEqual(2, opts.roots.?.len);
    try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
    try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
}

test "handle paths no args" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .empty;

    try std.testing.expectError(
        error.MissingArgument,
        Flag.Paths.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag),
    );

    try std.testing.expectEqualStrings(
        "no paths provided to the -p/--paths flag",
        diag.msg.?,
    );
}

test "handle paths no path args with flag arg" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{ "--config", "/tmp/3" });

    try std.testing.expectError(
        error.MissingArgument,
        Flag.Paths.asFlag().handleArgs(std.testing.allocator, &opts, &iter, &diag),
    );

    try std.testing.expectEqualStrings(
        "no paths provided to the -p/--paths flag",
        diag.msg.?,
    );
}

test parseArgs {
    // config and paths
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--config",
            "/tmp/1",
            "--paths",
            "/tmp/2",
            "/tmp/3",
        };

        var opts = try parseArgs(std.testing.allocator, args, &diag);
        defer opts.deinit(std.testing.allocator);

        try std.testing.expectEqual(null, diag.msg);

        try std.testing.expectEqualStrings("/tmp/1", opts.config_path.?);
        try std.testing.expectEqual(2, opts.roots.?.len);
        try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[0]);
        try std.testing.expectEqualStrings("/tmp/3", opts.roots.?[1]);
    }

    // paths and config
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "/tmp/2",
            "--config",
            "/tmp/3",
        };

        var opts = try parseArgs(std.testing.allocator, args, &diag);
        defer opts.deinit(std.testing.allocator);

        try std.testing.expectEqual(null, diag.msg);

        try std.testing.expectEqualStrings("/tmp/3", opts.config_path.?);
        try std.testing.expectEqual(2, opts.roots.?.len);
        try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
        try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
    }

    // config
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--config",
            "/tmp/1",
        };

        var opts = try parseArgs(std.testing.allocator, args, &diag);
        defer opts.deinit(std.testing.allocator);

        try std.testing.expectEqual(null, diag.msg);

        try std.testing.expectEqualStrings("/tmp/1", opts.config_path.?);
        try std.testing.expectEqual(null, opts.roots);
    }

    // paths
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "/tmp/2",
        };

        var opts = try parseArgs(std.testing.allocator, args, &diag);
        defer opts.deinit(std.testing.allocator);

        try std.testing.expectEqual(null, diag.msg);

        try std.testing.expectEqual(2, opts.roots.?.len);
        try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
        try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
        try std.testing.expectEqual(null, opts.config_path);
    }
}

test "parseArgs fails" {
    // no config, paths
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--config",
            "--paths",
            "/tmp/1",
            "/tmp/2",
        };

        try std.testing.expectError(
            error.IllegalArgument,
            parseArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "illegal argument after the -c/--config flag: --paths",
            diag.msg.?,
        );
    }

    // no paths, config
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "--config",
            "/tmp/1",
        };

        try std.testing.expectError(
            error.MissingArgument,
            parseArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "no paths provided to the -p/--paths flag",
            diag.msg.?,
        );
    }

    // paths, no config
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "/tmp/2",
            "--config",
        };

        try std.testing.expectError(
            error.MissingArgument,
            parseArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "no config path provided after the -c/--config flag",
            diag.msg.?,
        );
    }

    // config, no paths
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--config",
            "/tmp/1",
            "--paths",
        };

        try std.testing.expectError(
            error.MissingArgument,
            parseArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "no paths provided to the -p/--paths flag",
            diag.msg.?,
        );
    }

    // multiple config args
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--config",
            "/tmp/1",
            "/tmp/2",
        };

        try std.testing.expectError(
            error.IllegalArgument,
            parseArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "illegal argument: /tmp/2",
            diag.msg.?,
        );
    }

    // path args, multiple config args
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "--config",
            "/tmp/2",
            "/tmp/3",
        };

        try std.testing.expectError(
            error.IllegalArgument,
            parseArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "illegal argument: /tmp/3",
            diag.msg.?,
        );
    }
}
