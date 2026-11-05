// SPDX-License-Identifier: GPL-3.0
//
// The pointer: the cursor on the desk, the theme, what is under it, and what
// a click or a hover does to the focus.
//
// Moving and resizing with the pointer (mouse_mod + left/right button, or a
// client's request) run the state machine of pointer_op.zig: while it grabs,
// motion only changes the distance from where it began, and the manage pass
// turns that into a rectangle.
//
// Games and 3D tools ask to lock or confine the pointer (pointer-constraints)
// and read relative motion (relative-pointer): every motion is also sent as
// relative motion; a lock keeps the cursor where it is, a confinement keeps
// it inside the region. A constraint holds only while its surface is under
// the pointer and has the keyboard focus.

const std = @import("std");
const log = std.log.scoped(.cursor);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const action = model.action;
const config = model.config;
const types = model.types;
const backend = @import("backend.zig");
const keys = @import("keys.zig");
const pointer_op = @import("pointer_op.zig");

const layer = @import("layer.zig");
const Server = @import("server.zig").Server;
const View = @import("view.zig").View;

const cursor_size = 24;

/// Fingers followed at once (a hand and a bit more); more are ignored.
const max_touches = 10;

const Touch = struct { id: i32 = 0, active: bool = false, ox: f64 = 0, oy: f64 = 0 };

/// pixman's `pixman_region32_contains_point` (libpixman is linked for wlroots);
/// the region is a `wlr_pointer_constraint_v1.region`.
extern fn pixman_region32_contains_point(region: *const anyopaque, x: c_int, y: c_int, box: ?*anyopaque) c_int;
const btn_left = 0x110;
const btn_right = 0x111;

