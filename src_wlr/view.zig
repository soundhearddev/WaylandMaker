// SPDX-License-Identifier: GPL-3.0
//
// An xdg toplevel and its popups.
//
// A `View` belongs to the client's toplevel and lives as long as it. The
// model's `Window` exists only while the toplevel is mapped: `map` creates it,
// `unmap` and `destroy` close it (manage.closeWindowObject). The model decides
// where the view goes and how big it is; the view only carries that out.
//
// Scene layout of one view:
//
//   tree            positioned at the content's top-left, in layer `layers[..]`
//    |- surface_tree   the client's surfaces, shifted by their xdg geometry
//    `- borders[4]     top, bottom, left, right rectangles around the content

const std = @import("std");
const log = std.log.scoped(.view);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model");
const types = model.types;
const config = model.config;
const backend = @import("backend");
const manage = @import("manage.zig");

const Server = @import("server.zig").Server;
const Rect = types.Rect;
const intersect = manage.intersect;

const all_edges: wlr.Edges = .{ .top = true, .bottom = true, .left = true, .right = true };

/// Everything `place` depends on; equal means nothing to do.
const Drawn = struct {
    p: manage.Placement,
    geo_x: i32,
    geo_y: i32,
    /// The three border colours (a reload changes them).
    colors: [3]u32,
};

