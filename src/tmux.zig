const std = @import("std");
const process = std.process;

const Diag = @import("main.zig").Diag;

pub fn createSession(
    gpa: std.mem.Allocator,
    path: []const u8,
    session_name: []const u8,
    env_map: *process.EnvMap,
    diag: ?*Diag,
) !void {
    const args = &.{
        "tmux",
        "list-sessions",
        "-F",
        "#{session_name}",
    };

    var ls_proc: process.Child = .init(args, gpa);
    ls_proc.stdout_behavior = .Pipe;
    ls_proc.stdin_behavior = .Ignore;
    ls_proc.stderr_behavior = .Ignore;

    try ls_proc.spawn();

    const reader = ls_proc.stdout.?.reader();

    var buf: [2048]u8 = undefined;

    var found = false;
    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (std.mem.eql(u8, line, session_name)) {
            found = true;
            break;
        }
    }

    const term = try ls_proc.wait();

    const session_exists = switch (term) {
        .Exited => |error_code| switch (error_code) {
            0 => found,
            1 => false,
            else => {
                if (diag) |d| d.report("tmux exited with error code {d}\n", .{error_code});
                return error.NonZeroExitCode;
            },
        },
        else => |t| {
            if (diag) |d| d.report("tmux failed: {any}\n", .{t});
            return error.BadTermination;
        },
    };

    const inside_session = env_map.get("TMUX") != null;

    if (session_exists) {
        if (inside_session) {
            return process.execve(gpa, &.{ "tmux", "switch-client", "-t", session_name }, env_map);
        }

        return process.execve(gpa, &.{ "tmux", "attach-session", "-t", session_name }, env_map);
    }

    if (inside_session) {
        var create_proc: process.Child = .init(&.{ "tmux", "new-session", "-d", "-s", session_name }, gpa);
        _ = try create_proc.spawnAndWait();

        return process.execve(gpa, &.{ "tmux", "switch-client", "-t", session_name }, env_map);
    }

    return process.execve(gpa, &.{ "tmux", "new-session", "-s", session_name, "-c", path }, env_map);
}

test "ref all decls" {
    std.testing.refAllDeclsRecursive(@This());
}
