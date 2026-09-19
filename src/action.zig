// SPDX-License-Identifier: 0BSD
//
// Keybinding actions. Every function here runs from manage_start (see
// main.zig), i.e. INSIDE a manage sequence, so window-management requests
// like focus_window / close are legal. Actions mostly just edit our own
// data model; main.zig then lays it out and pushes the result to river.

const std = @import("std");

const types = @import("types.zig");
const layout = @import("layout.zig");
const window = @import("window.zig");

const Action = types.Action;
const WindowManager = types.WindowManager;
const Strip = types.Strip;
const Config = types.Config;

pub fn run(wm: *WindowManager, act: Action) void {
    const out = wm.outputs.first();
    const strip: ?*Strip = if (out) |o| &o.activeWorkspace().strip else null;

    switch (act) {
        .none => {},

        // ---- spawning ---------------------------------------------------
        .spawn_terminal => wm.pending_spawn = &Config.terminal_cmd,
        .spawn_launcher => wm.pending_spawn = &Config.launcher_cmd,
        .spawn_browser => wm.pending_spawn = &Config.browser_cmd,

        // ---- session / window -------------------------------------------
        .exit => {
            std.log.info("[ACTION] exit requested", .{});
            wm.quit = true;
        },
        .close => {
            const s = strip orelse return;
            wm.pending_close = s.focusedWindow();
        },

        .toggle_floating => {
            const seat = wm.seats.first() orelse return;
            const win = seat.focused orelse return;

            window.setFloating(wm, win, !win.floating);

            wm.pending_focus = win;
            wm.needs_layout = true;
        },

        // ---- focus ------------------------------------------------------
        .focus_left => {
            const s = strip orelse return;
            const col = s.active_column orelse return;
            const prev = types.prevColumn(col) orelse return;
            focusColumn(wm, s, prev);
        },
        .focus_right => {
            const s = strip orelse return;
            const col = s.active_column orelse return;
            const next = types.nextColumn(col) orelse return;
            focusColumn(wm, s, next);
        },
        .focus_up => {
            const s = strip orelse return;
            const win = s.focusedWindow() orelse return;
            const target = types.prevWindowInColumn(win) orelse return;
            focusWindow(wm, target);
        },
        .focus_down => {
            const s = strip orelse return;
            const win = s.focusedWindow() orelse return;
            const target = types.nextWindowInColumn(win) orelse return;
            focusWindow(wm, target);
        },
        .focus_first_column => {
            const s = strip orelse return;
            const first = s.columns.first() orelse return;
            focusColumn(wm, s, first);
        },
        .focus_last_column => {
            const s = strip orelse return;
            const last = s.columns.last() orelse return;
            focusColumn(wm, s, last);
        },

        // ---- rearranging ------------------------------------------------
        .move_column_left => {
            const s = strip orelse return;
            window.moveColumnLeft(s);
            followFocus(wm, s);
        },
        .move_column_right => {
            const s = strip orelse return;
            window.moveColumnRight(s);
            followFocus(wm, s);
        },
        .move_window_up => {
            const s = strip orelse return;
            const win = s.focusedWindow() orelse return;
            window.moveWindowUp(win);
            wm.needs_layout = true;
        },
        .move_window_down => {
            const s = strip orelse return;
            const win = s.focusedWindow() orelse return;
            window.moveWindowDown(win);
            wm.needs_layout = true;
        },
        .consume_left => {
            const s = strip orelse return;
            window.consumeLeft(wm, s);
            followFocus(wm, s);
        },
        .expel_right => {
            const s = strip orelse return;
            const o = out orelse return;
            window.expelRight(wm, s, o.rect());
            followFocus(wm, s);
        },

        // ---- sizing -----------------------------------------------------
        .cycle_column_width => {
            const s = strip orelse return;
            const o = out orelse return;
            const col = s.active_column orelse return;
            col.width = nextPresetWidth(o.width, col.width);
            followFocus(wm, s);
        },
        .widen_column => resizeActive(wm, strip, out, Config.width_step),
        .narrow_column => resizeActive(wm, strip, out, -Config.width_step),

        // ---- workspaces -------------------------------------------------
        .workspace_1 => switchWorkspace(wm, 0),
        .workspace_2 => switchWorkspace(wm, 1),
        .workspace_3 => switchWorkspace(wm, 2),
        .workspace_4 => switchWorkspace(wm, 3),
        .move_to_workspace_1 => sendTo(wm, 0),
        .move_to_workspace_2 => sendTo(wm, 1),
        .move_to_workspace_3 => sendTo(wm, 2),
        .move_to_workspace_4 => sendTo(wm, 3),
    }
}

// ----------------------------------------------------------------------------

fn focusColumn(wm: *WindowManager, strip: *Strip, col: *types.Column) void {
    strip.active_column = col;
    wm.pending_focus = col.focusedWindow();
    wm.needs_layout = true;
}

fn focusWindow(wm: *WindowManager, win: *types.Window) void {
    window.setActive(win);
    wm.pending_focus = win;
    wm.needs_layout = true;
}

/// After a structural change keep keyboard focus on the active column.
fn followFocus(wm: *WindowManager, strip: *Strip) void {
    wm.pending_focus = strip.focusedWindow();
    wm.needs_layout = true;
}

fn nextPresetWidth(output_width: i32, current: i32) i32 {
    // Pick the first preset strictly wider than the current width, or wrap
    // around to the smallest one.
    for (Config.width_presets) |f| {
        const w = layout.widthForFraction(output_width, f);
        if (w > current + 2) return w;
    }
    return layout.widthForFraction(output_width, Config.width_presets[0]);
}

fn resizeActive(wm: *WindowManager, strip: ?*Strip, out: ?*types.Output, delta_fraction: f64) void {
    const s = strip orelse return;
    const o = out orelse return;
    const col = s.active_column orelse return;

    const avail: f64 = @floatFromInt(@max(1, o.width - Config.gap * 2));
    const delta: i32 = @intFromFloat(avail * delta_fraction);
    const max_w = @max(Config.min_column_width, o.width - Config.gap * 2);
    col.width = std.math.clamp(col.width + delta, Config.min_column_width, max_w);
    followFocus(wm, s);
}

fn switchWorkspace(wm: *WindowManager, index: u32) void {
    const out = wm.outputs.first() orelse return;
    if (index >= Config.workspace_count or out.active_workspace == index) return;

    out.active_workspace = index;
    wm.pending_focus = out.activeWorkspace().strip.focusedWindow();
    wm.needs_layout = true;
}

fn sendTo(wm: *WindowManager, index: u32) void {
    const out = wm.outputs.first() orelse return;
    window.sendToWorkspace(wm, out, index);
}
