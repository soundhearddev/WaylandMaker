// SPDX-License-Identifier: 0BSD
//
// The Dock (Window Maker's "WMDock"), the Clip ("WMClip") and the Drawers:
// model, geometry and drawing. No Wayland types in here, like gfx.zig, so
// all of it is unit-testable without a compositor; ui.zig owns the surfaces
// and the pointer.
//
// The model is Window Maker's own (see wm_dock.zig, a port of dock.c): every
// icon has a grid position (xindex, yindex) relative to the first tile of
// its dock.
//
//   Dock    The logo tile and a COLUMN of tiles on the left or right screen
//           edge. Rows may be left empty. A fixed-size DockApp window
//           (app_id `dockapp:<name>`, at most 64x64) is put right into its
//           tile by dockhost.zig.
//   Clip    The workspace tile (number, name, an arrow upper right = next
//           and lower left = previous workspace) in a screen corner, and
//           the applications of the CURRENT workspace placed around it,
//           each one touching another. Tiles marked omnipresent follow the
//           workspace.
//   Drawer  A tile that hangs off the Dock and opens a ROW of tiles towards
//           the middle of the screen. Collapsed (only its tile) until the
//           pointer comes.
//
// Every dock is drawn on one surface that covers its tiles plus a margin
// where a dragged tile can still snap to. `Model` is a deep copy of what
// wm.dockapps held when it was built, so a config reload cannot leave it
// pointing into a freed arena.

const std = @import("std");
const gfx = @import("gfx.zig");
const config = @import("config.zig");
const dockapp = @import("dockapp.zig");
const xpm = @import("xpm.zig");
const types = @import("types.zig");
const wdock = @import("wm_dock.zig");

const Rect = types.Rect;

// ----------------------------------------------------------------------------
// Look (Window Maker / NeXT, same palette as the menu in ui.zig)
// ----------------------------------------------------------------------------

/// Window Maker's default icon size.
pub const tile: i32 = 64;
/// Side of the (square) icon inside a tile.
pub const icon_size: i32 = 48;
/// Edge length of the workspace arrow buttons in the Clip's corners.
pub const arrow: i32 = 16;

const font_logo: [:0]const u8 = "Sans Bold 22";
const font_letter: [:0]const u8 = "Sans Bold 24";
const font_number: [:0]const u8 = "Sans Bold 20";

const col_clear: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
const col_light = gfx.Color.rgb(0xffffff);
const col_dark = gfx.Color.rgb(0x555555);
const col_text = gfx.Color.rgb(0x000000);
const col_tile_from = gfx.Color.rgb(0xc6c2c6);
const col_tile_to = gfx.Color.rgb(0x9a969a);
const col_hot_from = gfx.Color.rgb(0xdedade);
const col_hot_to = gfx.Color.rgb(0xaeaaae);
const col_logo_from = gfx.Color.rgb(0x5a5a62);
const col_logo_to = gfx.Color.rgb(0x1e1e24);
const col_dot_shadow = gfx.Color.rgb(0x000000);
const col_stipple: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0x70 };
const col_arrow = gfx.Color.rgb(0x303030);
const col_arrow_hot = gfx.Color.rgb(0xffffff);
const col_gap: gfx.Color = .{ .r = 0x40, .g = 0x40, .b = 0x44, .a = 0xb0 };
const col_fade: gfx.Color = .{ .r = 0xd8, .g = 0xd8, .b = 0xdc, .a = 0xb0 };

// ----------------------------------------------------------------------------
// Model
// ----------------------------------------------------------------------------

pub const Slot = struct {
    app: dockapp.DockApp,
    icon: ?gfx.Icon = null,
    /// The grid icon. Owned by the model; it sits in a wdock.Dock while the
    /// slot is alive.
    gi: *wdock.Icon,
    /// false once the tile was taken away: the index stays reserved so
    /// references held by menus and presses never point at another tile.
    alive: bool = true,
    /// A window of this application is open (set by ui.zig every sync).
    running: bool = false,
    /// The application was started from this tile and has no window yet
    /// (Window Maker's `launching`). Cleared by `setRunning` as soon as a
    /// window matches, or by ui.zig after a time-out.
    launching: bool = false,
    /// Value of ui.zig's sync counter when `launching` was set.
    launch_stamp: u32 = 0,
};

/// Where the Dock/Clip sit relative to windows (Window Maker's "Dock
/// position" menu).
///   normal  below windows that overlap it; a click on it raises it
///   auto    raised while the pointer is on it ("Auto raise & lower")
///   top     always above windows ("Keep on Top"); the only level at which
///           the Dock reserves space
pub const Level = enum {
    normal,
    auto,
    top,

    pub fn label(l: Level) []const u8 {
        return switch (l) {
            .normal => "Normal",
            .auto => "Auto raise & lower",
            .top => "Keep on Top",
        };
    }
};

/// The level for the two config switches: `on_top` wins, then `auto`.
pub fn levelFor(on_top: bool, auto: bool) Level {
    if (on_top) return .top;
    return if (auto) .auto else .normal;
}

// ----------------------------------------------------------------------------
// The model
// ----------------------------------------------------------------------------

/// Most Drawers there can be.
pub const max_drawers: usize = 8;

/// The tiles a surface shows, as an inclusive grid rectangle.
pub const Cells = struct {
    minx: i32 = 0,
    miny: i32 = 0,
    maxx: i32 = 0,
    maxy: i32 = 0,

    pub fn cols(c: Cells) i32 {
        return c.maxx - c.minx + 1;
    }

    pub fn rows(c: Cells) i32 {
        return c.maxy - c.miny + 1;
    }
};

const Order = enum { y, x, abs_x };

