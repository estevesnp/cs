const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const os_tag = builtin.os.tag;

pub const NO_MATCH_EXIT_CODE: u8 = 1;
pub const INTERRUPT_EXIT_CODE: u8 = 130;

const args = [_][]const u8{
    "fzf",
    "--header=choose a dir",
    "--reverse",
    "--scheme=path",
    getPreviewCommand(),
};

pub fn runProcess(allocator: Allocator, dirs: []const []const u8, path_buf: []u8) !?[]u8 {
    var fzf_process: std.process.Child = .init(&args, allocator);
    fzf_process.stdin_behavior = .Pipe;
    fzf_process.stdout_behavior = .Pipe;

    try fzf_process.spawn();

    const in_writer = fzf_process.stdin.?.writer();
    for (dirs) |dir| {
        try in_writer.writeAll(dir);
        try in_writer.writeByte('\n');
    }

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
        .windows => @panic("not implemented"),
        else => "--preview=ls -lah --color=always {}",
    };
}
