// SPDX-License-Identifier: GPL-3.0
//
// The protocol globals that need little more than "create it" and one or two
// handlers: fractional scale, presentation time, idle notify / inhibit,
// xdg-activation, xdg-foreign, content type, alpha modifier, clipboard
// managers (ext-data-control), screen capture (ext-image-copy-capture) and
// the security-context that decides who may use the privileged ones.
//
// Compositor side (imports wlroots); the model knows nothing of this file.
//
// Not here, on purpose: the wlr-protocols ones (wlr-screencopy, gamma
// control, output power, export-dmabuf) need their XML from wlr-protocols,
// which is TODO "Protocol files" (section 8 of TODO wlroots.md): they come
// with that dependency, not as another vendored copy.

const std = @import("std");
const log = std.log.scoped(.protocols);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const action = model.action;

const Server = @import("server.zig").Server;
const View = @import("view.zig").View;

// ---- who may bind what -------------------------------------------------------------

/// What `wl_global_get_interface` returns; only the name is read.
const Interface = extern struct { name: [*:0]const u8 };

extern fn wl_display_set_global_filter(
    display: *wl.Server,
    filter: *const fn (?*const wl.Client, ?*const wl.Global, ?*anyopaque) callconv(.c) bool,
    data: ?*anyopaque,
) void;
extern fn wl_global_get_interface(global: *const wl.Global) *const Interface;

const activity_gap_ms = 100;

/// Globals a sandboxed client (Flatpak, anything that connected through a
/// security context) never sees: they read other programs' windows, the
/// clipboard, the screen, or the key timing, or they create sandboxes.
const privileged = [_][]const u8{
    "ext_image_copy_capture_manager_v1",
    "ext_output_image_capture_source_manager_v1",
    "ext_data_control_manager_v1",
    "ext_foreign_toplevel_list_v1",
    "ext_session_lock_manager_v1",
    "ext_idle_notifier_v1",
    "wp_security_context_manager_v1",
    "zwlr_layer_shell_v1",
};

fn isPrivileged(name: []const u8) bool {
    for (privileged) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

fn globalFilter(client: ?*const wl.Client, global: ?*const wl.Global, data: ?*anyopaque) callconv(.c) bool {
    const p: *Protocols = @ptrCast(@alignCast(data orelse return true));
    const c = client orelse return true;
    const g = global orelse return true;
    // Not sandboxed: everything.
    if (p.security_context.lookupClient(c) == null) return true;
    return !isPrivileged(std.mem.span(wl_global_get_interface(g).name));
}

// ---- idle inhibitors ------------------------------------------------------------------

/// One `zwp_idle_inhibitor_v1`. The screen stays awake while there is any.
const Inhibitor = struct {
    protocols: *Protocols,
    destroy: wl.Listener(*wlr.Surface) = .init(onDestroy),

    fn onDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const i: *Inhibitor = @fieldParentPtr("destroy", listener);
        const p = i.protocols;
        i.destroy.link.remove();
        p.inhibitors -|= 1;
        p.idle_notifier.setInhibited(p.inhibitors > 0);
        p.server.gpa.destroy(i);
    }
};

