const std = @import("std");
const Io = std.Io;

const walk = @import("walk");

const StringArray = ?[*:null]const ?[*:0]const u8;

const SearchResult = extern struct {
    paths: StringArray,
    count: u32,
    ok: bool,
};

const SearchOpts = extern struct {
    project_markers: StringArray,
    max_depth: u32,
    enable_logging: bool,
};

export fn search_projects(root_paths: StringArray, opts: SearchOpts) SearchResult {
    const gpa = std.heap.c_allocator;

    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var stderr_buf: [128]u8 = undefined;
    const locked = if (opts.enable_logging) io.lockStderr(&stderr_buf, null) catch null else null;
    defer if (locked != null) io.unlockStderr();
    const stderr = if (locked) |l| &l.file_writer.interface else null;

    return searchProjectsNullStrings(gpa, io, stderr, root_paths, opts) catch .{
        .count = 0,
        .paths = &.{},
        .ok = false,
    };
}

export fn free_projects(projects: StringArray) void {
    if (projects == null) return;
    const gpa = std.heap.c_allocator;

    const arr_sent_idx = std.mem.findSentinel(?[*:0]const u8, null, projects.?);

    for (0..arr_sent_idx) |idx| {
        const c_str = projects.?[idx].?;
        const str_sent_idx = std.mem.findSentinel(u8, 0, c_str);
        gpa.free(c_str[0..str_sent_idx :0]);
    }
}

fn searchProjectsNullStrings(
    gpa: std.mem.Allocator,
    io: Io,
    stderr: ?*Io.Writer,
    root_paths: StringArray,
    opts: SearchOpts,
) !SearchResult {
    const root_paths_bounded = try getBoundedCStringArray(gpa, root_paths);
    defer gpa.free(root_paths_bounded);

    const project_markers = try getBoundedCStringArray(gpa, opts.project_markers);
    defer gpa.free(project_markers);

    var project_set = try walk.searchProjects(gpa, io, root_paths_bounded, .{
        .max_depth = opts.max_depth,
        .project_markers = project_markers,
        .reporter = stderr,
    });
    defer project_set.deinit(gpa);

    const projects = project_set.keys();

    const paths = try gpa.allocSentinel(?[*:0]const u8, projects.len, null);
    for (projects, paths) |k, *p| p.* = k;

    return .{
        .count = @intCast(paths.len),
        .paths = paths,
        .ok = true,
    };
}

fn getBoundedCStringArray(gpa: std.mem.Allocator, arr: StringArray) ![]const [:0]const u8 {
    if (arr == null) return &.{};

    const arr_sent_idx = std.mem.findSentinel(?[*:0]const u8, null, arr.?);

    const elems = try gpa.alloc([:0]const u8, arr_sent_idx);
    for (0..arr_sent_idx) |idx| {
        const c_str = arr.?[idx].?;
        const str_sent_idx = std.mem.findSentinel(u8, 0, c_str);
        elems[idx] = c_str[0..str_sent_idx :0];
    }

    return elems;
}
