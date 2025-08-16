const std = @import("std");

const Writer = std.Io.Writer;
const Diag = @This();

pub const Tag = @TypeOf(.enum_literal);

var noop_writer: Writer = .{
    .buffer = &.{},
    .vtable = &.{
        .drain = struct {
            fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
                _ = w;
                _ = splat;

                var drained: usize = 0;
                for (data) |d| drained += d.len;

                return drained;
            }
        }.drain,
        .flush = Writer.noopFlush,
    },
};

writer: *Writer,

pub const empty: Diag = .{ .writer = &noop_writer };

pub fn init(writer: *Writer) Diag {
    return .{ .writer = writer };
}

pub fn reportUntagged(
    self: *Diag,
    comptime fmt: []const u8,
    args: anytype,
) void {
    self.writer.print(fmt ++ "\n", args) catch |err|
        std.debug.print("error printing to writer: {s}\n", .{@errorName(err)});
    self.writer.flush() catch |err|
        std.debug.print("error flushing writer: {s}\n", .{@errorName(err)});
}

pub fn report(
    self: *Diag,
    tag: Tag,
    comptime fmt: []const u8,
    args: anytype,
) void {
    self.writer.print("error parsing {s} flag: ", .{@tagName(tag)}) catch |err|
        std.debug.print("error printing to writer: {s}\n", .{@errorName(err)});
    self.reportUntagged(fmt, args);
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
