// SPDX-License-Identifier: GPL-3.0
//
// Spawning child processes.
//
// Why this does not use `std.process.spawn`: in Zig 0.16 it builds the
// child's environment from a snapshot of the environment taken when the
// process started (`Io.Threaded.environ`), NOT from the live libc
// `environ`. Everything we `setenv` afterwards -- WAYLAND_DISPLAY,
// XDG_SESSION_TYPE, XDG_CURRENT_DESKTOP, the config's `environment` -- was
// therefore invisible to every program we started: terminals, launchers
// and browsers could not find the compositor and died right away, while
// the compositor's own key binds (focus, move, ...) kept working.
//
// It also gives the child our signal mask. The event loop blocks
// SIGINT/SIGTERM/SIGHUP/SIGUSR1 (signalfd); a blocked mask survives exec, so
// children could not be terminated normally.
//
// So: posix_spawnp with the live environment, an empty signal mask, default
// signal dispositions, a session of its own and /dev/null on stdio.

const std = @import("std");
const log = std.log.scoped(.process);
const types = @import("types.zig");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

// glibc and musl agree on the flag values; the buffers are larger than
// either libc's struct (glibc: 336 / 80 bytes, musl: 64 / 80).
const SPAWN_SETSIGDEF: c_short = 0x04;
const SPAWN_SETSIGMASK: c_short = 0x08;
const SPAWN_SETSID: c_short = 0x80;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;

const Attr = extern struct { buf: [512]u8 align(16) = undefined };
const Actions = extern struct { buf: [256]u8 align(16) = undefined };

extern "c" fn posix_spawnattr_init(attr: *Attr) c_int;
extern "c" fn posix_spawnattr_destroy(attr: *Attr) c_int;
extern "c" fn posix_spawnattr_setflags(attr: *Attr, flags: c_short) c_int;
extern "c" fn posix_spawnattr_setsigmask(attr: *Attr, mask: *const std.posix.sigset_t) c_int;
extern "c" fn posix_spawnattr_setsigdefault(attr: *Attr, mask: *const std.posix.sigset_t) c_int;
extern "c" fn posix_spawn_file_actions_init(fa: *Actions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(fa: *Actions) c_int;
extern "c" fn posix_spawn_file_actions_addopen(fa: *Actions, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
extern "c" fn posix_spawnp(
    pid: *std.posix.pid_t,
    file: [*:0]const u8,
    fa: *const Actions,
    attr: *const Attr,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;

/// Start `argv` detached. SIGCHLD is handled with SA_NOCLDWAIT process-wide
/// (see boot.ignoreSigchld), so children are reaped automatically and never
/// become zombies.
pub fn spawn(wm: *types.WindowManager, argv: []const []const u8) void {
    _ = spawnChecked(wm, argv);
}

/// Like `spawn`, but says whether the process was started at all. (A
/// program that starts and then fails still counts as started.) The Dock
/// uses it so that a tile whose command does not exist is not marked as
/// "launching" for the next eight seconds.
pub fn spawnChecked(wm: *types.WindowManager, argv: []const []const u8) bool {
    _ = wm;
    if (argv.len == 0 or argv[0].len == 0) return false;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c_argv = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch return oom(argv[0]);
    for (argv, 0..) |arg, i| c_argv[i] = (arena.dupeZ(u8, arg) catch return oom(argv[0])).ptr;
    const file = c_argv[0].?;

    var attr: Attr = .{};
    if (posix_spawnattr_init(&attr) != 0) return oom(argv[0]);
    defer _ = posix_spawnattr_destroy(&attr);
    var empty = std.posix.sigemptyset();
    var all = std.posix.sigfillset();
    _ = posix_spawnattr_setsigmask(&attr, &empty);
    _ = posix_spawnattr_setsigdefault(&attr, &all);
    _ = posix_spawnattr_setflags(&attr, SPAWN_SETSIGDEF | SPAWN_SETSIGMASK | SPAWN_SETSID);

    var fa: Actions = .{};
    if (posix_spawn_file_actions_init(&fa) != 0) return oom(argv[0]);
    defer _ = posix_spawn_file_actions_destroy(&fa);
    _ = posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    _ = posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);

    // The LIVE environment: whatever was `setenv`-ed since we started.
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

    var pid: std.posix.pid_t = 0;
    const rc = posix_spawnp(&pid, file, &fa, &attr, c_argv.ptr, envp);
    if (rc != 0) {
        const e: std.posix.E = @enumFromInt(rc);
        log.err("failed to spawn `{s}`: {t}", .{ argv[0], e });
        return false;
    }
    // A command run through the shell is named by its text, not by /bin/sh.
    const shown = if (argv.len == 3 and std.mem.eql(u8, argv[0], "/bin/sh") and std.mem.eql(u8, argv[1], "-c")) argv[2] else argv[0];
    log.info("started `{s}` (pid {d})", .{ shown, pid });
    return true;
}

fn oom(name: []const u8) bool {
    log.err("out of memory: cannot start `{s}`", .{name});
    return false;
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
