const std = @import("std");
const mem = std.mem;
const process = std.process;
const testing = std.testing;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Action = enum { session, window };

// TODO: unify error handling
pub fn handleTmux(
    gpa: Allocator,
    env_map: *const process.EnvMap,
    action: Action,
    project_path: []const u8,
) SessionError {
    var basename_buf: [256]u8 = undefined;
    const session_name = normalizeBasename(std.fs.path.basename(project_path), &basename_buf);
    const inside_session = env_map.get("TMUX") != null;

    switch (action) {
        .session => return handleTmuxSession(
            gpa,
            inside_session,
            project_path,
            session_name,
        ),
        .window => return handleTmuxWindow(
            gpa,
            inside_session,
            project_path,
            session_name,
        ),
    }
}

const SessionError = process.ExecvError || process.Child.RunError || Writer.Error || Reader.DelimiterError || error{
    TmuxNotFound,
    TmuxNonZeroExitCode,
    TmuxBadTermination,
};

fn createAndAttachSession(
    gpa: Allocator,
    project_path: []const u8,
    session_name: []const u8,
) process.ExecvError {
    return process.execv(gpa, &.{
        "tmux",
        "new",
        "-A",
        "-s",
        session_name,
        "-c",
        project_path,
    });
}

/// creates a new session called `session_name` if one doesn't already exist.
/// then attaches to that session.
fn handleTmuxSession(
    gpa: Allocator,
    inside_session: bool,
    project_path: []const u8,
    session_name: []const u8,
) SessionError {
    if (!inside_session) {
        return createAndAttachSession(gpa, project_path, session_name);
    }

    // try creating session, ignore if it fails due to duplicate session
    const res = try process.Child.run(.{
        .allocator = gpa,
        .argv = &.{ "tmux", "new", "-ds", session_name, "-c", project_path },
    });

    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    switch (res.term) {
        .Exited => |code| if (code != 0) {
            if (!mem.startsWith(u8, res.stderr, "duplicate session")) {
                // TODO: diagnostics
                return error.TmuxNonZeroExitCode;
            }
        },
        else => return error.TmuxBadTermination,
    }

    return process.execv(gpa, &.{
        "tmux",
        "switch",
        "-t",
        session_name,
    });
}

const TmuxWriteReadError = error{TmuxReadError} || Writer.Error || Reader.DelimiterError;

/// if inside a session, creates a new window called `session_name`.
/// if not, just calls `handleTmuxSession`, creating a new session
fn handleTmuxWindow(
    gpa: Allocator,
    inside_session: bool,
    project_path: []const u8,
    session_name: []const u8,
) SessionError {
    // TODO: maybe pass this to method above?
    if (!inside_session) {
        return createAndAttachSession(gpa, project_path, session_name);
    }

    const args = &.{ "tmux", "new-window", "-c", project_path, "-n", session_name };

    const err = process.execv(gpa, args);
    return switch (err) {
        error.FileNotFound => error.TmuxNotFound,
        else => err,
    };
}

fn normalizeBasename(basename: []const u8, buf: []u8) []u8 {
    assert(buf.len >= basename.len);

    const trimmed = mem.trim(u8, basename, ".");
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