pub const View = struct {
    server: *Server,
    /// Null once the client destroyed it.
    toplevel: ?*wlr.XdgToplevel,
    tree: *wlr.SceneTree,
    surface_tree: *wlr.SceneTree,
    borders: [4]*wlr.SceneRect,
    /// The model's window while mapped.
    win: ?*types.Window = null,
    layer: ?types.Mode = null,
    /// What `place` did last. A pass places every visible window; most of
    /// them have not changed, and the scene calls are skipped for those.
    last: ?Drawn = null,
    sent_maximized: bool = false,

    commit: wl.Listener(*wlr.Surface) = .init(onCommit),
    map: wl.Listener(void) = .init(onMap),
    unmap: wl.Listener(void) = .init(onUnmap),
    destroy: wl.Listener(void) = .init(onDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(onRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(onRequestResize),
    request_maximize: wl.Listener(void) = .init(onRequestMaximize),
    request_fullscreen: wl.Listener(void) = .init(onRequestFullscreen),
    request_minimize: wl.Listener(void) = .init(onRequestMinimize),
    set_title: wl.Listener(void) = .init(onSetTitle),
    set_app_id: wl.Listener(void) = .init(onSetAppId),
    set_parent: wl.Listener(void) = .init(onSetParent),

    pub fn create(server: *Server, toplevel: *wlr.XdgToplevel) !void {
        const view = try server.gpa.create(View);
        errdefer server.gpa.destroy(view);

        // Starts in the tiled layer, hidden until the model has placed it.
        const tree = try server.layers[0].createSceneTree();
        errdefer tree.node.destroy();
        const surface_tree = try tree.createSceneXdgSurface(toplevel.base);
        var borders: [4]*wlr.SceneRect = undefined;
        const black = [4]f32{ 0, 0, 0, 1 };
        for (&borders) |*b| b.* = try tree.createSceneRect(0, 0, &black);

        view.* = .{
            .server = server,
            .toplevel = toplevel,
            .tree = tree,
            .surface_tree = surface_tree,
            .borders = borders,
        };
        tree.node.data = view;
        tree.node.setEnabled(false);
        toplevel.base.data = surface_tree;

        const surface = toplevel.base.surface;
        surface.events.commit.add(&view.commit);
        surface.events.map.add(&view.map);
        surface.events.unmap.add(&view.unmap);
        toplevel.events.destroy.add(&view.destroy);
        toplevel.events.request_move.add(&view.request_move);
        toplevel.events.request_resize.add(&view.request_resize);
        toplevel.events.request_maximize.add(&view.request_maximize);
        toplevel.events.request_fullscreen.add(&view.request_fullscreen);
        toplevel.events.request_minimize.add(&view.request_minimize);
        toplevel.events.set_title.add(&view.set_title);
        toplevel.events.set_app_id.add(&view.set_app_id);
        toplevel.events.set_parent.add(&view.set_parent);
    }

    // ---- what the manage pass asks for ----------------------------------------------

    pub fn configure(view: *View, c: manage.Configure) void {
        const toplevel = view.toplevel orelse return;
        if (!toplevel.base.initialized) return;
        if (c.tiled) |t| _ = toplevel.setTiled(if (t) all_edges else .{});
        if (c.fullscreen) |f| _ = toplevel.setFullscreen(f);
        if (c.size) |s| _ = toplevel.setSize(s.w, s.h);
    }

    pub fn place(view: *View, cfg: *const config.Config, p: manage.Placement) void {
        const toplevel = view.toplevel orelse return;
        if (!p.visible) {
            if (view.last != null) view.tree.node.setEnabled(false);
            view.last = null;
            return;
        }

        const geo = toplevel.base.geometry;
        const drawn: Drawn = .{
            .p = p,
            .geo_x = geo.x,
            .geo_y = geo.y,
            .colors = .{ cfg.border_focused, cfg.border_unfocused, cfg.border_floating },
        };
        if (view.last) |l| if (std.meta.eql(l, drawn)) return;
        const was_hidden = view.last == null;
        view.last = drawn;

        if (was_hidden) view.tree.node.setEnabled(true);

        // The layer decides what is drawn over what.
        if (view.layer != p.mode) {
            view.tree.node.reparent(view.server.layers[layerIndex(p.mode)]);
            view.layer = p.mode;
        }
        if (p.raise) view.tree.node.raiseToTop();

        if (view.sent_maximized != p.maximized) {
            view.sent_maximized = p.maximized;
            _ = toplevel.setMaximized(p.maximized);
        }

        view.tree.node.setPosition(p.rect.x, p.rect.y);

        // The client draws its geometry box (shadows and the like lie outside
        // it); that box is what fills the content rectangle. `clip` (relative
        // to the content's corner) cuts it further.
        view.surface_tree.node.setPosition(-geo.x, -geo.y);
        const content: Rect = .{ .x = 0, .y = 0, .w = p.rect.w, .h = p.rect.h };
        const shown = if (p.clip) |c| intersect(content, c) else content;
        if (shown) |r| {
            const clip: wlr.Box = .{ .x = geo.x + r.x, .y = geo.y + r.y, .width = r.w, .height = r.h };
            view.surface_tree.node.setEnabled(true);
            view.surface_tree.node.subsurfaceTreeSetClip(&clip);
        } else {
            view.surface_tree.node.setEnabled(false);
        }

        view.placeBorders(cfg, p);
    }

    fn layerIndex(mode: types.Mode) usize {
        return switch (mode) {
            .tiled => 0,
            .floating => 1,
            .fullscreen => 2,
        };
    }

    fn placeBorders(view: *View, cfg: *const config.Config, p: manage.Placement) void {
        const bw = p.border_width;
        if (p.border == .none or bw <= 0) {
            for (view.borders) |b| b.node.setEnabled(false);
            return;
        }
        const color = manage.rgba(manage.borderRgb(p.border, cfg));
        const w = p.rect.w;
        const h = p.rect.h;
        // top, bottom, left, right
        const boxes = [4]Rect{
            .{ .x = -bw, .y = -bw, .w = w + 2 * bw, .h = bw },
            .{ .x = -bw, .y = h, .w = w + 2 * bw, .h = bw },
            .{ .x = -bw, .y = 0, .w = bw, .h = h },
            .{ .x = w, .y = 0, .w = bw, .h = h },
        };
        for (view.borders, boxes) |b, box| {
            const r = (if (p.clip) |c| intersect(box, c) else box) orelse {
                b.node.setEnabled(false);
                continue;
            };
            b.node.setEnabled(true);
            b.node.setPosition(r.x, r.y);
            b.setSize(r.w, r.h);
            b.setColor(&color);
        }
    }

    // ---- toplevel events -----------------------------------------------------------------

    fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const view: *View = @fieldParentPtr("commit", listener);
        const toplevel = view.toplevel orelse return;
        const base = toplevel.base;
        if (base.initial_commit) {
            // The first configure must answer the initial commit. The size
            // comes from the manage pass once the window is placed; 0x0 lets
            // the client pick until then.
            _ = toplevel.setWmCapabilities(.{ .fullscreen = true, .maximize = true, .minimize = true });
            _ = toplevel.setSize(0, 0);
            return;
        }
        if (view.win) |win| {
            const geo = base.geometry;
            const old_w = win.actual_w;
            const old_h = win.actual_h;
            manage.setActualSize(win, geo.width, geo.height);
            const cur = toplevel.current;
            manage.setHints(win, cur.min_width, cur.min_height, cur.max_width, cur.max_height);
            if (old_w != geo.width or old_h != geo.height) view.server.scheduleManage();
        }
    }

    fn onMap(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("map", listener);
        const toplevel = view.toplevel orelse return;
        const server = view.server;
        const wm = server.wm;

        const win = manage.createWindow(
            wm,
            backend.handle(backend.Window, view),
            backend.handle(backend.Node, &view.tree.node),
        ) catch |err| {
            log.err("cannot add a window to the model: {t}", .{err});
            return;
        };
        view.win = win;
        view.layer = null;
        view.last = null;

        manage.setString(wm, &win.app_id, if (toplevel.app_id) |s| std.mem.span(s) else null);
        manage.setString(wm, &win.title, if (toplevel.title) |s| std.mem.span(s) else null);
        view.syncParent();
        const geo = toplevel.base.geometry;
        manage.setActualSize(win, geo.width, geo.height);
        const cur = toplevel.current;
        manage.setHints(win, cur.min_width, cur.min_height, cur.max_width, cur.max_height);

        // A client that maps already fullscreen keeps asking for it.
        if (toplevel.requested.fullscreen) manage.requestFullscreen(wm, win, true);
        server.scheduleManage();
    }

    fn onUnmap(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("unmap", listener);
        view.closeModelWindow();
    }

    fn closeModelWindow(view: *View) void {
        const win = view.win orelse return;
        view.win = null;
        view.tree.node.setEnabled(false);
        if (view.server.focused == view) view.server.focused = null;
        manage.closeWindowObject(view.server.wm, win);
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("destroy", listener);
        view.closeModelWindow();
        view.toplevel = null;

        view.commit.link.remove();
        view.map.link.remove();
        view.unmap.link.remove();
        view.destroy.link.remove();
        view.request_move.link.remove();
        view.request_resize.link.remove();
        view.request_maximize.link.remove();
        view.request_fullscreen.link.remove();
        view.request_minimize.link.remove();
        view.set_title.link.remove();
        view.set_app_id.link.remove();
        view.set_parent.link.remove();

        view.tree.node.destroy();
        view.server.gpa.destroy(view);
    }

    // ---- client requests ---------------------------------------------------------------------

    /// Client-initiated move/resize (a CSD title bar, a resize handle). Honoured
    /// only while a pointer button is down, as the protocol says.
    fn onRequestMove(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
        const view: *View = @fieldParentPtr("request_move", listener);
        const win = view.win orelse return;
        view.server.cursor.beginClientOp(.move, win, null);
    }

    fn onRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
        const view: *View = @fieldParentPtr("request_resize", listener);
        const win = view.win orelse return;
        view.server.cursor.beginClientOp(.resize, win, event.edges);
    }

    /// Maximize in a tiling layout is the column filling the work area. The
    /// protocol wants an answer either way.
    fn onRequestMaximize(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("request_maximize", listener);
        const toplevel = view.toplevel orelse return;
        if (view.win) |win| manage.requestMaximize(view.server.wm, win, toplevel.requested.maximized);
        if (toplevel.base.initialized) _ = toplevel.base.scheduleConfigure();
    }

    fn onRequestFullscreen(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("request_fullscreen", listener);
        const toplevel = view.toplevel orelse return;
        if (view.win) |win| {
            manage.requestFullscreen(view.server.wm, win, toplevel.requested.fullscreen);
        } else if (toplevel.base.initialized) {
            _ = toplevel.base.scheduleConfigure();
        }
    }

    fn onRequestMinimize(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("request_minimize", listener);
        const toplevel = view.toplevel orelse return;
        if (view.win) |win| manage.requestMinimize(view.server.wm, win);
        if (toplevel.base.initialized) _ = toplevel.base.scheduleConfigure();
    }

    fn onSetTitle(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("set_title", listener);
        const win = view.win orelse return;
        const toplevel = view.toplevel orelse return;
        manage.setString(view.server.wm, &win.title, if (toplevel.title) |s| std.mem.span(s) else null);
    }

    fn onSetAppId(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("set_app_id", listener);
        const win = view.win orelse return;
        const toplevel = view.toplevel orelse return;
        manage.setString(view.server.wm, &win.app_id, if (toplevel.app_id) |s| std.mem.span(s) else null);
        manage.appIdChanged(view.server.wm, win);
    }

    fn onSetParent(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("set_parent", listener);
        view.syncParent();
    }

    /// A dialog names its parent; the model floats windows that have one.
    fn syncParent(view: *View) void {
        const win = view.win orelse return;
        const toplevel = view.toplevel orelse return;
        win.parent = null;
        if (toplevel.parent) |p| {
            if (View.fromSurfaceTree(p.base.data)) |pv| win.parent = backend.handle(backend.Window, pv);
        }
    }

    /// The view an xdg surface's scene tree (`xdg_surface.data`) belongs to.
    pub fn fromSurfaceTree(data: ?*anyopaque) ?*View {
        const tree: *wlr.SceneTree = @ptrCast(@alignCast(data orelse return null));
        return fromNode(&tree.node);
    }

    /// The view whose tree contains `node`, found by walking up.
    pub fn fromNode(node: *wlr.SceneNode) ?*View {
        var it: ?*wlr.SceneNode = node;
        while (it) |n| : (it = if (n.parent) |p| &p.node else null) {
            if (n.data) |d| return @ptrCast(@alignCast(d));
        }
        return null;
    }
};