pub const Model = struct {
    /// Owns every string in `slots`, `names` and `drawer_names`.
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    scr: wdock.Screen,
    slots: std.ArrayList(Slot) = .empty,
    names: []const []const u8 = &.{},
    workspace_count: u32,
    /// Parallel to scr.drawers.
    drawer_names: std.ArrayList([]const u8) = .empty,
    /// Where the Dock and the Clip are (output-local, see `layout`).
    dock_right: bool = true,
    dock_y: i32 = 0,
    clip_corner: config.ClipCorner = .top_left,
    /// false until the first `layout`: the positions the entries came with
    /// are already in the convention of the corner the config names, so
    /// that first call must not mirror them.
    laid_out: bool = false,

    pub const Error = error{ OutOfMemory, Full, NoDrawer };

    /// Build from `list`. `cfg_names` (config.conf) win over the names the
    /// list carries (Window Maker's WMState). Icons are loaded here, so
    /// building is the only moment this touches the filesystem.
    pub fn init(
        gpa: std.mem.Allocator,
        list: dockapp.List,
        cfg_names: []const []const u8,
        workspace_count: u32,
    ) !Model {
        var m: Model = .{
            .arena = .init(gpa),
            .gpa = gpa,
            .scr = .{ .gpa = gpa, .width = 1920, .height = 1080 },
            .workspace_count = @max(1, workspace_count),
        };
        errdefer m.deinit();
        const a = m.arena.allocator();

        m.scr.dock = try wdock.create(&m.scr, .dock, m.scr.width - tile, 0);
        for (0..m.workspace_count) |_| {
            const clip = try wdock.create(&m.scr, .clip, 0, 0);
            try m.scr.clips.append(gpa, clip);
        }
        const dock = m.scr.dock.?;
        for (list.drawers, 0..) |d, i| {
            if (i >= max_drawers) break;
            // A hand-edited or damaged state file may put a Drawer on the
            // logo's row or on another Drawer's: that would draw two tiles
            // on top of each other. The index must stay (the entries refer
            // to it), so such a Drawer moves to a free row instead.
            var row = d.row;
            if (row == 0 or wdock.getDrawer(&m.scr, row) != null) {
                row = m.freeRow() orelse row;
            }
            const dr = try wdock.create(&m.scr, .drawer, dock.x_pos, dock.y_pos + row * tile);
            dr.collapsed = d.collapsed;
            dr.auto_collapse = d.auto_collapse;
            try m.drawer_names.append(gpa, try a.dupe(u8, d.name));
        }

        const names = if (cfg_names.len > 0) cfg_names else list.workspace_names;
        const names_copy = try a.alloc([]const u8, names.len);
        for (names, 0..) |n, i| names_copy[i] = try a.dupe(u8, n);
        m.names = names_copy;

        for (list.apps) |app| {
            _ = m.insert(app) catch |err| {
                std.log.warn("dock: entry `{s}` dropped: {t}", .{ app.name, err });
            };
        }
        return m;
    }

    pub fn deinit(m: *Model) void {
        for (m.slots.items) |*s| if (s.icon) |*i| i.deinit();
        m.slots.deinit(m.gpa);
        m.drawer_names.deinit(m.gpa);
        // Frees every dock with the icons still in it.
        m.scr.deinit();
        m.arena.deinit();
        m.* = undefined;
    }

    // ---- placing --------------------------------------------------------------

    fn clipOf(m: *const Model, ws: u32) *wdock.Dock {
        const n = m.scr.clips.items.len;
        return m.scr.clips.items[@min(@as(usize, ws), n - 1)];
    }

    fn occupied(dock: *const wdock.Dock, x: i32, y: i32) bool {
        for (dock.icons) |maybe| {
            if (maybe) |i| if (i.xindex == x and i.yindex == y) return true;
        }
        return false;
    }

    /// First free row of the Dock column, searching 1, -1, 2, -2, ... Skips
    /// rows a Drawer hangs on. (wDockFindFreeSlot would also use the sides
    /// of the Dock here; the Dock is a single column.)
    pub fn dockFreeRow(m: *const Model) ?i32 {
        const dock = m.scr.dock orelse return null;
        if (dock.icon_count >= dock.icons.len) return null;
        return m.freeRow();
    }

    /// The first row of the Dock column that is free, searching 1, -1, 2,
    /// -2, ...: not the logo's, none with a tile or a Drawer on it, and one
    /// that lies on the screen.
    fn freeRow(m: *const Model) ?i32 {
        const dock = m.scr.dock orelse return null;
        var step: i32 = 1;
        while (step <= @as(i32, @intCast(dock.icons.len))) : (step += 1) {
            for ([_]i32{ step, -step }) |y| {
                if (occupied(dock, 0, y)) continue;
                if (wdock.getDrawer(&m.scr, y) != null) continue;
                if (!m.scr.onScreen(dock.x_pos, dock.y_pos + y * tile)) continue;
                return y;
            }
        }
        return null;
    }

    fn insert(m: *Model, app: dockapp.DockApp) !usize {
        const a = m.arena.allocator();
        const gpa = m.gpa;
        const copy = try dupeApp(a, app);

        const gi = try gpa.create(wdock.Icon);
        errdefer gpa.destroy(gi);
        gi.* = .{
            .has_command = copy.command.len > 0,
            .lock = copy.locked,
            .auto_launch = copy.autolaunch,
            .tag = m.slots.items.len,
        };

        var omnipresent = false;
        const dock: *wdock.Dock = switch (copy.place) {
            .dock => m.scr.dock.?,
            .clip => blk: {
                omnipresent = copy.workspace == null;
                break :blk m.clipOf(copy.workspace orelse @intCast(m.scr.current_workspace));
            },
            .drawer => blk: {
                if (copy.drawer >= m.scr.drawers.items.len) return error.NoDrawer;
                break :blk m.scr.drawers.items[copy.drawer];
            },
        };

        // A position further away than the dock could ever be long is a
        // damaged value: the entry is placed like a new one.
        const reach: u32 = @intCast(@max(dock.icons.len, wdock.dock_max_icons));
        const in_reach = @abs(copy.x) <= reach and @abs(copy.y) <= reach;
        var xy: [2]i32 = undefined;
        switch (copy.place) {
            .dock => {
                if (in_reach and copy.y != 0 and !occupied(dock, 0, copy.y) and wdock.getDrawer(&m.scr, copy.y) == null) {
                    xy = .{ 0, copy.y };
                } else xy = .{ 0, m.dockFreeRow() orelse return error.Full };
            },
            .clip => {
                if (in_reach and (copy.x != 0 or copy.y != 0) and !occupied(dock, copy.x, copy.y)) {
                    xy = .{ copy.x, copy.y };
                } else xy = (try wdock.findFreeSlot(&m.scr, dock)) orelse return error.Full;
            },
            .drawer => xy = (try wdock.findFreeSlot(&m.scr, dock)) orelse return error.Full,
        }
        if (!wdock.attachIcon(dock, gi, xy[0], xy[1])) return error.Full;
        errdefer wdock.detach(&m.scr, dock, gi);
        if (omnipresent) _ = wdock.makeIconOmnipresent(&m.scr, gi, true);

        var new: Slot = .{ .app = copy, .gi = gi };
        new.icon = loadIcon(gpa, copy);
        errdefer if (new.icon) |*i| i.deinit();
        try m.slots.append(gpa, new);
        return m.slots.items.len - 1;
    }

    /// Put a new tile in the first free place of the Dock (`place = dock`),
    /// of the CURRENT workspace's Clip (`place = clip`) or of Drawer
    /// `app.drawer`. "Keep Application" and the "Move Icon To" menu use it.
    pub fn addApp(m: *Model, app: dockapp.DockApp) !usize {
        var copy = app;
        copy.x = 0;
        copy.y = 0;
        if (copy.place == .clip and copy.workspace != null) copy.workspace = @intCast(m.scr.current_workspace);
        return m.insert(copy);
    }

    // ---- looking -----------------------------------------------------------------

    pub fn workspaceName(m: *const Model, ws: u32) ?[]const u8 {
        if (ws >= m.names.len) return null;
        const n = m.names[ws];
        return if (n.len == 0) null else n;
    }

    /// The live slot `index`, if it is one.
    pub fn slot(m: *const Model, index: usize) ?*Slot {
        if (index >= m.slots.items.len) return null;
        const s = &m.slots.items[index];
        return if (s.alive) s else null;
    }

    /// The slot of a grid icon (null for a dock's own main tile).
    pub fn slotOf(m: *const Model, gi: *const wdock.Icon) ?*Slot {
        if (gi.main) return null;
        return m.slot(gi.tag);
    }

    /// The Dock tile whose entry matches a window with this app_id.
    pub fn dockSlotFor(m: *const Model, app_id: []const u8) ?usize {
        for (m.slots.items, 0..) |s, i| {
            if (!s.alive) continue;
            const d = s.gi.dock orelse continue;
            if (d.kind != .dock) continue;
            if (s.app.matches(app_id)) return i;
        }
        return null;
    }

    pub fn hasApp(m: *const Model, app_id: []const u8) bool {
        for (m.slots.items) |s| {
            if (s.alive and s.app.matches(app_id)) return true;
        }
        return false;
    }

    /// Mark the tiles whose application has a window; true if that changed.
    /// A window ends `launching`.
    pub fn setRunning(m: *Model, app_ids: []const []const u8) bool {
        var changed = false;
        for (m.slots.items) |*s| {
            if (!s.alive) continue;
            var run = false;
            for (app_ids) |id| {
                if (s.app.matches(id)) {
                    run = true;
                    break;
                }
            }
            if (s.running != run) {
                s.running = run;
                changed = true;
            }
            if (run and s.launching) {
                s.launching = false;
                changed = true;
            }
        }
        return changed;
    }

    pub fn markLaunching(m: *Model, index: usize, stamp: u32) void {
        const s = m.slot(index) orelse return;
        if (s.app.command.len == 0) return;
        s.launching = true;
        s.launch_stamp = stamp;
    }

    /// Milliseconds until the first `launching` mark runs out (0: it has),
    /// or null if no tile is launching. For the event loop's timeout.
    pub fn nextLaunchExpiry(m: *const Model, now: u32, max_age: u32) ?u32 {
        var best: ?u32 = null;
        for (m.slots.items) |s| {
            if (!s.alive or !s.launching) continue;
            const age = now -% s.launch_stamp;
            const left: u32 = if (age > max_age) 0 else max_age - age + 1;
            if (best == null or left < best.?) best = left;
        }
        return best;
    }

    /// Clear `launching` on tiles older than `max_age` (wrapping clock).
    pub fn expireLaunching(m: *Model, now: u32, max_age: u32) bool {
        var changed = false;
        for (m.slots.items) |*s| {
            if (s.alive and s.launching and now -% s.launch_stamp > max_age) {
                s.launching = false;
                changed = true;
            }
        }
        return changed;
    }

    // ---- changing --------------------------------------------------------------

    /// Take a tile away (not if it is locked). In a Drawer the others close
    /// the gap.
    pub fn removeSlot(m: *Model, index: usize) bool {
        const s = m.slot(index) orelse return false;
        if (s.app.locked) return false;
        const dock = s.gi.dock orelse return false;
        wdock.detach(&m.scr, dock, s.gi);
        if (dock.kind == .drawer) wdock.drawerFillTheGap(dock, s.gi, false);
        m.gpa.destroy(s.gi);
        if (s.icon) |*i| i.deinit();
        s.icon = null;
        s.alive = false;
        return true;
    }

    /// Apply a snap result of `wdock.snapIcon`: the tile now sits at `xy`
    /// of `dest`, which may be another dock. False if it did not fit.
    pub fn dropSlot(m: *Model, index: usize, dest: *wdock.Dock, xy: [2]i32) bool {
        const s = m.slot(index) orelse return false;
        const src = s.gi.dock orelse return false;
        if (src == dest) {
            wdock.reattachIcon(dest, s.gi, xy[0], xy[1]);
            return true;
        }
        if (dest.kind == .dock and s.app.command.len == 0) return false;
        if (!wdock.moveIconBetweenDocks(&m.scr, src, dest, s.gi, xy[0], xy[1])) return false;
        s.app.place = switch (dest.kind) {
            .dock => .dock,
            .clip => .clip,
            .drawer => .drawer,
        };
        if (dest.kind == .clip) s.app.workspace = @intCast(m.scr.current_workspace);
        if (src.kind == .drawer) wdock.drawerFillTheGap(src, s.gi, false);
        return true;
    }

    // ---- temporary tiles for DockApps -------------------------------------------

    /// A self-declared DockApp (`dockapp:<name>`) is running but has no tile:
    /// give it a temporary one in the Dock. It is not saved and goes away
    /// with the program (`pruneAttached`). Returns the slot index.
    pub fn attach(m: *Model, name: []const u8) !usize {
        return m.insert(.{ .name = name, .command = &.{}, .attached = true });
    }

    /// Remove every temporary tile whose program has quit. True if any went.
    pub fn pruneAttached(m: *Model) bool {
        var changed = false;
        for (m.slots.items, 0..) |*s, i| {
            if (s.alive and s.app.attached and !s.running and !s.launching) {
                s.app.locked = false;
                if (m.removeSlot(i)) changed = true;
            }
        }
        return changed;
    }

    /// "Keep Icon": make a temporary tile permanent. The command is the
    /// DockApp's name (name the app_id after the program).
    pub fn keepAttached(m: *Model, index: usize) bool {
        const s = m.slot(index) orelse return false;
        if (!s.app.attached) return false;
        const a = m.arena.allocator();
        const argv = a.alloc([]const u8, 1) catch return false;
        argv[0] = s.app.name;
        s.app.command = argv;
        s.app.attached = false;
        s.gi.has_command = true;
        return true;
    }

    // ---- Drawers --------------------------------------------------------------

    /// addADrawer: a new Drawer on the first free row next to the Dock.
    pub fn addDrawer(m: *Model, name: []const u8) !?*wdock.Dock {
        const dock = m.scr.dock orelse return null;
        if (m.scr.drawers.items.len >= max_drawers) return null;
        if (dock.icon_count + m.scr.drawers.items.len >= dock.icons.len) return null;
        const row = m.freeRow() orelse return null;
        const y = dock.y_pos + row * tile;
        const dr = try wdock.create(&m.scr, .drawer, dock.x_pos, y);
        dr.collapsed = true;
        m.drawer_names.append(m.gpa, m.arena.allocator().dupe(u8, name) catch {
            m.removeDrawerRaw(dr);
            return error.OutOfMemory;
        }) catch {
            m.removeDrawerRaw(dr);
            return error.OutOfMemory;
        };
        return dr;
    }

    fn removeDrawerRaw(m: *Model, d: *wdock.Dock) void {
        wdock.removeDrawer(&m.scr, d);
    }

    /// Drag a Drawer's tile: it goes to the Dock row nearest to `top_y`
    /// (output-local top edge of the tile) if that row is free.
    pub fn moveDrawerToward(m: *Model, d: *wdock.Dock, top_y: i32) bool {
        const dock = m.scr.dock orelse return false;
        const row = @divFloor(top_y - dock.y_pos + @divTrunc(tile, 2), tile);
        const y = dock.y_pos + row * tile;
        if (row == 0 or occupied(dock, 0, row) or !m.scr.onScreen(dock.x_pos, y)) return false;
        if (wdock.getDrawer(&m.scr, row)) |other| {
            if (other != d) return false;
            return true;
        }
        wdock.moveDock(&m.scr, d, d.x_pos, y);
        return true;
    }

    /// "Move Icon To" (Clip tiles): show the tile on workspace `ws`, or on
    /// all of them (null).
    pub fn setSlotWorkspace(m: *Model, index: usize, ws: ?u32) bool {
        const s = m.slot(index) orelse return false;
        if (s.app.place != .clip) return false;
        const gi = s.gi;
        const src = gi.dock orelse return false;
        if (ws == null) {
            if (wdock.makeIconOmnipresent(&m.scr, gi, true) == .failed) return false;
            s.app.workspace = null;
            return true;
        }
        _ = wdock.makeIconOmnipresent(&m.scr, gi, false);
        const dest = m.clipOf(ws.?);
        s.app.workspace = ws;
        if (dest == src) return true;
        const xy: [2]i32 = if (occupied(dest, gi.xindex, gi.yindex))
            ((wdock.findFreeSlot(&m.scr, dest) catch null) orelse return false)
        else
            .{ gi.xindex, gi.yindex };
        return wdock.moveIconBetweenDocks(&m.scr, src, dest, gi, xy[0], xy[1]);
    }

    pub fn drawerIndex(m: *const Model, d: *const wdock.Dock) ?usize {
        for (m.scr.drawers.items, 0..) |x, i| if (x == d) return i;
        return null;
    }

    /// Remove a Drawer and the tiles in it (locked ones too: the Drawer is
    /// going away).
    pub fn removeDrawer(m: *Model, d: *wdock.Dock) void {
        const di = m.drawerIndex(d) orelse return;
        for (m.slots.items, 0..) |*s, i| {
            if (s.alive and s.gi.dock == d) {
                s.app.locked = false;
                _ = m.removeSlot(i);
            }
        }
        _ = m.drawer_names.orderedRemove(di);
        wdock.removeDrawer(&m.scr, d);
    }

    // ---- placement on the output ---------------------------------------------

    /// Tell the model how big the output is and where the Dock and the Clip
    /// are on it (output-local coordinates). Moves everything; cheap.
    pub fn layout(m: *Model, w: i32, h: i32, dock_right: bool, dock_y: i32, corner: config.ClipCorner) void {
        m.scr.width = w;
        m.scr.height = h;
        m.dock_right = dock_right;
        m.dock_y = dock_y;
        // The Clip's tiles lie on the side of the corner that points into
        // the screen (see wdock.findFreeSlot): when the Clip changes sides,
        // they change sides with it, or they would end up off the screen.
        const flip_x = m.laid_out and clipOnLeft(corner) != clipOnLeft(m.clip_corner);
        const flip_y = m.laid_out and clipOnTop(corner) != clipOnTop(m.clip_corner);
        m.laid_out = true;
        m.clip_corner = corner;
        if (flip_x or flip_y) mirrorClips(m, flip_x, flip_y);

        if (m.scr.dock) |dock| {
            if (dock.on_right_side != dock_right) wdock.swap(&m.scr, dock);
            const x: i32 = if (dock_right) w - tile else 0;
            const y = m.clampDockY(dock_y, h);
            if (dock.x_pos != x or dock.y_pos != y) wdock.moveDock(&m.scr, dock, x, y);
        }
        const cx: i32 = if (clipOnLeft(corner)) 0 else w - tile;
        const cy: i32 = if (clipOnTop(corner)) 0 else h - tile;
        for (m.scr.clips.items) |c| {
            if (flip_x or flip_y or c.x_pos != cx or c.y_pos != cy) wdock.moveDock(&m.scr, c, cx, cy);
        }
    }

    /// Mirror the tiles of every Clip across the Clip's own tile.
    fn mirrorClips(m: *Model, flip_x: bool, flip_y: bool) void {
        for (m.scr.clips.items) |c| {
            for (c.icons) |maybe| {
                const b = maybe orelse continue;
                if (b.main) continue;
                if (flip_x) b.xindex = -b.xindex;
                if (flip_y) b.yindex = -b.yindex;
            }
        }
    }

    /// The topmost and the lowest row of the Dock column (the logo is row
    /// 0), Drawers included.
    fn rowRange(m: *const Model) [2]i32 {
        const dock = m.scr.dock orelse return .{ 0, 0 };
        var lo: i32 = 0;
        var hi: i32 = 0;
        for (dock.icons) |maybe| {
            const i = maybe orelse continue;
            lo = @min(lo, i.yindex);
            hi = @max(hi, i.yindex);
        }
        for (m.scr.drawers.items) |d| {
            const row = @divTrunc(d.y_pos - dock.y_pos, tile);
            lo = @min(lo, row);
            hi = @max(hi, row);
        }
        return .{ lo, hi };
    }

    /// The Dock's top edge for the wish `want`: as near to it as it can be
    /// with every tile and every Drawer still on the screen. (If the column
    /// is taller than the screen, only the logo is kept on it.)
    fn clampDockY(m: *const Model, want: i32, h: i32) i32 {
        const r = m.rowRange();
        const lo = -r[0] * tile;
        const hi = h - (r[1] + 1) * tile;
        if (lo > hi) return std.math.clamp(want, 0, @max(0, h - tile));
        return std.math.clamp(want, lo, hi);
    }

    pub fn currentClip(m: *const Model) *wdock.Dock {
        return m.clipOf(@intCast(m.scr.current_workspace));
    }

    /// The Clip follows the workspace: omnipresent tiles move along.
    pub fn setWorkspace(m: *Model, ws: u32) void {
        if (ws >= m.scr.clips.items.len or ws == m.scr.current_workspace) return;
        wdock.clipUpdateForWorkspaceChange(&m.scr, ws);
    }

    // ---- saving ----------------------------------------------------------------

    const SortCtx = struct {
        order: Order,
        fn lt(ctx: SortCtx, a: *const Slot, b: *const Slot) bool {
            return switch (ctx.order) {
                .y => a.gi.yindex < b.gi.yindex,
                .x => if (a.gi.xindex != b.gi.xindex) a.gi.xindex < b.gi.xindex else a.gi.yindex < b.gi.yindex,
                .abs_x => @abs(a.gi.xindex) < @abs(b.gi.xindex),
            };
        }
    };

    fn appendSorted(
        m: *const Model,
        a: std.mem.Allocator,
        out: *std.ArrayList(dockapp.DockApp),
        dock: *const wdock.Dock,
        order: Order,
        place: dockapp.Place,
        ws: ?u32,
        drawer: u32,
        omni: ?bool,
    ) !void {
        var tmp: std.ArrayList(*const Slot) = .empty;
        defer tmp.deinit(a);
        for (m.slots.items) |*s| {
            if (!s.alive or s.app.attached or s.gi.dock != dock) continue;
            if (omni) |o| if (s.gi.omnipresent != o) continue;
            try tmp.append(a, s);
        }
        std.mem.sort(*const Slot, tmp.items, SortCtx{ .order = order }, SortCtx.lt);
        for (tmp.items) |s| {
            var app = s.app;
            app.place = place;
            app.workspace = ws;
            app.drawer = drawer;
            app.x = s.gi.xindex;
            app.y = s.gi.yindex;
            try out.append(a, app);
        }
    }

    /// Everything the Model holds as one list, for writing it out.
    /// Temporary (`attached`) tiles are left out. The strings stay owned by
    /// the Model.
    pub fn exportList(m: *const Model, a: std.mem.Allocator) !dockapp.List {
        var out: std.ArrayList(dockapp.DockApp) = .empty;
        const dock = m.scr.dock.?;
        try m.appendSorted(a, &out, dock, .y, .dock, null, 0, null);
        for (m.scr.clips.items, 0..) |c, ws| {
            try m.appendSorted(a, &out, c, .x, .clip, @intCast(ws), 0, false);
        }
        // Omnipresent tiles live in the current Clip but belong to all
        // workspaces: `workspace = null`.
        try m.appendSorted(a, &out, m.currentClip(), .x, .clip, null, 0, true);
        for (m.scr.drawers.items, 0..) |d, di| {
            try m.appendSorted(a, &out, d, .abs_x, .drawer, null, @intCast(di), null);
        }

        const drawers = try a.alloc(dockapp.DrawerInfo, m.scr.drawers.items.len);
        for (m.scr.drawers.items, 0..) |d, i| {
            drawers[i] = .{
                .name = m.drawer_names.items[i],
                .row = @divTrunc(d.y_pos - dock.y_pos, tile),
                .collapsed = d.collapsed,
                .auto_collapse = d.auto_collapse,
            };
        }
        return .{
            .apps = try out.toOwnedSlice(a),
            .workspace_names = m.names,
            .drawers = drawers,
            .logo_y = 0,
        };
    }
};

