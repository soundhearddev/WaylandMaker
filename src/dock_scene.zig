// SPDX-License-Identifier: GPL-3.0
//
// The Dock on the screen: the wlroots end of dock_sync.zig, and the glue that
// feeds the pointer to dock_input.zig and carries out what it asks for.
//
// What is where:
//
//   dock_model / dock_view   the tiles and what each one looks like (no pixels)
//   dock_draw / dock_icons   the pixels of a look, the picture of an icon
//   dock_input               the pointer's effect on the model (no wlroots)
//   dock_sync                model + input state -> which scene nodes exist
//   dock_scene (this file)   scene nodes and buffers, the event glue
//
// Every tile is a `wlr_scene_buffer` in the scene tree of its dock surface.
// The surface trees live in one of two parent trees, below or above the
// windows (`Server.dock_below` / `dock_above`), so raising a Dock is one
// `reparent`. A tile's buffer is rendered once per `Look` (and output scale)
// and shared: hovering a tile and leaving it again costs two `setBuffer`
// calls and no drawing at all.
//
// The pointer: `Cursor` asks `motion` / `button` / `axis` first. They say
// whether the dock took the event; a press on a tile is taken until its
// release, wherever the pointer goes in between (the drag).
//
// Times for double clicks and the fold timers are the compositor's clock
// (`Server.nowMs`), never the events' own: the nested backends give event
// times of another clock.
//
// NOT compiled against the zig-wlroots bindings when this was written (they
// were not reachable); the calls it makes are the ones view.zig / output.zig /
// server.zig already make, plus `SceneTree.createSceneBuffer`,
// `SceneBuffer.setBuffer` / `setDestSize`, `SceneNode.placeAbove` and
// `Buffer.drop`. The pixel buffer itself is src/wm_pixbuf.c, compiled and
// tested against wlroots' own headers.

const std = @import("std");
const log = std.log.scoped(.dock);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const config = model.config;
const types = model.types;
const backend = @import("backend.zig");
const dock_draw = @import("dock_draw.zig");
const dock_icons = @import("dock_icons.zig");
const dock_input = @import("dock_input.zig");
const dock_model = @import("dock_model.zig");
const dock_sync = @import("dock_sync.zig");
const dock_view = @import("dock_view.zig");
const dockapp = @import("dockapp.zig");
const dockhost = @import("dockhost.zig");
const gfx = @import("gfx.zig");
const process = @import("process.zig");
const wm_files = @import("wm_files.zig");

const Server = @import("server.zig").Server;

extern "c" fn wm_pixbuf_create(width: c_int, height: c_int, argb: [*]const u8, stride: usize) ?*wlr.Buffer;

const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;

/// Rendered tiles kept; past this the cache starts over (the scene keeps the
/// buffers it still shows alive on its own).
const max_cached_buffers = 256;

// ============================================================================
// The scene backend (what dock_sync.Sync needs)
// ============================================================================

