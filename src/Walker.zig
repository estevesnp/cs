const std = @import("std");
const Allocator = std.mem.Allocator;

const Walker = @This();

arena: std.heap.ArenaAllocator,
roots: []const []const u8,
max_depth: usize,

git_projects: std.ArrayListUnmanaged([]const u8) = .empty,
path_stack: std.ArrayListUnmanaged([]const u8) = .empty,
to_check_stack: std.ArrayListUnmanaged([]const u8) = .empty,

pub fn init(allocator: Allocator, roots: []const []const u8, max_depth: ?usize) Walker {
    return .{
        .roots = roots,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .max_depth = max_depth orelse 10,
    };
}

pub fn deinit(self: *Walker) void {
    self.arena.deinit();
}

pub fn parseRoots(self: *Walker) ![]const []const u8 {
    for (self.roots) |root| {
        if (!std.fs.path.isAbsolute(root)) return error.InvalidPath;

        try self.path_stack.append(self.arena.allocator(), root);
        defer self.path_stack.clearRetainingCapacity();

        var root_dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
        defer root_dir.close();

        try self.recurse(root_dir, 0);
    }

    return self.git_projects.items;
}

fn recurse(self: *Walker, dir: std.fs.Dir, depth: usize) !void {
    if (depth >= self.max_depth) return;
    const allocator = self.arena.allocator();

    const init_len = self.to_check_stack.items.len;
    defer self.to_check_stack.items.len = init_len;

    var iter = dir.iterate();
    while (try iter.next()) |next| {
        if (std.mem.eql(u8, next.name, ".git")) {
            try self.git_projects.append(allocator, try std.fs.path.join(allocator, self.path_stack.items));
            return;
        }

        if (next.kind != .directory) continue;
        try self.to_check_stack.append(allocator, try allocator.dupe(u8, next.name));
    }

    for (init_len..self.to_check_stack.items.len) |idx| {
        const path_to_check = self.to_check_stack.items[idx];
        var dir_to_check = try dir.openDir(path_to_check, .{ .iterate = true });
        defer dir_to_check.close();

        try self.path_stack.append(allocator, path_to_check);
        try self.recurse(dir_to_check, depth + 1);
        self.path_stack.items.len -= 1;
    }
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test "parseRoots" {
    const allocator = std.testing.allocator;

    var root_1 = std.testing.tmpDir(.{ .iterate = true });
    defer root_1.cleanup();

    const root_1_path = try root_1.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_1_path);

    var root_2 = std.testing.tmpDir(.{ .iterate = true });
    defer root_2.cleanup();

    const root_2_path = try root_2.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_2_path);

    try test_setupDirs(root_1.dir);
    try test_setupDirs(root_2.dir);

    var walker: Walker = .init(allocator, &.{ root_1_path, root_2_path }, null);
    defer walker.deinit();

    const git_paths = try walker.parseRoots();

    try std.testing.expectEqual(8, git_paths.len);

    const expected_paths: []const []const u8 = &.{
        "git-1",
        &test_join(&.{ "git-2", "nested" }),
        &test_join(&.{ "git-3", "nested", "nesteder" }),
        &test_join(&.{ "git-double", "nested" }),
    };

    for (@as([]const []const u8, &.{ root_1_path, root_2_path })) |path| {
        outer: for (expected_paths) |expected_path| {
            const full_path = try std.fs.path.join(allocator, &.{ path, expected_path });
            defer allocator.free(full_path);

            for (git_paths) |git_path| {
                if (std.mem.eql(u8, git_path, full_path)) continue :outer;
            }
            return error.NotFound;
        }
    }
}

fn test_join(comptime path_parts: []const []const u8) [test_getLen(path_parts)]u8 {
    if (path_parts.len < 2) {
        @compileError("join needs more than one path part");
    }

    var res: [test_getLen(path_parts)]u8 = undefined;
    var slice: []u8 = &res;

    var idx: usize = 0;
    for (path_parts) |part| {
        defer idx += 1;
        @memcpy(slice[0..part.len], part);
        slice = slice[part.len..];

        if (idx != path_parts.len - 1) {
            slice[0] = std.fs.path.sep;
            slice = slice[1..];
        }
    }

    return res;
}

