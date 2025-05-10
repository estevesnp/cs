const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const os_tag = builtin.os.tag;

pub const NO_MATCH_EXIT_CODE: u8 = 1;
pub const INTERRUPT_EXIT_CODE: u8 = 130;

const ls_preview = "ls -lah --color=always {}";
const eza_preview = "eza -la --color=always {}";
const cmd_preview = "cmd /C \"dir /a {}\"";

const args = [_][]const u8{
    "fzf",
    "--header=choose a dir",
    "--reverse",
    "--scheme=path",
    "--preview",
    getPreviewCommand(),
};

pub fn runProcess(allocator: Allocator, dirs: []const []const u8, path_buf: []u8) !?[]u8 {
    var fzf_process: std.process.Child = .init(&args, allocator);
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

    const reader = fzf_process.stdout.?.reader();
    const path = try reader.readUntilDelimiterOrEof(path_buf, '\n');

    const term = try fzf_process.wait();

    return switch (term) {
        .Exited => |error_code| switch (error_code) {
            0 => path,
            NO_MATCH_EXIT_CODE, INTERRUPT_EXIT_CODE => null,
            else => error.NonZeroExitCode,
        },
        else => return error.BadTermination,
    };
}

fn getPreviewCommand() []const u8 {
    return switch (os_tag) {
        .windows => cmd_preview,
        else => ls_preview,
    };
}
