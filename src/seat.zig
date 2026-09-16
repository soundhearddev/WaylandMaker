const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const Seat = types.Seat;
const WindowManager = types.WindowManager;

pub fn create(
    wm: *WindowManager,
    river_seat: *river.SeatV1,
) !*Seat {
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

    return seat;
}

fn seatListener(
    river_seat: *river.SeatV1,
    event: river.SeatV1.Event,
    seat: *Seat,
) void {
    _ = river_seat;
    _ = seat;

    switch (event) {
        else => {},
    }
}
