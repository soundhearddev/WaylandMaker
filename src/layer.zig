// SPDX-License-Identifier: GPL-3.0
//
// wlr-layer-shell: panels, launchers, wallpapers, notification daemons.
//
// fuzzel, wofi, tofi, bemenu, rofi (wayland), waybar, swaybg, mako, ... are
// all layer-shell clients. Without this file none of them can show anything,
// whatever the key binds start.
//
// What it does, in the order wlroots needs it:
//   - every layer surface gets a scene tree in the tree of its layer
//     (background < bottom < windows < top < fullscreen < overlay), see
//     Server.layer_trees;
//   - `arrange` hands each one the monitor and what the surfaces below it
//     left over (`wlr_scene_layer_surface_v1_configure`): that is also what
//     sends the configure the client waits for. What exclusive zones left
//     goes into the model (`Output.usable`), so windows avoid bars;
//   - a surface that asks for exclusive keyboard interactivity on the top or
//     overlay layer holds the keyboard until it goes (the launcher); one
//     with on-demand interactivity gets it when it is clicked;
//   - a monitor that goes away closes its layer surfaces.

const std = @import("std");
const log = std.log.scoped(.layer);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const manage = @import("manage.zig");

const Server = @import("server.zig").Server;
const Monitor = @import("output.zig").Monitor;
const Popup = @import("view.zig").Popup;

/// Layers by number: 0 background, 1 bottom, 2 top, 3 overlay.
pub const layer_count = 4;

pub const LayerSurface = struct {
    server: *Server,
    surface: *wlr.LayerSurfaceV1,
    monitor: *Monitor,
    scene: *wlr.SceneLayerSurfaceV1,
    /// Popups of this surface (a bar's menu, a tooltip) live here, in a tree
    /// above everything, at the surface's position.
    popups: *wlr.SceneTree,
    mapped: bool = false,
    /// What the client asked for when we last arranged it. A commit that
    /// asks for the same (a wallpaper redrawing) does not arrange again.
    last: @FieldType(wlr.LayerSurfaceV1, "current") = undefined,
    arranged: bool = false,
    link: wl.list.Link = undefined,

    commit: wl.Listener(*wlr.Surface) = .init(onCommit),
    map: wl.Listener(void) = .init(onMap),
    unmap: wl.Listener(void) = .init(onUnmap),
    destroy: wl.Listener(*wlr.LayerSurfaceV1) = .init(onDestroy),
    new_popup: wl.Listener(*wlr.XdgPopup) = .init(onNewPopup),

    fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const ls: *LayerSurface = @fieldParentPtr("commit", listener);
        const wlr_ls = ls.surface;
        // Nothing to place before the first commit has been taken in.
        if (!wlr_ls.initialized) return;
        // The layer can change after the surface exists (set_layer).
        const want = ls.server.layer_trees[layerIndex(wlr_ls)];
        if (ls.scene.tree.node.parent != want) ls.scene.tree.node.reparent(want);

        // Arranging answers with a configure, and a client that redraws on
        // every configure (swaybg, waybar) commits again: arranging on every
        // commit made the two chase each other forever, with the compositor
        // busy and the wallpaper never settling. So only a change of what the
        // client asked for (and the first commit, which has to be answered)
        // is arranged; a plain buffer commit is not.
        if (ls.arranged and sameRequest(&ls.last, &wlr_ls.current)) return;
        ls.last = wlr_ls.current;
        ls.arranged = true;
        arrange(ls.server, ls.monitor);
    }

    fn onMap(listener: *wl.Listener(void)) void {
        const ls: *LayerSurface = @fieldParentPtr("map", listener);
        ls.mapped = true;
        log.info("layer surface `{s}` mapped on {s}", .{ ls.surface.namespace, ls.monitor.wlr_output.name });
        arrange(ls.server, ls.monitor);
        ls.server.cursor.refresh();
    }

    fn onUnmap(listener: *wl.Listener(void)) void {
        const ls: *LayerSurface = @fieldParentPtr("unmap", listener);
        ls.mapped = false;
        arrange(ls.server, ls.monitor);
        ls.server.cursor.refresh();
    }

    fn onDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
        const ls: *LayerSurface = @fieldParentPtr("destroy", listener);
        const server = ls.server;
        ls.commit.link.remove();
        ls.map.link.remove();
        ls.unmap.link.remove();
        ls.destroy.link.remove();
        ls.new_popup.link.remove();
        ls.link.remove();
        // The scene node of the surface itself goes with the surface (wlroots
        // destroys it); only what we made is ours to free.
        ls.popups.node.destroy();
        if (server.layer_focus == ls) server.setLayerFocus(null);
        const monitor = ls.monitor;
        server.gpa.destroy(ls);
        if (!monitor.gone) arrange(server, monitor);
        server.cursor.refresh();
    }

    fn onNewPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const ls: *LayerSurface = @fieldParentPtr("new_popup", listener);
        Popup.createForLayer(ls.server, xdg_popup, ls) catch |err| log.err("cannot create a popup: {t}", .{err});
    }
};