pub const Cursor = struct {
    server: *Server,
    wlr_cursor: *wlr.Cursor,
    xcursor: *wlr.XcursorManager,
    shape_manager: *wlr.CursorShapeManagerV1,
    relative: *wlr.RelativePointerManagerV1,
    constraints: *wlr.PointerConstraintsV1,
    /// The constraint that holds the pointer now, and where the surface's
    /// origin lies on the desk (to turn the pointer into surface coordinates).
    active: ?*wlr.PointerConstraintV1 = null,
    origin_x: f64 = 0,
    origin_y: f64 = 0,
    /// The cursor already shows the default image: motion over nothing must
    /// not set it again on every event.
    image_default: bool = false,
    /// Hidden while typing (`hide`); the next motion shows it again.
    hidden: bool = false,
    /// Pointer buttons held (a client's move/resize request is valid only
    /// while one is).
    buttons_down: u32 = 0,
    /// Where the running operation began, and the button that began it.
    op_x: f64 = 0,
    op_y: f64 = 0,
    op_button: u32 = 0,

    motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(onMotion),
    motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(onMotionAbsolute),
    button: wl.Listener(*wlr.Pointer.event.Button) = .init(onButton),
    axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(onAxis),
    frame: wl.Listener(*wlr.Cursor) = .init(onFrame),
    request_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(onRequestShape),
    new_constraint: wl.Listener(*wlr.PointerConstraintV1) = .init(onNewConstraint),
    touch_down: wl.Listener(*wlr.Touch.event.Down) = .init(onTouchDown),
    touch_up: wl.Listener(*wlr.Touch.event.Up) = .init(onTouchUp),
    touch_motion: wl.Listener(*wlr.Touch.event.Motion) = .init(onTouchMotion),
    touch_cancel: wl.Listener(*wlr.Touch.event.Cancel) = .init(onTouchCancel),
    touch_frame: wl.Listener(void) = .init(onTouchFrame),
    /// The fingers on the screen: where the origin of the surface each one
    /// began on lies on the desk, so that it keeps reporting to that surface
    /// when it slides off it.
    touches: [max_touches]Touch = [_]Touch{.{}} ** max_touches,
    /// A touch device is attached (the seat then has the touch capability).
    has_touch: bool = false,
    active_destroy: wl.Listener(*wlr.PointerConstraintV1) = .init(onActiveDestroy),

    /// `view` is null for a surface that is not a window: a layer surface (a
    /// launcher, a bar) or one of their popups. Those get the pointer too.
    const Hit = struct { view: ?*View, surface: *wlr.Surface, sx: f64, sy: f64 };

    pub fn init(c: *Cursor, server: *Server) !void {
        c.* = .{
            .server = server,
            .wlr_cursor = try wlr.Cursor.create(),
            .xcursor = try wlr.XcursorManager.create(null, themeSize()),
            .shape_manager = try wlr.CursorShapeManagerV1.create(server.wl_server, 1),
            .relative = try wlr.RelativePointerManagerV1.create(server.wl_server),
            .constraints = try wlr.PointerConstraintsV1.create(server.wl_server),
        };
        c.wlr_cursor.attachOutputLayout(server.output_layout);
        try c.xcursor.load(1);

        c.wlr_cursor.events.motion.add(&c.motion);
        c.wlr_cursor.events.motion_absolute.add(&c.motion_absolute);
        c.wlr_cursor.events.button.add(&c.button);
        c.wlr_cursor.events.axis.add(&c.axis);
        c.wlr_cursor.events.frame.add(&c.frame);
        c.shape_manager.events.request_set_shape.add(&c.request_shape);
        c.constraints.events.new_constraint.add(&c.new_constraint);
        c.wlr_cursor.events.touch_down.add(&c.touch_down);
        c.wlr_cursor.events.touch_up.add(&c.touch_up);
        c.wlr_cursor.events.touch_motion.add(&c.touch_motion);
        c.wlr_cursor.events.touch_cancel.add(&c.touch_cancel);
        c.wlr_cursor.events.touch_frame.add(&c.touch_frame);
    }

    /// `XCURSOR_SIZE` (a login shell or the session sets it), else 24. The
    /// theme comes from `XCURSOR_THEME` through wlroots itself.
    fn themeSize() u32 {
        const s = std.c.getenv("XCURSOR_SIZE") orelse return cursor_size;
        const n = std.fmt.parseInt(u32, std.mem.span(s), 10) catch return cursor_size;
        return std.math.clamp(n, 8, 256);
    }

    /// Hide the image while typing (`hide_cursor_when_typing`-style): clients
    /// set it again when the pointer enters one.
    pub fn hide(c: *Cursor) void {
        if (c.hidden or c.buttons_down > 0) return;
        c.hidden = true;
        c.wlr_cursor.unsetImage();
    }

    pub fn deinit(c: *Cursor) void {
        c.motion.link.remove();
        c.motion_absolute.link.remove();
        c.button.link.remove();
        c.axis.link.remove();
        c.frame.link.remove();
        c.request_shape.link.remove();
        c.new_constraint.link.remove();
        c.touch_down.link.remove();
        c.touch_up.link.remove();
        c.touch_motion.link.remove();
        c.touch_cancel.link.remove();
        c.touch_frame.link.remove();
        if (c.active != null) c.active_destroy.link.remove();
        c.wlr_cursor.destroy();
        c.xcursor.destroy();
    }

    pub fn attach(c: *Cursor, device: *wlr.InputDevice) void {
        c.wlr_cursor.attachInputDevice(device);
    }

    // ---- touch -----------------------------------------------------------------------------

    fn touchSlot(c: *Cursor, id: i32) ?*Touch {
        for (&c.touches) |*t| if (t.active and t.id == id) return t;
        return null;
    }

    /// A finger went down: the surface under it gets the touch (and, like a
    /// click, the focus). The pointer image is not used with touch.
    fn onTouchDown(listener: *wl.Listener(*wlr.Touch.event.Down), event: *wlr.Touch.event.Down) void {
        const c: *Cursor = @fieldParentPtr("touch_down", listener);
        const server = c.server;
        server.protocols.notifyActivity();
        var lx: f64 = 0;
        var ly: f64 = 0;
        c.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);
        const hit = c.hitAt(lx, ly) orelse return;
        const slot = blk: {
            for (&c.touches) |*t| if (!t.active) break :blk t;
            return; // more fingers than slots
        };
        slot.* = .{ .id = event.touch_id, .active = true, .ox = lx - hit.sx, .oy = ly - hit.sy };
        _ = server.seat.touchNotifyDown(hit.surface, event.time_msec, event.touch_id, hit.sx, hit.sy);

        if (hit.view) |hv| {
            server.releaseOnDemandFocus();
            if (hv.win) |win| action.requestFocus(server.wm, win);
        } else {
            _ = layer.clicked(server, hit.surface);
        }
    }

    fn onTouchUp(listener: *wl.Listener(*wlr.Touch.event.Up), event: *wlr.Touch.event.Up) void {
        const c: *Cursor = @fieldParentPtr("touch_up", listener);
        const slot = c.touchSlot(event.touch_id) orelse return;
        slot.active = false;
        _ = c.server.seat.touchNotifyUp(event.time_msec, event.touch_id);
    }

    fn onTouchMotion(listener: *wl.Listener(*wlr.Touch.event.Motion), event: *wlr.Touch.event.Motion) void {
        const c: *Cursor = @fieldParentPtr("touch_motion", listener);
        const slot = c.touchSlot(event.touch_id) orelse return;
        var lx: f64 = 0;
        var ly: f64 = 0;
        c.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);
        c.server.seat.touchNotifyMotion(event.time_msec, event.touch_id, lx - slot.ox, ly - slot.oy);
    }

    /// The device cancelled a touch (a palm, the screen switched off): the
    /// client sees the finger lift.
    fn onTouchCancel(listener: *wl.Listener(*wlr.Touch.event.Cancel), event: *wlr.Touch.event.Cancel) void {
        const c: *Cursor = @fieldParentPtr("touch_cancel", listener);
        const slot = c.touchSlot(event.touch_id) orelse return;
        slot.active = false;
        _ = c.server.seat.touchNotifyUp(event.time_msec, event.touch_id);
    }

    fn onTouchFrame(listener: *wl.Listener(void)) void {
        const c: *Cursor = @fieldParentPtr("touch_frame", listener);
        c.server.seat.touchNotifyFrame();
    }

    /// The client under the pointer sets the cursor image (a surface).
    pub fn clientSetsCursor(c: *Cursor, event: *wlr.Seat.event.RequestSetCursor) void {
        if (event.seat_client != c.server.seat.pointer_state.focused_client) return;
        c.image_default = false;
        c.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    /// ... or names a shape (cursor-shape-v1: resize arrows, text beam, ...).
    fn onRequestShape(listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape), event: *wlr.CursorShapeManagerV1.event.RequestSetShape) void {
        const c: *Cursor = @fieldParentPtr("request_shape", listener);
        if (event.device_type != .pointer) return;
        if (event.seat_client != c.server.seat.pointer_state.focused_client) return;
        c.image_default = false;
        c.wlr_cursor.setXcursor(c.xcursor, wlr.CursorShapeManagerV1.shapeName(event.shape));
    }

    // ---- hit testing ---------------------------------------------------------------

    fn hitAt(c: *Cursor, lx: f64, ly: f64) ?Hit {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        const node = c.server.scene.tree.node.at(lx, ly, &sx, &sy) orelse return null;
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;
        return .{ .view = View.fromNode(node), .surface = scene_surface.surface, .sx = sx, .sy = sy };
    }

    // ---- events ----------------------------------------------------------------------

    fn onMotion(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
        const c: *Cursor = @fieldParentPtr("motion", listener);
        // Relative motion first, whatever happens to the cursor: a locked
        // pointer does not move, and that is when it matters most.
        c.relative.sendRelativeMotion(c.server.seat, @as(u64, event.time_msec) * 1000, event.delta_x, event.delta_y, event.unaccel_dx, event.unaccel_dy);
        if (c.active) |con| {
            switch (con.type) {
                .locked => return,
                .confined => {
                    // The step, or the part of it that stays inside.
                    const x = c.wlr_cursor.x;
                    const y = c.wlr_cursor.y;
                    var dx = event.delta_x;
                    var dy = event.delta_y;
                    if (!c.inside(con, x + dx, y + dy)) {
                        if (c.inside(con, x + dx, y)) {
                            dy = 0;
                        } else if (c.inside(con, x, y + dy)) {
                            dx = 0;
                        } else {
                            return;
                        }
                    }
                    c.wlr_cursor.move(event.device, dx, dy);
                    c.processMotion(event.time_msec);
                    return;
                },
            }
        }
        c.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
        c.processMotion(event.time_msec);
    }

    /// Is the desk point inside what the constraint confines the pointer to
    /// (its region, within the surface)?
    fn inside(c: *Cursor, con: *wlr.PointerConstraintV1, lx: f64, ly: f64) bool {
        const sx = lx - c.origin_x;
        const sy = ly - c.origin_y;
        if (sx < 0 or sy < 0 or sx >= @as(f64, @floatFromInt(con.surface.current.width)) or sy >= @as(f64, @floatFromInt(con.surface.current.height))) return false;
        return pixman_region32_contains_point(&con.region, @intFromFloat(@floor(sx)), @intFromFloat(@floor(sy)), null) != 0;
    }

    // ---- pointer constraints ---------------------------------------------------------------

    /// A program asked to lock or confine the pointer. It takes hold when its
    /// surface is under the pointer and focused; check that now.
    fn onNewConstraint(listener: *wl.Listener(*wlr.PointerConstraintV1), _: *wlr.PointerConstraintV1) void {
        const c: *Cursor = @fieldParentPtr("new_constraint", listener);
        c.refresh();
    }

    fn onActiveDestroy(listener: *wl.Listener(*wlr.PointerConstraintV1), _: *wlr.PointerConstraintV1) void {
        const c: *Cursor = @fieldParentPtr("active_destroy", listener);
        c.active_destroy.link.remove();
        c.active = null;
    }

    /// The surface under the pointer (null: none) may hold a constraint.
    fn syncConstraint(c: *Cursor, surface: ?*wlr.Surface, sx: f64, sy: f64) void {
        const server = c.server;
        const wanted: ?*wlr.PointerConstraintV1 = blk: {
            const s = surface orelse break :blk null;
            // Only the window the user is typing into may grab the pointer.
            if (server.seat.keyboard_state.focused_surface != s) break :blk null;
            break :blk c.constraints.constraintForSurface(s, server.seat);
        };
        if (wanted == c.active) {
            if (wanted != null) {
                c.origin_x = c.wlr_cursor.x - sx;
                c.origin_y = c.wlr_cursor.y - sy;
            }
            return;
        }
        c.deactivate();
        const con = wanted orelse return;
        c.origin_x = c.wlr_cursor.x - sx;
        c.origin_y = c.wlr_cursor.y - sy;
        c.active = con;
        con.events.destroy.add(&c.active_destroy);
        con.sendActivated();
    }

    /// Release the constraint that holds the pointer. A lock that gave a
    /// cursor hint puts the pointer where the program says it was.
    fn deactivate(c: *Cursor) void {
        const con = c.active orelse return;
        c.active_destroy.link.remove();
        c.active = null;
        if (con.type == .locked and con.current.cursor_hint.enabled) {
            _ = c.wlr_cursor.warp(null, c.origin_x + con.current.cursor_hint.x, c.origin_y + con.current.cursor_hint.y);
        }
        // A one-shot constraint is gone after this.
        con.sendDeactivated();
    }

    fn onMotionAbsolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
        const c: *Cursor = @fieldParentPtr("motion_absolute", listener);
        if (c.active) |con| if (con.type == .locked) return;
        c.wlr_cursor.warpAbsolute(event.device, event.x, event.y);
        c.processMotion(event.time_msec);
    }

    /// Put the pointer at (x, y) in layout coordinates and tell whatever is
    /// under it, as if it had moved there (`warp_mouse_to_focus`).
    pub fn warpTo(c: *Cursor, x: f64, y: f64) void {
        _ = c.wlr_cursor.warp(null, x, y);
        c.processMotion(@truncate(c.server.nowMs()));
    }

    fn processMotion(c: *Cursor, time_msec: u32) void {
        const server = c.server;
        server.protocols.notifyActivity();
        if (c.hidden) {
            // Show it again: our own image now, and a fresh enter so the
            // client under the pointer sends its image again.
            c.hidden = false;
            c.image_default = false;
            server.seat.pointerNotifyClearFocus();
        }
        const wm = server.wm;
        const seat = wm.seats.first();
        if (seat) |s| {
            s.pointer_x = @intFromFloat(c.wlr_cursor.x);
            s.pointer_y = @intFromFloat(c.wlr_cursor.y);

            // A move or resize owns the pointer: clients see nothing.
            if (pointer_op.grabbing(s)) {
                pointer_op.setDelta(
                    s,
                    @intFromFloat(c.wlr_cursor.x - c.op_x),
                    @intFromFloat(c.wlr_cursor.y - c.op_y),
                );
                server.manageOnFrame();
                return;
            }
        }

        // The Dock (tiles, Clip, Drawers) has the pointer before any window.
        if (!server.lock.locked and server.dock_ui.motion(c.wlr_cursor.x, c.wlr_cursor.y)) {
            if (!c.image_default) {
                c.wlr_cursor.setXcursor(c.xcursor, "default");
                c.image_default = true;
            }
            server.seat.pointerNotifyClearFocus();
            c.deactivate();
            if (seat) |s| s.hovered = null;
            return;
        }

        const hit = c.hitAt(c.wlr_cursor.x, c.wlr_cursor.y) orelse {
            if (!c.image_default) {
                c.wlr_cursor.setXcursor(c.xcursor, "default");
                c.image_default = true;
            }
            server.seat.pointerNotifyClearFocus();
            c.deactivate();
            if (seat) |s| s.hovered = null;
            return;
        };
        server.seat.pointerNotifyEnter(hit.surface, hit.sx, hit.sy);
        server.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
        c.syncConstraint(hit.surface, hit.sx, hit.sy);
        const hit_view = hit.view orelse {
            if (seat) |s| s.hovered = null;
            return;
        };
        if (seat) |s| s.hovered = hit_view.win;

        // focus_follows_mouse: hovering is a focus request, once per window.
        if (wm.cfg.focus_follows_mouse and server.focused != hit_view) {
            if (hit_view.win) |win| action.requestFocusFollow(wm, win, wm.cfg.focus_follows_mouse_scroll);
        }
    }

    /// Tell whatever is under the pointer again, without the pointer moving:
    /// a surface appeared or went away under it (a launcher closing).
    pub fn refresh(c: *Cursor) void {
        c.processMotion(@truncate(c.server.nowMs()));
    }

    /// Modifiers held on the seat's keyboard.
    fn heldMods(c: *Cursor) u32 {
        const kb = c.server.seat.getKeyboard() orelse return 0;
        return @bitCast(kb.getModifiers());
    }

    fn onButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
        const c: *Cursor = @fieldParentPtr("button", listener);
        const server = c.server;
        server.protocols.notifyActivity();
        const wm = server.wm;
        const seat = wm.seats.first();

        // The Dock takes presses on its tiles, and the release of a press it
        // took, wherever the pointer is by then. Clients never see either.
        const pressed = event.state == .pressed;
        if (!server.lock.locked and server.dock_ui.button(c.wlr_cursor.x, c.wlr_cursor.y, event.button, pressed)) {
            if (!pressed) c.buttons_down -|= 1 else c.buttons_down += 1;
            return;
        }

        if (event.state == .released) {
            c.buttons_down -|= 1;
            // The button that began a move/resize ends it, and clients never
            // saw it pressed.
            if (seat) |s| if (s.op_state != .idle and event.button == c.op_button) {
                pointer_op.release(s);
                backend.manageDirty(wm.obj);
                return;
            };
            _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            return;
        }

        c.buttons_down += 1;
        const hit = c.hitAt(c.wlr_cursor.x, c.wlr_cursor.y);

        // mouse_mod + left = move, + right = resize.
        const op: ?types.PointerOp = switch (event.button) {
            btn_left => .move,
            btn_right => .resize,
            else => null,
        };
        if (!server.lock.locked and op != null and keys.normalize(c.heldMods()) == keys.normalize(config.modsBits(wm.cfg.mouse_mod))) {
            if (seat) |s| if (hit) |h| if (h.view) |hv| if (hv.win) |win| {
                c.beginOp(s, op.?, win, event.button);
                return;
            };
        }

        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);

        // Click to focus: a window through the model; a layer surface that
        // wants the keyboard on demand takes it itself.
        if (hit) |h| {
            if (h.view) |hv| {
                server.releaseOnDemandFocus();
                if (hv.win) |win| action.requestFocus(wm, win);
            } else {
                _ = layer.clicked(server, h.surface);
            }
        }
    }

    fn beginOp(c: *Cursor, seat: *types.Seat, op: types.PointerOp, win: *types.Window, button: u32) void {
        if (!pointer_op.begin(c.server.wm, seat, op, win)) return;
        c.op_x = c.wlr_cursor.x;
        c.op_y = c.wlr_cursor.y;
        c.op_button = button;
        backend.manageDirty(c.server.wm.obj);
    }

    /// A client asked to move or resize its window (CSD). Only while a button
    /// is held; `edges` says which handle of a resize was grabbed.
    pub fn beginClientOp(c: *Cursor, op: types.PointerOp, win: *types.Window, edges: ?wlr.Edges) void {
        if (c.buttons_down == 0) return;
        const seat = c.server.wm.seats.first() orelse return;
        c.beginOp(seat, op, win, btn_left);
        if (seat.op_state != .requested) return;
        if (edges) |e| {
            seat.op_resize_left = e.left;
            seat.op_resize_top = e.top;
        }
    }

    fn onAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
        const c: *Cursor = @fieldParentPtr("axis", listener);
        c.server.protocols.notifyActivity();
        // The wheel over the Clip changes the workspace.
        if (!c.server.lock.locked and event.orientation == .vertical_scroll and
            c.server.dock_ui.axis(c.wlr_cursor.x, c.wlr_cursor.y, event.delta)) return;
        c.server.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    fn onFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const c: *Cursor = @fieldParentPtr("frame", listener);
        c.server.seat.pointerNotifyFrame();
    }
};
