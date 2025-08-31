const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const default_project_markers: []const []const u8 = &.{ ".git", ".jj" };

pub const SearchError = fs.File.OpenError || Allocator.Error || Writer.Error;

/// when to flush the writer
pub const FlushAfter = enum {
    /// never flush
    never,
    /// only flush at the end of the search
    end,
    /// flush after checking each root path
    root,
    /// flush after appending a project
    project,
};

pub const ScanOpts = struct {
    /// writer to report to
    writer: *Writer,
    /// when to flush the writer
    flush_after: FlushAfter = .root,
    /// max depth for searching for projects
    max_depth: usize = 5,
    /// marker to identify if a project exists
    project_markers: []const []const u8 = default_project_markers,
    /// byte for separating projects in writer
    separator_byte: u8 = '\n',
};

pub const SearchOpts = struct {
    /// optional writer to report to
    writer: ?*Writer = null,
    /// when to flush the writer (if it exists)
    flush_after: FlushAfter = .never,
    /// max depth for searching for projects
    max_depth: usize = 5,
    /// marker to identify if a project exists
    project_markers: []const []const u8 = default_project_markers,
    /// byte for separating projects in writer
    separator_byte: u8 = '\n',
};

const ContextOptions = union(enum) {
    search_opts: SearchOpts,
    scan_opts: ScanOpts,
};

const Context = struct {
    projects: std.StringArrayHashMapUnmanaged(void) = .empty,
    path_stack: ArrayList([]const u8) = .empty,
    /// the check stack never owns the strings
    to_check_stack: ArrayList([]const u8) = .empty,

    // config
    max_depth: usize,
    project_markers: []const []const u8,
    writer: ?*Writer,
    flush_after: FlushAfter,
    separator_byte: u8,

    fn init(ctx_opts: ContextOptions) Context {
        return switch (ctx_opts) {
            inline else => |opts| .{
                .max_depth = opts.max_depth,
                .writer = opts.writer,
                .project_markers = opts.project_markers,
                .flush_after = opts.flush_after,
                .separator_byte = opts.separator_byte,
            },
        };
    }

    fn initWithRoot(gpa: Allocator, root_path: []const u8, opts: ContextOptions) !Context {
        var ctx: Context = .init(opts);
        try ctx.path_stack.append(gpa, root_path);

        return ctx;
    }

    fn changeRoot(self: *Context, gpa: Allocator, root_path: []const u8) !void {
        // items in this stack are never owned
        self.path_stack.clearRetainingCapacity();

        for (self.to_check_stack.items) |field| {
            gpa.free(field);
        }
        self.to_check_stack.clearRetainingCapacity();

        try self.path_stack.append(gpa, root_path);
    }

    fn popToCheck(self: *Context, gpa: Allocator, items_to_pop: usize) void {
        for (0..items_to_pop) |_| {
            const field = self.to_check_stack.pop() orelse return;
            gpa.free(field);
        }
    }

    fn deinit(self: *Context, gpa: Allocator) void {
        // items in this stack are never owned
        self.path_stack.deinit(gpa);

        for (self.to_check_stack.items) |field| {
            gpa.free(field);
        }
        self.to_check_stack.deinit(gpa);

        for (self.projects.keys()) |key| {
            gpa.free(key);
        }
        self.projects.deinit(gpa);
    }
};

/// scan for projects and write their full path to provided writer.
/// return number of projects found
pub fn scanProjects(
    gpa: Allocator,
    root_paths: []const []const u8,
    opts: ScanOpts,
) SearchError!usize {
    var ctx = try search(gpa, root_paths, .{ .scan_opts = opts });
    defer ctx.deinit(gpa);

    return ctx.projects.count();
}

/// search for projects and return their full path as a set.
/// if no arena is used, caller must free the return object. check `freeProjects`
pub fn searchProjects(
    gpa: Allocator,
    root_paths: []const []const u8,
    opts: SearchOpts,
) SearchError!std.StringArrayHashMapUnmanaged(void) {
    var ctx = try search(gpa, root_paths, .{ .search_opts = opts });
    defer ctx.deinit(gpa);

    return ctx.projects.move();
}

/// frees the projects by freeing the keys and de-initing the backing map
pub fn freeProjects(gpa: Allocator, projects: *std.StringArrayHashMapUnmanaged(void)) void {
    for (projects.keys()) |proj| {
        gpa.free(proj);
    }
    projects.deinit(gpa);
}

