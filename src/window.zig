// SPDX-License-Identifier: 0BSD
//
// river_window_v1 lifecycle and all strip/column manipulation: placing a
// new window, closing, moving columns, stacking/unstacking, resizing.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");

const WindowManager = types.WindowManager;
const Window = types.Window;
const Column = types.Column;
const Strip = types.Strip;
const Output = types.Output;
const Config = types.Config;

/// The window listener only gets the Window as context, but `closed` has to
/// reach the WindowManager. There is exactly one WindowManager per process.
pub var global_wm: ?*WindowManager = null;

pub fn create(wm: *WindowManager, river_win: *river.WindowV1) !*Window {
    const win = try wm.gpa.create(Window);
    win.* = .{
        .obj = river_win,
        .link = undefined,
    };
    wm.windows.append(win);
    river_win.setListener(*Window, listener, win);
    return win;
}

fn listener(river_win: *river.WindowV1, event: river.WindowV1.Event, win: *Window) void {
    const wm = global_wm orelse return;
    switch (event) {
        .dimensions => {
            // river sends this after every propose_dimensions. Do NOT
            // request another manage sequence here: manage -> propose ->
            // dimensions -> manage would loop forever. We only note that
            // the window is now mapped-ready. The very first dimensions
            // event does need a manage pass so the window gets its
            // focus/borders, hence the one-shot `ready` transition.
            if (!win.ready) {
                win.ready = true;
                wm.needs_layout = true;
                if (wm.obj) |o| o.manageDirty();
            }
        },
        .closed => {
            markClosed(wm, win);
            river_win.destroy();
        },
        .pointer_move_requested,
        .pointer_resize_requested,
        .fullscreen_requested,
        .maximize_requested,
        .minimize_requested,
        => {
            // Acknowledged but not implemented yet; ignoring is legal.
        },
        else => {},
    }
}

// ----------------------------------------------------------------------------
// Placement
// ----------------------------------------------------------------------------

/// Called from manage_start for every window still flagged `new`.
/// Must run inside a manage sequence (uses window-management requests).
pub fn manage(win: *Window, wm: *WindowManager) void {
    win.new = false;
    win.obj.useSsd();

    if (win.node == null) {
        win.node = win.obj.getNode() catch |err| {
            std.log.err("[WINDOW] getNode failed: {}", .{err});
            return;
        };
    }

    const out = wm.outputs.first() orelse {
        // No output yet: leave the window unplaced; it will be picked up
        // again because we set `new` back.
        win.new = true;
        return;
    };

    const ws = out.activeWorkspace();
    insertNewColumn(&ws.strip, win, wm.gpa, out.rect());

    wm.pending_focus = win;
    wm.needs_layout = true;
}

/// Open a fresh column right after the active one holding `win`.
pub fn insertNewColumn(strip: *Strip, win: *Window, gpa: std.mem.Allocator, usable: types.Rectangle) void {
    const col = gpa.create(Column) catch return;
    col.* = .{
        .strip = strip,
        .link = undefined,
        .width = layout.defaultColumnWidth(usable.width),
        .windows = undefined,
    };
    col.windows.init();
    col.windows.append(win);
    win.column = col;
    col.focused = win;

    if (strip.active_column) |active| {
        // Insert right after the active column (niri behaviour).
        insertColumnAfter(active, col);
    } else {
        strip.columns.append(col);
    }
    strip.active_column = col;
}

fn insertColumnAfter(after: *Column, col: *Column) void {
    const next = after.link.next.?;
    col.link.prev = &after.link;
    col.link.next = next;
    after.link.next = &col.link;
    next.prev = &col.link;
}

// ----------------------------------------------------------------------------
// Removal
// ----------------------------------------------------------------------------

fn markClosed(wm: *WindowManager, win: *Window) void {
    win.closed = true;
    detach(wm, win);

    if (wm.pending_focus == win) wm.pending_focus = null;
    if (wm.pending_close == win) wm.pending_close = null;

    var sit = wm.seats.first();
    while (sit) |s| : (sit = types.nextSeat(s, wm)) {
        if (s.focused == win) s.focused = null;
    }

    win.link.remove();
    wm.gpa.destroy(win);
    wm.needs_layout = true;
}