fn dupeApp(a: std.mem.Allocator, app: dockapp.DockApp) !dockapp.DockApp {
    var copy = app;
    copy.name = try a.dupe(u8, app.name);
    const argv = try a.alloc([]const u8, app.command.len);
    for (app.command, 0..) |arg, i| argv[i] = try a.dupe(u8, arg);
    copy.command = argv;
    if (app.icon) |i| copy.icon = try a.dupe(u8, i);
    if (app.app_id) |i| copy.app_id = try a.dupe(u8, i);
    return copy;
}

// ----------------------------------------------------------------------------
// Icons
// ----------------------------------------------------------------------------

/// Directories searched for a bare icon name (no '/'), best size first.
const icon_dirs = [_][]const u8{
    "/usr/share/icons/hicolor/64x64/apps",
    "/usr/share/icons/hicolor/48x48/apps",
    "/usr/share/icons/hicolor/128x128/apps",
    "/usr/share/icons/hicolor/256x256/apps",
    "/usr/share/icons/hicolor/32x32/apps",
    "/usr/share/pixmaps",
};

/// The icon of `app`: its `icon` key (a path, or a name looked up in
/// `icon_dirs`), or else the program's own name. PNG and XPM (Window Maker's
/// own format, see xpm.zig); anything else (SVG) just means "no icon", and
/// the tile shows the first letter of the name instead.
fn loadIcon(gpa: std.mem.Allocator, app: dockapp.DockApp) ?gfx.Icon {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    const wanted: []const u8 = app.icon orelse blk: {
        if (app.command.len == 0) break :blk app.name;
        break :blk std.fs.path.basename(app.command[0]);
    };
    if (wanted.len == 0) return null;

    // A path: the extension decides the decoder.
    if (std.mem.indexOfScalar(u8, wanted, '/') != null) {
        const path = std.fmt.bufPrintZ(&buf, "{s}", .{wanted}) catch return null;
        return loadFile(gpa, path);
    }

    // A name: strip an extension someone wrote anyway, then search every
    // directory for a PNG, then an XPM.
    var stem = wanted;
    inline for (.{ ".png", ".xpm" }) |ext| {
        if (std.mem.endsWith(u8, stem, ext)) stem = stem[0 .. stem.len - ext.len];
    }
    inline for (.{ ".png", ".xpm" }) |ext| {
        for (icon_dirs) |dir| {
            const path = std.fmt.bufPrintZ(&buf, "{s}/{s}" ++ ext, .{ dir, stem }) catch continue;
            if (loadFile(gpa, path)) |icon| return icon;
        }
    }
    return null;
}

