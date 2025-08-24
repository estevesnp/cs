const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// TODO: do we want to accept this as an argument? or have it per path?
const max_depth = 5;

const Context = struct {
    // TODO: change to set
    projects: ArrayList([]const u8) = .empty,
    path_stack: ArrayList([]const u8) = .empty,
    to_check_stack: ArrayList([]const u8) = .empty,

    fn init(gpa: Allocator, root_path: []const u8) !Context {
        var ctx: Context = .{};
        try ctx.path_stack.append(gpa, root_path);
        return ctx;
    }

    fn popToCheck(self: *Context, gpa: Allocator, items_to_pop: usize) void {
        for (0..items_to_pop) |_| {
            const field = self.to_check_stack.pop() orelse return;
            gpa.free(field);
        }
    }

    fn deinit(self: *Context, gpa: Allocator) void {
        // items in this stack are never owned
        self.path_stack.deinit(gpa);

        for (self.to_check_stack.items) |field| {
            gpa.free(field);
        }
        self.to_check_stack.deinit(gpa);

        for (self.projects.items) |field| {
            gpa.free(field);
        }
        self.projects.deinit(gpa);
    }
};

// TODO:
// - change to accept writer (would allow to write to FZF immediately)
//   - would need to check the project set before writing
// - accept multiple root_paths
pub fn search(gpa: Allocator, root_path: []const u8) !void {
    var root_dir = try fs.openDirAbsolute(root_path, .{ .iterate = true });
    defer root_dir.close();

    var ctx: Context = try .init(gpa, root_path);

    try searchDir(gpa, &ctx, root_dir, 0);

    for (ctx.projects.items) |proj| {
        std.debug.print("found {s}\n", .{proj});
    }
}

fn searchDir(gpa: Allocator, ctx: *Context, dir: fs.Dir, depth: usize) !void {
    if (depth > max_depth) return;

    const to_check_start_idx = ctx.to_check_stack.items.len;

    var iter = dir.iterate();
    while (try iter.next()) |inner| {
        if (std.mem.eql(u8, inner.name, ".git")) {
            const path_name = try fs.path.join(gpa, ctx.path_stack.items);
            try ctx.projects.append(gpa, path_name);
            ctx.popToCheck(gpa, ctx.to_check_stack.items.len - to_check_start_idx);
            return;
        }

        if (inner.kind != .directory) continue;
        try ctx.to_check_stack.append(gpa, try gpa.dupe(u8, inner.name));
    }

    const end_idx = ctx.to_check_stack.items.len;
    defer ctx.popToCheck(gpa, end_idx - to_check_start_idx);

    for (to_check_start_idx..end_idx) |idx| {
        const to_check = ctx.to_check_stack.items[idx];

        try ctx.path_stack.append(gpa, to_check);
        defer _ = ctx.path_stack.pop();

        var dir_to_check = try dir.openDir(to_check, .{ .iterate = true });
        defer dir_to_check.close();

        try searchDir(gpa, ctx, dir_to_check, depth + 1);
    }
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