fn test_getLen(pp: []const []const u8) usize {
    var count: usize = pp.len - 1;
    for (pp) |p| {
        count += p.len;
    }
    return count;
}

fn test_setupDirs(dir: std.fs.Dir) !void {
    {
        try dir.makeDir("git-1");
        var git = try dir.openDir("git-1", .{});
        defer git.close();

        var dot_git = try git.createFile(".git", .{});
        dot_git.close();
    }

    {
        try dir.makeDir("git-2");
        var git = try dir.openDir("git-2", .{});
        defer git.close();

        try git.makeDir("foo");
        try git.makeDir("bar");
        try git.makeDir(".cache");
        var cenas = try git.createFile("cenas.txt", .{});
        cenas.close();

        try git.makeDir("nested");
        var nested = try git.openDir("nested", .{});
        defer nested.close();

        try nested.makeDir("foo");
        try nested.makeDir("bar");
        try nested.makeDir(".cache");

        try nested.makeDir(".git");
    }

    {
        try dir.makeDir("git-3");
        var git = try dir.openDir("git-3", .{});
        defer git.close();

        try git.makeDir("foo");
        try git.makeDir("bar");
        try git.makeDir(".cache");
        var cenas = try git.createFile("cenas.txt", .{});
        cenas.close();

        try git.makeDir("nested");
        var nested = try git.openDir("nested", .{});
        defer nested.close();

        try nested.makeDir("foo");
        try nested.makeDir("bar");
        try nested.makeDir(".cache");

        try nested.makeDir("nesteder");
        var nesteder = try nested.openDir("nesteder", .{});
        defer nesteder.close();

        try nesteder.makeDir("foo");
        try nesteder.makeDir("bar");
        try nesteder.makeDir(".cache");

        try nesteder.makeDir(".git");
    }

    {
        try dir.makeDir("git-double");
        var git = try dir.openDir("git-double", .{});
        defer git.close();

        try git.makeDir("foo");
        try git.makeDir("bar");
        try git.makeDir(".cache");
        var cenas = try git.createFile("cenas.txt", .{});
        cenas.close();

        try git.makeDir("nested");
        var nested = try git.openDir("nested", .{});
        defer nested.close();

        try nested.makeDir("foo");
        try nested.makeDir("bar");
        try nested.makeDir(".git");

        try nested.makeDir("nesteder");
        var nesteder = try nested.openDir("nesteder", .{});
        defer nesteder.close();

        try nesteder.makeDir("foo");
        try nesteder.makeDir("bar");
        try nesteder.makeDir(".cache");

        try nesteder.makeDir(".git");
    }

    {
        try dir.makeDir("not-1");
        var git = try dir.openDir("not-1", .{});
        defer git.close();

        var not_git = try git.createFile(".notgit", .{});
        not_git.close();
    }

    {
        try dir.makeDir("not-2");
        var not = try dir.openDir("not-2", .{});
        defer not.close();

        try not.makeDir("foo");
        try not.makeDir("bar");
        try not.makeDir(".cache");
        var cenas = try not.createFile("cenas.txt", .{});
        cenas.close();

        try not.makeDir("nested");
        var nested = try not.openDir("nested", .{});
        defer nested.close();

        try nested.makeDir("foo");
        try nested.makeDir("bar");
        try nested.makeDir(".cache");
    }

    {
        try dir.makeDir("not-3");
        var not = try dir.openDir("not-3", .{});
        defer not.close();

        try not.makeDir("foo");
        try not.makeDir("bar");
        try not.makeDir(".cache");
        var cenas = try not.createFile("cenas.txt", .{});
        cenas.close();

        try not.makeDir("nested");
        var nested = try not.openDir("nested", .{});
        defer nested.close();

        try nested.makeDir("foo");
        try nested.makeDir("bar");
        try nested.makeDir(".cache");

        try nested.makeDir("nesteder");
        var nesteder = try nested.openDir("nesteder", .{});
        defer nesteder.close();

        try nesteder.makeDir("foo");
        try nesteder.makeDir("bar");
        try nesteder.makeDir(".cache");
    }
}