fn search(gpa: Allocator, root_paths: []const []const u8, opts: ContextOptions) SearchError!Context {
    assert(root_paths.len > 0);

    var ctx: Context = .init(opts);

    for (root_paths) |root_path| {
        try ctx.changeRoot(gpa, root_path);

        var root_dir = try fs.openDirAbsolute(root_path, .{ .iterate = true });
        defer root_dir.close();

        try searchDir(gpa, &ctx, root_dir, 0);

        if (ctx.flush_after == .root) {
            if (ctx.writer) |w| try w.flush();
        }
    }

    if (ctx.flush_after == .end) {
        if (ctx.writer) |w| try w.flush();
    }

    return ctx;
}

fn searchDir(gpa: Allocator, ctx: *Context, dir: fs.Dir, depth: usize) SearchError!void {
    if (depth > ctx.max_depth) return;

    const to_check_start_idx = ctx.to_check_stack.items.len;

    var iter = dir.iterate();
    while (try iter.next()) |inner| {
        if (anyEql(ctx.project_markers, inner.name)) {
            const path_name = try fs.path.join(gpa, ctx.path_stack.items);

            const gop = try ctx.projects.getOrPut(gpa, path_name);

            // a key was already allocated, this one needs to be freed
            if (gop.found_existing) {
                gpa.free(path_name);
            } else {
                if (ctx.writer) |w| {
                    try w.writeAll(path_name);
                    try w.writeByte(ctx.separator_byte);

                    if (ctx.flush_after == .project) try w.flush();
                }
            }

            ctx.popToCheck(gpa, ctx.to_check_stack.items.len - to_check_start_idx);
            return;
        }

        if (inner.kind != .directory) continue;
        try ctx.to_check_stack.append(gpa, try gpa.dupe(u8, inner.name));
    }

    const end_idx = ctx.to_check_stack.items.len;
    defer ctx.popToCheck(gpa, end_idx - to_check_start_idx);

    for (to_check_start_idx..end_idx) |idx| {
        const to_check = ctx.to_check_stack.items[idx];

        try ctx.path_stack.append(gpa, to_check);
        defer _ = ctx.path_stack.pop();

        var dir_to_check = try dir.openDir(to_check, .{ .iterate = true });
        defer dir_to_check.close();

        try searchDir(gpa, ctx, dir_to_check, depth + 1);
    }
}

fn anyEql(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |str| {
        if (std.mem.eql(u8, str, needle)) return true;
    }
    return false;
}

test "searchProjects returns correct projects" {
    const gpa = testing.allocator;

    var tmp_dir_state = testing.tmpDir(.{});
    defer tmp_dir_state.cleanup();

    const tmp_dir = tmp_dir_state.dir;

    const base_path = try tmp_dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);

    try test_mountFilesystem(gpa, tmp_dir);

    try test_assertProjects(
        gpa,
        &.{
            &.{base_path},
        },
        &.{
            &.{ base_path, "root-1", "nest-1-1", "proj-1-1-1" },
            &.{ base_path, "root-1", "proj-1-1" },
            &.{ base_path, "root-1", "proj-1-2" },
            &.{ base_path, "root-2", "proj-2-1" },
            &.{ base_path, "root-3" },
        },
    );

    try test_assertProjects(
        gpa,
        &.{
            &.{base_path},
            &.{ base_path, "root-1" },
            &.{ base_path, "root-2" },
            &.{ base_path, "root-3" },
        },
        &.{
            &.{ base_path, "root-1", "nest-1-1", "proj-1-1-1" },
            &.{ base_path, "root-1", "proj-1-1" },
            &.{ base_path, "root-1", "proj-1-2" },
            &.{ base_path, "root-2", "proj-2-1" },
            &.{ base_path, "root-3" },
        },
    );

    try test_assertProjects(
        gpa,
        &.{
            &.{ base_path, "root-1" },
        },
        &.{
            &.{ base_path, "root-1", "nest-1-1", "proj-1-1-1" },
            &.{ base_path, "root-1", "proj-1-1" },
            &.{ base_path, "root-1", "proj-1-2" },
        },
    );

    try test_assertProjects(
        gpa,
        &.{
            &.{ base_path, "root-2" },
            &.{ base_path, "root-3" },
            &.{ base_path, "root-4" },
        },
        &.{
            &.{ base_path, "root-2", "proj-2-1" },
            &.{ base_path, "root-3" },
        },
    );

    try test_assertProjects(
        gpa,
        &.{
            &.{ base_path, "root-4" },
        },
        &.{},
    );

    try test_assertProjects(
        gpa,
        &.{
            &.{ base_path, "root-2" },
            &.{ base_path, "root-2" },
        },
        &.{
            &.{ base_path, "root-2", "proj-2-1" },
        },
    );
}

