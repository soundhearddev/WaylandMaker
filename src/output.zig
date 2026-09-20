// SPDX-License-Identifier: 0BSD
//
// river_output_v1 and river_layer_shell_output_v1.
//
// The layer-shell `non_exclusive_area` is the rectangle left over after
// bars and docks have reserved their space. Windows tile inside it, so a
// bar never overlaps the layout.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const workspace = @import("workspace.zig");

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

    if (wm.layer_shell) |ls| bindLayerShell(wm, ls, out);
    return out;
}

/// Ask river for the layer-shell area of `out`. Called on creation, and
/// again for outputs that existed before the layer-shell global appeared.
pub fn bindLayerShell(wm: *WindowManager, ls: *river.LayerShellV1, out: *Output) void {
    if (out.layer_shell != null) return;
    const lso = ls.getOutput(out.obj) catch |err| {
        std.log.err("layer_shell.get_output failed: {t}", .{err});
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
            wm.obj.manageDirty();
        },
        .position => |p| {
            out.rect.x = p.x;
            out.rect.y = p.y;
            wm.obj.manageDirty();
        },
        .dimensions => |d| {
            out.rect.w = d.width;
            out.rect.h = d.height;
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
            const target = firstLive(wm, out);
            migrate(wm, out, target);
            types.unlink(&out.link);
            if (out.layer_shell) |l| l.destroy();
            out.obj.destroy();
            wm.gpa.destroy(out);
        }
        it = next;
    }
}

fn firstLive(wm: *WindowManager, except: *Output) ?*Output {
    var it = wm.outputs.first();
    while (it) |o| : (it = types.nextOutput(o, wm)) {
        if (o != except and !o.removed) return o;
    }
    return null;
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
