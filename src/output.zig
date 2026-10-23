// SPDX-License-Identifier: GPL-3.0
//
// river_output_v1 and river_layer_shell_output_v1.
//
// The layer-shell `non_exclusive_area` is the rectangle left over after
// bars and docks have reserved their space. Windows tile inside it, so a
// bar never overlaps the layout.

const std = @import("std");
const log = std.log.scoped(.output);
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const workspace = @import("workspace.zig");
const monitors = @import("monitors.zig");
const proc = @import("process.zig");
const perf = @import("perf.zig");
const wl = wayland.client.wl;

const Output = types.Output;
const Rect = types.Rect;
const WindowManager = types.WindowManager;

pub fn create(wm: *WindowManager, obj: *river.OutputV1) !*Output {
    const out = try wm.gpa.create(Output);
    errdefer wm.gpa.destroy(out);
    out.* = .{ .obj = obj };

    // Workspaces need a stable address (Strip/Column keep back-pointers),
    // which is why the array lives inside the heap-allocated Output.
    out.workspace_count = wm.cfg.workspace_count;
    var i: u32 = 0;
    while (i < out.workspace_count) : (i += 1) {
        out.workspaces[i].init(out, i);
    }

    wm.outputs.append(out);
    obj.setListener(*WindowManager, listener, wm);
    wm.monitors.changed(nowMs(wm));

    if (wm.layer_shell) |ls| bindLayerShell(wm, ls, out);
    return out;
}

/// Ask river for the layer-shell area of `out`. Called on creation, and
/// again for outputs that existed before the layer-shell global appeared.
pub fn bindLayerShell(wm: *WindowManager, ls: *river.LayerShellV1, out: *Output) void {
    if (out.layer_shell != null) return;
    const lso = ls.getOutput(out.obj) catch |err| {
        log.err("layer_shell.get_output failed: {t}", .{err});
        return;
    };
    out.layer_shell = lso;
    lso.setListener(*WindowManager, layerListener, wm);
    // Layer surfaces that don't name an output land on the first one.
    if (wm.outputs.first() == out) lso.setDefault();
}

fn find(wm: *WindowManager, obj: *river.OutputV1) ?*Output {
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (o.obj == obj) return o;
    }
    return null;
}

fn findByLayer(wm: *WindowManager, obj: *river.LayerShellOutputV1) ?*Output {
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (o.layer_shell == obj) return o;
    }
    return null;
}

fn listener(obj: *river.OutputV1, event: river.OutputV1.Event, wm: *WindowManager) void {
    const out = find(wm, obj) orelse return;
    switch (event) {
        .removed => {
            out.removed = true;
            wm.monitors.changed(nowMs(wm));
            wm.obj.manageDirty();
        },
        .wl_output => |g| {
            out.wl_global = g.name;
            copyInfo(wm, out);
            wm.monitors.changed(nowMs(wm));
            wm.obj.manageDirty();
        },
        .position => |p| {
            out.rect.x = p.x;
            out.rect.y = p.y;
            wm.monitors.changed(nowMs(wm));
            wm.obj.manageDirty();
        },
        .dimensions => |d| {
            out.rect.w = d.width;
            out.rect.h = d.height;
            wm.monitors.changed(nowMs(wm));
            wm.obj.manageDirty();
        },
        else => {},
    }
}

fn layerListener(obj: *river.LayerShellOutputV1, event: river.LayerShellOutputV1.Event, wm: *WindowManager) void {
    const out = findByLayer(wm, obj) orelse return;
    switch (event) {
        .non_exclusive_area => |a| {
            out.usable = sanitize(.{ .x = a.x, .y = a.y, .w = a.width, .h = a.height }, out.rect);
            wm.obj.manageDirty();
        },
    }
}

/// Never trust a work area blindly: an empty or out-of-range rectangle
/// (a bar that reserves the whole screen) would collapse every column to
/// 1px. Fall back to the full output instead.
pub fn sanitize(area: Rect, full: Rect) ?Rect {
    if (area.w <= 0 or area.h <= 0) return null;
    if (full.w > 0 and full.h > 0) {
        if (area.w < @divTrunc(full.w, 4) or area.h < @divTrunc(full.h, 4)) return null;
    }
    return area;
}

