const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const process = std.process;
const unicode = std.unicode;
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const cli = @import("cli.zig");
const walk = @import("walk.zig");
const SearchAction = cli.SearchAction;

const APP_NAME = "cs";
pub const CONFIG_FILE_NAME = "config.json";

const DEFAULT_FZF_PREVIEW = switch (builtin.os.tag) {
    // works in cmd and powershell
    .windows => "dir {}",
    else => "ls {}",
};

pub const Config = struct {
    /// directories to search for projects
    project_roots: []const []const u8 = &.{},
    /// files or dirs that mark a directory as a `project`
    project_markers: []const []const u8 = walk.default_project_markers,
    /// fzf preview command. --no-preview sets this as an empty string
    preview: []const u8 = DEFAULT_FZF_PREVIEW,
    /// action to take on project found
    action: SearchAction = .session,
};

pub const ConfigContext = struct {
    config_file: Io.File,
    config: Config,

    pub fn deinit(self: *ConfigContext, io: Io) void {
        self.config_file.close(io);
    }
};

pub const OpenConfigError = GetConfigDirPathError || GetConfigContextError;

/// gets the app's config path, then opens and deserializes it.
/// creates an empty config file if non exists.
pub fn openConfig(arena: Allocator, io: Io) OpenConfigError!ConfigContext {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try getConfigDirPath(&path_buf);

    return openConfigFromPath(arena, io, path);
}

const GetConfigContextError = Io.Dir.CreateDirError || Io.Dir.OpenError || Io.Dir.StatFileError || json.ParseError(json.Reader);

/// opens and deserializes config from the given path.
/// creates an empty config file if non exists.
pub fn openConfigFromPath(arena: Allocator, io: Io, config_path: []const u8) GetConfigContextError!ConfigContext {
    var config_dir = try Io.Dir.cwd().createDirPathOpen(io, config_path, .{});
    defer config_dir.close(io);

    var config_file = config_dir.openFile(io, CONFIG_FILE_NAME, .{ .mode = .read_write }) catch |err| switch (err) {
        // create file if none exists
        error.FileNotFound => return .{
            .config_file = try config_dir.createFile(io, CONFIG_FILE_NAME, .{}),
            .config = .{},
        },
        else => return err,
    };

    var file_buf: [2048]u8 = undefined;
    var file_reader = config_file.reader(io, &file_buf);

    var json_reader = json.Reader.init(arena, &file_reader.interface);
    defer json_reader.deinit();

    const config = json.parseFromTokenSourceLeaky(Config, arena, &json_reader, .{}) catch |err| {
        // don't fail if file is empty
        if (err == error.UnexpectedEndOfInput and try config_file.length(io) == 0) {
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

const GetConfigDirPathError = error{ BufTooSmall, HomeNotFound };

pub fn getConfigDirPath(path_buf: []u8) GetConfigDirPathError![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const key = unicode.wtf8ToWtf16LeStringLiteral("APPDATA");
            const appdata = process.getenvW(key) orelse return error.HomeNotFound;

            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const n = unicode.wtf16LeToWtf8(&buf, appdata);

            return try joinPaths(path_buf, &.{ buf[0..n], APP_NAME });
        },
        else => {
            if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_home| {
                return try joinPaths(path_buf, &.{ xdg_home, APP_NAME });
            }
            const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
            return try joinPaths(path_buf, &.{ home, ".config", APP_NAME });
        },
    }
}

pub fn updateConfig(io: Io, cfg_file: Io.File, cfg: Config) !void {
    try cfg_file.setLength(io, 0);

    var buf: [1024]u8 = undefined;
    var file_bw = cfg_file.writer(io, &buf);

    try file_bw.seekTo(0);

    const file_writer = &file_bw.interface;

    try json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, file_writer);
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
    testing.refAllDeclsRecursive(@This());
}

test joinPaths {
    {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings("abc/def/ghi", try joinPaths(&buf, &.{ "abc", "def", "ghi" }));
    }
    {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings("abc/def", try joinPaths(&buf, &.{ "abc", "def" }));
    }
    {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings("abc", try joinPaths(&buf, &.{"abc"}));
    }
    {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings("", try joinPaths(&buf, &.{""}));
    }
    {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        try testing.expectEqualStrings("/", try joinPaths(&buf, &.{ "", "" }));
    }

    {
        var buf: [6]u8 = undefined;
        try testing.expectError(error.BufTooSmall, joinPaths(&buf, &.{ "abc", "def" }));
    }
    {
        var buf: [0]u8 = undefined;
        try testing.expectError(error.BufTooSmall, joinPaths(&buf, &.{"a"}));
    }
}
