const std = @import("std");
const process = std.process;
const testing = std.testing;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Action = enum { session, window };

pub fn handleTmux(
    arena: Allocator,
    env_map: *const process.EnvMap,
    action: Action,
    project_path: []const u8,
) SessionError {
    var basename_buf: [256]u8 = undefined;
    const session_name = normalizeBasename(std.fs.path.basename(project_path), &basename_buf);

    switch (action) {
        .session => return handleTmuxSession(
            arena,
            env_map,
            project_path,
            session_name,
        ),
        .window => return handleTmuxWindow(
            arena,
            env_map,
            project_path,
            session_name,
        ),
    }
}

fn spawnTmuxControlMode(gpa: Allocator) process.Child.SpawnError!process.Child {
    var tmux_proc = std.process.Child.init(&.{
        "tmux",
        "-C",
        "new-session",
    }, gpa);

    tmux_proc.stdin_behavior = .Pipe;
    tmux_proc.stdout_behavior = .Pipe;

    try tmux_proc.spawn();

    return tmux_proc;
}

const SessionError = error{
    TmuxNotFound,
    TmuxNonZeroExitCode,
    TmuxBadTermination,
} || process.Child.SpawnError || Writer.Error || Reader.DelimiterError;

/// creates a new session called `session_name` if one doesn't already exist.
/// then attaches to that session.
fn handleTmuxSession(
    arena: Allocator,
    env_map: *const process.EnvMap,
    project_path: []const u8,
    session_name: []const u8,
) SessionError {
    var tmux_proc = try spawnTmuxControlMode(arena);
    errdefer _ = tmux_proc.kill() catch {};

    var stdin_buf: [256]u8 = undefined;
    var tmux_stdin_bw = tmux_proc.stdin.?.writer(&stdin_buf);
    const tmux_writer = &tmux_stdin_bw.interface;

    var stdout_buf: [1024]u8 = undefined;
    var tmux_stdout_br = tmux_proc.stdout.?.reader(&stdout_buf);
    const tmux_reader = &tmux_stdout_br.interface;

    createSession(tmux_writer, tmux_reader, project_path, session_name) catch |err| switch (err) {
        error.TmuxReadError => return error.TmuxNotFound,
        // inline else should work here, but due to limitations in error resolutions
        // it is needed to explicitly list the possible errors.
        error.EndOfStream, error.ReadFailed, error.StreamTooLong, error.WriteFailed => |e| return e,
    };

    const term = tmux_proc.wait() catch |err| switch (err) {
        error.FileNotFound => return error.TmuxNotFound,
        else => return err,
    };

    switch (term) {
        .Exited => |code| switch (code) {
            0 => {},
            else => return error.TmuxNonZeroExitCode,
        },
        else => return error.TmuxBadTermination,
    }

    const session_command = if (isInsideTmuxSession(env_map)) "switch-client" else "attach-session";
    const args = &.{ "tmux", session_command, "-t", session_name };

    const err = process.execve(arena, args, env_map);
    return switch (err) {
        error.FileNotFound => error.TmuxNotFound,
        else => err,
    };
}

const TmuxWriteReadError = error{TmuxReadError} || Writer.Error || Reader.DelimiterError;

fn createSession(
    tmux_stdin: *Writer,
    tmux_stdout: *Reader,
    project_path: []const u8,
    session_name: []const u8,
) TmuxWriteReadError!void {
    const session_exists = try sessionExists(tmux_stdin, tmux_stdout, session_name);
    if (!session_exists) {
        try tmux_stdin.print(
            \\new-session -s '{s}' -c '{s}'
            \\switch-client -l
            \\
        , .{ session_name, project_path });
    }

    try tmux_stdin.writeAll("kill-session\n\n");
    try tmux_stdin.flush();
}

fn sessionExists(
    tmux_stdin: *Writer,
    tmux_stdout: *Reader,
    session_name: []const u8,
) TmuxWriteReadError!bool {
    try tmux_stdin.writeAll("list-sessions -F '#{session_name}'\n");
    try tmux_stdin.flush();

    var reading_lines = false;
    while (true) {
        const line = tmux_stdout.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.TmuxReadError,
            else => return err,
        };

        if (line.len == 0) continue;
        if (line[0] == '%') {
            if (reading_lines) return false;
            continue;
        }

        reading_lines = true;
        if (std.mem.eql(u8, line, session_name)) {
            return true;
        }
    }
}

/// if inside a session, creates a new window called `session_name`.
/// if not, just calls `handleTmuxSession`, creating a new session
fn handleTmuxWindow(
    arena: Allocator,
    env_map: *const process.EnvMap,
    project_path: []const u8,
    session_name: []const u8,
) SessionError {
    if (!isInsideTmuxSession(env_map)) {
        return handleTmuxSession(arena, env_map, project_path, session_name);
    }

    const args = &.{ "tmux", "new-window", "-c", project_path, "-n", session_name };

    const err = process.execve(arena, args, env_map);
    return switch (err) {
        error.FileNotFound => error.TmuxNotFound,
        else => err,
    };
}

fn isInsideTmuxSession(env_map: *const process.EnvMap) bool {
    return env_map.get("TMUX") != null;
}

fn normalizeBasename(basename: []const u8, buf: []u8) []u8 {
    assert(buf.len >= basename.len);

    const trimmed = std.mem.trim(u8, basename, ".");
    const normalized = buf[0..trimmed.len];

    for (trimmed, 0..) |char, idx| {
        normalized[idx] = if (char == '.') '_' else char;
    }

    return normalized;
}

test normalizeBasename {
    try test_normalizeBasename("..foo.bar..", "foo_bar");
    try test_normalizeBasename("foo.bar..", "foo_bar");
    try test_normalizeBasename("..foo.bar", "foo_bar");
    try test_normalizeBasename("..foobar..", "foobar");
    try test_normalizeBasename("foobar", "foobar");
}

fn test_normalizeBasename(input: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, normalizeBasename(input, &buf));
}