/// Attach the windows of a removed output to the first remaining one, then
/// free it. Manage sequence only (fullscreen exit is a manage request).
pub fn reap(wm: *WindowManager) void {
    var it = wm.outputs.first();
    while (it) |out| {
        const next = types.nextOutput(out, wm);
        if (out.removed) {
            runHook(wm, out, .disconnect);
            const target = types.primaryOutput(wm);
            migrate(wm, out, target);
            if (wm.active_output == out) wm.active_output = target;
            types.unlink(&out.link);
            if (out.layer_shell) |l| l.destroy();
            out.obj.destroy();
            wm.gpa.destroy(out);
        }
        it = next;
    }
}

/// Move every window of `out` to the same workspace index on `dest`. With
/// no destination the windows are left unplaced and re-placed when an
/// output appears (win.new = true).
fn migrate(wm: *WindowManager, out: *Output, dest: ?*Output) void {
    var wi: u32 = 0;
    while (wi < out.workspace_count) : (wi += 1) {
        const src = &out.workspaces[wi];
        while (nextWindowOn(src)) |win| {
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
fn nextWindowOn(ws: *types.Workspace) ?*types.Window {
    if (ws.strip.columns.first()) |c| if (c.windows.first()) |w| return w;
    if (ws.floating.first()) |w| return w;
    return null;
}

// ----------------------------------------------------------------------------
// External monitors (policy in monitors.zig; this is where it meets the model)
// ----------------------------------------------------------------------------

/// Real time in ms on a clock that only goes forward.
pub fn nowMs(wm: *const WindowManager) u64 {
    const ts = std.Io.Clock.awake.now(wm.io);
    return @intCast(@max(0, ts.toMilliseconds()));
}

fn findWl(wm: *WindowManager, obj: *wl.Output) ?*types.WlOutput {
    for (wm.wl_outputs.items) |e| if (e.obj == obj) return e;
    return null;
}

/// Bind a `wl_output` global (main's registry listener): its events carry the
/// connector name, make and model that river's outputs do not.
pub fn bindWlOutput(wm: *WindowManager, registry: *wl.Registry, name: u32, version: u32) void {
    const obj = registry.bind(name, wl.Output, @min(version, 4)) catch |err| {
        log.warn("bind wl_output {d}: {t}", .{ name, err });
        return;
    };
    const e = wm.gpa.create(types.WlOutput) catch return;
    e.* = .{ .obj = obj, .info = .{ .global = name } };
    wm.wl_outputs.append(wm.gpa, e) catch {
        wm.gpa.destroy(e);
        return;
    };
    obj.setListener(*WindowManager, wlOutputListener, wm);
}

fn wlOutputListener(obj: *wl.Output, event: wl.Output.Event, wm: *WindowManager) void {
    const e = findWl(wm, obj) orelse return;
    switch (event) {
        .geometry => |g| {
            e.info.make.set(std.mem.span(g.make));
            e.info.model.set(std.mem.span(g.model));
        },
        .name => |n| e.info.name.set(std.mem.span(n.name)),
        .description => |d| e.info.description.set(std.mem.span(d.description)),
        .scale => |sc| e.info.scale = sc.factor,
        .done => {
            e.info.complete = true;
            var it = wm.outputs.first();
            while (it) |o| : (it = types.nextOutput(o, wm)) copyInfo(wm, o);
            wm.monitors.changed(nowMs(wm));
            wm.obj.manageDirty();
        },
        else => {},
    }
}

/// Take what the matching `wl_output` told us, if river already named it.
fn copyInfo(wm: *WindowManager, out: *Output) void {
    if (out.wl_global == 0) return;
    for (wm.wl_outputs.items) |e| {
        if (e.info.global != out.wl_global or !e.info.complete) continue;
        out.mon = e.info;
        return;
    }
}

/// Note on `win` where it lived, because `out` is going away (or off): it
/// goes back there when that monitor returns. The first home wins, so a
/// window that is moved twice still returns to where the user had it.
pub fn rememberHome(wm: *WindowManager, out: *Output, win: *types.Window, ws_index: u32) void {
    if (win.home.isSet()) return;
    const key = out.mon.key();
    if (key == 0) return;
    if (!monitors.effective(wm.monitors.rules, &out.mon, wm.cfg.workspace_count).restore_windows) return;
    win.home = .{ .key = key, .ws = ws_index };
}

/// Give back to `out` the windows that were taken off it. Returns how many.
/// Windows that are minimized or not placed lose their note without moving.
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
        log.info("{d} window(s) went back to {s}", .{ moved, labelOf(out) });
        wm.follow_request = true;
    }
    return moved;
}

fn labelOf(out: *const Output) []const u8 {
    const S = struct {
        var buf: [200]u8 = undefined;
    };
    return out.mon.label(&S.buf);
}

fn otherLive(wm: *WindowManager, except: *Output) bool {
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (o != except and types.liveOutput(o)) return true;
    }
    return false;
}

