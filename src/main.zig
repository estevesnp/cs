const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const assert = std.debug.assert;

const log = std.log.scoped(.main);

const config = @import("config.zig");
const cli = @import("cli.zig");
const Diag = @import("Diag.zig");

const USAGE =
    \\usage: cs [project] [flags]
    \\
    \\arguments:
    \\
    \\  project                       project to automatically open if found
    \\
    \\
    \\flags:
    \\
    \\  -h, --help                    print this message
    \\  -v, -V, --version             print version
    \\  --env                         print config and environment information
    \\  -a, --add-paths <path> [...]  update config adding search paths
    \\  --no-preview                  disables fzf preview
    \\  --preview <str>               preview command to pass to fzf
    \\  --script  <str>               script to run on new tmux session
    \\  --action  <action>            action to execute after finding repository.
    \\                                  options: session, window, cd, print
    \\                                  can also call the action directly, e.g. --cd
    \\
    \\
    \\description:
    \\
    \\  search configured paths for git repositories and run an action on them,
    \\  such as creating a new tmux session or changing directory to the project
    \\
;

const Context = struct {
    arena_state: *std.heap.ArenaAllocator,
    env_map: *std.process.EnvMap,
    diag: *Diag,

    pub fn init(gpa: std.mem.Allocator, diag: *Diag) !Context {
        var arena_state = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_state);

        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();

        const arena = arena_state.allocator();

        const env_map = try arena.create(std.process.EnvMap);
        env_map.* = try std.process.getEnvMap(arena);

        return .{
            .arena_state = arena_state,
            .env_map = env_map,
            .diag = diag,
        };
    }

    pub fn deinit(self: *Context) void {
        const gpa = self.arena_state.child_allocator;

        self.env_map.deinit();
        self.arena_state.deinit();
        gpa.destroy(self.arena_state);
    }

    pub fn allocator(self: *Context) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var stderr_buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    var diag: Diag = .init(&stderr.interface);

    const command = try cli.parse(&diag, args);

    switch (command) {
        .help => try std.fs.File.stdout().writeAll(USAGE),
        .version => printAndExit("{f}\n", .{options.cs_version}),
        .env => log.info("env", .{}),
        .@"add-paths" => |paths| {
            var context: Context = try .init(gpa, &diag);
            defer context.deinit();

            try addPaths(&context, paths);
        },
        .search => |opts| {
            var context: Context = try .init(gpa, &diag);
            defer context.deinit();

            try search(&context, opts);
        },
    }
}

fn printAndExit(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var stdout_bw = std.fs.File.stdout().writer(&buf);
    const stdout_writer = &stdout_bw.interface;

    stdout_writer.print(fmt, args) catch {
        log.err("failed to  write to stdout\n", .{});
        std.process.exit(1);
    };

    stdout_writer.flush() catch {
        log.err("failed to flush stdout\n", .{});
        std.process.exit(1);
    };

    std.process.exit(0);
}

fn addPaths(ctx: *Context, paths: []const []const u8) !void {
    assert(paths.len > 0);

    const arena = ctx.allocator();

    var cfg_context = try config.openConfig(arena, ctx.env_map);
    defer cfg_context.deinit();

    var cfg = cfg_context.config;

    var path_set: std.StringArrayHashMapUnmanaged(void) = try .init(arena, cfg.roots, &.{});
    defer path_set.deinit(arena);

    const cwd = std.fs.cwd();
    for (paths) |path| {
        if (path.len == 0) continue;
        const real_path = try cwd.realpathAlloc(arena, path);
        try path_set.put(arena, real_path, {});
    }

    cfg.roots = path_set.keys();

    var cfg_file = cfg_context.config_file;

    try cfg_file.setEndPos(0);
    try cfg_file.seekTo(0);

    var buf: [1024]u8 = undefined;
    var file_bw = cfg_file.writer(&buf);

    const file_writer = &file_bw.interface;
    defer file_writer.flush() catch ctx.diag.reportUntagged("error saving config", .{});

    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, file_writer);
}

fn search(ctx: *Context, search_opts: cli.SearchOpts) !void {
    _ = search_opts;
    const arena = ctx.allocator();

    var cfg_context = try config.openConfig(arena, ctx.env_map);
    defer cfg_context.deinit();

    const cfg = cfg_context.config;

    if (cfg.roots.len == 0) {
        ctx.diag.reportUntagged("no project roots found. add one using the '--add-paths' flag", .{});
        std.process.exit(1);
    }
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
