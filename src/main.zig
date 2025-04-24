const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = struct {};

const Walker = struct {
    root: []const u8,
    max_depth: usize = 5,
    git_projects: std.ArrayListUnmanaged([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, root: []const u8) Walker {
        return .{
            .root = root,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Walker) void {
        self.arena.deinit();
    }

    pub fn parseRoot(self: *Walker) ![]const []const u8 {
        var root_dir = try std.fs.openDirAbsolute(self.root, .{ .iterate = true });
        defer root_dir.close();

        try self.recurse(root_dir, 0);

        return self.git_projects.items;
    }

    fn recurse(self: *Walker, dir: std.fs.Dir, depth: usize) !void {
        if (depth >= self.max_depth) return;
        const allocator = self.arena.allocator();

        var iter = dir.iterate();
        while (try iter.next()) |next| {
            if (std.mem.eql(u8, next.name, ".git")) {
                try self.git_projects.append(allocator, try dir.realpathAlloc(allocator, "."));
                return;
            }

            if (next.kind != .directory) continue;

            var new = try dir.openDir(next.name, .{ .iterate = true });
            defer new.close();

            try self.recurse(new, depth + 1);
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const root = "/home/esteves/proj";

    const allocator = gpa.allocator();

    var walker: Walker = .init(allocator, root);
    defer walker.deinit();

    const dirs = try walker.parseRoot();

    for (dirs) |dir| {
        std.debug.print("{s}\n", .{dir});
    }
}
