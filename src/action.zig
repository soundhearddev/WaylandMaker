const std = @import("std");

const types = @import("types.zig");

const Action = types.Action;
const WindowManager = types.WindowManager;

/// Runs directly from the xkb_binding `pressed` event callback (see
/// seat.xkbBindingListener), which happens *before* the manage_start that
/// the protocol guarantees always follows it. river_seat_v1.focus_window
/// and other window-management requests may only be made *during* a
/// manage sequence, so this function must not call them directly -- it
/// only mutates our own plain data (active_column, workspace index, ...)
/// and stashes anything that needs a real Wayland request into
/// wm.pending_focus / wm.pending_spawn / wm.needs_layout for main.zig's
/// handleManageStart to apply once manage_start actually arrives.
pub fn handleAction(wm: *WindowManager, action: Action) void {
    switch (action) {
        .none => {},

        .exit => {
            std.log.info("[ACTION] Exiting wmaker-wl...", .{});
            std.process.exit(0);
        },

        .spawn_terminal => {
            wm.pending_spawn = &types.Config.terminal_cmd;
        },

        .close => {
            // river_window_v1.close is window-management state (manage-
            // sequence-only), so defer it like focus_window -- see
            // pending_close's doc comment in types.zig.
            wm.pending_close = activeWindow(wm);
        },

        .focus_prev_column => {
            if (activeStrip(wm)) |strip| {
                const col = strip.active_column orelse return;
                if (types.prevColumn(col)) |prev_col| {
                    strip.active_column = prev_col;
                    wm.pending_focus = prev_col.focusedWindow();
                    wm.needs_layout = true;
                }
            }
        },

        .focus_next_column => {
            if (activeStrip(wm)) |strip| {
                const col = strip.active_column orelse return;
                if (types.nextColumn(col)) |next_col| {
                    strip.active_column = next_col;
                    wm.pending_focus = next_col.focusedWindow();
                    wm.needs_layout = true;
                }
            }
        },

        .focus_next_window => {
            // Cycle focus within the active column: if there's more than
            // one window stacked in it, move to the next one (wrapping to
            // the first). Single-window columns have nothing to cycle.
            if (activeStrip(wm)) |strip| {
                const col = strip.active_column orelse return;
                const current = col.focusedWindow() orelse return;
                const next = types.nextWindowInColumn(current) orelse col.windows.first() orelse return;
                if (next != current) {
                    // Move `next` to the tail so focusedWindow() (which
                    // returns .last()) picks it up next time.
                    next.column_link.remove();
                    col.windows.append(next);
                    wm.pending_focus = next;
                    wm.needs_layout = true;
                }
            }
        },

        .workspace_1 => switchWorkspace(wm, 0),
        .workspace_2 => switchWorkspace(wm, 1),
        .workspace_3 => switchWorkspace(wm, 2),
        .workspace_4 => switchWorkspace(wm, 3),

        .toggle_omnipresent => {
            if (activeWindow(wm)) |win| {
                win.is_omnipresent = !win.is_omnipresent;
            }
        },

        .move, .resize => {
            // Interactive move/resize needs an op_start_pointer request,
            // which -- like focus_window -- is manage-sequence-only. Not
            // wired up yet; see docs/TODO.md.
        },
    }
}

fn activeStrip(wm: *WindowManager) ?*types.Strip {
    const out = wm.outputs.first() orelse return null;
    return &out.activeWorkspace().strip;
}

fn activeWindow(wm: *WindowManager) ?*types.Window {
    const strip = activeStrip(wm) orelse return null;
    return strip.focusedWindow();
}

fn switchWorkspace(wm: *WindowManager, index: u32) void {
    const out = wm.outputs.first() orelse return;
    if (out.active_workspace == index) return;

    out.switchWorkspace(index);
    wm.pending_focus = out.activeWorkspace().strip.focusedWindow();
    wm.needs_layout = true;
}
