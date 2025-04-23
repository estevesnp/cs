const std = @import("std");

const Config = struct {};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const dirs = try findGitProjects("/home/esteves/proj", allocator);

    for (dirs) |dir| {
        std.debug.print("{s}\n", .{dir});
        allocator.free(dir);
    }

    allocator.free(dirs);
}

fn findGitProjects(root_dir_path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    _ = &dirs;

    var root_dir = try std.fs.openDirAbsolute(root_dir_path, .{ .iterate = true });
    defer root_dir.close();

    try recurse(root_dir, 0, &dirs, allocator);

    return try dirs.toOwnedSlice(allocator);
}

fn recurse(dir: std.fs.Dir, depth: u8, dirs: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator) !void {
    if (depth >= 3) return;

    var iter = dir.iterate();
    while (try iter.next()) |next| {
        if (std.mem.eql(u8, ".git", next.name)) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = try dir.realpath(".", &buf);
            try dirs.append(allocator, try allocator.dupe(u8, full_path));
        }
        if (next.kind != .directory) continue;

        var n = try dir.openDir(next.name, .{ .iterate = true });
        defer n.close();

        try recurse(n, depth + 1, dirs, allocator);
    }
}
