const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub const default_project_markers: []const []const u8 = &.{ ".git", ".jj" };

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

pub const SearchOpts = struct {
    /// optional writer to write paths to
    writer: ?*Writer = null,
    /// optional writer to report to
    reporter: ?*Writer = null,
    /// when to flush the writer (if it exists)
    flush_after: FlushAfter = .never,
    /// max depth for searching for projects
    max_depth: usize = 5,
    /// marker to identify if a project exists
    project_markers: []const []const u8 = default_project_markers,
    /// byte for separating projects in writer
    separator_byte: u8 = '\n',
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
    reporter: ?*Writer,
    flush_after: FlushAfter,
    separator_byte: u8,

    fn init(opts: SearchOpts) Context {
        return .{
            .max_depth = opts.max_depth,
            .writer = opts.writer,
            .reporter = opts.reporter,
            .project_markers = if (opts.project_markers.len == 0) default_project_markers else opts.project_markers,
            .flush_after = opts.flush_after,
            .separator_byte = opts.separator_byte,
        };
    }

    fn initWithRoot(gpa: Allocator, root_path: []const u8, opts: SearchOpts) !Context {
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

    fn report(self: *Context, comptime fmt: []const u8, args: anytype) void {
        if (self.reporter) |reporter| {
            reporter.print(fmt ++ "\n", args) catch {};
            reporter.flush() catch {};
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

/// search for projects and return their full path as a set.
/// if no arena is used, caller must free the return object. check `freeProjects`
pub fn searchProjects(
    gpa: Allocator,
    root_paths: []const []const u8,
    opts: SearchOpts,
) SearchError!std.StringArrayHashMapUnmanaged(void) {
    var ctx = try search(gpa, root_paths, opts);
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

fn search(gpa: Allocator, root_paths: []const []const u8, opts: SearchOpts) SearchError!Context {
    assert(root_paths.len > 0);

    var ctx: Context = .init(opts);
    errdefer ctx.deinit(gpa);

    for (root_paths) |root_path| {
        var root_dir = fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                ctx.report("root {s} not found, skipping", .{root_path});
                continue;
            },
            else => |e| return e,
        };
        defer root_dir.close();

        try ctx.changeRoot(gpa, root_path);
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
            errdefer gpa.free(path_name);

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

        const dir_name = try gpa.dupe(u8, inner.name);
        errdefer gpa.free(dir_name);

        try ctx.to_check_stack.append(gpa, dir_name);
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

    try test_mountNestedTree(tmp_dir);

    try test_assertProjects(
        gpa,
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
        gpa,
        &.{
            &.{ base_path, "root-4" },
        },
        &.{},
    );

    try test_assertProjects(
        gpa,
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

test "searchProjects doesn't leak memory on nested tree" {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    const gpa = debug_allocator.allocator();

    var tmp_dir_state = testing.tmpDir(.{});
    defer tmp_dir_state.cleanup();

    const tmp_dir = tmp_dir_state.dir;

    const base_path = try tmp_dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);

    try test_mountNestedTree(tmp_dir);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        test_assertProjects,
        .{
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
        },
    );
}

test "searchProjects doesn't leak memory on file only filetree" {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    const gpa = debug_allocator.allocator();

    var tmp_dir_state = testing.tmpDir(.{});
    defer tmp_dir_state.cleanup();

    const tmp_dir = tmp_dir_state.dir;

    const base_path = try tmp_dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);

    try test_mountFilesOnlyTree(tmp_dir);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        test_assertProjects,
        .{
            gpa,
            &.{
                &.{base_path},
            },
            &.{},
        },
    );
}

test "searchProjects reports properly on non-existing roots" {
    const gpa = testing.allocator;

    var tmp_dir_state = testing.tmpDir(.{});
    defer tmp_dir_state.cleanup();

    const tmp_dir = tmp_dir_state.dir;

    const base_path = try tmp_dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);

    try test_mountNestedTree(tmp_dir);

    const root_paths: []const []const u8 = &.{
        try fs.path.join(gpa, &.{ base_path, "root-2" }),
        try fs.path.join(gpa, &.{ base_path, "root-4" }),
        try fs.path.join(gpa, &.{ base_path, "non-existing-dir" }),
    };
    defer for (root_paths) |p| gpa.free(p);

    const expected_repo = try fs.path.join(gpa, &.{ base_path, "root-2", "proj-2-1" });
    defer gpa.free(expected_repo);

    const expected_reported_message = try std.fmt.allocPrint(
        gpa,
        "root {s} not found, skipping\n",
        .{root_paths[2]},
    );
    defer gpa.free(expected_reported_message);

    var allocating_writer: Writer.Allocating = .init(gpa);
    defer allocating_writer.deinit();

    var projects = try searchProjects(gpa, root_paths, .{ .reporter = &allocating_writer.writer });
    defer freeProjects(gpa, &projects);

    try testing.expectEqual(1, projects.count());
    try testing.expectEqualStrings(expected_repo, projects.keys()[0]);
    try testing.expectEqualStrings(expected_reported_message, allocating_writer.written());
}

fn test_assertProjects(
    testing_allocator: Allocator,
    util_allocator: Allocator,
    root_paths: []const []const []const u8,
    expected_projects_paths: []const []const []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(util_allocator);
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

    var alloc_writer: Writer.Allocating = .init(arena);

    var project_set = try searchProjects(testing_allocator, roots, .{
        .writer = &alloc_writer.writer,
        .flush_after = .end,
    });
    defer freeProjects(testing_allocator, &project_set);

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
    try testing.expectEqual(expected_projects.len, written_projects.len);

    var returned_not_found = false;
    var written_not_found = false;
    for (expected_projects) |expected| {
        if (!anyEql(returned_projects, expected)) {
            returned_not_found = true;
            std.debug.print("expected returned '{s}' not found\n", .{expected});
        }
        if (!anyEql(written_projects, expected)) {
            written_not_found = true;
            std.debug.print("expected written '{s}' not found\n", .{expected});
        }
    }

    if (returned_not_found) {
        std.debug.print("actual returned projects:\n", .{});
        for (returned_projects) |p| std.debug.print("  '{s}'\n", .{p});
    }

    if (written_not_found) {
        std.debug.print("actual written projects:\n", .{});
        for (written_projects) |p| std.debug.print("  '{s}'\n", .{p});
    }

    if (returned_not_found or written_not_found) return error.NoMatch;
}

const WalkTest = struct {
    const Node = struct {
        name: []const u8,
        type: enum { file, directory },
        children: ?[]const Node = null,
    };

    fn file(name: []const u8) Node {
        return .{ .name = name, .type = .file };
    }

    fn dir(name: []const u8, children: []const Node) Node {
        return .{
            .name = name,
            .type = .directory,
            .children = children,
        };
    }
};

fn test_mountNestedTree(root: fs.Dir) !void {
    const w = WalkTest;
    const tree: []const WalkTest.Node = &.{
        w.dir("root-1", &.{
            w.file("a-file.txt"),
            w.dir("nest-1-1", &.{
                w.dir("not-proj-1-1-1", &.{
                    w.file("documents.csv"),
                }),
                w.dir("proj-1-1-1", &.{ // root
                    w.dir(".git", &.{}),
                }),
            }),
            w.dir("not-proj-1-1", &.{
                w.dir("empty", &.{
                    w.dir("emptier", &.{
                        w.file("foo.txt"),
                    }),
                }),
            }),
            w.dir("proj-1-1", &.{ // root
                w.file(".abc"),
                w.dir(".git", &.{}),
                w.file("text.txt"),
            }),
            w.dir("proj-1-2", &.{ // root
                w.file(".jj"),
                w.file("README.md"),
            }),
        }),
        w.dir("root-2", &.{
            w.dir("proj-2-1", &.{ // root
                w.file(".jj"),
                w.dir("src", &.{
                    w.file("main.c"),
                }),
            }),
        }),
        w.dir("root-3", &.{
            w.dir(".git", &.{}),
            w.dir("ziglab", &.{ // root
                w.dir(".git", &.{}),
            }),
        }),
        w.dir("root-4", &.{
            w.dir("bar", &.{
                w.dir("baz", &.{
                    w.file("b.txt"),
                }),
            }),
            w.dir("foo", &.{
                w.file("a.txt"),
            }),
        }),
    };

    try test_mountFilesystem(root, tree);
}

fn test_mountFilesOnlyTree(root: fs.Dir) !void {
    const w = WalkTest;
    const tree: []const WalkTest.Node = &.{
        w.file("foo"),
        w.file("bar"),
        w.file("bar"),
    };

    try test_mountFilesystem(root, tree);
}

fn test_mountFilesystem(root: fs.Dir, tree: []const WalkTest.Node) !void {
    for (tree) |node| {
        try test_createFilesystem(root, node);
    }
}

fn test_createFilesystem(parent: fs.Dir, node: WalkTest.Node) !void {
    if (node.type == .file) {
        var f = try parent.createFile(node.name, .{});
        f.close();
        return;
    }

    var next = try parent.makeOpenPath(node.name, .{});
    defer next.close();

    if (node.children) |children| {
        for (children) |dir| try test_createFilesystem(next, dir);
    }
}

test "ref all decls" {
    testing.refAllDeclsRecursive(@This());
}
