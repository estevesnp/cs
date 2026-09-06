const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

const walk = @import("walk/lib.zig");

const appname = "cs-refactor";
const is_windows = builtin.os.tag == .windows;

pub const config_filename = "config.json";
pub const roots_filename = "roots.json";

pub const Env = enum {
    CS_CONFIG_PATH,
    CS_EDITOR,

    pub fn get(self: Env, env_map: *const EnvironMap) ?[]const u8 {
        if (env_map.get(@tagName(self))) |value| {
            if (value.len == 0) return null;
            return value;
        }
        return null;
    }
};

pub const Action = enum {
    session,
    window,
    print,
};

pub const EditMode = enum {
    config,
    roots,
    dir,
};

pub const Config = struct {
    markers: []const []const u8 = walk.default_project_markers,
    max_depth: usize = walk.default_max_depth,
    action: Action = .session,
    preview: []const u8 = if (is_windows) "dir {}" else "ls {}",
    edit_mode: EditMode = .config,
};

pub const ConfigWithRoots = struct {
    config: PartialConfig = .{},
    roots: []const []const u8 = &.{},
    path: []const u8,
};

pub const PartialConfig = Partial(Config);

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
    var config: Config = .{};
    inline for (@typeInfo(PartialConfig).@"struct".field_names) |field| {
        if (@field(partial_config, field)) |val| @field(config, field) = val;
    }
    return config;
}

pub fn configDirPath(gpa: Allocator, environ_map: *const EnvironMap) ![]const u8 {
    if (Env.CS_CONFIG_PATH.get(environ_map)) |cfg_path| {
        if (cfg_path.len > 0) return gpa.dupe(u8, cfg_path);
    }

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

// TODO - deal with bad json
pub fn readConfigWithRoots(io: Io, arena: Allocator, environ_map: *const EnvironMap) !ConfigWithRoots {
    const cfg_path = try configDirPath(arena, environ_map);
    var cfg_dir = Io.Dir.cwd().openDir(io, cfg_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = cfg_path },
        else => |e| return e,
    };
    defer cfg_dir.close(io);

    const config = try parseFile(io, arena, PartialConfig, cfg_dir, config_filename);
    const roots = try parseFile(io, arena, []const []const u8, cfg_dir, roots_filename);

    return .{
        .path = cfg_path,
        .config = config orelse .{},
        .roots = roots orelse &.{},
    };
}

pub fn readConfigFromDir(io: Io, arena: Allocator, dir: Io.Dir) !Config {
    return try parseFile(io, arena, Config, dir, config_filename) orelse .{};
}

pub fn readRootsFromDir(io: Io, arena: Allocator, dir: Io.Dir) ![]const []const u8 {
    return try parseFile(io, arena, []const []const u8, dir, roots_filename) orelse &.{};
}

fn parseFile(io: Io, arena: Allocator, T: type, dir: Io.Dir, filename: []const u8) !?T {
    const data = dir.readFileAlloc(io, filename, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return try std.json.parseFromSliceLeaky(T, arena, data, .{ .ignore_unknown_fields = true });
}

test {
    std.testing.refAllDecls(@This());
}
