const std = @import("std");
const builtin = @import("builtin");

const json = std.json;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cli = @import("cli.zig");
const Options = cli.Options;

const os_tag = builtin.os.tag;

/// source to search for repos
pub const Source = struct {
    /// path to start search
    root: []const u8,

    /// max depth to search for repos. defaults to 10
    depth: usize = 10,
};

/// config
pub const Config = struct {
    pub const empty: Config = .{ .sources = &.{}, .preview_cmd = null };

    /// sources to search for repos
    sources: []Source,

    /// optional preview command provided to fzf
    preview_cmd: ?[]const u8 = null,
};

const APP_CFG_DIR = "cs";
const APP_CFG_FILE = "config.json";

pub fn createOrOpen() !std.fs.File {
    const cfg_paths = getConfigPaths();

    var base_dir = try std.fs.openDirAbsolute(cfg_paths.base_path, .{ .iterate = true });
    defer base_dir.close();

    var cfg_dir = try base_dir.makeOpenPath(cfg_paths.sub_path, .{});
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

    const new_roots = try gpa.alloc([]const u8, roots.len);

    var cwd: ?std.fs.Dir = null;

    for (roots, 0..) |r, idx| {
        if (std.fs.path.isAbsolute(r)) {
            new_roots[idx] = r;
            continue;
        }

        if (cwd == null) cwd = std.fs.cwd();
        new_roots[idx] = try cwd.?.realpathAlloc(gpa, r);
    }

    cfg.sources = &.{};

    try json.stringify(cfg, .{ .whitespace = .indent_2 }, cfg_file.writer());

    return cfg;
}

pub fn openConfig(arena: *std.heap.ArenaAllocator, cfg_file: std.fs.File) !Config {
    const gpa = arena.allocator();

    var json_reader = json.reader(gpa, cfg_file.reader());
    defer json_reader.deinit();
    return try json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{});
}

const CfgPath = struct {
    base_path: []const u8,
    sub_path: []const u8,
};

pub fn getConfigPaths() CfgPath {
    if (os_tag == .windows) return .{
        .base_path = std.process.getenvW("APPDATA").?,
        .sub_path = APP_CFG_DIR,
    };

    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| return .{
        .base_path = xdg,
        .sub_path = APP_CFG_DIR,
    };

    return .{
        .base_path = std.posix.getenv("HOME").?,
        .sub_path = ".config/" ++ APP_CFG_DIR,
    };
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
