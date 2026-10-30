// SPDX-License-Identifier: GPL-3.0
//
// Start-up and reload steps that do not depend on the compositor library:
// deriving everything from `wm.cfg`, the `environment` option, workspace
// counts, SIGCHLD.

const std = @import("std");
const log = std.log.scoped(.boot);

const model = @import("model.zig");
const types = model.types;
const config = model.config;
const action = model.action;
const workspace = model.workspace;
const wm_files = model.wm_files;
const style = @import("style.zig");

const WindowManager = types.WindowManager;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn system(command: [*:0]const u8) c_int;

/// Everything derived from `wm.cfg` that must be (re)built together, because
/// it all lives in `wm.cfg.arena`: the bind commands, the root menu, the
/// per-application rules (`wm_files.load` allocates them from the same arena,
/// so leaving them behind on reload would turn them into dangling pointers
/// the moment the old arena is freed).
///
/// Returns what only start-up needs (DockApps).
pub fn loadModel(wm: *WindowManager) !wm_files.Loaded {
    const arena = wm.cfg.arena.allocator();
    wm.commands = try action.parseAll(arena, &wm.cfg);
    const files = try wm_files.load(wm.io, arena, &wm.cfg);
    wm.root_menu = files.root_menu;
    wm.attrs = files.attributes;
    wm.dockapps = files.dockapps;
    wm.dock_state_path = files.dock_state_path;
    // The look (palette, fonts) before the Dock is rebuilt: its tiles are
    // drawn from it. Fonts used to be copied nowhere, so `font_*` did nothing.
    style.apply(&wm.cfg);
    wm.dock_gen +%= 1;
    wm.config_gen +%= 1;
    wm.monitors.configure(wm.cfg.monitor_rules.items, wm.cfg.monitor_profiles.items, wm.cfg.output_order, wm.cfg.monitor_settle_ms);
    return files;
}

/// `environment = { NAME = "value" }`: set in our own environment, which the
/// programs we start inherit. A value that is too long is skipped.
pub fn applyEnvironment(vars: []const config.EnvVar) void {
    for (vars) |e| {
        var nbuf: [160]u8 = undefined;
        var vbuf: [4096]u8 = undefined;
        const n = std.fmt.bufPrintZ(&nbuf, "{s}", .{e.name}) catch continue;
        const v = std.fmt.bufPrintZ(&vbuf, "{s}", .{e.value}) catch {
            log.warn("environment: the value of `{s}` is too long, skipped", .{e.name});
            continue;
        };
        if (setenv(n.ptr, v.ptr, 1) != 0) log.warn("environment: cannot set `{s}`", .{e.name});
    }
}

/// Set one variable for every program we start from now on.
pub fn exportVar(name: [:0]const u8, value: [:0]const u8) void {
    if (setenv(name.ptr, value.ptr, 1) != 0) log.warn("cannot set {s}", .{name});
}

/// A reload that changed `workspace_count` resizes every output; one that did
/// not leaves alone the workspaces added or removed with commands since.
pub fn applyWorkspaceCount(wm: *WindowManager, old_count: u32) void {
    if (old_count == wm.cfg.workspace_count) return;
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (o.removed) continue;
        _ = workspace.setWorkspaceCount(wm, o, wm.cfg.workspace_count);
    }
    wm.focus_request = null;
    wm.follow_request = true;
}

fn noopChild(_: std.posix.SIG) callconv(.c) void {}

/// Children are reaped by the kernel (SA_NOCLDWAIT), so none becomes a zombie.
/// Not SIG_IGN: an ignored signal stays ignored across exec, so every program
/// we start would inherit it and its own wait() calls would fail with ECHILD.
/// A handler is reset to the default by exec.
pub fn ignoreSigchld() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = noopChild },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.NOCLDWAIT | std.posix.SA.RESTART,
    };
    std.posix.sigaction(.CHLD, &act, null);
}

/// The name this compositor goes by as a desktop environment: the value of
/// `XDG_CURRENT_DESKTOP` / `XDG_SESSION_DESKTOP`, `DesktopNames=` in the
/// session file, and the prefix of `wmaker-wl-portals.conf`.
pub const desktop_name: [:0]const u8 = "wmaker-wl";

