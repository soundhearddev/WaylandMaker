// SPDX-License-Identifier: GPL-3.0
//
// Moving and resizing a window with the pointer: the state machine of
// `types.OpState`.
//
//   idle --begin--> requested --startPending--> running --release--> ending --finish--> idle
//                       |                                                                  ^
//                       `-- button up / window gone before the next pass ------------------'
//
// `requested` exists to keep one rule: an operation starts at a pass boundary,
// with the window's geometry of that moment, and ends at one.
//
// The cursor feeds `setDelta` (distance from where the press happened) and the
// manage pass calls `startPending`, `apply` and `finish` (manage.zig).

const std = @import("std");

const model = @import("model.zig");
const types = model.types;
const action = model.action;
const workspace = model.workspace;

const Seat = types.Seat;
const Window = types.Window;
const WindowManager = types.WindowManager;

/// An operation is in progress and the pointer belongs to it, not to clients.
pub fn grabbing(seat: *const Seat) bool {
    return seat.op_state == .requested or seat.op_state == .running;
}

/// Record the intent to start `op` on `win`. The button that started it is
/// held (`seat.op_button_down`).
pub fn begin(wm: *WindowManager, seat: *Seat, op: types.PointerOp, win: ?*Window) bool {
    if (seat.op_state != .idle) return false; // one operation at a time
    const w = win orelse return false;
    if (w.workspace == null or w.closed) return false;

    seat.op = op;
    seat.op_state = .requested;
    seat.op_window = w;
    seat.op_dx = 0;
    seat.op_dy = 0;
    seat.op_detached = false;
    seat.op_button_down = true;

    // Which corner a resize pulls on: the one nearest the pointer. A
    // client-requested resize overrides this with the real handle.
    const t = w.target;
    seat.op_resize_left = seat.pointer_x < t.x + @divTrunc(t.w, 2);
    seat.op_resize_top = seat.pointer_y < t.y + @divTrunc(t.h, 2);

    action.requestFocus(wm, w);
    return true;
}

/// The pointer is `dx`, `dy` away from where the operation began.
pub fn setDelta(seat: *Seat, dx: i32, dy: i32) void {
    seat.op_dx = dx;
    seat.op_dy = dy;
}

/// The button went up.
pub fn release(seat: *Seat) void {
    seat.op_button_down = false;
    switch (seat.op_state) {
        // The pass never saw it: nothing to end.
        .requested => cancel(seat),
        .running => seat.op_state = .ending,
        .ending, .idle => {},
    }
}

fn cancel(seat: *Seat) void {
    seat.op = .none;
    seat.op_state = .idle;
    seat.op_window = null;
}

/// Top of every pass, before layout.
pub fn startPending(wm: *WindowManager) void {
    var it = wm.seats.first();
    while (it) |seat| : (it = types.nextSeat(seat, wm)) {
        if (seat.op_state != .requested) continue;

        const w = seat.op_window;
        const alive = w != null and w.?.workspace != null and !w.?.closed;
        if (!alive or !seat.op_button_down) {
            // Target vanished, or the button is already up: do not start an
            // operation that could never be released.
            cancel(seat);
            continue;
        }
        seat.op_state = .running;
        snapshot(seat, w.?);
    }
}

/// Remember the geometry the operation started from (output-local content
/// rect, and whether the window is floating already).
fn snapshot(seat: *Seat, w: *Window) void {
    const out = (w.workspace orelse return).output;
    seat.op_start_rect = .{
        .x = w.target.x - out.rect.x,
        .y = w.target.y - out.rect.y,
        .w = w.target.w,
        .h = w.target.h,
    };
    seat.op_detached = w.mode == .floating;
    if (w.mode == .floating) {
        w.float_rect = seat.op_start_rect;
        w.has_float_rect = true;
    }
}

/// Apply the CUMULATIVE delta (`start + delta`, never `+=`). Runs every pass
/// while an operation is running.
pub fn apply(wm: *WindowManager) void {
    var it = wm.seats.first();
    while (it) |seat| : (it = types.nextSeat(seat, wm)) applyOne(wm, seat);
}

fn applyOne(wm: *WindowManager, seat: *Seat) void {
    if (seat.op_state != .running and seat.op_state != .ending) return;
    const w = seat.op_window orelse return;
    if (w.workspace == null or w.closed) return;
    // Fullscreen windows do not move or resize.
    if (w.mode == .fullscreen) return;

    switch (seat.op) {
        .none => {},
        .move => {
            if (!detach(wm, seat, w)) return;
            w.float_rect.x = seat.op_start_rect.x + seat.op_dx;
            w.float_rect.y = seat.op_start_rect.y + seat.op_dy;
        },
        .resize => {
            if (!detach(wm, seat, w)) return;
            w.float_rect = resizedRect(seat, w, wm.cfg.min_window_size);
            w.has_float_rect = true;
        },
    }
}

