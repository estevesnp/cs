const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

const walk = @import("walk/lib.zig");

const appname = "cs-refactor";
const is_windows = builtin.os.tag == .windows;

pub const Env = enum {
    CS_CONFIG_PATH,

    pub fn get(self: Env, env_map: *const EnvironMap) ?[]const u8 {
        return env_map.get(@tagName(self));
    }
};

pub const Action = enum {
    session,
    window,
    print,
};

pub const Config = struct {
    markers: []const []const u8 = walk.default_project_markers,
    max_depth: usize = walk.default_max_depth,
    action: Action = .session,
    preview: []const u8 = if (is_windows) "dir {}" else "ls {}",
};

pub const ConfigWithRoots = struct {
    config: Config,
    roots: []const []const u8,

    pub const default: ConfigWithRoots = .{
        .config = .{},
        .roots = &.{},
    };
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

fn normalizeConfig(partial_config: PartialConfig) Config {
    var config: Config = undefined;
    inline for (@typeInfo(PartialConfig).@"struct".field_names) |field|
        @field(config, field) = @field(partial_config, field) orelse @field(Config.default, field);
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

pub fn readConfig(io: Io, arena: Allocator, environ_map: *const EnvironMap) !ConfigWithRoots {
    const cfg_path = try configDirPath(arena, environ_map);
    var cfg_dir = Io.Dir.cwd().openDir(io, cfg_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .default,
        else => |e| return e,
    };
    defer cfg_dir.close(io);

    const config = try parseFile(io, arena, Config, cfg_dir, "config.json");
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

test {
    std.testing.refAllDecls(@This());
}
