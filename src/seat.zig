// SPDX-License-Identifier: 0BSD
//
// river_seat_v1: lifecycle, key/pointer bindings and the interactive
// pointer operation (move / resize) state machine.
//
// ── Pointer operation ─────────────────────────────────────────────────────
//
// States are documented on types.OpState. The chain, in order:
//
//   1. Super+LMB pressed       river_pointer_binding_v1.pressed. This arrives
//                              OUTSIDE a manage sequence, so we only record
//                              intent (state `requested`) and manage_dirty().
//   2. manage_start           startPendingOps(): op_start_pointer() is only
//                              legal inside a manage sequence -> `running`.
//   3. pointer moves          river sends op_delta and a manage_start for
//                              EVERY motion. dx/dy are CUMULATIVE since the
//                              start, so geometry is `start_rect + delta`,
//                              never `+=`. With the mouse held still nothing
//                              arrives; that is not a hang.
//   4. buttons released       op_release -> `ending`. The op is NOT over:
//                              river keeps the pointer captured until we
//                              send op_end.
//   5. manage_start           finishOps(): op_end() -> `idle`.
//
// Two ways to get stuck, both handled:
//   * button released between steps 1 and 2: river never heard of the op
//     and never sends op_release -> cancelled in `released` and again in
//     startPendingOps (button no longer down).
//   * the window dies mid-operation: forgetWindow() moves `running` to
//     `ending` so op_end still goes out.
//
// Every manage_start is answered with manage_finish (main.zig does that
// unconditionally), otherwise river waits for us forever.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const config = @import("config.zig");
const workspace = @import("workspace.zig");
const layout = @import("layout.zig");
const action = @import("action.zig");

const Seat = types.Seat;
const Window = types.Window;
const WindowManager = types.WindowManager;
const Rect = types.Rect;

pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;

/// Listener context is the WindowManager; the seat is looked up by object.
/// (zig-wayland listeners take exactly one context pointer.)
pub fn create(wm: *WindowManager, obj: *river.SeatV1) !*Seat {
    const seat = try wm.gpa.create(Seat);
    errdefer wm.gpa.destroy(seat);
    seat.* = .{
        .obj = obj,
        .xkb_bindings = undefined,
        .pointer_bindings = undefined,
    };
    seat.xkb_bindings.init();
    seat.pointer_bindings.init();

    wm.seats.append(seat);
    obj.setListener(*WindowManager, listener, wm);
    return seat;
}

fn find(wm: *WindowManager, obj: *river.SeatV1) ?*Seat {
    var it = wm.seats.first();
    while (it) |s| : (it = types.nextSeat(s, wm)) {
        if (s.obj == obj) return s;
    }
    return null;
}

fn findWindow(wm: *WindowManager, obj: ?*river.WindowV1) ?*Window {
    const o = obj orelse return null;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (w.obj == o) return w;
    }
    return null;
}

fn listener(obj: *river.SeatV1, event: river.SeatV1.Event, wm: *WindowManager) void {
    const seat = find(wm, obj) orelse return;
    switch (event) {
        .removed => {
            seat.removed = true;
            wm.obj.manageDirty();
        },

        .pointer_enter => |ev| {
            seat.hovered = findWindow(wm, ev.window);
            if (wm.cfg.focus_follows_mouse) {
                if (seat.hovered) |w| {
                    if (seat.op == .none) {
                        action.requestFocus(wm, w);
                    }
                }
            }
        },
        .pointer_leave => seat.hovered = null,

        .pointer_position => |ev| {
            seat.pointer_x = ev.x;
            seat.pointer_y = ev.y;
        },

        .window_interaction => |ev| {
            // A click on a window: focus and raise it.
            if (findWindow(wm, ev.window)) |w| action.requestFocus(wm, w);
        },

        .op_delta => |ev| {
            seat.op_dx = ev.dx;
            seat.op_dy = ev.dy;
        },
        // river reports the release only for an operation it is running.
        // The op is not over until we send op_end, so just note it.
        .op_release => {
            if (seat.op_state == .running) seat.op_state = .ending;
            wm.obj.manageDirty();
        },

        else => {},
    }
}

// ----------------------------------------------------------------------------
// Key bindings
// ----------------------------------------------------------------------------

