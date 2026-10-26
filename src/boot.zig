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

const WindowManager = types.WindowManager;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Everything derived from `wm.cfg` that must be (re)built together, because
/// it all lives in `wm.cfg.arena`: the bind commands, the root menu, the
/// per-application rules (`wm_files.load` allocates them from the same arena,
/// so leaving them behind on reload would turn them into dangling pointers
/// the moment the old arena is freed).
///
/// Returns what only start-up needs (autostart script, DockApps).
pub fn loadModel(wm: *WindowManager) !wm_files.Loaded {
    const arena = wm.cfg.arena.allocator();
    wm.commands = try action.parseAll(arena, &wm.cfg);
    const files = try wm_files.load(wm.io, arena, &wm.cfg);
    wm.root_menu = files.root_menu;
    wm.attrs = files.attributes;
    wm.dockapps = files.dockapps;
    wm.dock_state_path = files.dock_state_path;
    wm.dock_gen +%= 1;
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

/// Children are reaped by the kernel, so none becomes a zombie.
pub fn ignoreSigchld() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &act, null);
}

/// Window Maker's autostart script, run once through the shell (so it works
/// whether or not the file is marked executable).
pub fn runAutostart(wm: *WindowManager, path: ?[]const u8) void {
    for (wm.cfg.spawn_at_startup) |argv| model.proc.spawn(wm, argv);
    if (path) |p| {
        log.info("autostart: running {s}", .{p});
        model.proc.spawn(wm, &.{ "/bin/sh", p });
    }
}
