const std = @import("std");

const Diag = @This();

stream: std.io.AnyWriter,

pub fn init(stream: std.io.AnyWriter) Diag {
    return .{ .stream = stream };
}

pub fn report(self: *Diag, comptime fmt: []const u8, args: anytype) void {
    self.stream.print(fmt, args) catch |err| {
        std.debug.print("couldn't write to stream: {s}\n", .{@errorName(err)});
    };
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
