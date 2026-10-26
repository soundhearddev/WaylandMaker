// SPDX-License-Identifier: GPL-3.0
//
// Monitors on the model: what happens to windows when a monitor goes away or
// comes back, and the `monitor()` rules and profiles of the config.
//
// No wlroots in here. The compositor only reports monitors (manage.createOutput,
// setOutputRect, setOutputInfo, removeOutput); everything that follows from
// that is decided here, in the manage pass, and tested without a display.
//
//   * `migrate` / `rememberHome` / `restoreHomes`: the windows of a monitor that
//     goes away move to another one, with a note where they lived. They go
//     back when that monitor returns.
//   * `applyRule`: the `monitor()` rule that matches a monitor (on/off, primary,
//     workspace count, first workspace, hooks).
//   * `settle`: once the monitors have been quiet for `monitor_settle_ms`,
//     apply the rules and pick the `monitor_profile` for what is connected.

const std = @import("std");
const log = std.log.scoped(.outputs);

const model = @import("model.zig");
const types = model.types;
const workspace = model.workspace;
const monitors = model.monitors;
const proc = model.proc;
const perf = @import("perf.zig");

const Window = types.Window;
const Output = types.Output;
const WindowManager = types.WindowManager;

// ---- a monitor goes away ----------------------------------------------------

/// The live output that takes over the windows of `gone`: the primary one,
/// else the first.
pub fn pickOther(wm: *WindowManager, gone: *Output) ?*Output {
    var live: [monitors.max_monitors]*Output = undefined;
    const n = types.liveOutputs(wm, &live);
    for (live[0..n]) |o| if (o != gone and o.primary) return o;
    for (live[0..n]) |o| if (o != gone) return o;
    return null;
}

/// Move every window of `out` to the same workspace index on `dest`. With no
/// destination the windows are left unplaced and placed again when an output
/// appears (`win.new = true`).
pub fn migrate(wm: *WindowManager, out: *Output, dest: ?*Output) void {
    var wi: u32 = 0;
    while (wi < out.workspace_count) : (wi += 1) {
        const src = &out.workspaces[wi];
        while (anyWindowOn(src)) |win| {
            workspace.leaveFullscreen(win);
            rememberHome(wm, out, win, wi);
            if (dest) |d| {
                const idx = @min(wi, d.workspace_count - 1);
                workspace.moveToWorkspace(wm, win, &d.workspaces[idx]) catch {
                    workspace.unplace(wm, win);
                    win.new = true;
                };
            } else {
                workspace.unplace(wm, win);
                win.new = true;
            }
        }
    }
}

/// Any window still attached to `ws`, tiled or floating.
fn anyWindowOn(ws: *types.Workspace) ?*Window {
    if (ws.strip.columns.first()) |c| if (c.windows.first()) |w| return w;
    if (ws.floating.first()) |w| return w;
    return null;
}

/// Note on `win` where it lived, because `out` is going away (or off): it goes
/// back there when that monitor returns. The first home wins, so a window that
/// is moved twice still returns to where the user had it.
pub fn rememberHome(wm: *WindowManager, out: *Output, win: *Window, ws_index: u32) void {
    if (win.home.isSet()) return;
    const key = out.mon.key();
    if (key == 0) return;
    if (!monitors.effective(wm.monitors.rules, &out.mon, wm.cfg.workspace_count).restore_windows) return;
    win.home = .{ .key = key, .ws = ws_index };
}

/// Give back to `out` the windows that were taken off it. Returns how many.
/// Windows that are not placed lose their note without moving.
pub fn restoreHomes(wm: *WindowManager, out: *Output) usize {
    const key = out.mon.key();
    if (key == 0 or !types.liveOutput(out)) return 0;
    var moved: usize = 0;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (!w.home.matches(key)) continue;
        const idx = @min(w.home.ws, out.workspace_count - 1);
        w.home = .{};
        const ws = w.workspace orelse continue;
        if (ws.output == out) continue;
        workspace.leaveFullscreen(w);
        workspace.moveToWorkspace(wm, w, &out.workspaces[idx]) catch |err| {
            log.warn("cannot give a window back to its monitor: {t}", .{err});
            continue;
        };
        moved += 1;
    }
    if (moved > 0) {
        var buf: [200]u8 = undefined;
        log.info("{d} window(s) went back to {s}", .{ moved, out.mon.label(&buf) });
        wm.follow_request = true;
    }
    return moved;
}

