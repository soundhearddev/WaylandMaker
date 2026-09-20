// SPDX-License-Identifier: 0BSD
//
// Every structural change to the window tree lives here, so the
// invariants documented in types.zig hold by construction. No Wayland
// requests are made in this file: it only edits our own model. main.zig /
// action.zig decide what to tell river afterwards.
//
// All functions that can fail to allocate leave the model unchanged when
// they return an error.

const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");
const config = @import("config.zig");

const Window = types.Window;
const Column = types.Column;
const Strip = types.Strip;
const Workspace = types.Workspace;
const Output = types.Output;
const WindowManager = types.WindowManager;
const unlink = types.unlink;

// ----------------------------------------------------------------------------
// Low-level list surgery. wl.list only has "insert after". These are the
// only places that touch prev/next of columns and windows.
// ----------------------------------------------------------------------------

fn insertColumnAfter(strip: *Strip, after: ?*Column, col: *Column) void {
    if (after) |a| {
        a.link.insert(&col.link);
    } else {
        // Before everything: insert directly after the head sentinel.
        strip.columns.prepend(col);
    }
}

fn insertWindowAfter(col: *Column, after: ?*Window, win: *Window) void {
    if (after) |a| {
        a.column_link.insert(&win.column_link);
    } else {
        col.windows.prepend(win);
    }
    win.column = col;
}

/// Insert `col` so it ends up at position `index` (0 = leftmost); indices
/// past the end append.
fn insertColumnAtIndex(strip: *Strip, col: *Column, index: usize) void {
    var i: usize = 0;
    var prev: ?*Column = null;
    var it = strip.columns.first();
    while (it) |c| : (it = types.nextCol(c)) {
        if (i == index) break;
        prev = c;
        i += 1;
    }
    insertColumnAfter(strip, prev, col);
}

pub fn columnIndex(strip: *Strip, target: *Column) usize {
    var i: usize = 0;
    var it = strip.columns.first();
    while (it) |c| : (it = types.nextCol(c)) {
        if (c == target) return i;
        i += 1;
    }
    return i;
}

// ----------------------------------------------------------------------------
// Column creation / destruction
// ----------------------------------------------------------------------------

fn newColumn(wm: *WindowManager, strip: *Strip, width: i32) !*Column {
    const col = try wm.gpa.create(Column);
    col.* = .{
        .strip = strip,
        .windows = undefined,
        .width = width,
    };
    col.windows.init();
    return col;
}

/// Destroy `col` (must be empty). Repairs `strip.active`.
fn destroyColumn(wm: *WindowManager, col: *Column) void {
    std.debug.assert(col.windows.empty());
    const strip = col.strip;
    if (strip.active == col) {
        strip.active = types.nextCol(col) orelse types.prevCol(col);
    }
    unlink(&col.link);
    wm.gpa.destroy(col);
}

fn defaultWidth(wm: *WindowManager, out: *Output) i32 {
    return layout.columnWidthFor(out.workArea().w, wm.cfg.default_column_width, &wm.cfg);
}

// ----------------------------------------------------------------------------
// Placement
// ----------------------------------------------------------------------------

/// Place a brand-new (unplaced) window as tiled on `ws`, honouring
/// `new_window` mode. Makes it the active window of that workspace.
pub fn placeTiled(wm: *WindowManager, ws: *Workspace, win: *Window) !void {
    std.debug.assert(win.workspace == null);
    const strip = &ws.strip;

    if (wm.cfg.new_window == .stack) {
        if (strip.active) |col| {
            insertWindowAfter(col, col.active(), win);
            col.focused = win;
            win.mode = .tiled;
            win.workspace = ws;
            return;
        }
    }

    const col = try newColumn(wm, strip, defaultWidth(wm, ws.output));
    insertWindowAfter(col, null, win);
    col.focused = win;
    insertColumnAfter(strip, strip.active, col);
    strip.active = col;

    win.mode = .tiled;
    win.workspace = ws;
}

pub fn placeFloating(ws: *Workspace, win: *Window) void {
    std.debug.assert(win.workspace == null or win.workspace == ws);
    ws.floating.append(win);
    win.mode = .floating;
    win.workspace = ws;
    win.column = null;
}

/// Take `win` out of the layout entirely. After this call the window is
/// in no column, no floating list and is not fullscreen
/// (`win.workspace == null`). Safe to call on an unplaced window.
pub fn unplace(wm: *WindowManager, win: *Window) void {
    const ws = win.workspace orelse return;

    if (ws.fullscreen == win) ws.fullscreen = null;
    if (ws.last_focused == win) ws.last_focused = null;

    // A window is a member of a column (tiled, or fullscreen that came
    // from tiled) or of the floating list (floating, or fullscreen that
    // came from floating) -- never both. Removing from both is harmless
    // because unlink()/detach are no-ops for a window that isn't in one.
    detachFromColumn(wm, win);
    unlink(&win.floating_link);

    win.workspace = null;
    win.column = null;
}

