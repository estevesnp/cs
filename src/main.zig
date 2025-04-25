const std = @import("std");
const Allocator = std.mem.Allocator;

const Walker = @import("Walker.zig");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    try run(gpa.allocator(), "/home/esteves/proj");
}

fn run(allocator: Allocator, root: []const u8) !void {
    var walker: Walker = .init(allocator, root);
    defer walker.deinit();

    const dirs = walker.parseRoot() catch |err| {
        switch (err) {
            error.FileNotFound => {
                try stderr.print("source dir not found: {s}\n", .{root});
                std.process.exit(1);
            },
            else => return err,
        }
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (dirs) |dir| {
        try out.appendSlice(allocator, dir);
        try out.append(allocator, '\n');
    }

    try stdout.writeAll(out.items);
}