/// Create every configured binding for `seat`. Must run inside a manage
/// sequence because `enable` is only legal there.
pub fn setupBindings(wm: *WindowManager, seat: *Seat) void {
    const mgr = wm.xkb_bindings orelse return; // retried when the global appears
    seat.bindings_ready = true;

    var ok: usize = 0;
    for (wm.cfg.binds, 0..) |bind, i| {
        const binding = mgr.getXkbBinding(seat.obj, bind.keysym, bind.mods) catch |err| {
            std.log.err("getXkbBinding failed for `{s}`: {t}", .{ bind.command, err });
            continue;
        };
        const node = wm.gpa.create(types.XkbBinding) catch {
            binding.destroy();
            continue;
        };
        node.* = .{ .obj = binding, .command = i };
        seat.xkb_bindings.append(node);
        binding.setListener(*types.XkbBinding, xkbListener, node);
        binding.enable();
        ok += 1;
    }

    setupPointerBindings(wm, seat);
    std.log.info("seat: {d}/{d} key bindings registered", .{ ok, wm.cfg.binds.len });
}

fn xkbListener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, node: *types.XkbBinding) void {
    switch (event) {
        .pressed => {
            const wm = action.global orelse return;
            if (node.command >= wm.commands.len) return;
            // `pressed` arrives outside a manage sequence; queue it and ask
            // for one so it actually runs.
            wm.pending.append(wm.gpa, wm.commands[node.command]) catch return;
            wm.obj.manageDirty();
        },
        else => {},
    }
}

// ----------------------------------------------------------------------------
// Pointer bindings and the operation state machine
// ----------------------------------------------------------------------------

fn setupPointerBindings(wm: *WindowManager, seat: *Seat) void {
    const mods = wm.cfg.mouse_mod;
    inline for (.{ .{ BTN_LEFT, types.PointerOp.move }, .{ BTN_RIGHT, types.PointerOp.resize } }) |pair| {
        const binding = seat.obj.getPointerBinding(pair[0], mods) catch |err| {
            std.log.err("getPointerBinding failed: {t}", .{err});
            return;
        };
        const node = wm.gpa.create(types.PointerBinding) catch {
            binding.destroy();
            return;
        };
        node.* = .{ .obj = binding, .seat = seat, .op = pair[1] };
        seat.pointer_bindings.append(node);
        binding.setListener(*types.PointerBinding, pointerListener, node);
        binding.enable();
    }
}

fn pointerListener(_: *river.PointerBindingV1, event: river.PointerBindingV1.Event, node: *types.PointerBinding) void {
    const wm = action.global orelse return;
    const seat = node.seat;
    switch (event) {
        .pressed => {
            seat.op_button_down = true;
            beginOp(wm, seat, node.op, seat.hovered);
        },
        .released => {
            seat.op_button_down = false;
            // Released before manage_start could start the operation: river
            // never heard of it and will never send op_release. Cancel here
            // or the state machine would wait forever.
            if (seat.op_state == .requested) cancelRequested(seat);
            wm.obj.manageDirty();
        },
    }
}

/// Record intent to start `op` on `win`. The real op_start_pointer() is
/// sent from startPendingOps() inside the next manage sequence.
pub fn beginOp(wm: *WindowManager, seat: *Seat, op: types.PointerOp, win: ?*Window) void {
    if (seat.op_state != .idle) return; // one operation at a time
    const w = win orelse return;
    if (w.workspace == null or w.closed) return;

    seat.op = op;
    seat.op_state = .requested;
    seat.op_window = w;
    seat.op_dx = 0;
    seat.op_dy = 0;
    seat.op_detached = false;

    // Which corner a resize pulls on: the one nearest the pointer, like
    // niri. A client-requested resize overrides this with the real handle.
    const t = w.target;
    seat.op_resize_left = seat.pointer_x < t.x + @divTrunc(t.w, 2);
    seat.op_resize_top = seat.pointer_y < t.y + @divTrunc(t.h, 2);

    action.requestFocus(wm, w);
    wm.obj.manageDirty();
}

/// Client-requested move/resize (CSD title bar, resize handle). Same state
/// machine as Super+mouse. The client asks while its button is down.
pub fn beginClientOp(wm: *WindowManager, seat_obj: *river.SeatV1, op: types.PointerOp, win: *Window, edges: ?river.WindowV1.Edges) void {
    const seat = find(wm, seat_obj) orelse return;
    seat.op_button_down = true;
    beginOp(wm, seat, op, win);
    if (seat.op_state != .requested) return;
    if (edges) |e| {
        seat.op_resize_left = e.left;
        seat.op_resize_top = e.top;
    }
}

/// The button went up before river heard about the operation.
fn cancelRequested(seat: *Seat) void {
    seat.op = .none;
    seat.op_state = .idle;
    seat.op_window = null;
}