fn loadFile(gpa: std.mem.Allocator, path: [:0]const u8) ?gfx.Icon {
    if (std.ascii.endsWithIgnoreCase(path, ".xpm")) {
        const pm = xpm.load(gpa, path) orelse return null;
        defer pm.deinit(gpa);
        return gfx.Icon.fromPixels(pm.width, pm.height, pm.pixels);
    }
    return gfx.Icon.loadPng(path);
}

// ----------------------------------------------------------------------------
// Geometry (output-local grid <-> surface pixels)
// ----------------------------------------------------------------------------

pub fn clipOnLeft(corner: config.ClipCorner) bool {
    return corner == .top_left or corner == .bottom_left;
}

pub fn clipOnTop(corner: config.ClipCorner) bool {
    return corner == .top_left or corner == .top_right;
}

/// The grid rectangle one dock's surface covers. `margin` adds the cells a
/// dragged tile can still snap to (3 rows around the Dock, 1 cell around a
/// Clip, 1 column at the end of a Drawer); the surface has to be that big
/// before a drag starts, because a surface replaced mid-drag loses the
/// pointer grab. `only_main`: a collapsed Clip or Drawer shows its tile only.
pub fn cellsOf(d: *const wdock.Dock, only_main: bool, margin: bool) Cells {
    var c: Cells = .{};
    if (!only_main) {
        for (d.icons) |maybe| {
            const i = maybe orelse continue;
            c.minx = @min(c.minx, i.xindex);
            c.maxx = @max(c.maxx, i.xindex);
            c.miny = @min(c.miny, i.yindex);
            c.maxy = @max(c.maxy, i.yindex);
        }
    }
    if (margin and !only_main) {
        const mx: i32, const my: i32 = switch (d.kind) {
            .dock => .{ 0, 3 },
            .clip => .{ 1, 1 },
            .drawer => .{ 1, 0 },
        };
        c.minx -= mx;
        c.maxx += mx;
        c.miny -= my;
        c.maxy += my;
    }
    return c;
}

/// The grid cell under surface-local pixel (x, y).
pub fn cellAt(c: Cells, x: i32, y: i32) [2]i32 {
    return .{ c.minx + @divFloor(x, tile), c.miny + @divFloor(y, tile) };
}

/// The icon of `d` in grid cell `xy`.
pub fn iconAt(d: *const wdock.Dock, xy: [2]i32) ?*wdock.Icon {
    for (d.icons) |maybe| {
        if (maybe) |i| if (i.xindex == xy[0] and i.yindex == xy[1]) return i;
    }
    return null;
}

/// Surface-local pixel position of grid cell (x, y).
pub fn cellPx(c: Cells, x: i32, y: i32) [2]i32 {
    return .{ (x - c.minx) * tile, (y - c.miny) * tile };
}

