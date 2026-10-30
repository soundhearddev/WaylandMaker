// SPDX-License-Identifier: GPL-3.0
//
// The pointer: the cursor on the desk, the theme, what is under it, and what
// a click or a hover does to the focus.
//
// Moving and resizing with the pointer (mouse_mod + left/right button, or a
// client's request) run the state machine of pointer_op.zig: while it grabs,
// motion only changes the distance from where it began, and the manage pass
// turns that into a rectangle.

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
const btn_left = 0x110;
const btn_right = 0x111;

pub const Cursor = struct {
    server: *Server,
    wlr_cursor: *wlr.Cursor,
    xcursor: *wlr.XcursorManager,
    shape_manager: *wlr.CursorShapeManagerV1,
    /// The cursor already shows the default image: motion over nothing must
    /// not set it again on every event.
    image_default: bool = false,
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

    /// `view` is null for a surface that is not a window: a layer surface (a
    /// launcher, a bar) or one of their popups. Those get the pointer too.
    const Hit = struct { view: ?*View, surface: *wlr.Surface, sx: f64, sy: f64 };

    pub fn init(c: *Cursor, server: *Server) !void {
        c.* = .{
            .server = server,
            .wlr_cursor = try wlr.Cursor.create(),
            .xcursor = try wlr.XcursorManager.create(null, cursor_size),
            .shape_manager = try wlr.CursorShapeManagerV1.create(server.wl_server, 1),
        };
        c.wlr_cursor.attachOutputLayout(server.output_layout);
        try c.xcursor.load(1);

        c.wlr_cursor.events.motion.add(&c.motion);
        c.wlr_cursor.events.motion_absolute.add(&c.motion_absolute);
        c.wlr_cursor.events.button.add(&c.button);
        c.wlr_cursor.events.axis.add(&c.axis);
        c.wlr_cursor.events.frame.add(&c.frame);
        c.shape_manager.events.request_set_shape.add(&c.request_shape);
    }

    pub fn deinit(c: *Cursor) void {
        c.motion.link.remove();
        c.motion_absolute.link.remove();
        c.button.link.remove();
        c.axis.link.remove();
        c.frame.link.remove();
        c.request_shape.link.remove();
        c.wlr_cursor.destroy();
        c.xcursor.destroy();
    }

    pub fn attach(c: *Cursor, device: *wlr.InputDevice) void {
        c.wlr_cursor.attachInputDevice(device);
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
        c.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
        c.processMotion(event.time_msec);
    }

    fn onMotionAbsolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
        const c: *Cursor = @fieldParentPtr("motion_absolute", listener);
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
                backend.manageDirty(wm.obj);
                return;
            }
        }

        // The Dock (tiles, Clip, Drawers) has the pointer before any window.
        if (server.dock_ui.motion(c.wlr_cursor.x, c.wlr_cursor.y)) {
            if (!c.image_default) {
                c.wlr_cursor.setXcursor(c.xcursor, "default");
                c.image_default = true;
            }
            server.seat.pointerNotifyClearFocus();
            if (seat) |s| s.hovered = null;
            return;
        }

        const hit = c.hitAt(c.wlr_cursor.x, c.wlr_cursor.y) orelse {
            if (!c.image_default) {
                c.wlr_cursor.setXcursor(c.xcursor, "default");
                c.image_default = true;
            }
            server.seat.pointerNotifyClearFocus();
            if (seat) |s| s.hovered = null;
            return;
        };
        server.seat.pointerNotifyEnter(hit.surface, hit.sx, hit.sy);
        server.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
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
        const wm = server.wm;
        const seat = wm.seats.first();

        // The Dock takes presses on its tiles, and the release of a press it
        // took, wherever the pointer is by then. Clients never see either.
        const pressed = event.state == .pressed;
        if (server.dock_ui.button(c.wlr_cursor.x, c.wlr_cursor.y, event.button, pressed)) {
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
        if (op != null and keys.normalize(c.heldMods()) == keys.normalize(config.modsBits(wm.cfg.mouse_mod))) {
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
        // The wheel over the Clip changes the workspace.
        if (event.orientation == .vertical_scroll and
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
