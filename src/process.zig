// SPDX-License-Identifier: 0BSD
//
// Spawning child processes.

const std = @import("std");
const types = @import("types.zig");

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
        std.log.err("failed to spawn `{s}`: {t}", .{ argv[0], err });
        return false;
    };
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