/// Which edge and offset a Dock dragged so that its first tile lies at
/// output-local (gx, gy) belongs to: the nearer screen half wins the edge,
/// the offset is the distance from the top of the output.
pub fn dockPlacementFor(out: Rect, gx: i32, gy: i32) struct { edge: config.DockEdge, offset: i32 } {
    const centre = gx + @divTrunc(tile, 2);
    const edge: config.DockEdge = if (centre < out.x + @divTrunc(out.w, 2)) .left else .right;
    return .{ .edge = edge, .offset = @max(0, gy - out.y) };
}

/// The corner of `out` that global point (gx, gy) is nearest to: where a
/// dragged Clip lands.
pub fn clipCornerFor(out: Rect, gx: i32, gy: i32) config.ClipCorner {
    const left = gx < out.x + @divTrunc(out.w, 2);
    const top = gy < out.y + @divTrunc(out.h, 2);
    return if (top) (if (left) .top_left else .top_right) else (if (left) .bottom_left else .bottom_right);
}

// ----------------------------------------------------------------------------
// Drawing
// ----------------------------------------------------------------------------

pub const Arrow = enum { none, prev, next };

/// Which workspace arrow is under (x, y), given relative to the Clip tile's
/// own top-left corner. Upper right = next, lower left = previous.
pub fn clipArrowAt(x: i32, y: i32) Arrow {
    if (x < 0 or y < 0 or x >= tile or y >= tile) return .none;
    if (x >= tile - arrow and y < arrow) return .next;
    if (x < arrow and y >= tile - arrow) return .prev;
    return .none;
}

fn drawFrame(cv: *gfx.Canvas, x: i32, y: i32, hot: bool, from: ?gfx.Color, to: ?gfx.Color) void {
    const f = from orelse if (hot) col_hot_from else col_tile_from;
    const t = to orelse if (hot) col_hot_to else col_tile_to;
    cv.dGradient(x, y, tile, tile, f, t);
    cv.bevel(x, y, tile, tile, col_light, col_dark);
    cv.bevel(x + 1, y + 1, tile - 2, tile - 2, col_light, col_dark);
}

/// Window Maker's mark for "docked, but not running": three small dots in
/// the lower left corner (appicon.c's `dock_dots`, drawn at x = 4, 9, 14 and
/// `tile - 6`, each 3 x 2 px). A running application's tile is left plain.
fn drawNotRunning(cv: *gfx.Canvas, x: i32, y: i32) void {
    const dy = y + tile - 6;
    var dx: i32 = 4;
    while (dx <= 14) : (dx += 5) {
        cv.fillRect(x + dx + 1, dy + 1, 3, 2, col_dot_shadow);
        cv.fillRect(x + dx, dy, 3, 2, col_light);
    }
}

/// The raster Window Maker lays over an icon while its application starts
/// (`stipple_gc`): every second pixel darkened.
fn drawLaunching(cv: *gfx.Canvas, x: i32, y: i32) void {
    var py: i32 = 2;
    while (py < tile - 2) : (py += 1) {
        var sx: i32 = 2 + @mod(py, 2);
        while (sx < tile - 2) : (sx += 2) cv.fillRect(x + sx, y + py, 1, 1, col_stipple);
    }
}

/// Window Maker's "omnipresent" corner (appicon.c `drawCorner`): a small
/// folded corner at the upper right of a Clip tile that is on every
/// workspace.
fn drawOmnipresent(cv: *gfx.Canvas, x: i32, y: i32) void {
    const fx: f64 = @floatFromInt(x + tile - 2);
    const fy: f64 = @floatFromInt(y + 2);
    cv.fillPolygon(&.{ .{ fx - 10, fy }, .{ fx, fy }, .{ fx, fy + 10 } }, col_dark);
    cv.fillPolygon(&.{ .{ fx - 8, fy + 1 }, .{ fx - 1, fy + 1 }, .{ fx - 1, fy + 8 } }, col_light);
}

fn drawCentered(cv: *gfx.Canvas, text: [:0]const u8, x: i32, y: i32, w: i32, font: [:0]const u8, col: gfx.Color) void {
    const tw = gfx.measureText(text, font).w;
    cv.drawText(text, x + @divTrunc(w - tw, 2), y, font, col);
}

/// One application tile at (x, y). A tile whose docked window is on top of
/// it is still drawn: the window simply covers it.
fn drawAppTile(cv: *gfx.Canvas, x: i32, y: i32, slot: *const Slot, hot: bool) void {
    drawFrame(cv, x, y, hot, null, null);
    const off = @divTrunc(tile - icon_size, 2);
    if (slot.icon) |icon| {
        cv.drawIcon(icon, x + off, y + off, icon_size);
    } else {
        // No icon: the first character of the name, large.
        var letter: [8]u8 = @splat(0);
        letter[0] = '?';
        const name = slot.app.name;
        var n: usize = 1;
        if (name.len > 0) {
            const len = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
            n = @min(@as(usize, len), name.len, 4);
            @memcpy(letter[0..n], name[0..n]);
        }
        const s: [:0]const u8 = letter[0..n :0];
        drawCentered(cv, s, x, y + 14, tile, font_letter, col_text);
    }
    // Only an entry that can be started says "not running" (a hand-made
    // entry without a command has nothing to show).
    if (!slot.running and slot.app.command.len > 0) drawNotRunning(cv, x, y);
    if (slot.gi.omnipresent) drawOmnipresent(cv, x, y);
    if (slot.launching) drawLaunching(cv, x, y);
}

/// The empty slot a dragged tile will drop into: a recessed tile.
fn drawSlotGap(cv: *gfx.Canvas, x: i32, y: i32) void {
    cv.fillRect(x, y, tile, tile, col_gap);
    cv.bevel(x, y, tile, tile, col_dark, col_light);
}

/// A tile about to be removed: veiled in the background colour.
fn drawFade(cv: *gfx.Canvas, x: i32, y: i32) void {
    cv.fillRect(x, y, tile, tile, col_fade);
}

