// SPDX-License-Identifier: 0BSD
//
// river_seat_v1 lifecycle and keybindings.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const cfgmod = @import("config.zig");

const Seat = types.Seat;
const WindowManager = types.WindowManager;
const Action = types.Action;
const XkbBinding = types.XkbBinding;
const Config = types.Config;
const Modifiers = river.SeatV1.Modifiers;

pub fn create(wm: *WindowManager, river_seat: *river.SeatV1) !*Seat {
    const seat = try wm.gpa.create(Seat);
    seat.* = .{
        .obj = river_seat,
        .link = undefined,
        .xkb_bindings = undefined,
        // Bindings are created + enabled from manage_start.
        .needs_binding_setup = true,
    };
    seat.xkb_bindings.init();

    wm.seats.append(seat);
    river_seat.setListener(*WindowManager, listener, wm);
    return seat;
}

fn find(wm: *WindowManager, river_seat: *river.SeatV1) ?*Seat {
    var it = wm.seats.first();
    while (it) |s| : (it = types.nextSeat(s, wm)) {
        if (s.obj == river_seat) return s;
    }
    return null;
}

fn listener(river_seat: *river.SeatV1, event: river.SeatV1.Event, wm: *WindowManager) void {
    const seat = find(wm, river_seat) orelse return;
    switch (event) {
        .removed => {
            seat.removed = true;
        },
        .window_interaction => |ev| {
            // Click-to-focus: an interaction moves focus to that window.
            var it = wm.windows.first();
            while (it) |w| : (it = types.nextWindow(w, wm)) {
                if (w.obj == ev.window) {
                    @import("window.zig").setActive(w);
                    wm.pending_focus = w;
                    wm.needs_layout = true;
                    break;
                }
            }
        },
        else => {},
    }
}

// ----------------------------------------------------------------------------
// Default keybindings
// ----------------------------------------------------------------------------

const Def = struct {
    /// xkbcommon keysym (value of XKB_KEY_* in xkbcommon-keysyms.h).
    key: u32,
    mods: Modifiers,
    action: Action,
};

// Keysyms that are NOT just their ASCII value. Values taken from
// <xkbcommon/xkbcommon-keysyms.h>.
const KEY_Return: u32 = 0xff0d;
const KEY_Home: u32 = 0xff50;
const KEY_Left: u32 = 0xff51;
const KEY_Up: u32 = 0xff52;
const KEY_Right: u32 = 0xff53;
const KEY_Down: u32 = 0xff54;
const KEY_End: u32 = 0xff57;
// Printable keys: keysym == ASCII code of the unshifted character.
const KEY_comma: u32 = ',';
const KEY_period: u32 = '.';
const KEY_minus: u32 = '-';
const KEY_equal: u32 = '=';

const M = Config.mod;
const MS = Config.mod_shift;

pub const default_bindings = [_]Def{
    // --- launching --------------------------------------------------------
    .{ .key = KEY_Return, .mods = M, .action = .spawn_terminal },
    .{ .key = 'a', .mods = M, .action = .spawn_launcher },
    .{ .key = 'b', .mods = M, .action = .spawn_browser },

    // --- window / session -------------------------------------------------
    .{ .key = 'q', .mods = M, .action = .close },
    .{ .key = 'e', .mods = MS, .action = .exit },

    // --- focus (vim keys + arrows) ---------------------------------------
    .{ .key = 'h', .mods = M, .action = .focus_left },
    .{ .key = 'l', .mods = M, .action = .focus_right },
    .{ .key = 'j', .mods = M, .action = .focus_down },
    .{ .key = 'k', .mods = M, .action = .focus_up },
    .{ .key = KEY_Left, .mods = M, .action = .focus_left },
    .{ .key = KEY_Right, .mods = M, .action = .focus_right },
    .{ .key = KEY_Down, .mods = M, .action = .focus_down },
    .{ .key = KEY_Up, .mods = M, .action = .focus_up },
    .{ .key = KEY_Home, .mods = M, .action = .focus_first_column },
    .{ .key = KEY_End, .mods = M, .action = .focus_last_column },

    // --- moving columns / windows ----------------------------------------
    .{ .key = 'h', .mods = MS, .action = .move_column_left },
    .{ .key = 'l', .mods = MS, .action = .move_column_right },
    .{ .key = 'j', .mods = MS, .action = .move_window_down },
    .{ .key = 'k', .mods = MS, .action = .move_window_up },
    .{ .key = KEY_Left, .mods = MS, .action = .move_column_left },
    .{ .key = KEY_Right, .mods = MS, .action = .move_column_right },
    .{ .key = KEY_comma, .mods = M, .action = .consume_left },
    .{ .key = KEY_period, .mods = M, .action = .expel_right },

    // --- column width -----------------------------------------------------
    .{ .key = 'r', .mods = M, .action = .cycle_column_width },
    .{ .key = KEY_minus, .mods = M, .action = .narrow_column },
    .{ .key = KEY_equal, .mods = M, .action = .widen_column },

    // --- workspaces -------------------------------------------------------
    .{ .key = '1', .mods = M, .action = .workspace_1 },
    .{ .key = '2', .mods = M, .action = .workspace_2 },
    .{ .key = '3', .mods = M, .action = .workspace_3 },
    .{ .key = '4', .mods = M, .action = .workspace_4 },
    .{ .key = '1', .mods = MS, .action = .move_to_workspace_1 },
    .{ .key = '2', .mods = MS, .action = .move_to_workspace_2 },
    .{ .key = '3', .mods = MS, .action = .move_to_workspace_3 },
    .{ .key = '4', .mods = MS, .action = .move_to_workspace_4 },
};

