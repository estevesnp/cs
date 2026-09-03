const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

const walk = @import("walk");

const appname = "cs-refactor";
const is_windows = builtin.os.tag == .windows;

pub const Action = enum {
    session,
    window,
    print,
};

pub const Config = struct {
    // maybe seperate from rest of struct?
    markers: []const []const u8,
    max_depth: usize,
    action: Action,
    preview: []const u8,

    pub const default: Config = .{
        .markers = walk.default_project_markers,
        .max_depth = walk.default_max_depth,
        .action = .session,
        .preview = if (is_windows) "dir {}" else "ls {}",
    };
};

pub const PartialConfig = Partial(Config);

pub const PartialConfigWithRoots = struct {
    config: PartialConfig,
    roots: []const []const u8,
};

fn Partial(T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => |e| @compileError("Partial(T) only accepts struct types, received " ++ @tagName(e)),
    };

    var field_types: [info.field_types.len]type = undefined;
    var field_attrs: [info.field_attrs.len]std.lang.Type.Struct.FieldAttributes = undefined;

    for (info.field_types, &field_types, &field_attrs) |FieldType, *new_type, *new_attr| {
        new_type.* = ?FieldType;

        const default_value: ?FieldType = null;
        new_attr.* = .{ .default_value_ptr = &default_value };
    }

    return @Struct(.auto, null, info.field_names, &field_types, &field_attrs);
}

pub fn normalizeConfig(partial_config: PartialConfig) Config {
    var config: Config = undefined;
    inline for (@typeInfo(PartialConfig).@"struct".field_names) |field|
        @field(config, field) = @field(partial_config, field) orelse @field(Config.default, field);
    return config;
}

pub fn configDir(io: Io, gpa: Allocator, environ_map: *const EnvironMap) !Io.Dir {
    const path = try configDirPath(gpa, environ_map);
    return Io.Dir.cwd().createDirPathOpen(io, path, .{});
}

pub fn configDirPath(gpa: Allocator, environ_map: *const EnvironMap) ![]const u8 {
    if (is_windows) {
        const appdata = environ_map.get("APPDATA") orelse return error.NoAppData;
        return try Io.Dir.path.join(gpa, &.{ appdata, appname });
    }

    if (environ_map.get("XDG_CONFIG_HOME")) |xdg_home| {
        return try Io.Dir.path.join(gpa, &.{ xdg_home, appname });
    }
    const home = environ_map.get("HOME") orelse return error.NoHome;
    return try Io.Dir.path.join(gpa, &.{ home, ".config", appname });
}

pub fn readConfig(io: Io, arena: Allocator, environ_map: *const EnvironMap) !PartialConfigWithRoots {
    var cfg_dir = try configDir(io, arena, environ_map);
    defer cfg_dir.close(io);

    const config = try parseFile(io, arena, PartialConfig, cfg_dir, "config.json");
    const roots = try parseFile(io, arena, []const []const u8, cfg_dir, "roots.json");

    return .{
        .config = config orelse .{},
        .roots = roots orelse &.{},
    };
}

fn parseFile(io: Io, arena: Allocator, T: type, dir: Io.Dir, filename: []const u8) !?T {
    const data = dir.readFileAlloc(io, filename, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return try std.json.parseFromSliceLeaky(T, arena, data, .{ .ignore_unknown_fields = true });
}