/// A tiled window must be dragged `drag_threshold` pixels before it leaves the
/// strip, so a plain click with the mouse modifier changes nothing. Returns
/// false while the window is still below the threshold.
fn detach(wm: *WindowManager, seat: *Seat, w: *Window) bool {
    if (seat.op_detached) return true;
    const moved = @abs(seat.op_dx) + @abs(seat.op_dy);
    if (moved < wm.cfg.drag_threshold) return false;

    workspace.floatWindow(wm, w);
    w.float_rect = seat.op_start_rect;
    w.has_float_rect = true;
    seat.op_detached = true;
    workspace.activate(w);
    return true;
}

/// New content rect for a resize, from the start rect and the cumulative delta.
pub fn resizedRect(seat: *const Seat, w: *const Window, min_size: i32) types.Rect {
    var r = seat.op_start_rect;
    const min = @max(min_size, 1);

    var nw = if (seat.op_resize_left) r.w - seat.op_dx else r.w + seat.op_dx;
    var nh = if (seat.op_resize_top) r.h - seat.op_dy else r.h + seat.op_dy;
    const c = w.clampSize(@max(nw, min), @max(nh, min), min);
    nw = c.w;
    nh = c.h;

    // Growing from the left/top edge moves the origin so the opposite edge
    // stays put.
    if (seat.op_resize_left) r.x += r.w - nw;
    if (seat.op_resize_top) r.y += r.h - nh;
    r.w = nw;
    r.h = nh;
    return r;
}

/// End of every pass (after layout, so the last delta is in the final frame).
pub fn finish(wm: *WindowManager) void {
    var it = wm.seats.first();
    while (it) |seat| : (it = types.nextSeat(seat, wm)) {
        if (seat.op_state != .ending) continue;
        cancel(seat);
        seat.op_button_down = false;
    }
}

/// A window is going away: an operation on it ends.
pub fn forget(seat: *Seat, win: *const Window) void {
    if (seat.op_window != win) return;
    seat.op_window = null;
    switch (seat.op_state) {
        .requested => cancel(seat),
        .running => seat.op_state = .ending,
        .ending, .idle => {},
    }
}

// ---- tests ------------------------------------------------------------------------

const testing = std.testing;

fn testSeat() Seat {
    return .{ .obj = undefined };
}

test "resizedRect: growing from the right/bottom, and from the left/top keeps the far edge" {
    var s = testSeat();
    var w: Window = .{ .obj = undefined, .node = undefined };
    s.op_start_rect = .{ .x = 100, .y = 100, .w = 400, .h = 300 };

    s.op_resize_left = false;
    s.op_resize_top = false;
    s.op_dx = 50;
    s.op_dy = -20;
    const a = resizedRect(&s, &w, 100);
    try testing.expectEqual(types.Rect{ .x = 100, .y = 100, .w = 450, .h = 280 }, a);

    s.op_resize_left = true;
    s.op_resize_top = true;
    const b = resizedRect(&s, &w, 100);
    // Width 350, height 320: origin moves so the right/bottom edge stays.
    try testing.expectEqual(types.Rect{ .x = 150, .y = 80, .w = 350, .h = 320 }, b);
    try testing.expectEqual(@as(i32, 500), b.x + b.w);
    try testing.expectEqual(@as(i32, 400), b.y + b.h);

    // Never below the minimum.
    s.op_dx = 1000;
    try testing.expectEqual(@as(i32, 100), resizedRect(&s, &w, 100).w);
}

test "release before the pass cancels, release while running ends" {
    var s = testSeat();
    s.op_state = .requested;
    s.op_button_down = true;
    release(&s);
    try testing.expectEqual(types.OpState.idle, s.op_state);
    try testing.expect(!grabbing(&s));

    s.op_state = .running;
    try testing.expect(grabbing(&s));
    release(&s);
    try testing.expectEqual(types.OpState.ending, s.op_state);
    try testing.expect(!grabbing(&s));
}

test "forget: an operation on a closed window ends" {
    var s = testSeat();
    var w: Window = .{ .obj = undefined, .node = undefined };
    s.op_window = &w;
    s.op_state = .running;
    forget(&s, &w);
    try testing.expect(s.op_window == null);
    try testing.expectEqual(types.OpState.ending, s.op_state);
}
