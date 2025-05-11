const std = @import("std");
const builtin = @import("builtin");

pub const NO_MATCH_EXIT_CODE: u8 = 1;
pub const INTERRUPT_EXIT_CODE: u8 = 130;

const ls_preview = "ls -lah --color=always {}";
const eza_preview = "eza -la --color=always {}";
const cmd_preview = "cmd /C \"dir /a {}\"";

pub fn runProcess(gpa: std.mem.Allocator, dirs: []const []const u8, preview_cmd: ?[]const u8) !?[]u8 {
    const prev_cmd = preview_cmd orelse getDefaultPreviewCommand();

    const args = [_][]const u8{
        "fzf",
        "--header=choose a repo",
        "--reverse",
        "--scheme=path",
        "--preview-label=[ repository files ]",
        "--preview",
        prev_cmd,
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

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fixed_stream = std.io.fixedBufferStream(&buf);

    const reader = fzf_process.stdout.?.reader();

    try reader.streamUntilDelimiter(fixed_stream.writer(), '\n', buf.len);
    const path = buf[0..fixed_stream.pos];

    const term = try fzf_process.wait();

    return switch (term) {
        .Exited => |error_code| switch (error_code) {
            0 => try gpa.dupe(u8, path),
            NO_MATCH_EXIT_CODE, INTERRUPT_EXIT_CODE => null,
            else => error.NonZeroExitCode,
        },
        else => return error.BadTermination,
    };
}

fn getDefaultPreviewCommand() []const u8 {
    return switch (builtin.os.tag) {
        .windows => cmd_preview,
        else => ls_preview,
    };
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