/// `name` cut so it still fits the tile; never splits a UTF-8 sequence.
fn clipName(buf: *[24:0]u8, name: []const u8) [:0]const u8 {
    var end: usize = @min(name.len, buf.len);
    if (std.mem.indexOfScalar(u8, name[0..end], 0)) |nul| end = nul;
    while (end > 0 and end < name.len and (name[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(buf[0..end], name[0..end]);
    buf[end] = 0;
    return buf[0..end :0];
}

/// A tile being dragged, for drawing.
pub const DragView = struct {
    /// The tile in the air.
    icon: *const wdock.Icon,
    /// Where it would land, if that is in this bar's dock (grid cell).
    target: ?[2]i32 = null,
    /// It snaps nowhere: letting go removes it. The tile stays where it was,
    /// drawn faded.
    detached: bool = false,
    /// Pointer, surface-local; the dragged tile is drawn under it.
    x: i32,
    y: i32,
};

/// What `drawBar` needs to know besides the model.
pub const View = struct {
    dock: *const wdock.Dock,
    cells: Cells,
    /// Collapsed Clip / Drawer: only its own tile.
    only_main: bool = false,
    hover: ?*const wdock.Icon = null,
    hover_arrow: Arrow = .none,
    drag: ?DragView = null,
    /// The Clip's workspace tile shows this (0-based) number and name.
    workspace: u32 = 0,
    name: ?[]const u8 = null,
    /// A drag is going on and this bar is where it would land.
    target: ?[2]i32 = null,
};

fn drawMainTile(cv: *gfx.Canvas, v: View, x: i32, y: i32, hot: bool) void {
    switch (v.dock.kind) {
        .dock => {
            drawFrame(cv, x, y, hot, col_logo_from, col_logo_to);
            drawCentered(cv, "WM", x, y + 16, tile, font_logo, col_light);
        },
        .clip => {
            const hot0 = hot and v.hover_arrow == .none;
            drawFrame(cv, x, y, hot0, null, null);
            var num_buf: [12:0]u8 = undefined;
            const num = std.fmt.bufPrintZ(&num_buf, "{d}", .{v.workspace + 1}) catch "?";
            if (v.name) |name| {
                drawCentered(cv, num, x, y + 10, tile, font_number, col_text);
                var name_buf: [24:0]u8 = undefined;
                const clipped = clipName(&name_buf, name);
                drawCentered(cv, clipped, x, y + 41, tile, gfx.fonts.dockLabel(), col_text);
            } else {
                drawCentered(cv, num, x, y + 20, tile, font_number, col_text);
            }
            // The two arrows (Window Maker: upper right = next, lower left = prev).
            const fa: f64 = @floatFromInt(arrow);
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            const ft: f64 = @floatFromInt(tile);
            const next_col = if (hot and v.hover_arrow == .next) col_arrow_hot else col_arrow;
            const prev_col = if (hot and v.hover_arrow == .prev) col_arrow_hot else col_arrow;
            cv.fillPolygon(&.{
                .{ fx + ft - 3 - fa, fy + 3 },
                .{ fx + ft - 3, fy + 3 },
                .{ fx + ft - 3, fy + 3 + fa },
            }, next_col);
            cv.fillPolygon(&.{
                .{ fx + 3, fy + ft - 3 - fa },
                .{ fx + 3, fy + ft - 3 },
                .{ fx + 3 + fa, fy + ft - 3 },
            }, prev_col);
        },
        .drawer => {
            drawFrame(cv, x, y, hot, null, null);
            // A chevron towards where the Drawer opens (away from it when it is open).
            const left_open = v.dock.on_right_side;
            const points_left = if (v.only_main) left_open else !left_open;
            const cx: f64 = @floatFromInt(x + @divTrunc(tile, 2));
            const cy: f64 = @floatFromInt(y + @divTrunc(tile, 2));
            const s: f64 = 10;
            if (points_left) {
                cv.fillPolygon(&.{ .{ cx - s, cy }, .{ cx + s, cy - s }, .{ cx + s, cy + s } }, col_arrow);
            } else {
                cv.fillPolygon(&.{ .{ cx + s, cy }, .{ cx - s, cy - s }, .{ cx - s, cy + s } }, col_arrow);
            }
        },
    }
}

/// One whole dock surface: every tile at its grid cell, the empty cells
/// transparent. A tile being dragged leaves its cell empty and floats under
/// the pointer; the cell it would land in is shown recessed.
pub fn drawBar(cv: *gfx.Canvas, m: *const Model, v: View) void {
    cv.clear(col_clear);
    if (v.target) |t| {
        const p = cellPx(v.cells, t[0], t[1]);
        drawSlotGap(cv, p[0], p[1]);
    }
    for (v.dock.icons) |maybe| {
        const gi = maybe orelse continue;
        if (v.only_main and !gi.main) continue;
        const p = cellPx(v.cells, gi.xindex, gi.yindex);
        var lifted = false;
        if (v.drag) |d| if (d.icon == gi) {
            lifted = !d.detached;
        };
        if (lifted) continue;
        const hot = v.hover == gi and v.drag == null;
        if (gi.main) {
            drawMainTile(cv, v, p[0], p[1], hot);
        } else if (m.slotOf(gi)) |s| {
            drawAppTile(cv, p[0], p[1], s, hot);
        }
        if (v.drag) |d| if (d.icon == gi and d.detached) drawFade(cv, p[0], p[1]);
    }
    if (v.drag) |d| if (!d.detached) {
        const w = v.cells.cols() * tile;
        const h = v.cells.rows() * tile;
        const fx = std.math.clamp(d.x - @divTrunc(tile, 2), 0, @max(0, w - tile));
        const fy = std.math.clamp(d.y - @divTrunc(tile, 2), 0, @max(0, h - tile));
        if (m.slotOf(d.icon)) |s| {
            drawAppTile(cv, fx, fy, s, true);
        } else if (d.icon.main) {
            drawMainTile(cv, v, fx, fy, true);
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn mk(name: []const u8, place: dockapp.Place, x: i32, y: i32) dockapp.DockApp {
    return .{ .name = name, .command = &.{name}, .place = place, .x = x, .y = y };
}

fn px(data: []const u8, stride: i32, x: i32, y: i32) u32 {
    const off: usize = @intCast(y * stride + x * 4);
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

fn rowOf(m: *const Model, name: []const u8) ?i32 {
    for (m.slots.items) |s| {
        if (s.alive and std.mem.eql(u8, s.app.name, name)) return s.gi.yindex;
    }
    return null;
}

test "Model: Dock tiles keep their grid rows, gaps stay, clashes find a free row" {
    const apps = [_]dockapp.DockApp{
        mk("a", .dock, 0, 1),
        mk("b", .dock, 0, 4), // a gap of two rows: stays
        mk("c", .dock, 0, -2), // above the logo
        mk("d", .dock, 0, 1), // clashes with a
        mk("e", .dock, 0, 0), // the logo's row
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    try std.testing.expectEqual(@as(?i32, 1), rowOf(&m, "a"));
    try std.testing.expectEqual(@as(?i32, 4), rowOf(&m, "b"));
    try std.testing.expectEqual(@as(?i32, -2), rowOf(&m, "c"));
    // d and e went to the first free rows. The Dock sits at the top of the
    // screen, so nothing above the logo fits: 2, then 3.
    try std.testing.expectEqual(@as(?i32, 2), rowOf(&m, "d"));
    try std.testing.expectEqual(@as(?i32, 3), rowOf(&m, "e"));
}

test "Model: an empty list is just the logo; names: config.conf wins" {
    var m = try Model.init(std.testing.allocator, .{ .workspace_names = &.{ "one", "two" } }, &.{"cfg"}, 2);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.scr.dock.?.icon_count);
    try std.testing.expectEqualStrings("cfg", m.workspaceName(0).?);
    try std.testing.expect(m.workspaceName(1) == null);
}

test "Model: Clip tiles belong to their workspace, omnipresent ones follow it" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "w0", .command = &.{"w0"}, .place = .clip, .workspace = 0, .x = 1 },
        .{ .name = "w1", .command = &.{"w1"}, .place = .clip, .workspace = 1, .x = 1 },
        .{ .name = "all", .command = &.{"all"}, .place = .clip, .workspace = null, .x = 2 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 3);
    defer m.deinit();

    const c0 = m.scr.clips.items[0];
    try std.testing.expect(iconAt(c0, .{ 1, 0 }) != null);
    try std.testing.expectEqual(@as(usize, 1), m.scr.globalIconCount());

    m.setWorkspace(1);
    const c1 = m.scr.clips.items[1];
    var found = false;
    for (c1.icons) |maybe| if (maybe) |i| {
        if (i.omnipresent) found = true;
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(m.currentClip(), c1);
}

test "Model: exportList writes positions, workspaces, omnipresent and drawers back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const drawers = [_]dockapp.DrawerInfo{.{ .name = "tools", .row = 2 }};
    const apps = [_]dockapp.DockApp{
        mk("a", .dock, 0, 1),
        mk("b", .dock, 0, -1),
        .{ .name = "c", .command = &.{"c"}, .place = .clip, .workspace = 1, .x = 1 },
        .{ .name = "g", .command = &.{"g"}, .place = .clip, .workspace = null, .x = 2 },
        .{ .name = "t1", .command = &.{"t1"}, .place = .drawer, .drawer = 0 },
        .{ .name = "t2", .command = &.{"t2"}, .place = .drawer, .drawer = 0 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps, .drawers = &drawers }, &.{}, 2);
    defer m.deinit();

    const list = try m.exportList(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), list.drawers.len);
    try std.testing.expectEqualStrings("tools", list.drawers[0].name);
    try std.testing.expectEqual(@as(i32, 2), list.drawers[0].row);

    var seen: usize = 0;
    for (list.apps) |x| {
        seen += 1;
        if (std.mem.eql(u8, x.name, "b")) try std.testing.expectEqual(@as(i32, -1), x.y);
        if (std.mem.eql(u8, x.name, "c")) try std.testing.expectEqual(@as(?u32, 1), x.workspace);
        if (std.mem.eql(u8, x.name, "g")) {
            try std.testing.expectEqual(@as(?u32, null), x.workspace);
            try std.testing.expect(x.place == .clip);
        }
        if (std.mem.eql(u8, x.name, "t2")) {
            try std.testing.expect(x.place == .drawer);
            try std.testing.expectEqual(@as(i32, -2), x.x); // right-side Dock: grows left
        }
    }
    try std.testing.expectEqual(@as(usize, 6), seen);

    // ... and what was written reads back the same.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    _ = try dockapp.render(&aw.writer, list, .{});
    const back = try dockapp.parseWMStateAll(arena.allocator(), aw.written());
    try std.testing.expectEqual(list.apps.len, back.apps.len);
    try std.testing.expectEqual(@as(usize, 1), back.drawers.len);
}

test "Model: layout puts the Dock, the Clip and the Drawers on the output" {
    const drawers = [_]dockapp.DrawerInfo{.{ .row = 2 }};
    var m = try Model.init(std.testing.allocator, .{ .drawers = &drawers }, &.{}, 2);
    defer m.deinit();
    m.layout(1000, 800, true, 100, .bottom_right);
    try std.testing.expectEqual(@as(i32, 936), m.scr.dock.?.x_pos);
    try std.testing.expectEqual(@as(i32, 100), m.scr.dock.?.y_pos);
    try std.testing.expectEqual(@as(i32, 100 + 2 * tile), m.scr.drawers.items[0].y_pos);
    try std.testing.expectEqual(@as(i32, 936), m.scr.clips.items[0].x_pos);
    try std.testing.expectEqual(@as(i32, 736), m.scr.clips.items[1].y_pos);

    // Dock to the left: everything mirrors.
    m.layout(1000, 800, false, 0, .top_left);
    try std.testing.expectEqual(@as(i32, 0), m.scr.dock.?.x_pos);
    try std.testing.expect(!m.scr.drawers.items[0].on_right_side);
}

test "Model: temporary DockApp tiles are attached, pruned with the program, kept on request" {
    var m = try Model.init(std.testing.allocator, .{}, &.{}, 1);
    defer m.deinit();
    const i = try m.attach("clock");
    try std.testing.expectEqual(@as(?usize, i), m.dockSlotFor("dockapp:clock"));
    _ = m.setRunning(&.{"dockapp:clock"});
    try std.testing.expect(!m.pruneAttached());
    {
        const arena_list = try m.exportList(std.testing.allocator);
        defer std.testing.allocator.free(arena_list.apps);
        defer std.testing.allocator.free(arena_list.drawers);
        try std.testing.expectEqual(@as(usize, 0), arena_list.apps.len);
    }
    _ = m.setRunning(&.{});
    try std.testing.expect(m.pruneAttached());
    try std.testing.expect(m.slot(i) == null);

    const j = try m.attach("clock");
    try std.testing.expect(m.keepAttached(j));
    _ = m.setRunning(&.{});
    try std.testing.expect(!m.pruneAttached());
    try std.testing.expect(m.slot(j) != null);
}

test "Model.removeSlot: a locked tile stays, a Drawer closes its gap" {
    const drawers = [_]dockapp.DrawerInfo{.{ .row = 1 }};
    const apps = [_]dockapp.DockApp{
        .{ .name = "x", .command = &.{"x"}, .y = 1, .locked = true },
        .{ .name = "t1", .command = &.{"t1"}, .place = .drawer },
        .{ .name = "t2", .command = &.{"t2"}, .place = .drawer },
        .{ .name = "t3", .command = &.{"t3"}, .place = .drawer },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps, .drawers = &drawers }, &.{}, 1);
    defer m.deinit();
    try std.testing.expect(!m.removeSlot(0));
    try std.testing.expect(m.removeSlot(2)); // t2: the middle one
    try std.testing.expectEqual(@as(i32, -2), m.slots.items[3].gi.xindex);
    try std.testing.expect(m.slot(2) == null);
}

test "Model.dropSlot: between docks, the tile changes place" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "a", .command = &.{"a"}, .y = 1 },
        .{ .name = "c", .command = &.{"c"}, .place = .clip, .workspace = 0, .x = 1 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();
    const clip = m.scr.clips.items[0];
    try std.testing.expect(m.dropSlot(0, clip, .{ 0, 1 }));
    try std.testing.expect(m.slots.items[0].app.place == .clip);
    try std.testing.expect(m.slots.items[0].gi.dock.? == clip);
    try std.testing.expect(m.dropSlot(0, m.scr.dock.?, .{ 0, 3 }));
    try std.testing.expect(m.slots.items[0].app.place == .dock);
    try std.testing.expectEqual(@as(i32, 3), m.slots.items[0].gi.yindex);
}

test "addDrawer picks a free row; removeDrawer takes its tiles along" {
    var m = try Model.init(std.testing.allocator, .{ .apps = &.{mk("a", .dock, 0, 1)} }, &.{}, 1);
    defer m.deinit();
    m.layout(1000, 800, true, 200, .top_left);
    const d = (try m.addDrawer("Drawer")).?;
    try std.testing.expectEqual(@as(i32, 200 - tile), d.y_pos); // row 1 is taken: the row above
    _ = try m.addApp(.{ .name = "z", .command = &.{"z"}, .place = .drawer, .drawer = 0 });
    try std.testing.expectEqual(@as(usize, 1), d.icon_count - 1);
    m.removeDrawer(d);
    try std.testing.expectEqual(@as(usize, 0), m.scr.drawers.items.len);
    try std.testing.expect(m.slot(1) == null);
}

test "setRunning reports a change exactly once; launching is set, cleared by a window and times out" {
    var m = try Model.init(std.testing.allocator, .{ .apps = &.{mk("term", .dock, 0, 1)} }, &.{}, 1);
    defer m.deinit();
    try std.testing.expect(m.setRunning(&.{"term"}));
    try std.testing.expect(!m.setRunning(&.{"term"}));
    try std.testing.expect(m.setRunning(&.{}));
    m.markLaunching(0, 100);
    try std.testing.expect(m.slots.items[0].launching);
    try std.testing.expect(!m.expireLaunching(105, 10));
    try std.testing.expect(m.expireLaunching(120, 10));
    m.markLaunching(0, 200);
    try std.testing.expect(m.setRunning(&.{"term"}));
    try std.testing.expect(!m.slots.items[0].launching);
}

test "cellsOf and cellAt: the surface of a Dock, with and without the margin" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "clock", .command = &.{"wl-clock"}, .y = 1 },
        .{ .name = "tokyo", .command = &.{"wl-clock"}, .y = 3 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();
    m.layout(1920, 1080, true, 0, .top_left);
    const dock = m.scr.dock.?;

    const c = cellsOf(dock, false, false);
    try std.testing.expectEqual(@as(i32, 0), c.miny);
    try std.testing.expectEqual(@as(i32, 3), c.maxy);
    const cm = cellsOf(dock, false, true);
    try std.testing.expectEqual(@as(i32, -3), cm.miny);
    try std.testing.expectEqual(@as(i32, 6), cm.maxy);
    try std.testing.expectEqual([2]i32{ 0, -3 }, cellAt(cm, 5, 5));
    // The grid icon of a tile knows its pixel position: where a DockApp goes.
    const gi = m.slots.items[m.dockSlotFor("dockapp:tokyo").?].gi;
    try std.testing.expectEqual(@as(i32, 1856), gi.x_pos);
    try std.testing.expectEqual(@as(i32, 3 * tile), gi.y_pos);
    // A collapsed Clip shows its tile only.
    const cc = cellsOf(m.currentClip(), true, true);
    try std.testing.expectEqual(@as(i32, 1), cc.cols());
}
test "drawBar paints tiles; only a NOT running tile gets Window Maker's three dots" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "term", .command = &.{"definitely-no-such-icon-xyz"}, .y = 1 },
        .{ .name = "web", .command = &.{"definitely-no-such-icon-abc"}, .y = 2 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    _ = m.setRunning(&.{"definitely-no-such-icon-xyz"}); // term runs, web does not

    const w = tile;
    const h = tile * 3;
    const data = try std.testing.allocator.alloc(u8, @intCast(w * h * 4));
    defer std.testing.allocator.free(data);
    @memset(data, 0xff);
    var cv = try gfx.Canvas.initForData(data.ptr, w, h, w * 4);
    defer cv.deinit();

    drawBar(&cv, &m, .{ .dock = m.scr.dock.?, .cells = cellsOf(m.scr.dock.?, false, false) });
    cv.flush();

    const logo = px(data, w * 4, 32, 4);
    const running = px(data, w * 4, 32, tile + 4);
    try std.testing.expectEqual(@as(u32, 0xff), logo >> 24);
    try std.testing.expect((logo & 0xff) < 0x80); // dark
    try std.testing.expect((running & 0xff) > 0x80); // light
    for ([_]i32{ 4, 9, 14 }) |dx| {
        try std.testing.expectEqual(@as(u32, 0xffffffff), px(data, w * 4, dx + 1, 2 * tile + tile - 6));
        try std.testing.expect(px(data, w * 4, dx + 1, tile + tile - 6) != 0xffffffff);
    }
}

