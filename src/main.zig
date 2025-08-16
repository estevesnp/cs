const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const cli = @import("cli.zig");
const Diag = @import("Diag.zig");

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

    const parsed = try cli.parse(&diag, args);

    printParsed(parsed);
}

fn printParsed(parsed: cli.Command) void {
    switch (parsed) {
        .add_paths => |paths| {
            std.debug.print("add paths: ", .{});
            for (paths) |path| {
                std.debug.print("{s} ", .{path});
            }
            std.debug.print("\n", .{});
        },
        .help => std.debug.print("help\n", .{}),
        .version => std.debug.print("version\n", .{}),
        .env => std.debug.print("env\n", .{}),
        .run => |r| {
            std.debug.print("run:\n", .{});
            std.debug.print("  project: {s}\n", .{r.project});
            std.debug.print("  preview: {s}\n", .{r.fzf_preview});
            std.debug.print("  script: {s}\n", .{r.tmux_session_script});
            std.debug.print("  action: {s}\n", .{@tagName(r.action)});
        },
    }
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