/// Top of every manage sequence, before layout. Sends the requests that
/// are only legal inside one.
pub fn startPendingOps(wm: *WindowManager) void {
    var it = wm.seats.first();
    while (it) |seat| : (it = types.nextSeat(seat, wm)) {
        if (seat.op_state != .requested) continue;

        const w = seat.op_window;
        const alive = w != null and w.?.workspace != null and !w.?.closed;
        if (!alive or !seat.op_button_down) {
            // Target vanished, or the button is already up: do not start
            // an operation that could never be released.
            cancelRequested(seat);
            continue;
        }
        seat.obj.opStartPointer();
        seat.op_state = .running;
        snapshotOp(seat, w.?);
    }
}

/// Remember the geometry the operation started from (output-local content
/// rect, whether the window is tiled or floating).
fn snapshotOp(seat: *Seat, w: *Window) void {
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

/// Apply the CUMULATIVE delta (`start + delta`, never `+=`). Runs every
/// manage sequence while an operation is running.
pub fn applyOp(wm: *WindowManager, seat: *Seat) void {
    if (seat.op_state != .running and seat.op_state != .ending) return;
    const w = seat.op_window orelse return;
    if (w.workspace == null or w.closed) return;
    // Fullscreen windows do not move or resize.
    if (w.mode == .fullscreen) return;

    const cfg = &wm.cfg;
    switch (seat.op) {
        .none => {},
        .move => {
            if (!detach(wm, seat, w)) return;
            w.float_rect.x = seat.op_start_rect.x + seat.op_dx;
            w.float_rect.y = seat.op_start_rect.y + seat.op_dy;
        },
        .resize => {
            if (!detach(wm, seat, w)) return;
            w.float_rect = resizedRect(seat, w, cfg.min_window_size);
            w.has_float_rect = true;
        },
    }
}

/// A tiled window must be dragged `drag_threshold` pixels before it leaves
/// the strip, so a plain click with the mouse modifier changes nothing.
/// Returns false while the window is still below the threshold.
fn detach(wm: *WindowManager, seat: *Seat, w: *Window) bool {
    if (seat.op_detached) return true;
    const moved = @abs(seat.op_dx) + @abs(seat.op_dy);
    if (moved < wm.cfg.drag_threshold) return false;

    workspace.floatWindow(wm, w);
    w.float_rect = seat.op_start_rect;
    w.has_float_rect = true;
    seat.op_detached = true;
    workspace.activate(w);
    if (seat.op == .resize) w.obj.informResizeStart();
    return true;
}

/// New content rect for a resize, from the start rect and cumulative delta.
fn resizedRect(seat: *const Seat, w: *const Window, min_size: i32) types.Rect {
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

/// Send op_end once the operation is over. Runs at the end of every manage
/// sequence (after layout, so the last delta is in the final frame).
pub fn finishOps(wm: *WindowManager) void {
    var it = wm.seats.first();
    while (it) |seat| : (it = types.nextSeat(seat, wm)) {
        if (seat.op_state != .ending) continue;

        if (seat.op_window) |w| {
            if (seat.op == .resize and seat.op_detached and w.workspace != null and !w.closed) {
                w.obj.informResizeEnd();
            }
        }
        seat.obj.opEnd();
        seat.op = .none;
        seat.op_state = .idle;
        seat.op_window = null;
        seat.op_button_down = false;
    }
}

// ----------------------------------------------------------------------------
// Focus
// ----------------------------------------------------------------------------

/// Give keyboard focus to `win` (or clear it). Manage sequence only.
pub fn focus(seat: *Seat, win: ?*Window) void {
    if (win) |w| {
        if (w.closed or w.workspace == null) return;
        if (seat.focused == w) return;
        seat.obj.focusWindow(w.obj);
        if (seat.focused != null and seat.focused != w) seat.previous = seat.focused;
        seat.focused = w;
    } else if (seat.focused != null) {
        seat.obj.clearFocus();
        seat.focused = null;
    }
}

// ----------------------------------------------------------------------------
// Removal
// ----------------------------------------------------------------------------

/// Destroy every key/pointer binding of `seat` and mark it as needing
/// `setupBindings` again. Used both when a seat disappears (`reap`, below)
/// and to swap in a freshly reloaded config (`main.reloadConfig`); both are
/// manage-sequence-only, same as `setupBindings` (`destroy` on a binding is
/// management state).
pub fn teardownBindings(wm: *WindowManager, seat: *Seat) void {
    while (seat.xkb_bindings.first()) |b| {
        types.unlink(&b.link);
        b.obj.destroy();
        wm.gpa.destroy(b);
    }
    while (seat.pointer_bindings.first()) |b| {
        types.unlink(&b.link);
        b.obj.destroy();
        wm.gpa.destroy(b);
    }
    seat.bindings_ready = false;
}

/// Destroy seats river told us are gone. Manage sequence only.
pub fn reap(wm: *WindowManager) void {
    var it = wm.seats.first();
    while (it) |s| {
        const next = types.nextSeat(s, wm);
        if (s.removed) {
            teardownBindings(wm, s);
            types.unlink(&s.link);
            s.obj.destroy();
            wm.gpa.destroy(s);
        }
        it = next;
    }
}

/// A window is going away: drop every seat reference to it.
pub fn forgetWindow(wm: *WindowManager, win: *Window) void {
    var it = wm.seats.first();
    while (it) |s| : (it = types.nextSeat(s, wm)) {
        if (s.focused == win) s.focused = null;
        if (s.previous == win) s.previous = null;
        if (s.hovered == win) s.hovered = null;
        if (s.op_window == win) {
            s.op_window = null;
            switch (s.op_state) {
                // river never heard of it: just forget it.
                .requested => cancelRequested(s),
                // river IS in op mode: it must be ended or the pointer stays
                // captured. finishOps() sends op_end this sequence.
                .running => s.op_state = .ending,
                .ending, .idle => {},
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Tests: the pure parts of the state machine. Anything that would send a
// request (opStartPointer / opEnd) needs a connection and is covered by the
// reasoning in the header comment; what can go wrong without one is the
// geometry and the cancel paths, tested here.
// ----------------------------------------------------------------------------

fn testSeat() Seat {
    var s: Seat = .{ .obj = undefined, .xkb_bindings = undefined, .pointer_bindings = undefined };
    s.op_start_rect = .{ .x = 100, .y = 100, .w = 400, .h = 300 };
    return s;
}

fn testWindow() Window {
    return .{ .obj = undefined, .node = undefined };
}

test "resize from the bottom-right grows with the delta" {
    var s = testSeat();
    const w = testWindow();
    s.op = .resize;
    s.op_dx = 50;
    s.op_dy = 30;
    const r = resizedRect(&s, &w, 120);
    try std.testing.expectEqual(@as(i32, 100), r.x);
    try std.testing.expectEqual(@as(i32, 100), r.y);
    try std.testing.expectEqual(@as(i32, 450), r.w);
    try std.testing.expectEqual(@as(i32, 330), r.h);
}

test "resize from the top-left keeps the opposite corner fixed" {
    var s = testSeat();
    const w = testWindow();
    s.op = .resize;
    s.op_resize_left = true;
    s.op_resize_top = true;
    s.op_dx = -40; // drag left: grows
    s.op_dy = 20; // drag down: shrinks
    const r = resizedRect(&s, &w, 120);
    try std.testing.expectEqual(@as(i32, 440), r.w);
    try std.testing.expectEqual(@as(i32, 280), r.h);
    // right and bottom edges did not move
    try std.testing.expectEqual(@as(i32, 500), r.x + r.w);
    try std.testing.expectEqual(@as(i32, 400), r.y + r.h);
}

test "resize is cumulative, not incremental" {
    var s = testSeat();
    const w = testWindow();
    s.op = .resize;
    // Same total delta reached by different paths gives the same rect.
    s.op_dx = 60;
    const a = resizedRect(&s, &w, 120);
    s.op_dx = 20;
    _ = resizedRect(&s, &w, 120);
    s.op_dx = 60;
    const b = resizedRect(&s, &w, 120);
    try std.testing.expectEqual(a.w, b.w);
}

test "resize never goes below the minimum size" {
    var s = testSeat();
    const w = testWindow();
    s.op = .resize;
    s.op_dx = -100000;
    s.op_dy = -100000;
    const r = resizedRect(&s, &w, 120);
    try std.testing.expectEqual(@as(i32, 120), r.w);
    try std.testing.expectEqual(@as(i32, 120), r.h);
}

test "resize honours the client's minimum" {
    var s = testSeat();
    var w = testWindow();
    w.min_w = 300;
    w.min_h = 250;
    s.op = .resize;
    s.op_dx = -100000;
    s.op_dy = -100000;
    const r = resizedRect(&s, &w, 120);
    try std.testing.expectEqual(@as(i32, 300), r.w);
    try std.testing.expectEqual(@as(i32, 250), r.h);
}

test "release before start cancels without needing op_end" {
    var s = testSeat();
    s.op = .move;
    s.op_state = .requested;
    cancelRequested(&s);
    try std.testing.expect(s.op_state == .idle);
    try std.testing.expect(s.op == .none);
    try std.testing.expect(s.op_window == null);
}
