const std = @import("std");
const json = std.json;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const os_tag = builtin.os.tag;

pub const Config = struct {
    roots: []const []const u8,
};

const stderr = std.io.getStdErr().writer();

const APP_CFG_DIR = "cs";
const APP_CFG_FILE = "config.json";

pub fn parseConfig(allocator: Allocator, cfg_file: std.fs.File) !json.Parsed(Config) {
    var json_reader = json.reader(allocator, cfg_file.reader());
    defer json_reader.deinit();

    return json.parseFromTokenSource(Config, allocator, &json_reader, .{ .allocate = .alloc_always });
}

pub fn getDefaultConfigPath(allocator: Allocator) ![]const u8 {
    return switch (os_tag) {
        .windows => getDefaultConfigPathWindows(allocator),
        else => getDefaultConfigPathPosix(allocator),
    };
}

fn getDefaultConfigPathPosix(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, APP_CFG_DIR, APP_CFG_FILE });
    }

    const base_path = std.posix.getenv("HOME") orelse unreachable;
    return std.fs.path.join(allocator, &.{ base_path, ".config", APP_CFG_DIR, APP_CFG_FILE });
}

fn getDefaultConfigPathWindows(allocator: Allocator) ![]const u8 {
    const appdata = std.process.getenvW("APPDATA");
    return std.fs.path.join(allocator, &.{ appdata, APP_CFG_DIR, APP_CFG_FILE });
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
