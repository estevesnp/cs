const std = @import("std");
const builtin = @import("builtin");

const json = std.json;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cli = @import("cli.zig");
const Options = cli.Options;

const os_tag = builtin.os.tag;

pub const Config = struct {
    const empty: Config = .{ .roots = &.{} };

    roots: []const []const u8,
};

const APP_CFG_DIR = "cs";
const APP_CFG_FILE = "config.json";

pub fn createOrOpen() !std.fs.File {
    const base_path, const sub_path = switch (os_tag) {
        .windows => .{ std.process.getenvW("APPDATA").?, APP_CFG_DIR },
        else => blk: {
            if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
                break :blk .{ xdg, APP_CFG_DIR };
            }
            break :blk .{ std.posix.getenv("HOME").?, ".config/" ++ APP_CFG_DIR };
        },
    };

    var base_dir = try std.fs.openDirAbsolute(base_path, .{ .iterate = true });
    defer base_dir.close();

    var cfg_dir = try base_dir.makeOpenPath(sub_path, .{});
    defer cfg_dir.close();

    return cfg_dir.createFile(APP_CFG_FILE, .{ .read = true, .truncate = false });
}

pub fn updateConfig(arena: *std.heap.ArenaAllocator, cfg_file: std.fs.File, roots: []const []const u8) !Config {
    const gpa = arena.allocator();

    var cfg: Config = blk: {
        if (try cfg_file.getEndPos() == 0) break :blk .empty;

        var json_reader = json.reader(gpa, cfg_file.reader());
        defer json_reader.deinit();
        const c = try json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{});

        try cfg_file.setEndPos(0);
        try cfg_file.seekTo(0);

        break :blk c;
    };

    cfg.roots = roots;

    try json.stringify(cfg, .{ .whitespace = .indent_2 }, cfg_file.writer());

    return cfg;
}

pub fn openConfig(arena: *std.heap.ArenaAllocator, cfg_file: std.fs.File) !Config {
    const gpa = arena.allocator();

    var json_reader = json.reader(gpa, cfg_file.reader());
    defer json_reader.deinit();
    return try json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{});
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