pub const Protocols = struct {
    server: *Server,
    idle_notifier: *wlr.IdleNotifierV1,
    idle_inhibit: *wlr.IdleInhibitManagerV1,
    activation: *wlr.XdgActivationV1,
    /// The list of toplevels for taskbars and switchers (ext-foreign-toplevel-list);
    /// view.zig adds a handle per mapped window.
    foreign_list: *wlr.ExtForeignToplevelListV1,
    security_context: *wlr.SecurityContextManagerV1,
    inhibitors: u32 = 0,
    /// When activity was last passed on (`notifyActivity`).
    last_activity_ms: u64 = 0,

    new_inhibitor: wl.Listener(*wlr.IdleInhibitorV1) = .init(onNewInhibitor),
    request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = .init(onRequestActivate),

    pub fn create(server: *Server) !*Protocols {
        const p = try server.gpa.create(Protocols);
        errdefer server.gpa.destroy(p);
        const display = server.wl_server;

        // Clients render at the real scale instead of being stretched; the
        // scene tells each surface the scale of its output by itself once
        // the manager exists.
        _ = try wlr.FractionalScaleManagerV1.create(display, 1);
        // Frame timing for video players and benchmarks.
        _ = try wlr.Presentation.create(display, server.backend, 2);
        _ = try wlr.ContentTypeManagerV1.create(display, 1);
        _ = try wlr.AlphaModifierV1.create(display);

        const registry = try wlr.XdgForeignRegistry.create(display);
        _ = try wlr.XdgForeignV2.create(display, registry);

        // Clipboard managers (wl-clip-persist, cliphist) and screen capture
        // (grim, screen sharing through the portal).
        _ = try wlr.ExtDataControlManagerV1.create(display, 1);
        _ = try wlr.ExtOutputImageCaptureSourceManagerV1.create(display, 1);
        _ = try wlr.ExtImageCopyCaptureManagerV1.create(display, 1);

        p.* = .{
            .server = server,
            .idle_notifier = try wlr.IdleNotifierV1.create(display),
            .idle_inhibit = try wlr.IdleInhibitManagerV1.create(display),
            .activation = try wlr.XdgActivationV1.create(display),
            .foreign_list = try wlr.ExtForeignToplevelListV1.create(display, 1),
            .security_context = try wlr.SecurityContextManagerV1.create(display),
        };
        p.idle_inhibit.events.new_inhibitor.add(&p.new_inhibitor);
        p.activation.events.request_activate.add(&p.request_activate);
        wl_display_set_global_filter(display, globalFilter, p);
        return p;
    }

    pub fn destroy(p: *Protocols) void {
        p.new_inhibitor.link.remove();
        p.request_activate.link.remove();
        p.server.gpa.destroy(p);
    }

    /// Input happened: the idle clocks start again (swayidle, screen lockers).
    ///
    /// wlroots re-arms a timer per listener on every call (a system call each),
    /// and a mouse reports a thousand times a second. Idle times are seconds,
    /// so at most one call per 100 ms is passed on; the first activity after a
    /// pause is always passed on at once, which is what wakes a sleeping screen.
    pub fn notifyActivity(p: *Protocols) void {
        const now = p.server.nowMs();
        if (now -% p.last_activity_ms < activity_gap_ms) return;
        p.last_activity_ms = now;
        p.idle_notifier.notifyActivity(p.server.seat);
    }

    fn onNewInhibitor(listener: *wl.Listener(*wlr.IdleInhibitorV1), inhibitor: *wlr.IdleInhibitorV1) void {
        const p: *Protocols = @fieldParentPtr("new_inhibitor", listener);
        const i = p.server.gpa.create(Inhibitor) catch {
            log.err("out of memory: idle inhibitor ignored", .{});
            return;
        };
        i.* = .{ .protocols = p };
        inhibitor.events.destroy.add(&i.destroy);
        p.inhibitors += 1;
        p.idle_notifier.setInhibited(true);
    }

    /// A program asks for attention or focus for a window. Only a request
    /// backed by a user action (the token was made with a seat and a serial)
    /// takes the focus: a program that merely wants to be seen must not
    /// steal it from what the user is typing in.
    fn onRequestActivate(listener: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate), event: *wlr.XdgActivationV1.event.RequestActivate) void {
        const p: *Protocols = @fieldParentPtr("request_activate", listener);
        if (event.token.seat == null) {
            log.debug("activation without a user action ignored", .{});
            return;
        }
        const xdg = wlr.XdgSurface.tryFromWlrSurface(event.surface) orelse return;
        const view = View.fromSurfaceTree(xdg.data) orelse return;
        const win = view.win orelse return;
        action.requestFocus(p.server.wm, win);
    }
};
