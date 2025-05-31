const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Diag = @import("Diag.zig");

pub const NO_MATCH_EXIT_CODE: u8 = 1;
pub const INTERRUPT_EXIT_CODE: u8 = 130;

const ls_preview = "ls -lah --color=always {}";

pub fn runProcess(
    gpa: std.mem.Allocator,
    dirs: []const []const u8,
    preview_cmd: ?[]const u8,
    query: ?[]const u8,
    diag: ?*Diag,
) !?[]u8 {
    assert(dirs.len > 0);

    const args = [_][]const u8{
        "fzf",
        "--header=choose a repo",
        "--reverse",
        "--scheme=path",
        "--preview-label=[ repository files ]",
        "--preview",
        preview_cmd orelse ls_preview,
        "--query",
        query orelse "",
    };

    var fzf_process: std.process.Child = .init(&args, gpa);

    fzf_process.stdin_behavior = .Pipe;
    fzf_process.stdout_behavior = .Pipe;

    try fzf_process.spawn();

    var buf_writer = std.io.bufferedWriter(fzf_process.stdin.?.writer());
    const fzf_writer = buf_writer.writer();
    for (dirs) |dir| {
        try fzf_writer.writeAll(dir);
        try fzf_writer.writeByte('\n');
    }
    try buf_writer.flush();

    fzf_process.stdin.?.close();
    fzf_process.stdin = null;

    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var fixed_stream = std.io.fixedBufferStream(&buf);

    const reader = fzf_process.stdout.?.reader();

    reader.streamUntilDelimiter(fixed_stream.writer(), '\n', buf.len) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    const path = buf[0..fixed_stream.pos];

    return switch (try fzf_process.wait()) {
        .Exited => |exit_code| switch (exit_code) {
            0 => try gpa.dupe(u8, path),
            NO_MATCH_EXIT_CODE, INTERRUPT_EXIT_CODE => null,
            else => {
                if (diag) |d| d.report("fzf exited with error code {d}\n", .{exit_code});
                return error.NonZeroExitCode;
            },
        },
        else => |t| {
            if (diag) |d| d.report("fzf failed: {any}\n", .{t});
            return error.BadTermination;
        },
    };
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