/// Take a window out of its column, delete the column if it became empty and
/// re-target focus so the strip never points at a dead column.
fn detach(wm: *WindowManager, win: *Window) void {
    const col = win.column orelse return;
    const strip = col.strip;
    const was_active = strip.active_column == col;

    const neighbour_win = types.nextWindowInColumn(win) orelse types.prevWindowInColumn(win);

    win.column_link.remove();
    win.column = null;

    if (col.focused == win) col.focused = neighbour_win;

    if (col.isEmpty()) {
        const fallback = types.nextColumn(col) orelse types.prevColumn(col);
        col.link.remove();
        if (was_active) strip.active_column = fallback;
        wm.gpa.destroy(col);
    }

    if (was_active) {
        wm.pending_focus = if (strip.active_column) |a| a.focusedWindow() else null;
    }
}

// ----------------------------------------------------------------------------
// Focus helpers
// ----------------------------------------------------------------------------

/// Make `win`'s column active and remember it as the column's focused
/// window (used when the pointer or a keybind moves focus).
pub fn setActive(win: *Window) void {
    const col = win.column orelse return;
    col.focused = win;
    col.strip.active_column = col;
}

// ----------------------------------------------------------------------------
// Column / window rearrangement (called from action.zig)
// ----------------------------------------------------------------------------

pub fn moveColumnLeft(strip: *Strip) void {
    const col = strip.active_column orelse return;
    const prev = types.prevColumn(col) orelse return;
    col.link.remove();
    // Re-insert *before* prev: that is "after prev.prev".
    const before = prev.link.prev.?;
    col.link.prev = before;
    col.link.next = &prev.link;
    before.next = &col.link;
    prev.link.prev = &col.link;
}

pub fn moveColumnRight(strip: *Strip) void {
    const col = strip.active_column orelse return;
    const next = types.nextColumn(col) orelse return;
    col.link.remove();
    insertColumnAfter(next, col);
}

pub fn moveWindowUp(win: *Window) void {
    const prev = types.prevWindowInColumn(win) orelse return;
    win.column_link.remove();
    const before = prev.column_link.prev.?;
    win.column_link.prev = before;
    win.column_link.next = &prev.column_link;
    before.next = &win.column_link;
    prev.column_link.prev = &win.column_link;
}

pub fn moveWindowDown(win: *Window) void {
    const next = types.nextWindowInColumn(win) orelse return;
    win.column_link.remove();
    const after = next.column_link.next.?;
    win.column_link.prev = &next.column_link;
    win.column_link.next = after;
    next.column_link.next = &win.column_link;
    after.prev = &win.column_link;
}

/// Pull the focused window into the column on its left, stacking it.
pub fn consumeLeft(wm: *WindowManager, strip: *Strip) void {
    const col = strip.active_column orelse return;
    const win = col.focusedWindow() orelse return;
    const left = types.prevColumn(col) orelse return;

    win.column_link.remove();
    win.column = left;
    left.windows.append(win);
    left.focused = win;

    if (col.isEmpty()) {
        col.link.remove();
        wm.gpa.destroy(col);
    } else {
        col.focused = col.windows.first();
    }
    strip.active_column = left;
}

/// Push the focused window out of a stacked column into a new column on
/// its right. A single-window column has nothing to expel.
pub fn expelRight(wm: *WindowManager, strip: *Strip, usable: types.Rectangle) void {
    const col = strip.active_column orelse return;
    if (col.windowCount() < 2) return;
    const win = col.focusedWindow() orelse return;

    const neighbour = types.nextWindowInColumn(win) orelse types.prevWindowInColumn(win);
    win.column_link.remove();
    win.column = null;
    col.focused = neighbour;

    const new_col = wm.gpa.create(Column) catch {
        // Put it back if we cannot allocate.
        col.windows.append(win);
        win.column = col;
        return;
    };
    new_col.* = .{
        .strip = strip,
        .link = undefined,
        .width = col.width,
        .windows = undefined,
    };
    _ = usable;
    new_col.windows.init();
    new_col.windows.append(win);
    new_col.focused = win;
    win.column = new_col;

    insertColumnAfter(col, new_col);
    strip.active_column = new_col;
}

/// Move the focused window to another workspace on the same output.
pub fn sendToWorkspace(wm: *WindowManager, out: *Output, index: u32) void {
    if (index >= Config.workspace_count or index == out.active_workspace) return;

    const src = &out.activeWorkspace().strip;
    const col = src.active_column orelse return;
    const win = col.focusedWindow() orelse return;

    detach(wm, win);

    const dst = &out.workspaces[index].strip;
    insertNewColumn(dst, win, wm.gpa, out.rect());
    // insertNewColumn made it the active column of the *other* workspace;
    // focus stays on the current one.
    wm.needs_layout = true;
}
