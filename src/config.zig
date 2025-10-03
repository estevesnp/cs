const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const process = std.process;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");

const SearchAction = cli.SearchAction;

const default_fzf_preview = switch (builtin.os.tag) {
    // works in cmd and powershell
    .windows => "dir {}",
    else => "ls {}",
};

pub const Config = struct {
    /// directories to search for projects
    project_roots: []const []const u8 = &.{},
    /// fzf preview command. --no-preview sets this as an empty string
    preview: []const u8 = default_fzf_preview,
    /// action to take on project found
    action: SearchAction = .session,
};

pub const ConfigContext = struct {
    config_file: fs.File,
    config: Config,

    pub fn deinit(self: *ConfigContext) void {
        self.config_file.close();
    }
};

pub fn openConfig(arena: Allocator) !ConfigContext {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const config_path = try getConfigPath(&path_buf);

    return getConfigContext(arena, config_path);
}

fn getConfigContext(arena: Allocator, config_path: []const u8) !ConfigContext {
    var config_dir = try fs.cwd().makeOpenPath(config_path, .{});
    defer config_dir.close();

    var config_missing = false;
    var config_file = config_dir.openFile("config.json", .{ .mode = .read_write }) catch |err| blk: switch (err) {
        error.FileNotFound => {
            config_missing = true;
            break :blk try config_dir.createFile("config.json", .{});
        },
        else => return err,
    };

    if (config_missing) {
        return .{
            .config_file = config_file,
            .config = .{},
        };
    }

    var file_buf: [2048]u8 = undefined;
    var file_reader = config_file.reader(&file_buf);

    var json_reader = std.json.Reader.init(arena, &file_reader.interface);
    defer json_reader.deinit();

    const config = std.json.parseFromTokenSourceLeaky(Config, arena, &json_reader, .{}) catch |err| {
        if (err == error.UnexpectedEndOfInput and try config_file.getEndPos() == 0) {
            return .{
                .config_file = config_file,
                .config = .{},
            };
        }
        return err;
    };

    return .{
        .config_file = config_file,
        .config = config,
    };
}

fn getConfigPath(path_buf: []u8) ![]u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_home| {
        return try joinPaths(path_buf, &.{ xdg_home, "cs" });
    }
    return try joinPaths(path_buf, &.{ std.posix.getenv("HOME").?, ".config", "cs" });
}

pub fn updateConfig(cfg_file: fs.File, cfg: Config) !void {
    try cfg_file.setEndPos(0);
    try cfg_file.seekTo(0);

    var buf: [1024]u8 = undefined;
    var file_bw = cfg_file.writer(&buf);

    const file_writer = &file_bw.interface;

    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, file_writer);
    try file_writer.flush();
}

fn joinPaths(buf: []u8, sub_paths: []const []const u8) error{BufTooSmall}![]u8 {
    if (sub_paths.len == 0) return buf[0..0];

    // init with separators
    var total_needed: usize = sub_paths.len - 1;
    for (sub_paths) |sub_path| {
        total_needed += sub_path.len;
    }

    if (buf.len < total_needed) return error.BufTooSmall;

    var idx: usize = 0;

    for (sub_paths, 0..) |sub_path, sub_idx| {
        @memcpy(buf[idx..][0..sub_path.len], sub_path);
        idx += sub_path.len;

        if (sub_idx < sub_paths.len - 1) {
            buf[idx] = fs.path.sep;
            idx += 1;
        }
    }

    return buf[0..idx];
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test joinPaths {
    {
        var buf: [fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("abc/def/ghi", try joinPaths(&buf, &.{ "abc", "def", "ghi" }));
    }
    {
        var buf: [fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("abc/def", try joinPaths(&buf, &.{ "abc", "def" }));
    }
    {
        var buf: [fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("abc", try joinPaths(&buf, &.{"abc"}));
    }
    {
        var buf: [fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("", try joinPaths(&buf, &.{""}));
    }
    {
        var buf: [fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("/", try joinPaths(&buf, &.{ "", "" }));
    }

    {
        var buf: [6]u8 = undefined;
        try std.testing.expectError(error.BufTooSmall, joinPaths(&buf, &.{ "abc", "def" }));
    }
    {
        var buf: [0]u8 = undefined;
        try std.testing.expectError(error.BufTooSmall, joinPaths(&buf, &.{"a"}));
    }
}