test "drawBar: an empty row stays transparent, a lifted tile leaves a hole" {
    const apps = [_]dockapp.DockApp{.{ .name = "a", .command = &.{"definitely-no-such-icon-q"}, .y = 2 }};
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();
    const dock = m.scr.dock.?;
    const cells = cellsOf(dock, false, false);
    const w = tile;
    const h = tile * cells.rows();
    const data = try std.testing.allocator.alloc(u8, @intCast(w * h * 4));
    defer std.testing.allocator.free(data);
    @memset(data, 0xff);
    var cv = try gfx.Canvas.initForData(data.ptr, w, h, w * 4);
    defer cv.deinit();

    drawBar(&cv, &m, .{ .dock = dock, .cells = cells });
    cv.flush();
    // Row 1 is empty: fully transparent.
    try std.testing.expectEqual(@as(u32, 0), px(data, w * 4, 32, tile + 32) >> 24);
    // Row 2 holds the tile.
    try std.testing.expectEqual(@as(u32, 0xff), px(data, w * 4, 32, 2 * tile + 4) >> 24);

    // Lift it: the cell is empty (no drag target given) and the pointer's copy floats.
    drawBar(&cv, &m, .{ .dock = dock, .cells = cells, .drag = .{ .icon = m.slots.items[0].gi, .x = 32, .y = 32 } });
    cv.flush();
    try std.testing.expectEqual(@as(u32, 0), px(data, w * 4, 32, 2 * tile + 60) >> 24);
}

