const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const Seat = types.Seat;
const WindowManager = types.WindowManager;

pub fn create(wm: *WindowManager, river_seat: *river.SeatV1) !*Seat {
    const seat = try wm.allocator.create(Seat);
    seat.* = .{
        .wm = wm,
        .river_seat = river_seat,
    };

    wm.seats.append(&seat.link);
    river_seat.setListener(*Seat, seatListener, seat);
    return seat;
}

fn seatListener(river_seat: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    _ = river_seat;
    switch (event) {
        .pointer_grab_start => |ev| {
            _ = ev;
            // Pointer Grab Logik
        },
        .pointer_grab_end => {
            seat.op = .none;
        },
        else => {},
    }
}
