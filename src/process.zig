// SPDX-License-Identifier: GPL-3.0
//
// Spawning child processes.

const std = @import("std");
const log = std.log.scoped(.process);
const types = @import("types.zig");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Start `argv` detached. SIGCHLD is ignored process-wide (see main.zig),
/// so children are reaped automatically and never become zombies.
pub fn spawn(wm: *types.WindowManager, argv: []const []const u8) void {
    _ = spawnChecked(wm, argv);
}

/// Like `spawn`, but says whether the process was started at all. (A
/// program that starts and then fails still counts as started.) The Dock
/// uses it so that a tile whose command does not exist is not marked as
/// "launching" for the next eight seconds.
pub fn spawnChecked(wm: *types.WindowManager, argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    _ = std.process.spawn(wm.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        log.err("failed to spawn `{s}`: {t}", .{ argv[0], err });
        return false;
    };
    // A command run through the shell is named by its text, not by /bin/sh.
    const shown = if (argv.len == 3 and std.mem.eql(u8, argv[0], "/bin/sh") and std.mem.eql(u8, argv[1], "-c")) argv[2] else argv[0];
    log.info("started `{s}`", .{shown});
    return true;
}

/// Run `cmd` through `/bin/sh -c`, detached, exactly like the root menu's
/// `SHEXEC` and the autostart script. Unlike `spawn`, this gives the
/// command a real shell: pipes, `&&`/`||`, `~`/`$HOME`/`$VAR` expansion,
/// globs, backgrounding with a trailing `&`, and chaining several programs
/// on one bind all work, so any command a user can type into a terminal
/// can be bound to a key.
pub fn spawnShell(wm: *types.WindowManager, cmd: []const u8) void {
    if (cmd.len == 0) return;
    spawn(wm, &.{ "/bin/sh", "-c", cmd });
}

/// Is there a program `name` we could start: an executable file at that path
/// (when it has a `/`), or in one of the directories of $PATH.
pub fn exists(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    var buf: [4096]u8 = undefined;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return false;
        return access(z.ptr, 1) == 0; // X_OK
    }
    const path: [*:0]const u8 = std.c.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, std.mem.span(path), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const z = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (access(z.ptr, 1) == 0) return true;
    }
    return false;
}

test "exists: programs in PATH, absolute paths, and nothing" {
    try std.testing.expect(exists("sh"));
    try std.testing.expect(exists("/bin/sh"));
    try std.testing.expect(!exists("wmaker-wl-no-such-program"));
    try std.testing.expect(!exists("/nonexistent/dir/prog"));
    try std.testing.expect(!exists(""));
}
