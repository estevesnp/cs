const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    try Io.File.stdout().writeStreamingAll(io, "Hello, World (again)!\n");
}
