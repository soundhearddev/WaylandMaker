const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const linux = @import("event-codes");

const types = @import("types.zig");
const action = @import("action.zig");

const Seat = types.Seat;
const Window = types.Window;
const WindowManager = types.WindowManager;
const Action = types.Action;
const XkbBinding = types.XkbBinding;

pub fn create(wm: *WindowManager, river_seat: *river.SeatV1) !*Seat {
    const seat = try wm.gpa.create(Seat);

    seat.* = .{
        .obj = river_seat,
        .link = undefined,
        .xkb_bindings = undefined,
        .pointer_bindings = undefined,
    };

    seat.xkb_bindings.init();
    seat.pointer_bindings.init();

    wm.seats.append(seat);
    river_seat.setListener(*Seat, seatListener, seat);

    // IMPORTANT: bindings are *not* set up here. get_xkb_binding is fine
    // to call any time, but the enable() request it needs (see bindOne
    // below) "may only be made as part of a manage sequence" per the
    // protocol, and create() runs from the registry listener, before the
    // first manage_start has even been received. Setting up bindings here
    // used to silently violate that ordering. Instead we flag the seat as
    // needing setup and main.zig's manage_start handler calls
    // setupBindings() for every such seat once we're actually inside a
    // manage sequence.
    seat.needs_binding_setup = true;

    return seat;
}

/// Must only be called from within a manage sequence (i.e. from
/// main.zig's manage_start handler) -- see the comment in create() above.
pub fn setupBindings(wm: *WindowManager, seat: *Seat) void {
    seat.needs_binding_setup = false;

    const xkb_mgr = wm.xkb_bindings orelse return;

    const BindingConfig = struct {
        key: u32,
        action: Action,
    };

    // NOTE: previously this list only bound exit/focus_prev_column/
    // focus_next_column, so mod+Return (and mod+1..4, mod+C, ...) were
    // never even registered with river -- the key press had nowhere to
    // go. get_xkb_binding takes an xkbcommon *keysym*, not a Linux
    // KEY_* evdev code -- see keycodeToXkbKeysym below for the mapping
    // used for plain letters/digits, and xkb_keysym_return further down
    // for why Return specifically needs a real keysym constant instead.
    const bindings = [_]BindingConfig{
        .{ .key = linux.KEY_Q, .action = .exit },
        .{ .key = linux.KEY_H, .action = .focus_prev_column },
        .{ .key = linux.KEY_L, .action = .focus_next_column },
        .{ .key = linux.KEY_J, .action = .focus_next_window },
        .{ .key = linux.KEY_C, .action = .close },
        .{ .key = linux.KEY_O, .action = .toggle_omnipresent },
        .{ .key = linux.KEY_1, .action = .workspace_1 },
        .{ .key = linux.KEY_2, .action = .workspace_2 },
        .{ .key = linux.KEY_3, .action = .workspace_3 },
        .{ .key = linux.KEY_4, .action = .workspace_4 },
    };

    for (bindings) |b| {
        bindOne(wm, xkb_mgr, seat, keycodeToXkbKeysym(b.key), b.action);
    }

    // mod+Return: spawn a terminal. XKB_KEY_Return (0xff0d) is an
    // xkbcommon *keysym*, unrelated to the evdev KEY_ENTER numeric value
    // (28) in event-codes.zig -- binding KEY_ENTER directly, as if it
    // were a keysym, is the actual reason mod+Return never fired.
    bindOne(wm, xkb_mgr, seat, xkb_keysym_return, .spawn_terminal);
}

/// XKB_KEY_Return from <xkbcommon/xkbcommon-keysyms.h>. Pulled in as a
/// bare constant (rather than xkbcommon.Keysym.fromName at runtime,
/// which rill uses for its fully data-driven config) since we only need
/// this one fixed binding for now; see docs/TODO.md for switching the
/// rest of the table over to keysym names too.
const xkb_keysym_return: u32 = 0xff0d;

/// evdev KEY_* codes (from linux/input-event-codes.h, i.e. our
/// `event-codes` module) happen to equal the corresponding xkbcommon
/// keysym for the small set of alphanumeric keys used above (letters and
/// digits 1-4 map 1:1 in both numbering schemes in the ranges we use
/// here), so a straight passthrough is correct for those specific keys.
/// It is NOT correct in general (Return, Escape, function keys, etc் all
/// differ) -- do not extend this table blindly, use real keysym values
/// (see xkb_keysym_return above) for anything outside plain letters/digits.
fn keycodeToXkbKeysym(evdev_key: u32) u32 {
    return switch (evdev_key) {
        linux.KEY_1 => '1',
        linux.KEY_2 => '2',
        linux.KEY_3 => '3',
        linux.KEY_4 => '4',
        linux.KEY_Q => 'q',
        linux.KEY_H => 'h',
        linux.KEY_J => 'j',
        linux.KEY_L => 'l',
        linux.KEY_C => 'c',
        linux.KEY_O => 'o',
        else => evdev_key,
    };
}

fn bindOne(wm: *WindowManager, xkb_mgr: *river.XkbBindingsV1, seat: *Seat, keysym: u32, act: Action) void {
    const xkb_binding = xkb_mgr.getXkbBinding(
        seat.obj,
        keysym,
        types.Config.mod,
    ) catch |err| {
        std.log.err("[SEAT] Failed to create xkb binding for keysym {x}: {}", .{ keysym, err });
        return;
    };

    const binding_node = wm.gpa.create(XkbBinding) catch return;
    binding_node.* = .{
        .obj = xkb_binding,
        .seat = seat,
        .action = act,
        .link = undefined,
    };
    seat.xkb_bindings.append(binding_node);

    const ctx = wm.gpa.create(BindingContext) catch return;
    ctx.* = .{ .wm = wm, .action = act };

    xkb_binding.setListener(*BindingContext, xkbBindingListener, ctx);
    xkb_binding.enable();
}

const BindingContext = struct {
    wm: *WindowManager,
    action: Action,
};

fn xkbBindingListener(
    xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    ctx: *BindingContext,
) void {
    _ = xkb_binding;
    switch (event) {
        .pressed => {
            action.handleAction(ctx.wm, ctx.action);
        },
        else => {},
    }
}

pub fn focus(seat: *Seat, win: ?*Window) void {
    if (win) |w| {
        seat.obj.focusWindow(w.obj);
    }
}

pub fn nextSeat(s: *Seat) ?*Seat {
    const n = s.link.next orelse return null;
    return @fieldParentPtr("link", n);
}

fn seatListener(river_seat: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    _ = river_seat;
    _ = seat;
    _ = event;
}