/// Do two states ask for the same place, size, layer and keyboard? The
/// serial and the size of the last configure are left out on purpose: they
/// change when the client answers us.
fn sameRequest(a: anytype, b: anytype) bool {
    return std.meta.eql(a.anchor, b.anchor) and
        a.exclusive_zone == b.exclusive_zone and
        std.meta.eql(a.margin, b.margin) and
        a.desired_width == b.desired_width and
        a.desired_height == b.desired_height and
        a.layer == b.layer and
        a.keyboard_interactive == b.keyboard_interactive;
}

fn layerIndex(wlr_ls: *wlr.LayerSurfaceV1) usize {
    return @min(@as(usize, @intCast(@intFromEnum(wlr_ls.current.layer))), layer_count - 1);
}

/// A client made a layer surface (wlr_layer_shell_v1.new_surface).
pub fn create(server: *Server, wlr_ls: *wlr.LayerSurfaceV1) void {
    const monitor = pickMonitor(server, wlr_ls) orelse {
        log.warn("layer surface `{s}`: no monitor to put it on, closing it", .{wlr_ls.namespace});
        wlr_ls.destroy();
        return;
    };
    build(server, wlr_ls, monitor) catch |err| {
        log.err("cannot create the layer surface `{s}`: {t}", .{ wlr_ls.namespace, err });
        wlr_ls.destroy();
    };
}

/// The output the client named, else the active one, else any.
fn pickMonitor(server: *Server, wlr_ls: *wlr.LayerSurfaceV1) ?*Monitor {
    if (wlr_ls.output) |wanted| {
        var it = server.monitors.iterator(.forward);
        while (it.next()) |m| if (m.wlr_output == wanted and !m.gone) return m;
        return null; // an output that is gone
    }
    if (server.wm.active_output) |active| {
        var it = server.monitors.iterator(.forward);
        while (it.next()) |m| if (m.out == active and !m.gone) return m;
    }
    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| if (!m.gone) return m;
    return null;
}

fn build(server: *Server, wlr_ls: *wlr.LayerSurfaceV1, monitor: *Monitor) !void {
    const ls = try server.gpa.create(LayerSurface);
    errdefer server.gpa.destroy(ls);

    // `current` is not filled before the first commit: the layer the client
    // asked for is in `pending`.
    const layer: usize = @min(@as(usize, @intCast(@intFromEnum(wlr_ls.pending.layer))), layer_count - 1);
    const scene = try server.layer_trees[layer].createSceneLayerSurfaceV1(wlr_ls);
    errdefer scene.tree.node.destroy();
    const popups = try server.layer_popups.createSceneTree();
    errdefer popups.node.destroy();

    wlr_ls.output = monitor.wlr_output;
    ls.* = .{
        .server = server,
        .surface = wlr_ls,
        .monitor = monitor,
        .scene = scene,
        .popups = popups,
    };
    wlr_ls.data = ls;

    wlr_ls.surface.events.commit.add(&ls.commit);
    wlr_ls.surface.events.map.add(&ls.map);
    wlr_ls.surface.events.unmap.add(&ls.unmap);
    wlr_ls.events.destroy.add(&ls.destroy);
    wlr_ls.events.new_popup.add(&ls.new_popup);
    server.layer_surfaces.append(ls);
    log.info("layer surface `{s}` on {s} (layer {d})", .{ wlr_ls.namespace, monitor.wlr_output.name, layer });
}