fn test_assertProjects(
    gpa: Allocator,
    root_paths: []const []const []const u8,
    expected_projects_paths: []const []const []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const roots = try arena.alloc([]const u8, root_paths.len);
    for (root_paths, roots) |path, *root| {
        root.* = try fs.path.join(arena, path);
    }

    const expected_projects = try arena.alloc([]const u8, expected_projects_paths.len);

    for (expected_projects_paths, expected_projects) |path, *proj| {
        proj.* = try fs.path.join(arena, path);
    }

    var alloc_writer = Writer.Allocating.init(arena);

    var project_set = try searchProjects(gpa, roots, .{
        .writer = &alloc_writer.writer,
        .flush_after = .end,
    });
    defer freeProjects(gpa, &project_set);

    const returned_projects = project_set.keys();

    var written_projects: [][]const u8 = try arena.alloc([]const u8, expected_projects.len);

    var iter = std.mem.splitScalar(u8, alloc_writer.written(), '\n');
    var idx: usize = 0;
    while (iter.next()) |proj| : (idx += 1) {
        if (idx >= returned_projects.len) {
            // should be the final project
            try testing.expectEqual(0, proj.len);
            try testing.expectEqual(null, iter.next());
            break;
        }
        written_projects[idx] = proj;
    }

    try testing.expectEqual(expected_projects.len, returned_projects.len);

    for (expected_projects) |expected| {
        if (!anyEql(returned_projects, expected)) {
            std.debug.print("expected '{s}' not found\n", .{expected});
            std.debug.print("actual returned projects:\n", .{});
            for (returned_projects) |p| std.debug.print("  '{s}'\n", .{p});
            return error.NoMatch;
        }
        if (!anyEql(written_projects, expected)) {
            std.debug.print("expected '{s}' not found\n", .{expected});
            std.debug.print("actual written projects:\n", .{});
            for (written_projects) |p| std.debug.print("  '{s}'\n", .{p});
            return error.NoMatch;
        }
    }
}

const TestFile = struct {
    name: []const u8,
    type: enum { file, directory },
    children: ?[]TestFile = null,
};

fn test_mountFilesystem(gpa: Allocator, root: fs.Dir) !void {
    // /
    // ├── root-1
    // │   ├── a-file.txt
    // │   ├── nest-1-1
    // │   │   ├── not-proj-1-1-1
    // │   │   │   └── documents.csv
    // │   │   └── proj-1-1-1
    // │   │       └── .git
    // │   ├── not-proj-1-1
    // │   │   └── empty
    // │   │       └── emptier
    // │   │           └── foo.txt
    // │   ├── proj-1-1
    // │   │   ├── .abc
    // │   │   ├── .git
    // │   │   └── text.txt
    // │   └── proj-1-2
    // │       ├── .jj
    // │       └── README.md
    // ├── root-2
    // │   └── proj-2-1
    // │       ├── .jj
    // │       └── src
    // │           └── main.c
    // ├── root-3
    // │   ├── .git
    // │   └── ziglab
    // │       └── .git
    // └── root-4
    //     ├── bar
    //     │   └── baz
    //     │       └── b.txt
    //     └── foo
    //         └── a.txt

    var tree_file = try fs.cwd().openFile("test/walk-tree.json", .{});
    defer tree_file.close();

    var buf: [4096]u8 = undefined;
    var file_br = tree_file.reader(&buf);
    var json_reader = std.json.Reader.init(gpa, &file_br.interface);
    defer json_reader.deinit();

    var rest = try std.json.parseFromTokenSource([]TestFile, gpa, &json_reader, .{});
    defer rest.deinit();

    for (rest.value) |info| {
        try test_createFilesystem(root, info);
    }
}

fn test_createFilesystem(parent: fs.Dir, info: TestFile) !void {
    if (info.type == .file) {
        var f = try parent.createFile(info.name, .{});
        f.close();
        return;
    }

    var next = try parent.makeOpenPath(info.name, .{});
    defer next.close();

    if (info.children) |children| {
        for (children) |dir| try test_createFilesystem(next, dir);
    }
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
