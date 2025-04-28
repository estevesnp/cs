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
    };
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8, diag: ?*Diag) !Options {
    var iter: Iterator([]const u8) = .init(args);

    var opts: Options = .empty;
    errdefer opts.deinit(allocator);

    _ = iter.next();

    while (iter.next()) |arg| {
        var found_flag = false;

        if (isPathsFlag(arg)) {
            try handlePaths(allocator, &opts, &iter, diag);
            found_flag = true;
        }

        if (isConfigFlag(arg)) {
            try handleConfig(allocator, &opts, &iter, diag);
            found_flag = true;
        }

        if (found_flag) continue;

        if (diag) |d| {
            try d.register(allocator, "illegal argument: {s}", .{arg});
        }
        return error.IllegalArgument;
    }

    return opts;
}

fn handlePaths(
    allocator: std.mem.Allocator,
    opts: *Options,
    args_iter: *Iterator([]const u8),
    diag: ?*Diag,
) !void {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);

    while (args_iter.next()) |inner_arg| {
        if (isConfigFlag(inner_arg)) {
            try handleConfig(allocator, opts, args_iter, diag);
            break;
        }

        try paths.append(allocator, inner_arg);
    }

    if (paths.items.len == 0) {
        if (diag) |d| {
            d.msg = "no paths provided to the -p/--prefix flag";
        }
        return error.MissingArgument;
    }

    opts.roots = try paths.toOwnedSlice(allocator);
}

fn handleConfig(
    allocator: std.mem.Allocator,
    opts: *Options,
    args_iter: *Iterator([]const u8),
    diag: ?*Diag,
) !void {
    const cfg_path = args_iter.next() orelse {
        if (diag) |d| {
            d.msg = "no config path provided after the -c/--config flag";
        }
        return error.MissingArgument;
    };

    opts.config_path = try allocator.dupe(u8, cfg_path);
}

fn isPathsFlag(arg: []const u8) bool {
    return contains(arg, &.{ "-p", "--path" });
}

fn isConfigFlag(arg: []const u8) bool {
    return contains(arg, &.{ "-c", "--config" });
}

fn contains(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |match| {
        if (std.mem.eql(u8, needle, match)) return true;
    }
    return false;
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test Iterator {
    {
        var iter = Iterator(u8).init(&.{ 1, 2, 3 });

        try std.testing.expectEqual(iter.next(), 1);
        try std.testing.expectEqual(iter.next(), 2);
        try std.testing.expectEqual(iter.next(), 3);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }

    {
        var iter = Iterator(u8).init(&.{1});

        try std.testing.expectEqual(iter.next(), 1);
        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }

    {
        var iter = Iterator(u8).init(&.{});

        try std.testing.expectEqual(iter.next(), null);
        try std.testing.expectEqual(iter.next(), null);
    }
}

test handleConfig {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{"/tmp/1"});

    try handleConfig(std.testing.allocator, &opts, &iter, &diag);

    try std.testing.expectEqual(null, diag.msg);

    try std.testing.expectEqual(null, opts.roots);
    try std.testing.expectEqualStrings("/tmp/1", opts.config_path.?);
}

test "handleConfig no args" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .empty;

    try std.testing.expectError(
        error.MissingArgument,
        handleConfig(std.testing.allocator, &opts, &iter, &diag),
    );

    try std.testing.expectEqualStrings(
        "no config path provided after the -c/--config flag",
        diag.msg.?,
    );
}

test handlePaths {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .init(&.{ "/tmp/1", "/tmp/2" });

    try handlePaths(std.testing.allocator, &opts, &iter, &diag);

    try std.testing.expectEqual(null, diag.msg);

    try std.testing.expectEqual(null, opts.config_path);
    try std.testing.expectEqual(2, opts.roots.?.len);
    try std.testing.expectEqualStrings("/tmp/1", opts.roots.?[0]);
    try std.testing.expectEqualStrings("/tmp/2", opts.roots.?[1]);
}

test "handlePaths no args" {
    var opts: Options = .empty;
    defer opts.deinit(std.testing.allocator);

    var diag: Diag = .empty;
    defer diag.deinit(std.testing.allocator);

    var iter: Iterator([]const u8) = .empty;

    try std.testing.expectError(
        error.MissingArgument,
        handlePaths(std.testing.allocator, &opts, &iter, &diag),
    );

    try std.testing.expectEqualStrings(
        "no paths provided to the -p/--prefix flag",
        diag.msg.?,
    );
}
