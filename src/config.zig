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

    pub const Context = struct {
        pub fn hash(_: @This(), s: Source) u32 {
            return std.array_hash_map.hashString(s.root);
        }

        pub fn eql(_: @This(), a: Source, b: Source, _: usize) bool {
            return std.array_hash_map.eqlString(a.root, b.root);
        }
    };
};

/// config
pub const Config = struct {
    pub const empty: Config = .{ .sources = &.{}, .preview_cmd = null };

    /// sources to search for repos
    sources: []Source,

    /// optional preview command provided to fzf
    preview_cmd: ?[]const u8 = null,
};

pub const APP_CFG_DIR = "cs";
pub const APP_CFG_FILE = "config.json";

pub fn createOrOpen() !std.fs.File {
    const cfg_paths = getConfigDirParts();

    var base_dir = try std.fs.openDirAbsolute(cfg_paths.base_path, .{ .iterate = true });
    defer base_dir.close();

    var cfg_dir = try base_dir.makeOpenPath(cfg_paths.sub_path, .{});
    defer cfg_dir.close();

    return cfg_dir.createFile(APP_CFG_FILE, .{ .read = true, .truncate = false });
}

pub fn getConfigPath(gpa: Allocator) ![]const u8 {
    const parts = getConfigDirParts();
    return std.fs.path.join(gpa, &.{ parts.base_path, parts.sub_path, APP_CFG_FILE });
}

const CfgPath = struct {
    base_path: []const u8,
    sub_path: []const u8,
};

fn getConfigDirParts() CfgPath {
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

pub fn getAndTruncateConfig(arena: *std.heap.ArenaAllocator) !struct { std.fs.File, Config } {
    const gpa = arena.allocator();
    var cfg_file = try createOrOpen();

    if (try cfg_file.getEndPos() == 0) return .{ cfg_file, .empty };

    var json_reader = std.json.reader(gpa, cfg_file.reader());
    defer json_reader.deinit();

    const cfg = std.json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{}) catch
        return error.ParsingConfig;

    try cfg_file.setEndPos(0);
    try cfg_file.seekTo(0);

    return .{ cfg_file, cfg };
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
