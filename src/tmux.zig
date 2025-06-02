const std = @import("std");
const process = std.process;
const assert = std.debug.assert;

const Diag = @import("Diag.zig");

pub fn createSession(
    gpa: std.mem.Allocator,
    repo_path: []const u8,
    startup_script: ?[]const u8,
    env_map: *process.EnvMap,
    diag: ?*Diag,
) !void {
    assert(repo_path.len > 0);

    var session_buf: [256]u8 = undefined;
    const session_name = normalizeBasename(std.fs.path.basename(repo_path), &session_buf);

    const args = &.{
        "tmux",
        "-C",
        "new-session",
    };

    var control_process = std.process.Child.init(args, gpa);
    control_process.stdin_behavior = .Pipe;
    control_process.stdout_behavior = .Pipe;

    try control_process.spawn();

    const writer = control_process.stdin.?.writer();
    const reader = control_process.stdout.?.reader();

    try writer.writeAll("list-sessions -F '#{session_name}'\n");

    var buf: [2048]u8 = undefined;
    var reading_lines = false;
    var session_exists = false;
    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (line.len == 0) continue;
        if (line[0] == '%') {
            if (reading_lines) break;
            continue;
        }
        reading_lines = true;

        if (std.mem.eql(u8, line, session_name)) {
            session_exists = true;
            break;
        }
    }

    if (!session_exists) {
        try writer.print("new-session -s '{s}' -c '{s}'\n", .{ session_name, repo_path });

        if (startup_script) |script| {
            try writer.print("{s}\n", .{script});
        }

        try writer.writeAll("switch-client -l\n");
    }

    try writer.writeAll("kill-session\n\n");

    switch (try control_process.wait()) {
        .Exited => |exit_code| switch (exit_code) {
            0 => {},
            else => {
                if (diag) |d| d.report("tmux exited with error code {d}\n", .{exit_code});
                return error.NonZeroExitCode;
            },
        },
        else => |t| {
            if (diag) |d| d.report("tmux failed: {any}\n", .{t});
            return error.BadTermination;
        },
    }

    const inside_session = env_map.get("TMUX") != null;

    if (inside_session) {
        return process.execve(gpa, &.{ "tmux", "switch-client", "-t", session_name }, env_map);
    }

    return process.execve(gpa, &.{ "tmux", "attach-session", "-t", session_name }, env_map);
}

/// trims a basename for '.' and replaces inner '.' with '_'
/// example: '..foo.bar..' becomes 'foo_bar'
fn normalizeBasename(basename: []const u8, buf: []u8) []u8 {
    assert(buf.len >= basename.len);

    const trimmed = std.mem.trim(u8, basename, ".");
    const normalized = buf[0..trimmed.len];

    @memcpy(normalized, trimmed);

    for (trimmed, 0..) |char, idx| {
        buf[idx] = if (char == '.') '_' else char;
    }

    return normalized;
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}

test normalizeBasename {
    try testNormalizeBasename("..foo.bar..", "foo_bar");
    try testNormalizeBasename("foo.bar..", "foo_bar");
    try testNormalizeBasename("..foo.bar", "foo_bar");
    try testNormalizeBasename("..foobar..", "foobar");
    try testNormalizeBasename("foobar", "foobar");
}

fn testNormalizeBasename(input: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, normalizeBasename(input, &buf));
}
