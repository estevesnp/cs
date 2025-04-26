const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const config = @import("config.zig");
const Config = config.Config;
const Walker = @import("Walker.zig");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const cfg_path = try config.getConfigPath(allocator);
    defer allocator.free(cfg_path);

    const cfg = try parseConfig(allocator, cfg_path);
    defer cfg.deinit();

    try run(allocator, cfg.value);
}

fn parseConfig(allocator: Allocator, cfg_path: []const u8) !json.Parsed(Config) {
    var cfg_file = std.fs.openFileAbsolute(cfg_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("config file not found. please create one at {s}\n", .{cfg_path});
            std.process.exit(1);
        },
        else => return err,
    };

    defer cfg_file.close();

    const file_size = try cfg_file.getEndPos();
    const file_buf = try allocator.alloc(u8, file_size);
    defer allocator.free(file_buf);

    _ = try cfg_file.readAll(file_buf);

    return try json.parseFromSlice(Config, allocator, file_buf, .{ .allocate = .alloc_always });
}

fn run(allocator: Allocator, cfg: Config) !void {
    var walker: Walker = .init(allocator, cfg.roots);
    defer walker.deinit();

    const dirs = try walker.parseRoots();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (dirs) |dir| {
        try out.appendSlice(allocator, dir);
        try out.append(allocator, '\n');
    }

    try stdout.writeAll(out.items);
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
