const std = @import("std");
const process = std.process;
const assert = std.debug.assert;

const Diag = @import("Diag.zig");

pub fn createSession(
    gpa: std.mem.Allocator,
    repo_path: []const u8,
    session_name: []const u8,
    startup_script: ?[]const u8,
    env_map: *process.EnvMap,
    diag: ?*Diag,
) !void {
    assert(repo_path.len > 0);
    assert(session_name.len > 0);

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

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