/// Create (but do not enable) all default bindings for `seat`.
/// Called from manage_start; the `enable` request is only legal there.
pub fn setupBindings(wm: *WindowManager, seat: *Seat) void {
    seat.needs_binding_setup = false;

    const mgr = wm.xkb_bindings orelse {
        // river_xkb_bindings_v1 not available (yet): retry next manage.
        seat.needs_binding_setup = true;
        return;
    };

    for (default_bindings) |def| {
        bindOne(wm, mgr, seat, def);
    }
    std.log.info("[SEAT] registered {d} keybindings", .{default_bindings.len});
}

/// def.key is expressed as a QWERTY physical-position keysym; remap it for
/// the user's configured keyboard_layout so bindings stay on the same
/// physical key (e.g. Mod+<the key left of "z"> to close, not always the
/// literal letter 'q'). Non-letter keysyms (Return, arrows, ',', '.', ...)
/// are unaffected by any of the supported layouts and pass through as-is.
fn mappedKey(wm: *WindowManager, key: u32) u32 {
    if (key >= 'a' and key <= 'z') {
        return cfgmod.layoutMapKeysym(wm.config.keyboard_layout, @intCast(key));
    }
    return key;
}

fn bindOne(wm: *WindowManager, mgr: *river.XkbBindingsV1, seat: *Seat, def: Def) void {
    const key = mappedKey(wm, def.key);
    const binding = mgr.getXkbBinding(seat.obj, key, def.mods) catch |err| {
        std.log.err("[SEAT] getXkbBinding({x}) failed: {}", .{ key, err });
        return;
    };

    const node = wm.gpa.create(XkbBinding) catch return;
    node.* = .{
        .obj = binding,
        .seat = seat,
        .action = def.action,
        .link = undefined,
    };
    seat.xkb_bindings.append(node);

    // The listener context is the XkbBinding node itself, so `pressed`
    // knows both the action and the WindowManager (via seat -> global).
    binding.setListener(*XkbBinding, bindingListener, node);
    binding.enable();
}

fn bindingListener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, node: *XkbBinding) void {
    switch (event) {
        .pressed => {
            const wm = @import("window.zig").global_wm orelse return;
            // Queue only. The manage_start that follows executes it, where
            // the Wayland requests it needs are actually legal.
            wm.pending_actions.append(wm.gpa, node.action) catch {
                std.log.err("[SEAT] out of memory queueing action", .{});
                return;
            };
            wm.needs_layout = true;
        },
        else => {},
    }
}

/// Drop seats river told us are gone.
pub fn reap(wm: *WindowManager) void {
    var it = wm.seats.first();
    while (it) |s| {
        const next = types.nextSeat(s, wm);
        if (s.removed) {
            while (s.xkb_bindings.first()) |b| {
                b.link.remove();
                b.obj.destroy();
                wm.gpa.destroy(b);
            }
            s.link.remove();
            s.obj.destroy();
            wm.gpa.destroy(s);
        }
        it = next;
    }
}

pub fn focus(seat: *Seat, win: ?*types.Window) void {
    if (win) |w| {
        seat.obj.focusWindow(w.obj);
        seat.focused = w;
    } else {
        seat.obj.clearFocus();
        seat.focused = null;
    }
}
