// SPDX-License-Identifier: GPL-3.0
//
// The pointer: the cursor on the desk, the theme, what is under it, and what
// a click or a hover does to the focus.
//
// Moving and resizing windows with the pointer (the `idle -> requested ->
// running -> ending` state machine of types.OpState) is milestone B.

const std = @import("std");
const log = std.log.scoped(.cursor);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model");
const action = model.action;

const Server = @import("server.zig").Server;
const View = @import("view.zig").View;

const cursor_size = 24;

pub const Cursor = struct {
    server: *Server,
    wlr_cursor: *wlr.Cursor,
    xcursor: *wlr.XcursorManager,
    shape_manager: *wlr.CursorShapeManagerV1,

    motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(onMotion),
    motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(onMotionAbsolute),
    button: wl.Listener(*wlr.Pointer.event.Button) = .init(onButton),
    axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(onAxis),
    frame: wl.Listener(*wlr.Cursor) = .init(onFrame),
    request_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(onRequestShape),

    const Hit = struct { view: *View, surface: *wlr.Surface, sx: f64, sy: f64 };

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
        c.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    /// ... or names a shape (cursor-shape-v1: resize arrows, text beam, ...).
    fn onRequestShape(listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape), event: *wlr.CursorShapeManagerV1.event.RequestSetShape) void {
        const c: *Cursor = @fieldParentPtr("request_shape", listener);
        if (event.device_type != .pointer) return;
        if (event.seat_client != c.server.seat.pointer_state.focused_client) return;
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
        const view = View.fromNode(node) orelse return null;
        return .{ .view = view, .surface = scene_surface.surface, .sx = sx, .sy = sy };
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

    fn processMotion(c: *Cursor, time_msec: u32) void {
        const server = c.server;
        const wm = server.wm;
        if (wm.seats.first()) |s| {
            s.pointer_x = @intFromFloat(c.wlr_cursor.x);
            s.pointer_y = @intFromFloat(c.wlr_cursor.y);
        }

        const hit = c.hitAt(c.wlr_cursor.x, c.wlr_cursor.y) orelse {
            c.wlr_cursor.setXcursor(c.xcursor, "default");
            server.seat.pointerNotifyClearFocus();
            return;
        };
        server.seat.pointerNotifyEnter(hit.surface, hit.sx, hit.sy);
        server.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);

        // focus_follows_mouse: hovering is a focus request, once per window.
        if (wm.cfg.focus_follows_mouse and server.focused != hit.view) {
            if (hit.view.win) |win| action.requestFocusFollow(wm, win, wm.cfg.focus_follows_mouse_scroll);
        }
    }

    fn onButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
        const c: *Cursor = @fieldParentPtr("button", listener);
        const server = c.server;
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);

        // Click to focus.
        if (event.state != .pressed) return;
        const hit = c.hitAt(c.wlr_cursor.x, c.wlr_cursor.y) orelse return;
        if (hit.view.win) |win| action.requestFocus(server.wm, win);
    }

    fn onAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
        const c: *Cursor = @fieldParentPtr("axis", listener);
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