/// Remove `win` from its column, destroying the column if it becomes
/// empty and repairing focus pointers. Does not touch `win.workspace`.
fn detachFromColumn(wm: *WindowManager, win: *Window) void {
    const col = win.column orelse return;

    const neighbour = types.nextWin(win) orelse types.prevWin(win);
    if (col.focused == win) col.focused = neighbour;

    unlink(&win.column_link);
    win.column = null;

    if (col.windows.empty()) destroyColumn(wm, col);
}

// ----------------------------------------------------------------------------
// Mode changes
// ----------------------------------------------------------------------------

/// tiled -> floating. The window keeps the size it had on screen, so it
/// does not visibly jump, unless the caller already gave it a rect.
pub fn floatWindow(wm: *WindowManager, win: *Window) void {
    if (win.mode != .tiled) return;
    const ws = win.workspace orelse return;
    const out = ws.output;

    // Remember where to go back to.
    if (win.column) |col| {
        win.saved_column_index = columnIndex(&ws.strip, col);
        win.saved_column_width = col.width;
    }

    // Start floating exactly where the tiled window is now, so toggling
    // does not make it jump. `target` is the content rect in global
    // coordinates; float_rect is the content rect relative to the output.
    win.float_rect = .{
        .x = win.target.x - out.rect.x,
        .y = win.target.y - out.rect.y,
        .w = win.target.w,
        .h = win.target.h,
    };
    win.has_float_rect = true;

    detachFromColumn(wm, win);
    ws.floating.append(win);
    win.mode = .floating;
}

/// floating -> tiled. Goes back to the column it left if that position
/// still exists, otherwise opens a new column at the remembered index.
pub fn tileWindow(wm: *WindowManager, win: *Window) void {
    if (win.mode != .floating) return;
    const ws = win.workspace orelse return;
    const strip = &ws.strip;

    unlink(&win.floating_link);

    const col = newColumn(wm, strip, if (win.saved_column_width > 0)
        win.saved_column_width
    else
        defaultWidth(wm, ws.output)) catch {
        // Could not allocate: stay floating instead of losing the window.
        ws.floating.append(win);
        return;
    };
    insertWindowAfter(col, null, win);
    col.focused = win;
    insertColumnAtIndex(strip, col, win.saved_column_index);
    strip.active = col;

    win.mode = .tiled;
}

pub fn setFullscreen(wm: *WindowManager, win: *Window) void {
    _ = wm;
    if (win.mode == .fullscreen) return;
    const ws = win.workspace orelse return;

    // Only one fullscreen window per workspace: the previous one drops
    // back to where it came from.
    if (ws.fullscreen) |old| leaveFullscreen(old);

    switch (win.mode) {
        .tiled => {
            // Stay a *member* of the column so the strip keeps its shape;
            // fullscreen is a display state on top of it.
            win.restore = .tiled;
        },
        .floating => {
            win.restore = .floating;
        },
        .fullscreen => unreachable,
    }
    // Keep column / floating membership; only the mode flag and the
    // workspace's pointer change. (I2 relaxes for fullscreen: see below.)
    win.mode = .fullscreen;
    ws.fullscreen = win;
}

pub fn leaveFullscreen(win: *Window) void {
    if (win.mode != .fullscreen) return;
    const ws = win.workspace orelse return;
    if (ws.fullscreen == win) ws.fullscreen = null;
    win.mode = switch (win.restore) {
        .tiled => .tiled,
        .floating => .floating,
    };
}

// ----------------------------------------------------------------------------
// Moving between workspaces / outputs
// ----------------------------------------------------------------------------

pub fn moveToWorkspace(wm: *WindowManager, win: *Window, dest: *Workspace) !void {
    const src = win.workspace orelse return;
    if (src == dest) return;

    const was_floating = win.mode == .floating or (win.mode == .fullscreen and win.restore == .floating);
    const rect = win.float_rect;
    const had_rect = win.has_float_rect;

    leaveFullscreen(win);
    unplace(wm, win);

    if (was_floating) {
        placeFloating(dest, win);
        win.float_rect = rect;
        win.has_float_rect = had_rect;
    } else {
        try placeTiled(wm, dest, win);
    }
}

// ----------------------------------------------------------------------------
// Column / window rearrangement (tiled only)
// ----------------------------------------------------------------------------

