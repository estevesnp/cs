const std = @import("std");

const Writer = std.Io.Writer;
const Diag = @This();

const log = std.log.scoped(.Diag);

const cli = @import("cli.zig");

/// enum derived from the `cli.Command` fields
/// used for tagging diagnostic messages
pub const Tag = blk: {
    const cmd_fields = @typeInfo(cli.Command).@"union".fields;
    const search_fields = @typeInfo(cli.SearchOpts).@"struct".fields;

    const num_fields = cmd_fields.len + search_fields.len;
    var fields: [num_fields]std.builtin.Type.EnumField = undefined;

    var idx = 0;
    for (cmd_fields) |field| {
        // 'search' isn't a flag
        if (@FieldType(cli.Command, field.name) == cli.SearchOpts) continue;

        fields[idx] = .{ .name = field.name, .value = idx };
        idx += 1;
    }

    for (search_fields) |field| {
        fields[idx] = .{ .name = field.name, .value = idx };
        idx += 1;
    }

    const enum_info = std.builtin.Type.Enum{
        .tag_type = u8,
        .fields = fields[0..idx],
        .decls = &.{},
        .is_exhaustive = true,
    };

    break :blk @Type(std.builtin.Type{ .@"enum" = enum_info });
};

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
    self.writer.print(fmt ++ "\n", args) catch |err| {
        log.err("error printing to writer: {t}", .{err});
        return;
    };
    self.writer.flush() catch |err|
        log.err("error flushing writer: {t}", .{err});
}

pub fn report(
    self: *Diag,
    tag: Tag,
    comptime fmt: []const u8,
    args: anytype,
) void {
    self.writer.print("error parsing {t} flag: ", .{tag}) catch |err| {
        log.err("error printing to writer: {t}", .{err});
        return;
    };
    self.reportUntagged(fmt, args);
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