test "clipName cuts on a character boundary and drops NULs" {
    var buf: [24:0]u8 = undefined;
    try std.testing.expectEqualStrings("Main", clipName(&buf, "Main"));
    try std.testing.expectEqualStrings("a", clipName(&buf, "a\x00b"));
    const long = "äääääääääääääääääääääääää"; // 25 x 2 bytes
    const cut = clipName(&buf, long);
    try std.testing.expect(cut.len <= 24);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "Output.workArea subtracts what the Dock reserves, on top of layer-shell" {
    var o: types.Output = undefined;
    o.rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    o.usable = null;
    o.reserved = .{};
    try std.testing.expectEqual(o.rect, o.workArea());

    o.reserved = .{ .right = 64 };
    try std.testing.expectEqual(types.Rect{ .x = 0, .y = 0, .w = 936, .h = 800 }, o.workArea());

    // A bar at the top (layer-shell) and the Dock on the left add up.
    o.usable = .{ .x = 0, .y = 30, .w = 1000, .h = 770 };
    o.reserved = .{ .left = 64 };
    try std.testing.expectEqual(types.Rect{ .x = 64, .y = 30, .w = 936, .h = 770 }, o.workArea());

    // Nonsense can never produce an empty rectangle.
    o.reserved = .{ .left = 5000 };
    try std.testing.expect(o.workArea().w >= 1);
}

test "an .xpm icon file is loaded for a Dock tile and painted" {
    const cc = @cImport({
        @cInclude("stdio.h");
        @cInclude("stdlib.h");
    });
    var tmpl = "/tmp/wmaker-dockxpm-XXXXXX".*;
    const dir = cc.mkdtemp(&tmpl) orelse return error.MkdTemp;
    defer {
        var cmd: [96]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{std.mem.span(dir)})) |z| _ = cc.system(z.ptr) else |_| {}
    }
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/app.xpm", .{std.mem.span(dir)});
    const text =
        \\/* XPM */
        \\static char *a[] = {
        \\"2 2 2 1",
        \\"a c #ff0000",
        \\"b c None",
        \\"aa",
        \\"ab"
        \\};
    ;
    const f = cc.fopen(path.ptr, "wb") orelse return error.Open;
    _ = cc.fwrite(text.ptr, 1, text.len, f);
    _ = cc.fclose(f);

    const apps = [_]dockapp.DockApp{
        .{ .name = "x", .command = &.{"x"}, .icon = path },
        // A broken file must not take the Dock down: it just has no icon.
        .{ .name = "y", .command = &.{"y"}, .icon = "/nonexistent/none.xpm" },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    try std.testing.expect(m.slots.items[0].icon != null);
    try std.testing.expectEqual(@as(i32, 2), m.slots.items[0].icon.?.w);
    try std.testing.expect(m.slots.items[1].icon == null);
}

test "Model.layout: the Clip's tiles change sides with the Clip, the first layout only adopts the corner" {
    const apps = [_]dockapp.DockApp{
        // Saved while the Clip sat in the bottom right corner: tiles point
        // up and to the left.
        .{ .name = "c", .command = &.{"c"}, .place = .clip, .workspace = 0, .x = -2, .y = -1 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();
    const gi = m.slots.items[0].gi;

    m.layout(1000, 800, true, 0, .bottom_right);
    try std.testing.expectEqual(@as(i32, -2), gi.xindex);
    try std.testing.expectEqual(@as(i32, -1), gi.yindex);

    m.layout(1000, 800, true, 0, .top_left);
    try std.testing.expectEqual(@as(i32, 2), gi.xindex);
    try std.testing.expectEqual(@as(i32, 1), gi.yindex);
    try std.testing.expect(m.scr.onScreen(gi.x_pos, gi.y_pos));

    m.layout(1000, 800, true, 0, .top_right);
    try std.testing.expectEqual(@as(i32, -2), gi.xindex);
    try std.testing.expectEqual(@as(i32, 1), gi.yindex);
    try std.testing.expectEqual(@as(i32, 936 - 2 * tile), gi.x_pos);
    try std.testing.expectEqual(@as(i32, tile), gi.y_pos);
}

test "Model.layout: moving the Dock never pushes a tile or a Drawer off the screen" {
    const apps = [_]dockapp.DockApp{ mk("a", .dock, 0, 1), mk("b", .dock, 0, 3) };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();
    const dock = m.scr.dock.?;

    // The lowest tile is in row 3: the logo may go down to 800 - 4 tiles.
    m.layout(1000, 800, true, 5000, .top_left);
    try std.testing.expectEqual(@as(i32, 800 - 4 * tile), dock.y_pos);
    for (m.slots.items) |s| try std.testing.expect(m.scr.onScreen(s.gi.x_pos, s.gi.y_pos));

    m.layout(1000, 800, true, -50, .top_left);
    try std.testing.expectEqual(@as(i32, 0), dock.y_pos);

    // A Drawer above the logo keeps the Dock off the top edge.
    m.layout(1000, 800, true, 300, .top_left);
    const d = (try m.addDrawer("Drawer")).?;
    try std.testing.expectEqual(@as(i32, -1), @divTrunc(d.y_pos - dock.y_pos, tile));
    m.layout(1000, 800, true, 0, .top_left);
    try std.testing.expectEqual(@as(i32, tile), dock.y_pos);
    try std.testing.expectEqual(@as(i32, 0), d.y_pos);

    // A column taller than the screen: the logo stays reachable.
    m.layout(1000, 128, true, 0, .top_left);
    try std.testing.expect(dock.y_pos >= 0 and dock.y_pos <= 128 - tile);
}

test "Model.init: a Drawer on the logo's row or on another Drawer's row moves to a free row" {
    const drawers = [_]dockapp.DrawerInfo{ .{ .row = 0 }, .{ .row = 2 }, .{ .row = 2 } };
    var m = try Model.init(std.testing.allocator, .{ .drawers = &drawers }, &.{}, 1);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 3), m.scr.drawers.items.len);
    const dock = m.scr.dock.?;
    var rows: [3]i32 = undefined;
    for (m.scr.drawers.items, 0..) |d, i| rows[i] = @divTrunc(d.y_pos - dock.y_pos, tile);
    try std.testing.expect(rows[0] != 0);
    try std.testing.expectEqual(@as(i32, 2), rows[1]);
    try std.testing.expect(rows[0] != rows[1] and rows[1] != rows[2] and rows[0] != rows[2]);
}

test "Model: a position far outside any dock is treated as no position" {
    const apps = [_]dockapp.DockApp{
        mk("a", .dock, 0, 1_000_000),
        .{ .name = "c", .command = &.{"c"}, .place = .clip, .workspace = 0, .x = -900_000, .y = 3 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();
    // No overflow, and both tiles sit within a few rows of their dock.
    try std.testing.expect(@abs(m.slots.items[0].gi.yindex) < 64);
    try std.testing.expect(@abs(m.slots.items[1].gi.xindex) < 64);
    try std.testing.expect(@abs(m.slots.items[1].gi.yindex) < 64);
}

test "nextLaunchExpiry: none, then the time left, then due -- and expireLaunching agrees" {
    var m = try Model.init(std.testing.allocator, .{ .apps = &.{ mk("a", .dock, 0, 1), mk("b", .dock, 0, 2) } }, &.{}, 1);
    defer m.deinit();
    try std.testing.expectEqual(@as(?u32, null), m.nextLaunchExpiry(1000, 100));
    m.markLaunching(0, 1000);
    m.markLaunching(1, 1050);
    try std.testing.expectEqual(@as(?u32, 51), m.nextLaunchExpiry(1050, 100));
    // At exactly max_age it is not over yet (expireLaunching wants `>`), one
    // millisecond later it is: the timeout must never be 0 while nothing
    // would expire, or the loop would spin.
    try std.testing.expectEqual(@as(?u32, 1), m.nextLaunchExpiry(1100, 100));
    try std.testing.expect(!m.expireLaunching(1100, 100));
    try std.testing.expect(m.expireLaunching(1101, 100)); // the first tile
    try std.testing.expectEqual(@as(?u32, 50), m.nextLaunchExpiry(1101, 100));
    try std.testing.expectEqual(@as(?u32, 0), m.nextLaunchExpiry(1151, 100));
    try std.testing.expect(m.expireLaunching(1151, 100));
    try std.testing.expectEqual(@as(?u32, null), m.nextLaunchExpiry(1151, 100));
}
