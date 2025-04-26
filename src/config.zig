const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub const Config = struct {
    roots: []const []const u8,
};

const os_tag = builtin.os.tag;
const APP_CFG_DIR = "cs";
const APP_CFG_FILE = "config.json";

pub fn getConfigPath(allocator: Allocator) ![]const u8 {
    return switch (os_tag) {
        .windows => getConfigPathWindows(allocator),
        else => getConfigPathPosix(allocator),
    };
}

fn getConfigPathPosix(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, APP_CFG_DIR, APP_CFG_FILE });
    }

    const base_path = std.posix.getenv("HOME") orelse unreachable;
    return std.fs.path.join(allocator, &.{ base_path, ".config", APP_CFG_DIR, APP_CFG_FILE });
}

fn getConfigPathWindows(allocator: Allocator) ![]const u8 {
    const appdata = std.process.getenvW("APPDATA");
    return std.fs.path.join(allocator, &.{ appdata, APP_CFG_DIR, APP_CFG_FILE });
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