const Hook = enum { connect, disconnect };

fn runHook(wm: *WindowManager, out: *Output, which: Hook) void {
    const r = monitors.findRule(wm.monitors.rules, &out.mon) orelse return;
    const argv = switch (which) {
        .connect => r.on_connect,
        .disconnect => r.on_disconnect,
    };
    if (argv.len == 0) return;
    log.info("monitor {s}: running its on_{t} command", .{ labelOf(out), which });
    proc.spawn(wm, argv);
}

/// Apply the rule that matches `out`: on/off, primary, workspace count, the
/// first workspace, the windows that belong here. Safe to repeat (a reload
/// does); the first workspace and the connect hook are used once per
/// connection. Manage sequence only.
pub fn applyRule(wm: *WindowManager, out: *Output) void {
    if (out.removed) return;
    const eff = monitors.effective(wm.monitors.rules, &out.mon, wm.cfg.workspace_count);
    const first = !out.settled;
    out.settled = true;
    out.primary = eff.primary and eff.enabled;

    if (!eff.enabled) {
        if (!out.disabled) {
            if (otherLive(wm, out)) {
                out.disabled = true;
                log.info("monitor {s} is switched off by its rule", .{labelOf(out)});
                migrate(wm, out, types.primaryOutput(wm));
            } else {
                log.warn("monitor {s}: its rule switches it off, but it is the only one; kept on", .{labelOf(out)});
            }
        }
    } else if (out.disabled) {
        out.disabled = false;
        log.info("monitor {s} is switched on again", .{labelOf(out)});
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

/// Called every manage sequence: once the monitors have been quiet for
/// `monitor_settle_ms`, apply the rules and pick the profile for what is
/// connected now. How long the event loop may sleep for it: `settleWaitMs`.
pub fn settle(wm: *WindowManager) void {
    const now = nowMs(wm);
    if (!wm.monitors.settle.due(now)) return;
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

pub fn settleWaitMs(wm: *const WindowManager) ?i32 {
    return wm.monitors.settle.waitMs(nowMs(wm));
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "sanitize: a work area that is empty or tiny is refused, a sensible one is kept" {
    const full: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };

    // Empty or inverted: never usable.
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = 0, .h = 1080 }, full) == null);
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = 1920, .h = 0 }, full) == null);
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = -5, .h = 1080 }, full) == null);
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = 1920, .h = -5 }, full) == null);

    // A bar that reserves nearly the whole screen: smaller than a quarter of
    // the output in either direction is not trusted ...
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = 479, .h = 1080 }, full) == null);
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = 1920, .h = 269 }, full) == null);

    // ... exactly a quarter, and everything bigger, is.
    const quarter = sanitize(.{ .x = 0, .y = 0, .w = 480, .h = 270 }, full).?;
    try std.testing.expectEqual(@as(i32, 480), quarter.w);
    try std.testing.expectEqual(@as(i32, 270), quarter.h);

    // The usual case: a 30 px bar at the top. The rectangle is returned as it is.
    const below_bar = sanitize(.{ .x = 0, .y = 30, .w = 1920, .h = 1050 }, full).?;
    try std.testing.expectEqual(@as(i32, 30), below_bar.y);
    try std.testing.expectEqual(@as(i32, 1050), below_bar.h);
}

test "sanitize: without a known output size only an empty area is refused" {
    const unknown: Rect = .{};
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, unknown) != null);
    try std.testing.expect(sanitize(.{ .x = 0, .y = 0, .w = 0, .h = 10 }, unknown) == null);
}

