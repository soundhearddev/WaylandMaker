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

    setupBindings(wm, seat);

    return seat;
}

fn setupBindings(wm: *WindowManager, seat: *Seat) void {
    const xkb_mgr = wm.xkb_bindings orelse return;

    const BindingConfig = struct {
        key: u32,
        action: Action,
    };

    const bindings = [_]BindingConfig{
        .{ .key = linux.KEY_Q, .action = .exit },
        .{ .key = linux.KEY_H, .action = .focus_prev_column },
        .{ .key = linux.KEY_L, .action = .focus_next_column },
    };

    for (bindings) |b| {
        const xkb_binding = xkb_mgr.getXkbBinding(
            seat.obj,
            b.key,
            types.Config.mod,
        ) catch continue;

        const binding_node = wm.gpa.create(XkbBinding) catch continue;
        binding_node.* = .{
            .obj = xkb_binding,
            .seat = seat,
            .action = b.action,
            .link = undefined,
        };

        seat.xkb_bindings.append(binding_node);

        const ctx = wm.gpa.create(BindingContext) catch continue;
        ctx.* = .{
            .wm = wm,
            .action = b.action,
        };

        xkb_binding.setListener(*BindingContext, xkbBindingListener, ctx);
    }
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

fn seatListener(river_seat: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    _ = river_seat;
    _ = seat;
    _ = event;
}
