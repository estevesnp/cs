const std = @import("std");
const mem = std.mem;
const process = std.process;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Action = enum { session, window };
pub const Error = SessionError || error{TmuxNotFound};

/// handles the provided `action`, replacing this process by performing an
/// `execv` onto new process, attaching to a tmux session or window.
pub fn handleTmux(
    gpa: Allocator,
    action: Action,
    project_path: []const u8,
) Error {
    var basename_buf: [256]u8 = undefined;
    const session_name = normalizeBasename(std.fs.path.basename(project_path), &basename_buf);
    const inside_session = std.posix.getenv("TMUX") != null;

    const err = switch (action) {
        .session => handleTmuxSession(
            gpa,
            inside_session,
            project_path,
            session_name,
        ),
        .window => handleTmuxWindow(
            gpa,
            inside_session,
            project_path,
            session_name,
        ),
    };

    return switch (err) {
        error.FileNotFound => error.TmuxNotFound,
        else => err,
    };
}

/// when outside of a session, attemps to create a new one with `session_name`
/// starting from `project_path`. if one already exists, attaches to it
/// instead. fails if inside a session due to session nesting.
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

const SessionError = process.ExecvError || process.Child.RunError || error{TmuxExitError};

/// create a session with `session_name` starting from `project_path`. if one
/// already exists, attach to it instead.
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
                return error.TmuxExitError;
            }
        },
        // TODO: diagnostics
        else => return error.TmuxExitError,
    }

    return process.execv(gpa, &.{
        "tmux",
        "switch",
        "-t",
        session_name,
    });
}

/// create a new window in the existing session with name of `session_name`
/// starting from the `project_path`. creates a new session if not inside one
/// already.
fn handleTmuxWindow(
    gpa: Allocator,
    inside_session: bool,
    project_path: []const u8,
    session_name: []const u8,
) process.ExecvError {
    if (!inside_session) {
        return createAndAttachSession(gpa, project_path, session_name);
    }

    const args = &.{ "tmux", "new-window", "-c", project_path, "-n", session_name };

    return process.execv(gpa, args);
}

/// normalizes the basename of a directory for tmux, trimming it and replacing
/// `.` with `_`.
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
    try testing.expectEqualStrings(expected, normalizeBasename(input, &buf));
}