pub fn moveColumn(strip: *Strip, dir: enum { left, right, first, last }) bool {
    const col = strip.active orelse return false;
    switch (dir) {
        .left => {
            const prev = types.prevCol(col) orelse return false;
            unlink(&col.link);
            insertColumnAfter(strip, types.prevCol(prev), col);
        },
        .right => {
            const next = types.nextCol(col) orelse return false;
            unlink(&col.link);
            insertColumnAfter(strip, next, col);
        },
        .first => {
            if (types.prevCol(col) == null) return false;
            unlink(&col.link);
            insertColumnAfter(strip, null, col);
        },
        .last => {
            if (types.nextCol(col) == null) return false;
            unlink(&col.link);
            strip.columns.append(col);
        },
    }
    return true;
}

pub fn moveWindowVertical(win: *Window, dir: enum { up, down }) bool {
    const col = win.column orelse return false;
    switch (dir) {
        .up => {
            const prev = types.prevWin(win) orelse return false;
            unlink(&win.column_link);
            insertWindowAfter(col, types.prevWin(prev), win);
        },
        .down => {
            const next = types.nextWin(win) orelse return false;
            unlink(&win.column_link);
            insertWindowAfter(col, next, win);
        },
    }
    return true;
}

/// Pull the active window into the column on its left (stacking it).
pub fn consumeLeft(wm: *WindowManager, strip: *Strip) bool {
    const col = strip.active orelse return false;
    const win = col.active() orelse return false;
    const left = types.prevCol(col) orelse return false;

    const neighbour = types.nextWin(win) orelse types.prevWin(win);
    if (col.focused == win) col.focused = neighbour;
    unlink(&win.column_link);

    insertWindowAfter(left, left.windows.last(), win);
    left.focused = win;
    strip.active = left;

    if (col.windows.empty()) destroyColumn(wm, col);
    return true;
}

/// Push the active window out of a stacked column into a new column on
/// its right.
pub fn expelRight(wm: *WindowManager, strip: *Strip) bool {
    const col = strip.active orelse return false;
    if (col.count() < 2) return false;
    const win = col.active() orelse return false;

    const new_col = newColumn(wm, strip, col.width) catch return false;

    const neighbour = types.nextWin(win) orelse types.prevWin(win);
    if (col.focused == win) col.focused = neighbour;
    unlink(&win.column_link);

    insertWindowAfter(new_col, null, win);
    new_col.focused = win;
    insertColumnAfter(strip, col, new_col);
    strip.active = new_col;
    return true;
}

// ----------------------------------------------------------------------------
// Column width
// ----------------------------------------------------------------------------

/// niri's maximize-column: the column takes the whole work area (inside the
/// gaps); calling it again restores the previous width.
pub fn toggleMaximized(wm: *WindowManager, col: *Column) void {
    if (col.unmaximized_width != 0) {
        col.width = col.unmaximized_width;
        col.unmaximized_width = 0;
        return;
    }
    const out = col.strip.workspace.output;
    col.unmaximized_width = col.width;
    col.width = layout.columnWidthFor(out.workArea().w, 1.0, &wm.cfg);
}

// ----------------------------------------------------------------------------
// Focus helpers
// ----------------------------------------------------------------------------

/// Make `win` the active window of its workspace in our model (the strip's
/// active column / the workspace's last-focused floating window). Does not
/// talk to river; see seat.focus.
pub fn activate(win: *Window) void {
    const ws = win.workspace orelse return;
    ws.last_focused = win;
    switch (win.mode) {
        .tiled => if (win.column) |col| {
            col.focused = win;
            col.strip.active = col;
        },
        .floating => raise(win),
        .fullscreen => if (win.restore == .tiled) {
            if (win.column) |col| {
                col.focused = win;
                col.strip.active = col;
            }
        } else raise(win),
    }
}

/// Move a floating window to the top of the z-order.
pub fn raise(win: *Window) void {
    const ws = win.workspace orelse return;
    if (!types.isLinked(&win.floating_link)) return;
    if (ws.floating.last() == win) return;
    unlink(&win.floating_link);
    ws.floating.append(win);
}

// ----------------------------------------------------------------------------
// Finding things
// ----------------------------------------------------------------------------

/// The window that should have keyboard focus on `ws` when nothing better
/// is known.
pub fn defaultFocus(ws: *Workspace) ?*Window {
    if (ws.fullscreen) |f| return f;
    if (ws.last_focused) |w| return w;
    if (ws.strip.activeWindow()) |w| return w;
    return ws.floating.last();
}

pub fn wsIndexOf(wm: *WindowManager, win: *Window) ?u32 {
    _ = wm;
    const ws = win.workspace orelse return null;
    return ws.index;
}