/// Variables D-Bus and systemd --user learn about at session start, besides
/// the ones of the `environment` option. DISPLAY is not in the list: there is
/// no X server, and a stale value would send X11 clients to the wrong place.
const session_vars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP";

/// Tell D-Bus (and with `--systemd`, systemd --user) where this session is.
/// Programs started by D-Bus activation -- notification daemons, portals, a
/// file manager opened from a browser -- get their environment from there,
/// not from us, so without this they cannot find the compositor.
///
/// Runs synchronously (it takes a few milliseconds) so that everything
/// started afterwards already finds the variables. A missing
/// `dbus-update-activation-environment` is no error; `timeout` keeps a
/// broken bus from holding up the session.
pub fn importEnvironment(wm: *WindowManager) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("T=; command -v timeout >/dev/null 2>&1 && T='timeout 5'; V='" ++ session_vars) catch return;
    for (wm.cfg.environment) |e| w.print(" {s}", .{e.name}) catch break;
    w.writeAll("'; if command -v dbus-update-activation-environment >/dev/null 2>&1; then " ++
        "$T dbus-update-activation-environment --systemd $V; " ++
        "elif command -v systemctl >/dev/null 2>&1; then $T systemctl --user import-environment $V; fi " ++
        ">/dev/null 2>&1") catch return;
    const text = w.buffered();
    if (text.len >= buf.len) return;
    buf[text.len] = 0;

    // `ignoreSigchld` makes the kernel reap children on its own, and then
    // `system` cannot wait for its shell (it reports -1 although the command
    // ran). The default action is put back for the time of the call.
    const dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, &dfl, &previous);
    const rc = system(@ptrCast(&buf));
    std.posix.sigaction(.CHLD, &previous, null);
    log.info("environment imported into D-Bus / systemd (status {d})", .{rc});
}

/// Reach `graphical-session.target` the way sway and niri do: start
/// `wmaker-wl-session.target`, which binds to it. User services of other
/// programs (`PartOf=graphical-session.target`, `After=graphical-session.target`,
/// for example waybar, swaybg or mako as units) wait for exactly this, and
/// xdg-desktop-portal and friends use it to tell that a desktop session runs.
///
/// Must come after `importEnvironment`: the services the target pulls in read
/// the imported variables. `--no-block` keeps the session from waiting for
/// them, and a machine without systemd, or without the unit installed, is
/// not an error (the `systemctl` call just fails quietly).
pub fn startSessionTarget(wm: *WindowManager) void {
    if (!wm.cfg.session_target) return;
    runShell("command -v systemctl >/dev/null 2>&1 && systemctl --user list-unit-files " ++
        "wmaker-wl-session.target >/dev/null 2>&1 && " ++
        "systemctl --user start --no-block wmaker-wl-session.target >/dev/null 2>&1", "session target");
}

/// The counterpart at exit: `wmaker-wl-shutdown.target` conflicts with the
/// session target and stops it (and every service bound to the session).
pub fn stopSessionTarget(wm: *WindowManager) void {
    if (!wm.cfg.session_target) return;
    runShell("command -v systemctl >/dev/null 2>&1 && " ++
        "systemctl --user start --job-mode=replace-irreversibly wmaker-wl-shutdown.target " ++
        ">/dev/null 2>&1", "session target stop");
}

/// `system()` for one fixed command line, with the default SIGCHLD action
/// back for its duration (see `importEnvironment`).
fn runShell(comptime command: [:0]const u8, what: []const u8) void {
    const dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, &dfl, &previous);
    const rc = system(command.ptr);
    std.posix.sigaction(.CHLD, &previous, null);
    log.info("{s} (status {d})", .{ what, rc });
}

/// Run once at session start, never on a reload: the environment import,
/// then every program of `spawn_at_startup`.
pub fn runStartup(wm: *WindowManager) void {
    if (wm.cfg.import_environment) importEnvironment(wm);
    startSessionTarget(wm);
    for (wm.cfg.spawn_at_startup) |argv| model.proc.spawn(wm, argv);
}
