const std = @import("std");
const Allocator = std.mem.Allocator;

const Walker = @import("Walker.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const root = "/home/esteves/proj";

    const allocator = gpa.allocator();

    var walker: Walker = .init(allocator, root);
    defer walker.deinit();

    const dirs = try walker.parseRoot();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (dirs) |dir| {
        try out.appendSlice(allocator, dir);
        try out.append(allocator, '\n');
    }

    try std.io.getStdOut().writeAll(out.items);
}
