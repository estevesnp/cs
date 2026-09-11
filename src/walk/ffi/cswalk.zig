const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const log = std.log.scoped(.cs);

const walk = @import("walk");

const CStringArray = [*]const [*:0]const u8;

const CsSearchResult = extern struct {
    handle: ?*CsHandle,
    paths: CStringArray,
    count: u32,
    ok: bool,
};

const CsSearchOpts = extern struct {
    project_markers: ?CStringArray,
    markers_count: u32,
    max_depth: u32,
    enable_logging: bool,
};

const CsHandle = struct {
    arena: std.heap.ArenaAllocator,
};

const allocator = if (builtin.link_libc)
    std.heap.c_allocator
else if (!builtin.single_threaded)
    std.heap.smp_allocator
else
    std.heap.page_allocator;

export fn cs_search_projects(root_paths: ?CStringArray, root_count: u32, opts: CsSearchOpts) CsSearchResult {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    const arena = arena_state.allocator();

    var handle = arena.create(CsHandle) catch |err| {
        log.err("error creating handle: {t}", .{err});
        return failedResult(null);
    };
    handle.arena = arena_state;

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    return searchProjects(handle, io, root_paths, root_count, opts) catch |err| {
        log.err("error searching for projects: {t}", .{err});
        return failedResult(handle);
    };
}

export fn cs_free_projects(handle: ?*CsHandle) void {
    if (handle) |h| h.arena.deinit();
}

fn failedResult(handle: ?*CsHandle) CsSearchResult {
    return .{
        .handle = handle,
        .count = 0,
        .paths = &.{},
        .ok = false,
    };
}

fn searchProjects(
    handle: *CsHandle,
    io: Io,
    root_paths: ?CStringArray,
    root_count: u32,
    opts: CsSearchOpts,
) !CsSearchResult {
    const arena = handle.arena.allocator();

    const root_paths_bounded = try getBoundedCStringArray(arena, root_paths, root_count);
    const project_markers = try getBoundedCStringArray(arena, opts.project_markers, opts.markers_count);

    var project_set = try walk.searchProjects(arena, io, root_paths_bounded, .{
        .max_depth = opts.max_depth,
        .project_markers = project_markers,
        .reporter = if (opts.enable_logging) .stderr else .none,
    });

    const projects = project_set.keys();

    const paths = try arena.alloc([*:0]const u8, projects.len);
    for (projects, paths) |k, *p| p.* = k;

    return .{
        .handle = handle,
        .paths = paths.ptr,
        .count = @intCast(paths.len),
        .ok = true,
    };
}

fn getBoundedCStringArray(arena: std.mem.Allocator, arr: ?CStringArray, count: u32) ![]const [:0]const u8 {
    if (arr == null or count == 0) return &.{};

    const elems = try arena.alloc([:0]const u8, count);
    for (0..count) |idx| elems[idx] = std.mem.sliceTo(arr.?[idx], 0);

    return elems;
}
