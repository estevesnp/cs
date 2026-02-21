const std = @import("std");
const mem = std.mem;
const process = std.process;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

pub const Action = enum { session, window };
pub const Error = SessionError || error{TmuxNotFound};

/// handles the provided `action`, replacing this process by performing an
/// `execv` onto new process, attaching to a tmux session or window
pub fn handleTmux(
    gpa: Allocator,
    io: Io,
    environ_map: *const process.Environ.Map,
    action: Action,
    project_path: []const u8,
) Error {
    var basename_buf: [256]u8 = undefined;
    const session_name = normalizeBasename(std.Io.Dir.path.basename(project_path), &basename_buf);

    if (environ_map.get("TMUX") == null) {
        return createAndAttachSession(io, project_path, session_name);
    }

    const err = switch (action) {
        .session => handleTmuxSession(
            gpa,
            io,
            project_path,
            session_name,
        ),
        .window => handleTmuxWindow(
            io,
            project_path,
            session_name,
        ),
    };

    return switch (err) {
        error.FileNotFound => error.TmuxNotFound,
        else => err,
    };
}

/// when outside of a session, tmux attempts to create a new one with `session_name`
/// starting from `project_path`. if one already exists, tmux attaches to it
/// instead. fails if inside a session due to session nesting
fn createAndAttachSession(
    io: Io,
    project_path: []const u8,
    session_name: []const u8,
) process.ReplaceError {
    return process.replace(io, .{
        .argv = &.{
            "tmux",
            "new",
            "-A",
            "-s",
            session_name,
            "-c",
            project_path,
        },
    });
}

const SessionError = process.ReplaceError || process.RunError || error{TmuxExitError};

/// create a session with `session_name` starting from `project_path`.
/// assumes it is already inside a session.
fn handleTmuxSession(
    gpa: Allocator,
    io: Io,
    project_path: []const u8,
    session_name: []const u8,
) SessionError {
    // TODO - since we don't use stdout, we can just try to capture stderr
    const new_session_result = try process.run(gpa, io, .{
        .argv = &.{ "tmux", "new", "-ds", session_name, "-c", project_path },
    });

    defer gpa.free(new_session_result.stdout);
    defer gpa.free(new_session_result.stderr);

    switch (new_session_result.term) {
        .exited => |code| if (code != 0) {
            // we can ignore if there is a duplicate session,
            // since we will join it either way
            if (!mem.startsWith(u8, new_session_result.stderr, "duplicate session")) {
                // TODO - diagnostics
                // TODO - maybe log instead of erroring out?
                return error.TmuxExitError;
            }
        },
        // TODO - diagnostics
        else => return error.TmuxExitError,
    }

    return process.replace(io, .{
        .argv = &.{
            "tmux",
            "switch",
            "-t",
            session_name,
        },
    });
}

/// create a new window in the existing session with name of `session_name`
/// starting from the `project_path`.
/// assumes it is already inside a session.
fn handleTmuxWindow(
    io: Io,
    project_path: []const u8,
    session_name: []const u8,
) process.ReplaceError {
    return process.replace(io, .{
        .argv = &.{
            "tmux",
            "new-window",
            "-c",
            project_path,
            "-n",
            session_name,
        },
    });
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
