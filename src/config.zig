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
pub const CONFIG_PATH_ENV = "CS_CONFIG_PATH";

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
    config_path: []const u8,

    pub fn deinit(self: *ConfigContext, gpa: Allocator, io: Io) void {
        gpa.free(self.config_path);
        self.config_file.close(io);
    }
};

pub const OpenConfigError = GetConfigDirPathError || GetConfigContextError;

/// gets the app's config path, then opens and deserializes it.
/// creates an empty config file if non exists.
pub fn openConfig(gpa: Allocator, io: Io, environ_map: *const process.Environ.Map) OpenConfigError!ConfigContext {
    const path = try getConfigDirPath(gpa, environ_map);
    errdefer gpa.free(path);

    return openConfigFromPath(gpa, io, path);
}

const GetConfigContextError = Io.Dir.CreateDirError || Io.Dir.OpenError || Io.Dir.StatFileError || json.ParseError(json.Reader);

/// opens and deserializes config from the given path.
/// creates an empty config file if non exists.
pub fn openConfigFromPath(gpa: Allocator, io: Io, config_path: []const u8) GetConfigContextError!ConfigContext {
    var config_dir = try Io.Dir.cwd().createDirPathOpen(io, config_path, .{});
    defer config_dir.close(io);

    var config_file = config_dir.openFile(io, CONFIG_FILE_NAME, .{ .mode = .read_write }) catch |err| switch (err) {
        // create file if none exists
        error.FileNotFound => return .{
            .config_file = try config_dir.createFile(io, CONFIG_FILE_NAME, .{}),
            .config = .{},
            .config_path = config_path,
        },
        else => return err,
    };

    var file_buf: [2048]u8 = undefined;
    var file_reader = config_file.reader(io, &file_buf);

    var json_reader = json.Reader.init(gpa, &file_reader.interface);
    defer json_reader.deinit();

    const config = json.parseFromTokenSourceLeaky(Config, gpa, &json_reader, .{}) catch |err| {
        // don't fail if file is empty
        if (err == error.UnexpectedEndOfInput and try config_file.length(io) == 0) {
            return .{
                .config_file = config_file,
                .config = .{},
                .config_path = config_path,
            };
        }
        return err;
    };

    return .{
        .config_file = config_file,
        .config = config,
        .config_path = config_path,
    };
}

const GetConfigDirPathError = error{ OutOfMemory, HomeNotFound };

pub fn getConfigDirPath(gpa: Allocator, environ_map: *const process.Environ.Map) GetConfigDirPathError![]u8 {
    if (environ_map.get(CONFIG_PATH_ENV)) |cfg_path| {
        if (cfg_path.len > 0) {
            return gpa.dupe(u8, cfg_path);
        }
    }

    switch (builtin.os.tag) {
        .windows => {
            const appdata = environ_map.get("APPDATA") orelse return error.HomeNotFound;
            return Io.Dir.path.join(gpa, &.{ appdata, APP_NAME });
        },
        else => {
            if (environ_map.get("XDG_CONFIG_HOME")) |xdg_home| {
                return Io.Dir.path.join(gpa, &.{ xdg_home, APP_NAME });
            }
            const home = environ_map.get("HOME") orelse return error.HomeNotFound;
            return Io.Dir.path.join(gpa, &.{ home, ".config", APP_NAME });
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

test "ref all decls" {
    testing.refAllDecls(@This());
}
