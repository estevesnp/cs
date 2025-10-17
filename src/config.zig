const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const process = std.process;
const unicode = std.unicode;
const json = std.json;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const SearchAction = cli.SearchAction;

const APP_NAME = "cs";
const CONFIG_FILE_NAME = "config.json";

const DEFAULT_FZF_PREVIEW = switch (builtin.os.tag) {
    // works in cmd and powershell
    .windows => "dir {}",
    else => "ls {}",
};

pub const Config = struct {
    /// directories to search for projects
    project_roots: []const []const u8 = &.{},
    /// fzf preview command. --no-preview sets this as an empty string
    preview: []const u8 = DEFAULT_FZF_PREVIEW,
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

pub const OpenConfigError = GetConfigPathError || GetConfigContextError;

pub const OpenConfigOpts = struct {
    config_path_buf: ?[]u8 = null,
};

/// opens and deserializes the app's config file.
/// accepts an optional buffer that gets filled with the config path.
/// memsets the buffer to 0 and asserts that it is big enough for the path.
/// asserts that the buffer is big enough for the path and memsets it to 0.
pub fn openConfig(arena: Allocator, opts: OpenConfigOpts) OpenConfigError!ConfigContext {
    if (opts.config_path_buf) |path_buf| {
        return openConfigWithBuf(arena, path_buf);
    }

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    return openConfigWithBuf(arena, &path_buf);
}

fn openConfigWithBuf(arena: Allocator, path_buf: []u8) OpenConfigError!ConfigContext {
    const config_path = try getConfigPath(path_buf);
    return getConfigContext(arena, config_path);
}

const GetConfigContextError = fs.Dir.MakeError || fs.Dir.OpenError || fs.Dir.StatFileError || json.ParseError(json.Reader);

fn getConfigContext(arena: Allocator, config_path: []const u8) GetConfigContextError!ConfigContext {
    var config_dir = try fs.cwd().makeOpenPath(config_path, .{});
    defer config_dir.close();

    var config_file = config_dir.openFile(CONFIG_FILE_NAME, .{ .mode = .read_write }) catch |err| switch (err) {
        // create file if none exists
        error.FileNotFound => return .{
            .config_file = try config_dir.createFile(CONFIG_FILE_NAME, .{}),
            .config = .{},
        },
        else => return err,
    };

    var file_buf: [2048]u8 = undefined;
    var file_reader = config_file.reader(&file_buf);

    var json_reader = json.Reader.init(arena, &file_reader.interface);
    defer json_reader.deinit();

    const config = json.parseFromTokenSourceLeaky(Config, arena, &json_reader, .{}) catch |err| {
        // don't fail if file is empty
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

const GetConfigPathError = error{ BufTooSmall, HomeNotFound };

fn getConfigPath(path_buf: []u8) GetConfigPathError![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const key = unicode.wtf8ToWtf16LeStringLiteral("APPDATA");
            const appdata = process.getenvW(key) orelse return error.HomeNotFound;

            var buf: [fs.max_path_bytes]u8 = undefined;
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

pub fn updateConfig(cfg_file: fs.File, cfg: Config) !void {
    try cfg_file.setEndPos(0);
    try cfg_file.seekTo(0);

    var buf: [1024]u8 = undefined;
    var file_bw = cfg_file.writer(&buf);

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

    const path = buf[0..idx];

    // set the rest of the buffer to 0
    if (path.len < buf.len) {
        @memset(buf[path.len..buf.len], 0);
    }

    return path;
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test joinPaths {
    {
        var buf: [fs.max_path_bytes]u8 = undefined;
        const expected = "abc/def/ghi";
        try std.testing.expectEqualStrings(expected, try joinPaths(&buf, &.{ "abc", "def", "ghi" }));
        try std.testing.expectStringStartsWith(&buf, expected);
        for (buf[expected.len..]) |char| {
            try std.testing.expectEqual(0, char);
        }
    }
    {
        const expected = "abc/def";
        var buf: [expected.len]u8 = undefined;
        try std.testing.expectEqualStrings(expected, try joinPaths(&buf, &.{ "abc", "def" }));
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