const Scene = struct {
    gpa: std.mem.Allocator,
    below: *wlr.SceneTree,
    above: *wlr.SceneTree,
    /// The output scale the buffers are rendered for (whole numbers).
    scale: i32 = 1,
    /// Look.key() + scale -> the rendered tile.
    buffers: std.AutoHashMap(u64, *wlr.Buffer),
    /// icon_key -> the picture (null: looked for, none found).
    icons: std.AutoHashMap(u64, ?gfx.Icon),

    pub const Group = *wlr.SceneTree;
    pub const Node = *wlr.SceneBuffer;

    fn init(gpa: std.mem.Allocator, below: *wlr.SceneTree, above: *wlr.SceneTree) Scene {
        return .{ .gpa = gpa, .below = below, .above = above, .buffers = .init(gpa), .icons = .init(gpa) };
    }

    fn deinit(s: *Scene) void {
        s.forgetBuffers();
        s.forgetIcons();
        s.buffers.deinit();
        s.icons.deinit();
    }

    fn forgetBuffers(s: *Scene) void {
        var it = s.buffers.valueIterator();
        while (it.next()) |b| b.*.drop();
        s.buffers.clearRetainingCapacity();
    }

    fn forgetIcons(s: *Scene) void {
        var it = s.icons.valueIterator();
        while (it.next()) |maybe| if (maybe.*) |*ic| ic.deinit();
        s.icons.clearRetainingCapacity();
    }

    // ---- groups -------------------------------------------------------------

    pub fn createGroup(s: *Scene) !Group {
        return s.below.createSceneTree();
    }

    pub fn destroyGroup(_: *Scene, g: Group) void {
        g.node.destroy();
    }

    pub fn placeGroup(_: *Scene, g: Group, x: i32, y: i32) void {
        g.node.setPosition(x, y);
    }

    pub fn raiseGroup(s: *Scene, g: Group, up: bool) void {
        g.node.reparent(if (up) s.above else s.below);
    }

    // ---- tiles --------------------------------------------------------------

    pub fn createTile(s: *Scene, g: Group, t: dock_view.Tile, c: dock_sync.Content) !Node {
        const node = try g.createSceneBuffer(null);
        errdefer node.node.destroy();
        s.show(node, t, c);
        return node;
    }

    pub fn updateTile(s: *Scene, node: Node, t: dock_view.Tile, c: dock_sync.Content) void {
        s.show(node, t, c);
    }

    pub fn destroyTile(_: *Scene, node: Node) void {
        node.node.destroy();
    }

    fn show(s: *Scene, node: Node, t: dock_view.Tile, c: dock_sync.Content) void {
        node.node.setPosition(t.x, t.y);
        node.setDestSize(t.look.size, t.look.size);
        if (s.bufferFor(t.look, c)) |buf| node.setBuffer(buf);
        if (t.floating) node.node.raiseToTop();
    }

    // ---- pixels -------------------------------------------------------------

    /// The rendered tile for `look`: from the cache, else drawn now.
    fn bufferFor(s: *Scene, look: dock_view.Look, c: dock_sync.Content) ?*wlr.Buffer {
        const key = look.key() ^ (@as(u64, @intCast(s.scale)) *% 0x9e3779b97f4a7c15);
        if (s.buffers.get(key)) |b| return b;

        const side: usize = @intCast(dock_draw.deviceSide(look, s.scale));
        const bytes = s.gpa.alloc(u8, dock_draw.byteLen(look, s.scale)) catch return null;
        defer s.gpa.free(bytes);

        dock_draw.render(bytes, look, .{ .icon = s.iconFor(look, c), .name = c.name }, s.scale) catch |err| {
            log.warn("cannot draw a tile: {t}", .{err});
            return null;
        };
        const buf = wm_pixbuf_create(@intCast(side), @intCast(side), bytes.ptr, side * 4) orelse return null;

        if (s.buffers.count() >= max_cached_buffers) s.forgetBuffers();
        s.buffers.put(key, buf) catch {
            // Not cached: the scene is its only owner then.
            const owner = buf;
            owner.drop();
            return null;
        };
        return buf;
    }

    /// The icon of an app tile, loaded the first time it is needed. Only
    /// app tiles have one.
    fn iconFor(s: *Scene, look: dock_view.Look, c: dock_sync.Content) ?gfx.Icon {
        if (look.kind != .app or look.icon_key == 0) return null;
        const key = look.icon_key +% @intFromBool(look.mini);
        if (s.icons.get(key)) |hit| return hit;
        const slot = c.slot orelse return null;
        const loaded = dock_icons.resolve(s.gpa, slot.app);
        s.icons.put(key, loaded) catch {
            if (loaded) |ic| {
                var owned = ic;
                owned.deinit();
            }
            return null;
        };
        return loaded;
    }
};

// ============================================================================
// The Dock UI
// ============================================================================