/// Place every layer surface of `m`, and work out what is left for windows.
/// Surfaces with an exclusive zone first, so the others see what they left;
/// within a pass from the overlay down to the background.
pub fn arrange(server: *Server, m: *Monitor) void {
    if (m.gone) return;
    var full: wlr.Box = undefined;
    server.output_layout.getBox(m.wlr_output, &full);
    if (full.width <= 0 or full.height <= 0) return; // not on the desk (yet)
    var usable = full;

    const exclusive_pass = [_]bool{ true, false };
    for (exclusive_pass) |exclusive| {
        var layer: usize = layer_count;
        while (layer > 0) {
            layer -= 1;
            var it = server.layer_surfaces.iterator(.forward);
            while (it.next()) |ls| {
                if (ls.monitor != m) continue;
                // Before its first commit a surface has no state to place.
                if (!ls.surface.initialized) continue;
                if (layerIndex(ls.surface) != layer) continue;
                if ((ls.surface.current.exclusive_zone > 0) != exclusive) continue;
                ls.scene.configure(&full, &usable);
                ls.popups.node.setPosition(ls.scene.tree.node.x, ls.scene.tree.node.y);
            }
        }
    }

    const whole = usable.x == full.x and usable.y == full.y and usable.width == full.width and usable.height == full.height;
    manage.setOutputUsable(server.wm, m.out, if (whole) null else .{ .x = usable.x, .y = usable.y, .w = usable.width, .h = usable.height });
    updateKeyboard(server);
}

pub fn arrangeAll(server: *Server) void {
    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| arrange(server, m);
}

/// A surface on the top or overlay layer that asked for exclusive keyboard
/// interactivity holds the keyboard (the launcher); the newest one on the
/// highest layer wins.
fn updateKeyboard(server: *Server) void {
    var grab: ?*LayerSurface = null;
    var it = server.layer_surfaces.iterator(.forward);
    while (it.next()) |ls| {
        if (!ls.mapped or !ls.surface.initialized) continue;
        if (ls.surface.current.keyboard_interactive != .exclusive) continue;
        const layer = layerIndex(ls.surface);
        if (layer < 2) continue; // background and bottom never grab
        if (grab) |g| if (layer < layerIndex(g.surface)) continue;
        grab = ls;
    }
    // Keep a grab that is still valid; a click-given (on demand) focus stays
    // too, unless something exclusive appeared.
    if (grab == null) {
        if (server.layer_focus) |cur| {
            if (cur.mapped and cur.surface.current.keyboard_interactive != .none) return;
        }
    }
    server.setLayerFocus(grab);
}

/// A click landed on `surface` (no window): if it is a layer surface that
/// wants the keyboard on demand, it gets it. True when it was a layer surface.
pub fn clicked(server: *Server, surface: *wlr.Surface) bool {
    const root = surface.getRootSurface();
    const wlr_ls = wlr.LayerSurfaceV1.tryFromWlrSurface(root) orelse return false;
    const ls: *LayerSurface = @ptrCast(@alignCast(wlr_ls.data orelse return false));
    if (wlr_ls.current.keyboard_interactive != .none and ls.mapped) server.setLayerFocus(ls);
    return true;
}

/// The monitor is going: its layer surfaces cannot stay (the client is told
/// to close them; most of them reappear on the next output).
pub fn closeOn(server: *Server, m: *Monitor) void {
    var doomed: [64]*LayerSurface = undefined;
    var n: usize = 0;
    var it = server.layer_surfaces.iterator(.forward);
    while (it.next()) |ls| {
        if (ls.monitor != m or n == doomed.len) continue;
        doomed[n] = ls;
        n += 1;
    }
    // Destroying one edits the list: collected first, destroyed after.
    for (doomed[0..n]) |ls| ls.surface.destroy();
}
