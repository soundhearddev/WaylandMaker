// SPDX-License-Identifier: 0BSD
//
// Spawning child processes.

const std = @import("std");
const types = @import("types.zig");

/// Start `argv` detached. SIGCHLD is ignored process-wide (see main.zig),
/// so children are reaped automatically and never become zombies.
pub fn spawn(wm: *types.WindowManager, argv: []const []const u8) void {
    if (argv.len == 0) return;
    _ = std.process.spawn(wm.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.err("failed to spawn `{s}`: {t}", .{ argv[0], err });
    };
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