pub const DockUi = struct {
    server: *Server,
    scene: Scene,
    sync: dock_sync.Sync(Scene),
    input: dock_input.Input = .{},
    /// Global position of the output the Dock is on (updated by `update`).
    origin: [2]i32 = .{ 0, 0 },
    size: [2]i32 = .{ 0, 0 },
    /// The model the surfaces were made from, and its generation.
    seen_model: ?*dock_model.Model = null,
    seen_built: ?u32 = null,
    timer: ?*wl.EventSource = null,

    pub fn create(server: *Server) !*DockUi {
        const gpa = server.gpa;
        const ui = try gpa.create(DockUi);
        errdefer gpa.destroy(ui);
        ui.* = .{
            .server = server,
            .scene = .init(gpa, server.dock_below, server.dock_above),
            .sync = undefined,
        };
        ui.sync = .init(gpa, &ui.scene);
        return ui;
    }

    pub fn destroy(ui: *DockUi) void {
        if (ui.timer) |t| t.remove();
        ui.sync.deinit();
        ui.scene.deinit();
        ui.server.gpa.destroy(ui);
    }

    fn nowMs32(ui: *const DockUi) u32 {
        return @truncate(ui.server.nowMs());
    }

    // ---- showing ------------------------------------------------------------

    /// The monitor the Dock is on (the model's primary output).
    fn primaryMonitor(ui: *DockUi) ?*@import("output.zig").Monitor {
        const out = types.primaryOutput(ui.server.wm) orelse return null;
        var it = ui.server.monitors.iterator(.forward);
        while (it.next()) |m| if (m.out == out) return m;
        return null;
    }

    /// Make the screen show the model as it is. Cheap when nothing changed.
    /// After every manage pass, and after every pointer event that changed
    /// what the dock looks like.
    pub fn update(ui: *DockUi) void {
        const wm = ui.server.wm;
        const cfg = &wm.cfg;
        const m = wm.dock orelse return ui.hideAll();
        const out = types.primaryOutput(wm) orelse return ui.hideAll();

        if (ui.seen_model != m or ui.seen_built != wm.dock_built) ui.modelChanged(m);
        ui.origin = .{ out.rect.x, out.rect.y };
        ui.size = .{ out.rect.w, out.rect.h };

        if (ui.primaryMonitor()) |mon| {
            const s: i32 = @max(1, @as(i32, @intFromFloat(@ceil(mon.wlr_output.scale))));
            if (s != ui.scene.scale) {
                ui.scene.scale = s;
                ui.scene.forgetBuffers();
                ui.sync.invalidate();
            }
        }
        ui.input.settings.single_click = cfg.dock_single_click;

        const shown = ui.sync.update(m, &ui.input, .{
            .origin = ui.origin,
            .dock_visible = cfg.dock_enabled,
            .clip_visible = cfg.clip_enabled,
            .dock_level = dock_model.levelFor(cfg.dock_on_top, cfg.dock_auto_raise),
            .clip_level = dock_model.levelFor(cfg.clip_on_top, cfg.clip_auto_raise),
        });
        ui.setShown(shown and cfg.dock_enabled);
        ui.armTimer();
    }

    fn hideAll(ui: *DockUi) void {
        ui.sync.dropAll();
        ui.input.reset();
        ui.setShown(false);
    }

    /// The Dock takes its column out of the work area once it is on screen
    /// (dockhost.update reads `wm.dock_shown`), and gives it back when it
    /// goes.
    fn setShown(ui: *DockUi, shown: bool) void {
        const wm = ui.server.wm;
        if (wm.dock_shown == shown) return;
        wm.dock_shown = shown;
        backend.manageDirty(wm.obj);
    }

    /// A new model (the config was reloaded): the surfaces and the pointer's
    /// memory refer to the old one; the folds start as the config says.
    fn modelChanged(ui: *DockUi, m: *dock_model.Model) void {
        const cfg = &ui.server.wm.cfg;
        ui.sync.dropAll();
        ui.input.reset();
        ui.scene.forgetBuffers();
        ui.scene.forgetIcons();
        ui.seen_model = m;
        ui.seen_built = ui.server.wm.dock_built;
        for (m.scr.clips.items) |c| {
            c.collapsed = cfg.clip_collapsed;
            c.auto_collapse = cfg.clip_auto_collapse;
        }
    }

    // ---- the pointer --------------------------------------------------------

    /// Output-local position of the pointer, or null when it is not on the
    /// Dock's output.
    fn local(ui: *const DockUi, lx: f64, ly: f64) ?[2]i32 {
        const x: i32 = @intFromFloat(@floor(lx));
        const y: i32 = @intFromFloat(@floor(ly));
        const rx = x - ui.origin[0];
        const ry = y - ui.origin[1];
        if (rx < 0 or ry < 0 or rx >= ui.size[0] or ry >= ui.size[1]) return null;
        return .{ rx, ry };
    }

    /// The pointer moved to (lx, ly). True: the dock has it (a tile is under
    /// it or one is pressed), no window should see the motion.
    pub fn motion(ui: *DockUi, lx: f64, ly: f64) bool {
        const m = ui.server.wm.dock orelse return false;
        const p = ui.local(lx, ly) orelse {
            if (ui.input.pressing()) return true;
            if (ui.input.leave(ui.nowMs32())) ui.update();
            return false;
        };
        const out = ui.input.motion(m, p[0], p[1], ui.nowMs32());
        ui.finish(out);
        return out.consumed;
    }

    pub fn button(ui: *DockUi, lx: f64, ly: f64, code: u32, pressed: bool) bool {
        const m = ui.server.wm.dock orelse return false;
        const btn: dock_input.Button = switch (code) {
            btn_left => .left,
            btn_right => .right,
            btn_middle => .middle,
            else => return ui.input.pressing(),
        };
        // A release ends a press whichever way the pointer left the output.
        const p = ui.local(lx, ly) orelse blk: {
            if (!ui.input.pressing()) return false;
            break :blk [2]i32{ -1, -1 };
        };
        const out = ui.input.button(m, p[0], p[1], btn, pressed, ui.nowMs32());
        ui.finish(out);
        return out.consumed;
    }

    pub fn axis(ui: *DockUi, lx: f64, ly: f64, delta: f64) bool {
        const m = ui.server.wm.dock orelse return false;
        if (!ui.server.wm.cfg.clip_scroll_workspaces) return false;
        const p = ui.local(lx, ly) orelse return false;
        const out = ui.input.scroll(m, p[0], p[1], delta);
        ui.finish(out);
        return out.consumed;
    }

    /// The pointer is not on the Dock's output any more.
    pub fn pointerLeft(ui: *DockUi) void {
        if (ui.input.leave(ui.nowMs32())) ui.update();
    }

    fn finish(ui: *DockUi, out: dock_input.Outcome) void {
        for (out.effects.slice()) |fx| ui.apply(fx);
        if (out.redraw or out.effects.len > 0) ui.update();
    }

    // ---- what the dock asks for ---------------------------------------------

    fn apply(ui: *DockUi, fx: dock_input.Effect) void {
        const wm = ui.server.wm;
        const m = wm.dock orelse return;
        switch (fx) {
            .launch => |l| ui.launch(m, l.slot),
            .activate => |index| {
                const s = m.slot(index) orelse return;
                if (dockhost.windowFor(wm, &s.app)) |w| dockhost.requestActivate(wm, w);
            },
            .workspace => |delta| {
                // The Clip changes the workspace of the output it is on.
                if (types.primaryOutput(wm)) |out| wm.active_output = out;
                wm.pending.append(wm.gpa, if (delta > 0) .workspace_next else .workspace_prev) catch {
                    log.warn("out of memory: workspace change dropped", .{});
                    return;
                };
                backend.manageDirty(wm.obj);
            },
            .place_dock => |p| {
                wm.cfg.dock_edge = p.edge;
                wm.cfg.dock_offset = p.offset;
                backend.manageDirty(wm.obj);
            },
            .place_clip => |corner| {
                wm.cfg.clip_corner = corner;
                backend.manageDirty(wm.obj);
            },
            .menu => |mn| log.info("dock menu at {d},{d}: not ported yet", .{ mn.x, mn.y }),
            .save => ui.save(m),
        }
    }

    fn launch(ui: *DockUi, m: *dock_model.Model, index: usize) void {
        const wm = ui.server.wm;
        const s = m.slot(index) orelse return;
        if (s.app.command.len == 0) return;
        if (!process.spawnChecked(wm, s.app.command)) return;
        m.markLaunching(index, ui.nowMs32());
        // The pass that follows lets the launch time out.
        backend.manageDirty(wm.obj);
    }

    /// Write WMState: the tiles where they are, and the Dock's and the
    /// Clip's own settings.
    fn save(ui: *DockUi, m: *dock_model.Model) void {
        const wm = ui.server.wm;
        if (!wm.cfg.dock_save_state) return;
        const path = wm.dock_state_path orelse return;
        var arena = std.heap.ArenaAllocator.init(wm.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = m.exportList(a) catch |err| {
            log.warn("dock state not saved: {t}", .{err});
            return;
        };
        const clip = m.currentClip();
        const state: dockapp.State = .{
            .edge = wm.cfg.dock_edge,
            .offset = wm.cfg.dock_offset,
            .clip_corner = wm.cfg.clip_corner,
            .clip_collapsed = clip.collapsed,
            .clip_auto_collapse = clip.auto_collapse,
        };
        wm_files.saveDockState(wm.io, wm.gpa, path, list, state) catch |err| {
            log.warn("dock state not saved to {s}: {t}", .{ path, err });
        };
    }

    // ---- time ---------------------------------------------------------------

    /// Wake the loop when a fold is due or a launch mark runs out.
    fn armTimer(ui: *DockUi) void {
        const now = ui.nowMs32();
        var wait: ?u32 = null;
        if (ui.input.deadline()) |at| wait = at -% now;
        if (ui.server.wm.dock) |m| if (m.nextLaunchExpiry(now, dockhost.launch_timeout_ms)) |ms| {
            wait = if (wait) |w| @min(w, ms) else ms;
        };
        const ms = wait orelse return;
        // A deadline already past counts as now (the difference wrapped).
        const delay: u32 = if (ms > 0x8000_0000) 1 else @max(ms, 1);

        const timer = ui.timer orelse blk: {
            const t = ui.server.loop.addTimer(*DockUi, onTimer, ui) catch {
                log.err("out of memory: cannot arm the dock timer", .{});
                return;
            };
            ui.timer = t;
            break :blk t;
        };
        timer.timerUpdate(@intCast(@min(delay, 60_000))) catch |err| log.warn("dock timer: {t}", .{err});
    }

    fn onTimer(ui: *DockUi) c_int {
        const now = ui.nowMs32();
        _ = ui.input.tick(now);
        if (ui.server.wm.dock) |m| _ = m.expireLaunching(now, dockhost.launch_timeout_ms);
        ui.update();
        return 0;
    }
};