// ---- rules ------------------------------------------------------------------------

fn otherLive(wm: *WindowManager, except: *Output) bool {
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (o != except and types.liveOutput(o)) return true;
    }
    return false;
}

const Hook = enum { connect, disconnect };

/// Run the `on_connect` / `on_disconnect` command of the rule that matches `out`.
pub fn runHook(wm: *WindowManager, out: *Output, which: Hook) void {
    const r = monitors.findRule(wm.monitors.rules, &out.mon) orelse return;
    const argv = switch (which) {
        .connect => r.on_connect,
        .disconnect => r.on_disconnect,
    };
    if (argv.len == 0) return;
    var buf: [200]u8 = undefined;
    log.info("monitor {s}: running its on_{t} command", .{ out.mon.label(&buf), which });
    proc.spawn(wm, argv);
}

/// Apply the rule that matches `out`: on/off, primary, workspace count, the
/// first workspace, the windows that belong here. Safe to repeat (a reload
/// does); the first workspace and the connect hook are used once per
/// connection. Manage pass only.
pub fn applyRule(wm: *WindowManager, out: *Output) void {
    if (out.removed) return;
    const eff = monitors.effective(wm.monitors.rules, &out.mon, wm.cfg.workspace_count);
    const first = !out.settled;
    out.settled = true;
    out.primary = eff.primary and eff.enabled;

    var buf: [200]u8 = undefined;
    if (!eff.enabled) {
        if (!out.disabled) {
            if (otherLive(wm, out)) {
                out.disabled = true;
                log.info("monitor {s} is switched off by its rule", .{out.mon.label(&buf)});
                migrate(wm, out, types.primaryOutput(wm));
            } else {
                log.warn("monitor {s}: its rule switches it off, but it is the only one; kept on", .{out.mon.label(&buf)});
            }
        }
    } else if (out.disabled) {
        out.disabled = false;
        log.info("monitor {s} is switched on again", .{out.mon.label(&buf)});
    }

    _ = workspace.setWorkspaceCount(wm, out, eff.workspaces);
    if (first) {
        out.active = @min(eff.start_workspace, out.workspace_count - 1);
        runHook(wm, out, .connect);
    }
    if (!out.disabled and eff.restore_windows) _ = restoreHomes(wm, out);
}

/// Re-apply the rules to every output (after a config reload).
pub fn applyAll(wm: *WindowManager) void {
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) applyRule(wm, o);
}

// ---- settling -------------------------------------------------------------------------

/// Called every manage pass: once the monitors have been quiet for
/// `monitor_settle_ms`, apply the rules and pick the profile for what is
/// connected now. How long the event loop may sleep for it: `settleWaitMs`.
pub fn settle(wm: *WindowManager, now_ms: u64) void {
    if (!wm.monitors.settle.due(now_ms)) return;
    wm.monitors.settle.clear();
    const span = perf.start(wm.io, .monitors);
    defer _ = perf.stop(wm.io, span);

    applyAll(wm);

    var infos: [monitors.max_monitors]monitors.Info = undefined;
    var n: usize = 0;
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (o.removed or !o.ready() or n == infos.len) continue;
        infos[n] = o.mon;
        n += 1;
    }
    if (wm.monitors.nextProfile(infos[0..n])) |p| {
        log.info("monitors changed ({d} connected): profile `{s}`", .{ n, p.name });
        if (p.run.len > 0) proc.spawn(wm, p.run);
    } else {
        log.info("monitors changed ({d} connected), no profile applies", .{n});
    }
    wm.follow_request = true;
}

/// How long the event loop may sleep before `settle` has something to do;
/// null: nothing is pending, no timer needed.
pub fn settleWaitMs(wm: *const WindowManager, now_ms: u64) ?i32 {
    return wm.monitors.settle.waitMs(now_ms);
}
