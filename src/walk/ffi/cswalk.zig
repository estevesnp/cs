const std = @import("std");
const Io = std.Io;

const walk = @import("walk");

const CStringArray = [*]const [*:0]const u8;

const CsSearchResult = extern struct {
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

export fn cs_search_projects(root_paths: ?CStringArray, root_count: u32, opts: CsSearchOpts) CsSearchResult {
    const gpa = std.heap.smp_allocator;

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var stderr_buf: [128]u8 = undefined;
    const locked = if (opts.enable_logging) io.lockStderr(&stderr_buf, null) catch null else null;
    defer if (locked != null) io.unlockStderr();
    const stderr = if (locked) |l| &l.file_writer.interface else null;

    return searchProjects(gpa, io, stderr, root_paths, root_count, opts) catch .{
        .count = 0,
        .paths = &.{},
        .ok = false,
    };
}

export fn cs_free_projects(projects: ?CStringArray, count: u32) void {
    if (projects == null or count == 0) return;
    const gpa = std.heap.smp_allocator;

    const allocated_projects = projects.?[0..count];
    for (allocated_projects) |proj| gpa.free(std.mem.sliceTo(proj, 0));
    gpa.free(allocated_projects);
}

fn searchProjects(
    gpa: std.mem.Allocator,
    io: Io,
    stderr: ?*Io.Writer,
    root_paths: ?CStringArray,
    root_count: u32,
    opts: CsSearchOpts,
) !CsSearchResult {
    const root_paths_bounded = try getBoundedCStringArray(gpa, root_paths, root_count);
    defer gpa.free(root_paths_bounded);

    const project_markers = try getBoundedCStringArray(gpa, opts.project_markers, opts.markers_count);
    defer gpa.free(project_markers);

    var project_set = try walk.searchProjects(gpa, io, root_paths_bounded, .{
        .max_depth = opts.max_depth,
        .project_markers = project_markers,
        .reporter = stderr,
    });
    defer project_set.deinit(gpa);

    const projects = project_set.keys();

    const paths = try gpa.alloc([*:0]const u8, projects.len);
    for (projects, paths) |k, *p| p.* = k;

    return .{
        .count = @intCast(paths.len),
        .paths = paths.ptr,
        .ok = true,
    };
}

fn getBoundedCStringArray(gpa: std.mem.Allocator, arr: ?CStringArray, count: u32) ![]const [:0]const u8 {
    if (arr == null or count == 0) return &.{};

    const elems = try gpa.alloc([:0]const u8, count);
    for (0..count) |idx| elems[idx] = std.mem.sliceTo(arr.?[idx], 0);

    return elems;
}
