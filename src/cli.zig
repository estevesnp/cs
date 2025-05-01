const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    config_path: ?[]const u8 = null,
    roots: ?[]const []const u8 = null,

    pub const empty: Options = .{ .config_path = null, .roots = null };

    pub const Error = Flag.Error;

    pub fn parseFromArgs(allocator: Allocator, args: []const []const u8, diag: ?*Diag) Error!Options {
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

    pub fn deinit(self: *Options, allocator: Allocator) void {
        if (self.config_path) |cfg| allocator.free(cfg);
        if (self.roots) |roots| {
            for (roots) |root| {
                allocator.free(root);
            }
            allocator.free(roots);
        }
    }
};

pub const Diag = struct {
    msg: ?[]const u8 = null,
    owns_mem: bool = false,

    pub const empty: Diag = .{ .msg = null, .owns_mem = false };

    pub fn register(
        self: *Diag,
        allocator: Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        self.msg = try std.fmt.allocPrint(allocator, fmt, args);
        self.owns_mem = true;
    }

    pub fn deinit(self: *Diag, allocator: Allocator) void {
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

        const empty: Self = .{ .slice = &.{} };

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
    const Error = error{
        RepeatedFlag,
        MissingArgument,
        IllegalArgument,
        OutOfMemory,
    };

    pub const Config = struct {
        const flags: []const []const u8 = &.{ "-c", "--config" };

        fn asFlag() Flag {
            return .{ .config = .{} };
        }

        fn handleArgs(
            self: @This(),
            allocator: Allocator,
            opts: *Options,
            args_iter: *Iterator([]const u8),
            diag: ?*Diag,
        ) Error!void {
            _ = self;

            if (opts.config_path != null) {
                if (diag) |d| {
                    d.msg = "the -c/--config flag is present more than once";
                }
                return Error.RepeatedFlag;
            }

            const cfg_path = args_iter.next() orelse {
                if (diag) |d| {
                    d.msg = "no config path provided after the -c/--config flag";
                }
                return Error.MissingArgument;
            };

            if (isFlagArgument(cfg_path)) {
                if (diag) |d| {
                    try d.register(allocator, "illegal argument after the -c/--config flag: {s}", .{cfg_path});
                }
                return Error.IllegalArgument;
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
            allocator: Allocator,
            opts: *Options,
            args_iter: *Iterator([]const u8),
            diag: ?*Diag,
        ) Error!void {
            _ = self;

            if (opts.roots != null) {
                if (diag) |d| {
                    d.msg = "the -p/--paths flag is present more than once";
                }
                return Error.RepeatedFlag;
            }

            var paths: std.ArrayListUnmanaged([]const u8) = .empty;
            defer paths.deinit(allocator);

            while (args_iter.peek()) |arg| {
                if (isFlagArgument(arg)) break;

                try paths.append(allocator, try allocator.dupe(u8, arg));
                _ = args_iter.next();
            }

            if (paths.items.len == 0) {
                if (diag) |d| {
                    d.msg = "no paths provided to the -p/--paths flag";
                }
                return Error.MissingArgument;
            }

            opts.roots = try paths.toOwnedSlice(allocator);
        }
    };

    config: Config,
    paths: Paths,

    fn handleArgs(
        self: Flag,
        allocator: Allocator,
        opts: *Options,
        args_iter: *Iterator([]const u8),
        diag: ?*Diag,
    ) Error!void {
        switch (self) {
            inline else => |f| return f.handleArgs(allocator, opts, args_iter, diag),
        }
    }

    fn fromArg(flag: []const u8) Error!Flag {
        inline for (@typeInfo(Flag).@"union".decls) |decl| {
            const flag_type = @field(Flag, decl.name);

            if (contains(flag, flag_type.flags)) {
                return flag_type.asFlag();
            }
        }

        return Error.IllegalArgument;
    }
};

fn contains(needle: []const u8, haystack: []const []const u8) bool {
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

test "Option.parseFromArgs" {
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

        var opts = try Options.parseFromArgs(std.testing.allocator, args, &diag);
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

        var opts = try Options.parseFromArgs(std.testing.allocator, args, &diag);
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

        var opts = try Options.parseFromArgs(std.testing.allocator, args, &diag);
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

        var opts = try Options.parseFromArgs(std.testing.allocator, args, &diag);
        defer opts.deinit(std.testing.allocator);

        try std.testing.expectEqual(null, diag.msg);

        try std.testing.expectEqual(2, opts.roots.?.len);
        try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
        try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
        try std.testing.expectEqual(null, opts.config_path);
    }
}

test "Option.parseFromArgs fails" {
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
            Options.parseFromArgs(std.testing.allocator, args, &diag),
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
            Options.parseFromArgs(std.testing.allocator, args, &diag),
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
            Options.parseFromArgs(std.testing.allocator, args, &diag),
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
            Options.parseFromArgs(std.testing.allocator, args, &diag),
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
            Options.parseFromArgs(std.testing.allocator, args, &diag),
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
            Options.parseFromArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "illegal argument: /tmp/3",
            diag.msg.?,
        );
    }

    // repeated config flag
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--config",
            "/tmp/1",
            "-c",
            "/tmp/2",
        };

        try std.testing.expectError(
            error.RepeatedFlag,
            Options.parseFromArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "the -c/--config flag is present more than once",
            diag.msg.?,
        );
    }

    // repeated paths flag
    {
        var diag: Diag = .empty;
        defer diag.deinit(std.testing.allocator);

        const args: []const []const u8 = &.{
            "cs",
            "--paths",
            "/tmp/1",
            "-p",
            "/tmp/2",
        };

        try std.testing.expectError(
            error.RepeatedFlag,
            Options.parseFromArgs(std.testing.allocator, args, &diag),
        );

        try std.testing.expectEqualStrings(
            "the -p/--paths flag is present more than once",
            diag.msg.?,
        );
    }
}

test "repeated flags" {
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