pub const Popup = struct {
    server: *Server,
    xdg_popup: *wlr.XdgPopup,

    commit: wl.Listener(*wlr.Surface) = .init(onCommit),
    destroy: wl.Listener(void) = .init(onDestroy),

    pub fn create(server: *Server, xdg_popup: *wlr.XdgPopup) !void {
        const xdg_surface = xdg_popup.base;
        // A popup of something that is not an xdg surface (layer shell, later)
        // is that other shell's business.
        const parent_surface = xdg_popup.parent orelse return;
        const parent = wlr.XdgSurface.tryFromWlrSurface(parent_surface) orelse return;
        const parent_tree: *wlr.SceneTree = @ptrCast(@alignCast(parent.data orelse return));

        const scene_tree = try parent_tree.createSceneXdgSurface(xdg_surface);
        xdg_surface.data = scene_tree;

        const popup = try server.gpa.create(Popup);
        popup.* = .{ .server = server, .xdg_popup = xdg_popup };
        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *Popup = @fieldParentPtr("commit", listener);
        if (!popup.xdg_popup.base.initial_commit) return;
        popup.unconstrain();
        _ = popup.xdg_popup.base.scheduleConfigure();
    }

    /// Keep the popup on the monitor its window is on.
    fn unconstrain(popup: *Popup) void {
        const server = popup.server;
        const parent_surface = popup.xdg_popup.parent orelse return;
        const parent = wlr.XdgSurface.tryFromWlrSurface(parent_surface) orelse return;
        const tree: *wlr.SceneTree = @ptrCast(@alignCast(parent.data orelse return));
        const view = View.fromNode(&tree.node) orelse return;

        var lx: c_int = 0;
        var ly: c_int = 0;
        _ = view.tree.node.coords(&lx, &ly);
        const wlr_output = server.output_layout.outputAt(@floatFromInt(lx), @floatFromInt(ly)) orelse return;
        var box: wlr.Box = undefined;
        server.output_layout.getBox(wlr_output, &box);
        const rel: wlr.Box = .{ .x = box.x - lx, .y = box.y - ly, .width = box.width, .height = box.height };
        popup.xdg_popup.unconstrainFromBox(&rel);
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("destroy", listener);
        popup.commit.link.remove();
        popup.destroy.link.remove();
        popup.server.gpa.destroy(popup);
    }
};
