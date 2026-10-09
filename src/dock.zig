// SPDX-License-Identifier: 0BSD
//
// The Dock (Window Maker's "WMDock") and the Clip ("WMClip"): model,
// geometry, hit testing and drawing. No Wayland types in here, like
// gfx.zig, so all of it is unit-testable without a compositor; ui.zig owns
// the surfaces and the pointer.
//
//   Dock   A column of 64 px tiles on the left or right screen edge. The
//          logo tile ("WM") is part of it; the others are the DockApps with
//          `place = dock`. A click starts the application, or focuses it if
//          a window of it is already open. A small mark in the corner of a
//          tile says "running". A fixed-size DockApp window (app_id
//          `dockapp:<name>`, at most 64x64) that matches a tile is put right
//          into that tile by ui.zig's placeDocked, which is how wmclock-style
//          applets live in Window Maker's dock.
//
//   Clip   One tile with the workspace on it: its number and name, an arrow
//          in the upper right corner (next workspace) and one in the lower
//          left corner (previous workspace), exactly where Window Maker puts
//          them. Next to it, in one row, the DockApps with `place = clip`
//          that belong to the CURRENT workspace.
//
// The tiles are drawn on one surface each (one for the Dock, one for the
// Clip). `Model` is a deep copy of what wm.dockapps held when it was built,
// so a config reload cannot leave it pointing into a freed arena.

const std = @import("std");
const gfx = @import("gfx.zig");
const config = @import("config.zig");
const dockapp = @import("dockapp.zig");
const xpm = @import("xpm.zig");
const types = @import("types.zig");

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
    /// A window of this application is open (set by ui.zig every sync).
    running: bool = false,
    /// The application was started from this tile and has no window yet
    /// (Window Maker's `launching`). Cleared by `setRunning` as soon as a
    /// window matches, or by ui.zig after a time-out (a program that never
    /// opens a window must not leave the tile covered forever).
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

/// What one Dock tile is.
pub const Tile = union(enum) {
    logo,
    /// Index into `Model.dock`.
    app: usize,
};

/// Most tiles a Dock or a Clip ever holds (also bounds the scratch arrays
/// of `moveDockTile`). A screen is never taller than this many tiles.
pub const max_dock_tiles: usize = 64;

/// Which of the ORIGINAL tiles is shown at position `t` once tile `from`
/// has been moved to position `to` (everything between shifts by one).
/// Used for the live preview while dragging and by `Model.moveDockTile`,
/// so what is drawn is what is dropped.
pub fn reorderIndex(from: usize, to: usize, t: usize) usize {
    if (t == to) return from;
    if (from < to) {
        // from+1 .. to move up by one
        return if (t >= from and t < to) t + 1 else t;
    }
    // to .. from-1 move down by one
    return if (t > to and t <= from) t - 1 else t;
}

/// How far (px) from the Dock a dragged tile may be taken before letting go
/// removes it instead of reordering (Window Maker's DOCK_DETTACH_THRESHOLD
/// is about this much, too).
pub const detach_distance: i32 = 56;

/// Is the pointer (surface-local x) far enough outside a Dock/Clip column
/// of width `tile` to count as "taking the tile away"?
pub fn detached(x: i32, y: i32, w: i32, h: i32) bool {
    return x < -detach_distance or x > w + detach_distance or y < -detach_distance or y > h + detach_distance;
}

/// Tile position the pointer at surface-local `y` is over while a Dock
/// tile is dragged: clamped, so dragging past either end drops there.
pub fn dropTile(y: i32, ntiles: usize) usize {
    if (ntiles == 0) return 0;
    if (y < 0) return 0;
    const t: usize = @intCast(@divTrunc(y, tile));
    return @min(t, ntiles - 1);
}

pub const Model = struct {
    /// Owns every string in `dock`/`clip`/`names`.
    arena: std.heap.ArenaAllocator,
    /// Dock entries, sorted top to bottom.
    dock: []Slot,
    /// All Clip entries, sorted left to right (see `clipFor`).
    clip: []Slot,
    names: []const []const u8,
    /// Dock entries that sit ABOVE the logo tile.
    above_logo: usize,
    workspace_count: u32,

    /// Build from `list`. `cfg_names` (config.conf) win over the names the
    /// list carries (Window Maker's WMState). Icons are loaded here, so
    /// building is the only moment this touches the filesystem.
    pub fn init(
        gpa: std.mem.Allocator,
        list: dockapp.List,
        cfg_names: []const []const u8,
        workspace_count: u32,
    ) !Model {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var dock: std.ArrayList(Slot) = .empty;
        var clip: std.ArrayList(Slot) = .empty;
        errdefer for ([_]*std.ArrayList(Slot){ &dock, &clip }) |l| for (l.items) |*s| if (s.icon) |*i| i.deinit();

        for (list.apps) |app| {
            const copy = try dupeApp(a, app);
            var slot: Slot = .{ .app = copy };
            slot.icon = loadIcon(gpa, copy);
            switch (copy.place) {
                .dock => try dock.append(a, slot),
                .clip => try clip.append(a, slot),
            }
        }

        // Stable sorts: entries with the same position keep file order.
        std.mem.sort(Slot, dock.items, {}, dockLess);
        std.mem.sort(Slot, clip.items, {}, clipLess);

        var above: usize = 0;
        for (dock.items) |s| {
            if (s.app.y < list.logo_y) above += 1;
        }

        if (dock.items.len > max_dock_tiles) dock.shrinkRetainingCapacity(max_dock_tiles);
        if (clip.items.len > max_dock_tiles) clip.shrinkRetainingCapacity(max_dock_tiles);

        const names = if (cfg_names.len > 0) cfg_names else list.workspace_names;
        var names_copy = try a.alloc([]const u8, names.len);
        for (names, 0..) |n, i| names_copy[i] = try a.dupe(u8, n);

        var model: Model = .{
            .arena = arena,
            .dock = try dock.toOwnedSlice(a),
            .clip = try clip.toOwnedSlice(a),
            .names = names_copy,
            .above_logo = above,
            .workspace_count = workspace_count,
        };
        // Only now, so a (valid) hand-written position like `0,5` is kept
        // by the sort above, but what is saved from here on is gap free.
        model.renumberDock();
        return model;
    }

    pub fn deinit(m: *Model) void {
        for (m.dock) |*s| if (s.icon) |*i| i.deinit();
        for (m.clip) |*s| if (s.icon) |*i| i.deinit();
        m.arena.deinit();
        m.* = undefined;
    }

    /// Number of tiles in the Dock: the logo plus every entry.
    pub fn dockTiles(m: *const Model) usize {
        return m.dock.len + 1;
    }

    pub fn dockTile(m: *const Model, t: usize) ?Tile {
        if (t >= m.dockTiles()) return null;
        if (t == m.above_logo) return .logo;
        return .{ .app = if (t < m.above_logo) t else t - 1 };
    }

    /// Indices into `clip` of the entries shown on workspace `ws` (0-based):
    /// those with no workspace and those with exactly this one. Written into
    /// `out`; returns the part that was filled (never more than out.len).
    pub fn clipFor(m: *const Model, ws: u32, out: []usize) []usize {
        var n: usize = 0;
        for (m.clip, 0..) |s, i| {
            if (n == out.len) break;
            if (s.app.workspace) |w| if (w != ws) continue;
            out[n] = i;
            n += 1;
        }
        return out[0..n];
    }

    /// "Main" for workspace 0 if it is named so, else null.
    pub fn workspaceName(m: *const Model, ws: u32) ?[]const u8 {
        if (ws >= m.names.len) return null;
        const n = m.names[ws];
        return if (n.len == 0) null else n;
    }

    /// Update every slot's `running` flag from the app_ids of the open
    /// windows. Returns true if any flag changed (=> redraw).
    pub fn setRunning(m: *Model, app_ids: []const []const u8) bool {
        var changed = false;
        for ([_][]Slot{ m.dock, m.clip }) |list| {
            for (list) |*s| {
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
                // A window has appeared: the start is over.
                if (run and s.launching) {
                    s.launching = false;
                    changed = true;
                }
            }
        }
        return changed;
    }

    /// Mark an entry as just started (draws the raster) and remember when.
    pub fn markLaunching(m: *Model, clip: bool, index: usize, stamp: u32) void {
        const list = if (clip) m.clip else m.dock;
        if (index >= list.len) return;
        if (list[index].running) return;
        list[index].launching = true;
        list[index].launch_stamp = stamp;
    }

    /// End `launching` of every entry started more than `max_age` syncs ago
    /// (a program that never opens a window). True if anything changed.
    pub fn expireLaunching(m: *Model, now: u32, max_age: u32) bool {
        var changed = false;
        for ([_][]Slot{ m.dock, m.clip }) |list| {
            for (list) |*s| {
                if (s.launching and now -% s.launch_stamp > max_age) {
                    s.launching = false;
                    changed = true;
                }
            }
        }
        return changed;
    }

    /// Move the Dock tile `from` (an application tile, never the logo) so
    /// that it ends up at tile position `to`, everything in between shifting
    /// by one. Crossing the logo tile changes how many entries sit above it.
    /// The y of every entry is renumbered (Window Maker's grid: the logo is
    /// 0, tiles above it negative, below it 0, 1, 2 ... in `position`-terms
    /// of dockapps.conf) so the new order survives being written out and read
    /// back. False if nothing moved.
    pub fn moveDockTile(m: *Model, from: usize, to: usize) bool {
        const n = m.dockTiles();
        if (from >= n or to >= n or from == to) return false;
        if (m.dockTile(from).? == .logo) return false;

        // Sequence of tiles before and after, as Tile values.
        var before: [max_dock_tiles]Tile = undefined;
        if (n > max_dock_tiles) return false;
        for (0..n) |t| before[t] = m.dockTile(t).?;

        var after: [max_dock_tiles]Tile = undefined;
        for (0..n) |t| after[t] = before[reorderIndex(from, to, t)];

        // Rebuild `dock` in the new order. Slots are plain values, so copy
        // through a scratch array (a slot owns an icon: it is moved, not
        // duplicated, and the old array is overwritten completely).
        var scratch: [max_dock_tiles]Slot = undefined;
        var k: usize = 0;
        var logo_at: usize = 0;
        for (0..n) |t| switch (after[t]) {
            .logo => logo_at = t,
            .app => |i| {
                scratch[k] = m.dock[i];
                k += 1;
            },
        };
        @memcpy(m.dock[0..k], scratch[0..k]);
        m.above_logo = logo_at;
        m.renumberDock();
        return true;
    }

    /// y of every Dock entry from its position (see moveDockTile).
    fn renumberDock(m: *Model) void {
        for (m.dock, 0..) |*s, i| {
            s.app.y = if (i < m.above_logo)
                @as(i32, @intCast(i)) - @as(i32, @intCast(m.above_logo))
            else
                @as(i32, @intCast(i - m.above_logo));
        }
    }

    /// Remove Dock entry `index` (an index into `dock`). Its icon is freed.
    pub fn removeDock(m: *Model, index: usize) bool {
        if (index >= m.dock.len) return false;
        if (m.dock[index].app.locked) return false;
        if (m.dock[index].icon) |*i| i.deinit();
        if (index < m.above_logo) m.above_logo -= 1;
        std.mem.copyForwards(Slot, m.dock[index .. m.dock.len - 1], m.dock[index + 1 ..]);
        m.dock = m.dock[0 .. m.dock.len - 1];
        m.renumberDock();
        return true;
    }

    /// Move Clip entry `from` to index `to` (both indices into `clip`, which
    /// is ordered by x); the entries in between shift by one and every x is
    /// renumbered, so the order survives being saved.
    pub fn moveClipEntry(m: *Model, from: usize, to: usize) bool {
        if (from >= m.clip.len or to >= m.clip.len or from == to) return false;
        const item = m.clip[from];
        if (from < to) {
            std.mem.copyForwards(Slot, m.clip[from..to], m.clip[from + 1 .. to + 1]);
        } else {
            std.mem.copyBackwards(Slot, m.clip[to + 1 .. from + 1], m.clip[to..from]);
        }
        m.clip[to] = item;
        for (m.clip, 0..) |*sl, i| {
            sl.app.x = @intCast(i);
            sl.app.y = 0;
        }
        return true;
    }

    /// Remove Clip entry `index` (an index into `clip`).
    pub fn removeClip(m: *Model, index: usize) bool {
        if (index >= m.clip.len) return false;
        if (m.clip[index].app.locked) return false;
        if (m.clip[index].icon) |*i| i.deinit();
        std.mem.copyForwards(Slot, m.clip[index .. m.clip.len - 1], m.clip[index + 1 ..]);
        m.clip = m.clip[0 .. m.clip.len - 1];
        return true;
    }

    /// Add `app` (copied into the model) at the end of the Dock or the
    /// Clip, with its icon. Returns the new index.
    pub fn addApp(m: *Model, gpa: std.mem.Allocator, app: dockapp.DockApp) !usize {
        const a = m.arena.allocator();
        var copy = try dupeApp(a, app);
        var slot: Slot = .{ .app = copy };
        slot.icon = loadIcon(gpa, copy);
        errdefer if (slot.icon) |*i| i.deinit();
        switch (copy.place) {
            .dock => {
                if (m.dock.len + 1 > max_dock_tiles) return error.TooMany;
                const list = try a.alloc(Slot, m.dock.len + 1);
                @memcpy(list[0..m.dock.len], m.dock);
                copy.y = @as(i32, @intCast(m.dock.len - m.above_logo));
                slot.app = copy;
                list[m.dock.len] = slot;
                m.dock = list;
                return m.dock.len - 1;
            },
            .clip => {
                if (m.clip.len + 1 > max_dock_tiles) return error.TooMany;
                const list = try a.alloc(Slot, m.clip.len + 1);
                @memcpy(list[0..m.clip.len], m.clip);
                var last_x: i32 = -1;
                for (m.clip) |c| last_x = @max(last_x, c.app.x);
                copy.x = last_x + 1;
                slot.app = copy;
                list[m.clip.len] = slot;
                m.clip = list;
                return m.clip.len - 1;
            },
        }
    }

    /// Does an entry (Dock or Clip) already start this application?
    pub fn hasApp(m: *const Model, app_id: []const u8) bool {
        for ([_][]const Slot{ m.dock, m.clip }) |list| {
            for (list) |s| if (s.app.matches(app_id)) return true;
        }
        return false;
    }

    /// Everything the Model holds as one list (Dock in tile order, then the
    /// Clip), for writing it out. The strings stay owned by the Model.
    pub fn exportList(m: *const Model, a: std.mem.Allocator) !dockapp.List {
        var out = try a.alloc(dockapp.DockApp, m.dock.len + m.clip.len);
        for (m.dock, 0..) |s, i| out[i] = s.app;
        for (m.clip, 0..) |s, i| out[m.dock.len + i] = s.app;
        return .{ .apps = out, .workspace_names = m.names, .logo_y = 0 };
    }

    /// The Dock entry that a docked window with this app_id belongs to, and
    /// only if the window can be hosted by it: `app_id` must be
    /// self-declared (`dockapp:...`), see ui.zig's placeDocked.
    pub fn dockSlotFor(m: *const Model, app_id: []const u8) ?usize {
        if (dockapp.declaredName(app_id) == null) return null;
        for (m.dock, 0..) |s, i| if (s.app.matches(app_id)) return i;
        return null;
    }
};

fn dockLess(_: void, a: Slot, b: Slot) bool {
    return a.app.y < b.app.y;
}

fn clipLess(_: void, a: Slot, b: Slot) bool {
    if (a.app.x != b.app.x) return a.app.x < b.app.x;
    return a.app.y < b.app.y;
}

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
// Geometry (all in global coordinates, like types.Output.rect)
// ----------------------------------------------------------------------------

/// Tiles that fit along `len` pixels (at least 1: the logo/Clip tile is
/// always there).
pub fn tilesThatFit(len: i32) usize {
    return @intCast(@max(1, @divTrunc(len, tile)));
}

/// The Dock's rectangle on `out` for `ntiles` tiles.
pub fn dockRect(out: Rect, ntiles: usize, cfg: *const config.Config) Rect {
    return dockRectAt(out, ntiles, cfg.dock_edge, cfg.dock_offset);
}

/// Same, for a run-time position: the Dock can be dragged to another edge
/// or offset (ui.zig keeps its own `edge`/`offset`, started from config.conf
/// or the saved state).
pub fn dockRectAt(out: Rect, ntiles: usize, edge: config.DockEdge, offset: i32) Rect {
    const h: i32 = @as(i32, @intCast(ntiles)) * tile;
    const x = switch (edge) {
        .left => out.x,
        .right => out.right() - tile,
    };
    const y = std.math.clamp(out.y + offset, out.y, @max(out.y, out.bottom() - h));
    return .{ .x = x, .y = y, .w = tile, .h = h };
}

/// Which edge and offset a Dock dragged so that its top-left lies at global
/// (gx, gy) belongs to: the nearer screen half wins the edge, the offset is
/// the distance from the top of the output (clamped by `dockRectAt`).
pub fn dockPlacementFor(out: Rect, gx: i32, gy: i32) struct { edge: config.DockEdge, offset: i32 } {
    const centre = gx + @divTrunc(tile, 2);
    const edge: config.DockEdge = if (centre < out.x + @divTrunc(out.w, 2)) .left else .right;
    return .{ .edge = edge, .offset = @max(0, gy - out.y) };
}

/// The Clip's rectangle for `ntiles` tiles in a row. The tile with the
/// workspace arrows is the outermost one (see `clipTileX`). If it would
/// land on the Dock it moves sideways, next to it.
pub fn clipRect(out: Rect, ntiles: usize, cfg: *const config.Config, dock: ?Rect) Rect {
    const w: i32 = @as(i32, @intCast(ntiles)) * tile;
    const left = clipOnLeft(cfg.clip_corner);
    var r: Rect = .{
        .x = if (left) out.x else out.right() - w,
        .y = switch (cfg.clip_corner) {
            .top_left, .top_right => out.y,
            .bottom_left, .bottom_right => out.bottom() - tile,
        },
        .w = w,
        .h = tile,
    };
    if (dock) |d| {
        if (r.x < d.right() and d.x < r.right() and r.y < d.bottom() and d.y < r.bottom()) {
            r.x = if (left) d.right() else d.x - w;
        }
    }
    return r;
}

pub fn clipOnLeft(corner: config.ClipCorner) bool {
    return corner == .top_left or corner == .bottom_left;
}

/// x (inside the Clip's surface) of tile `i` of `n`; tile 0 is the one with
/// the workspace arrows, the others follow away from the screen edge.
pub fn clipTileX(i: usize, n: usize, on_left: bool) i32 {
    const idx: i32 = @intCast(if (on_left) i else n - 1 - i);
    return idx * tile;
}

/// The Dock tile at surface-local y, if any.
pub fn dockTileAt(y: i32, ntiles: usize) ?usize {
    if (y < 0) return null;
    const t: usize = @intCast(@divTrunc(y, tile));
    return if (t < ntiles) t else null;
}

/// Tile position (1 .. ntiles-1; 0 is the workspace tile and never taken)
/// the pointer at surface-local `x` is over while a Clip tile is dragged.
/// Clamped, so dragging past either end drops there. With no application
/// tile at all there is nothing to drop on: 1 is returned anyway.
pub fn clipDropTile(x: i32, ntiles: usize, on_left: bool) usize {
    if (ntiles <= 1) return 1;
    const raw: usize = if (x < 0) 0 else @min(@as(usize, @intCast(@divTrunc(x, tile))), ntiles - 1);
    const t = if (on_left) raw else ntiles - 1 - raw;
    return @max(t, 1);
}

/// The corner of `out` that global point (gx, gy) is nearest to: where a
/// dragged Clip lands.
pub fn clipCornerFor(out: Rect, gx: i32, gy: i32) config.ClipCorner {
    const left = gx < out.x + @divTrunc(out.w, 2);
    const top = gy < out.y + @divTrunc(out.h, 2);
    return if (top) (if (left) .top_left else .top_right) else (if (left) .bottom_left else .bottom_right);
}

/// The Clip tile at surface-local x, if any (0 = the workspace tile).
pub fn clipTileAt(x: i32, ntiles: usize, on_left: bool) ?usize {
    if (x < 0) return null;
    const idx: usize = @intCast(@divTrunc(x, tile));
    if (idx >= ntiles) return null;
    return if (on_left) idx else ntiles - 1 - idx;
}

/// Where a window goes when it is hosted by the Dock, in global
/// coordinates, or null if it cannot be. `dock` is the Dock's rectangle and
/// `ntiles` the tiles actually drawn. Only a window that declared itself a
/// DockApp (app_id `dockapp:<name>`, see `Model.dockSlotFor`) with a FIXED
/// size of at most one tile qualifies: anything resizable (a terminal
/// started with `--class dockapp:htop`) would be stretched to the
/// compositor's minimum window size and sprawl over its neighbours, so it
/// stays an ordinary floating window and its tile just launches/focuses it.
/// The window is centred in its tile.
pub fn dockedRect(
    m: *const Model,
    dock: Rect,
    ntiles: usize,
    app_id: []const u8,
    min_w: i32,
    min_h: i32,
    max_w: i32,
    max_h: i32,
) ?Rect {
    if (max_w <= 0 or max_h <= 0 or min_w != max_w or min_h != max_h) return null;
    if (max_w > tile or max_h > tile) return null;
    const slot = m.dockSlotFor(app_id) orelse return null;
    const t: usize = if (slot < m.above_logo) slot else slot + 1;
    if (t >= ntiles) return null;
    return .{
        .x = dock.x + @divTrunc(tile - max_w, 2),
        .y = dock.y + @as(i32, @intCast(t)) * tile + @divTrunc(tile - max_h, 2),
        .w = max_w,
        .h = max_h,
    };
}

pub const Arrow = enum { none, prev, next };

/// Which workspace arrow is under (x, y), given relative to the Clip tile's
/// own top-left corner. Upper right = next, lower left = previous.
pub fn clipArrowAt(x: i32, y: i32) Arrow {
    if (x < 0 or y < 0 or x >= tile or y >= tile) return .none;
    if (x >= tile - arrow and y < arrow) return .next;
    if (x < arrow and y >= tile - arrow) return .prev;
    return .none;
}

// ----------------------------------------------------------------------------
// Drawing
// ----------------------------------------------------------------------------

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
fn drawAppTile(cv: *gfx.Canvas, x: i32, y: i32, slot: *const Slot, hot: bool, in_clip: bool) void {
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
    if (in_clip and slot.app.workspace == null) drawOmnipresent(cv, x, y);
    if (slot.launching) drawLaunching(cv, x, y);
}

/// A tile being dragged out of the Dock (or the Clip), for drawing.
pub const DragView = struct {
    /// Tile position the drag started on (Dock) / Clip tile index.
    from: usize,
    /// Position the tile would be dropped at (see `reorderIndex`).
    to: usize,
    /// Pointer, surface-local; the dragged tile is drawn under it.
    x: i32,
    y: i32,
    /// Taken far from the bar: letting go removes it. The tile stays where
    /// it was, drawn faded.
    detached: bool = false,
};

/// The whole Dock surface (tile * ntiles high). `hover` is a tile index.
pub fn drawDock(cv: *gfx.Canvas, m: *const Model, ntiles: usize, hover: ?usize) void {
    drawDockDrag(cv, m, ntiles, hover, null);
}

/// Same, with a tile being dragged. The other tiles show the order the drop
/// would give (the gap travels with the pointer, like Window Maker's slots);
/// the dragged tile floats under the pointer.
pub fn drawDockDrag(cv: *gfx.Canvas, m: *const Model, ntiles: usize, hover: ?usize, drag: ?DragView) void {
    cv.clear(col_clear);
    var t: usize = 0;
    while (t < ntiles) : (t += 1) {
        const y: i32 = @as(i32, @intCast(t)) * tile;
        const hot = hover != null and hover.? == t;
        var src = t;
        if (drag) |d| if (!d.detached) {
            // The dragged tile's own slot stays empty while it floats.
            if (t == d.to) {
                drawSlotGap(cv, 0, y);
                continue;
            }
            src = reorderIndex(d.from, d.to, t);
        };
        drawDockTile(cv, m, src, y, hot and drag == null);
    }
    if (drag) |d| {
        const grabbed = m.dockTile(d.from) orelse return;
        if (d.detached) {
            // Faded in place: this is what would disappear.
            const y: i32 = @as(i32, @intCast(d.from)) * tile;
            drawFade(cv, 0, y);
        } else {
            const fy = std.math.clamp(d.y - @divTrunc(tile, 2), 0, @as(i32, @intCast(ntiles)) * tile - tile);
            switch (grabbed) {
                .logo => drawDockTile(cv, m, d.from, fy, true),
                .app => |i| drawAppTile(cv, 0, fy, &m.dock[i], true, false),
            }
        }
    }
}

fn drawDockTile(cv: *gfx.Canvas, m: *const Model, t: usize, y: i32, hot: bool) void {
    switch (m.dockTile(t) orelse return) {
        .logo => {
            drawFrame(cv, 0, y, hot, col_logo_from, col_logo_to);
            drawCentered(cv, "WM", 0, y + 16, tile, font_logo, col_light);
        },
        .app => |i| drawAppTile(cv, 0, y, &m.dock[i], hot, false),
    }
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

/// What the Clip shows besides its tiles.
pub const ClipView = struct {
    /// Workspace (0-based) and its name, if it has one.
    workspace: u32,
    name: ?[]const u8,
    /// Indices into `Model.clip` of the application tiles, in order.
    apps: []const usize,
    on_left: bool,
    /// Hovered tile (0 = the workspace tile) and, on it, the arrow.
    hover: ?usize = null,
    hover_arrow: Arrow = .none,
    /// An application tile being dragged (`from`/`to` are tile positions,
    /// 1 .. apps.len; 0, the workspace tile, never moves).
    drag: ?DragView = null,
};

/// The whole Clip surface: 1 + apps.len tiles wide.
pub fn drawClip(cv: *gfx.Canvas, m: *const Model, v: ClipView) void {
    cv.clear(col_clear);
    const n = v.apps.len + 1;

    // The workspace tile.
    const x0 = clipTileX(0, n, v.on_left);
    const hot0 = v.hover != null and v.hover.? == 0;
    drawFrame(cv, x0, 0, hot0 and v.hover_arrow == .none, null, null);

    var num_buf: [12:0]u8 = undefined;
    const num = std.fmt.bufPrintZ(&num_buf, "{d}", .{v.workspace + 1}) catch "?";
    if (v.name) |name| {
        drawCentered(cv, num, x0, 10, tile, font_number, col_text);
        var name_buf: [24:0]u8 = undefined;
        const clipped = clipName(&name_buf, name);
        drawCentered(cv, clipped, x0, 41, tile, gfx.fonts.dockLabel(), col_text);
    } else {
        drawCentered(cv, num, x0, 20, tile, font_number, col_text);
    }

    // The two arrows (Window Maker: upper right = next, lower left = prev).
    const fa: f64 = @floatFromInt(arrow);
    const fx: f64 = @floatFromInt(x0);
    const ft: f64 = @floatFromInt(tile);
    const next_col = if (hot0 and v.hover_arrow == .next) col_arrow_hot else col_arrow;
    const prev_col = if (hot0 and v.hover_arrow == .prev) col_arrow_hot else col_arrow;
    cv.fillPolygon(&.{
        .{ fx + ft - 3 - fa, 3 },
        .{ fx + ft - 3, 3 },
        .{ fx + ft - 3, 3 + fa },
    }, next_col);
    cv.fillPolygon(&.{
        .{ fx + 3, ft - 3 - fa },
        .{ fx + 3, ft - 3 },
        .{ fx + 3 + fa, ft - 3 },
    }, prev_col);

    // The applications of this workspace.
    var grabbed: ?usize = null; // index into v.apps
    for (v.apps, 0..) |_, k| {
        const i = k + 1;
        const x = clipTileX(i, n, v.on_left);
        const hot = v.hover != null and v.hover.? == i and v.drag == null;
        var src = k;
        if (v.drag) |d| if (d.from >= 1 and d.from <= v.apps.len and d.to >= 1 and d.to <= v.apps.len) {
            grabbed = d.from - 1;
            if (!d.detached) {
                if (k == d.to - 1) {
                    drawSlotGap(cv, x, 0);
                    continue;
                }
                src = reorderIndex(d.from - 1, d.to - 1, k);
            }
        };
        drawAppTile(cv, x, 0, &m.clip[v.apps[src]], hot, true);
    }
    if (v.drag) |d| if (grabbed) |g| {
        if (d.detached) {
            drawFade(cv, clipTileX(g + 1, n, v.on_left), 0);
        } else {
            const gx = std.math.clamp(d.x - @divTrunc(tile, 2), 0, @as(i32, @intCast(n)) * tile - tile);
            drawAppTile(cv, gx, 0, &m.clip[v.apps[g]], true, true);
        }
    };
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

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn testApp(name: []const u8, place: dockapp.Place, x: i32, y: i32, ws: ?u32) dockapp.DockApp {
    return .{ .name = name, .command = &.{name}, .place = place, .x = x, .y = y, .workspace = ws };
}

test "Model: dock sorted by y, logo inserted at logo_y, ties go below the logo" {
    const apps = [_]dockapp.DockApp{
        testApp("c", .dock, 0, 2, null),
        testApp("a", .dock, 0, -1, null),
        testApp("b", .dock, 0, 0, null), // same y as the logo: below it
        testApp("d", .dock, 0, 2, null), // same y as c: file order kept
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps, .logo_y = 0 }, &.{}, 4);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 5), m.dockTiles());
    try std.testing.expectEqual(@as(usize, 1), m.above_logo);
    // a, LOGO, b, c, d
    try std.testing.expectEqualStrings("a", m.dock[m.dockTile(0).?.app].app.name);
    try std.testing.expect(m.dockTile(1).? == .logo);
    try std.testing.expectEqualStrings("b", m.dock[m.dockTile(2).?.app].app.name);
    try std.testing.expectEqualStrings("c", m.dock[m.dockTile(3).?.app].app.name);
    try std.testing.expectEqualStrings("d", m.dock[m.dockTile(4).?.app].app.name);
    try std.testing.expect(m.dockTile(5) == null);
}

test "Model: an empty list is just the logo tile" {
    var m = try Model.init(std.testing.allocator, .{}, &.{}, 4);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.dockTiles());
    try std.testing.expect(m.dockTile(0).? == .logo);
}

test "Model: clipFor shows 'all workspaces' entries and the current workspace's" {
    const apps = [_]dockapp.DockApp{
        testApp("everywhere", .clip, 0, 0, null),
        testApp("ws0", .clip, 1, 0, 0),
        testApp("ws1", .clip, 2, 0, 1),
        testApp("dock", .dock, 0, 0, null),
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 3), m.clip.len);

    var buf: [8]usize = undefined;
    const on0 = m.clipFor(0, &buf);
    try std.testing.expectEqual(@as(usize, 2), on0.len);
    try std.testing.expectEqualStrings("everywhere", m.clip[on0[0]].app.name);
    try std.testing.expectEqualStrings("ws0", m.clip[on0[1]].app.name);

    const on1 = m.clipFor(1, &buf);
    try std.testing.expectEqual(@as(usize, 2), on1.len);
    try std.testing.expectEqualStrings("ws1", m.clip[on1[1]].app.name);

    // The output buffer bounds the result.
    var tiny: [1]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), m.clipFor(0, &tiny).len);
}

test "Model: names, config.conf wins over WMState" {
    const from_state: []const []const u8 = &.{ "A", "B" };
    const from_cfg: []const []const u8 = &.{ "", "Web" };
    {
        var m = try Model.init(std.testing.allocator, .{ .workspace_names = from_state }, &.{}, 4);
        defer m.deinit();
        try std.testing.expectEqualStrings("A", m.workspaceName(0).?);
        try std.testing.expect(m.workspaceName(2) == null);
    }
    {
        var m = try Model.init(std.testing.allocator, .{ .workspace_names = from_state }, from_cfg, 4);
        defer m.deinit();
        try std.testing.expect(m.workspaceName(0) == null); // empty = unnamed
        try std.testing.expectEqualStrings("Web", m.workspaceName(1).?);
    }
}

test "Model: setRunning reports a change exactly once" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "term", .command = &.{"foot"} },
        .{ .name = "web", .command = &.{"firefox"}, .place = .clip },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();

    const open: []const []const u8 = &.{ "foot", "other" };
    try std.testing.expect(m.setRunning(open));
    try std.testing.expect(m.dock[0].running);
    try std.testing.expect(!m.clip[0].running);
    try std.testing.expect(!m.setRunning(open)); // nothing new
    try std.testing.expect(m.setRunning(&.{})); // closed again
    try std.testing.expect(!m.dock[0].running);
}

test "Model: only self-declared windows can be hosted by a Dock tile" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "clock", .command = &.{"wl-clock"} },
        .{ .name = "term", .command = &.{"foot"} },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    try std.testing.expectEqual(@as(?usize, 0), m.dockSlotFor("dockapp:clock"));
    // `foot` matches the entry, but a normal window is not a dockapp.
    try std.testing.expectEqual(@as(?usize, null), m.dockSlotFor("foot"));
    try std.testing.expectEqual(@as(?usize, null), m.dockSlotFor("dockapp:nothing"));
}

test "Model: deep copy survives the source going away" {
    var src: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var m: Model = undefined;
    {
        const a = src.allocator();
        const argv = try a.alloc([]const u8, 1);
        argv[0] = try a.dupe(u8, "foot");
        const apps = try a.alloc(dockapp.DockApp, 1);
        apps[0] = .{ .name = try a.dupe(u8, "term"), .command = argv };
        m = try Model.init(std.testing.allocator, .{ .apps = apps }, &.{}, 2);
    }
    src.deinit();
    defer m.deinit();
    try std.testing.expectEqualStrings("term", m.dock[0].app.name);
    try std.testing.expectEqualStrings("foot", m.dock[0].app.command[0]);
}

test "dockRect: edge, offset and clamping" {
    var cfg: config.Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    const out: Rect = .{ .x = 100, .y = 0, .w = 1920, .h = 1080 };

    var r = dockRect(out, 3, &cfg);
    try std.testing.expectEqual(Rect{ .x = 100 + 1920 - 64, .y = 0, .w = 64, .h = 192 }, r);

    cfg.dock_edge = .left;
    cfg.dock_offset = 200;
    r = dockRect(out, 3, &cfg);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 200, .w = 64, .h = 192 }, r);

    // An offset that would push the column off the bottom is pulled back.
    cfg.dock_offset = 5000;
    r = dockRect(out, 3, &cfg);
    try std.testing.expectEqual(@as(i32, 1080 - 192), r.y);
}

test "clipRect: corners, and stepping aside for the Dock" {
    var cfg: config.Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    const out: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };

    cfg.clip_corner = .top_left;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 192, .h = 64 }, clipRect(out, 3, &cfg, null));
    cfg.clip_corner = .bottom_right;
    try std.testing.expectEqual(Rect{ .x = 1000 - 192, .y = 800 - 64, .w = 192, .h = 64 }, clipRect(out, 3, &cfg, null));

    // Dock on the right, Clip in the top right corner: the Clip moves left.
    cfg.dock_edge = .right;
    cfg.clip_corner = .top_right;
    const dock = dockRect(out, 4, &cfg);
    const r = clipRect(out, 2, &cfg, dock);
    try std.testing.expectEqual(dock.x - 128, r.x);
    // Same on the left.
    cfg.dock_edge = .left;
    cfg.clip_corner = .top_left;
    const dock_l = dockRect(out, 4, &cfg);
    try std.testing.expectEqual(dock_l.right(), clipRect(out, 2, &cfg, dock_l).x);
    // No overlap, no move: Dock below the Clip.
    cfg.dock_offset = 200;
    const low = dockRect(out, 4, &cfg);
    try std.testing.expectEqual(@as(i32, 0), clipRect(out, 2, &cfg, low).x);
}

test "tile hit tests: Dock rows, Clip columns on both sides, arrows" {
    try std.testing.expectEqual(@as(?usize, 0), dockTileAt(0, 3));
    try std.testing.expectEqual(@as(?usize, 2), dockTileAt(191, 3));
    try std.testing.expectEqual(@as(?usize, null), dockTileAt(192, 3));
    try std.testing.expectEqual(@as(?usize, null), dockTileAt(-1, 3));

    // Anchored left: tile 0 is leftmost. Anchored right: it is rightmost.
    try std.testing.expectEqual(@as(?usize, 0), clipTileAt(10, 3, true));
    try std.testing.expectEqual(@as(?usize, 2), clipTileAt(150, 3, true));
    try std.testing.expectEqual(@as(?usize, 0), clipTileAt(150, 3, false));
    try std.testing.expectEqual(@as(?usize, 2), clipTileAt(10, 3, false));
    try std.testing.expectEqual(@as(?usize, null), clipTileAt(192, 3, true));
    try std.testing.expectEqual(@as(i32, 128), clipTileX(0, 3, false));
    try std.testing.expectEqual(@as(i32, 128), clipTileX(2, 3, true));

    try std.testing.expectEqual(Arrow.next, clipArrowAt(60, 3));
    try std.testing.expectEqual(Arrow.prev, clipArrowAt(3, 60));
    try std.testing.expectEqual(Arrow.none, clipArrowAt(32, 32));
    try std.testing.expectEqual(Arrow.none, clipArrowAt(3, 3)); // upper left: neither
    try std.testing.expectEqual(Arrow.none, clipArrowAt(60, 60));
    try std.testing.expectEqual(Arrow.none, clipArrowAt(64, 3)); // next tile
}

test "tilesThatFit never returns 0" {
    try std.testing.expectEqual(@as(usize, 1), tilesThatFit(10));
    try std.testing.expectEqual(@as(usize, 1), tilesThatFit(-5));
    try std.testing.expectEqual(@as(usize, 16), tilesThatFit(1080));
}

fn px(data: []const u8, stride: i32, x: i32, y: i32) u32 {
    const off: usize = @intCast(y * stride + x * 4);
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

test "drawDock paints tiles; only a NOT running tile gets Window Maker's three dots" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "term", .command = &.{"definitely-no-such-icon-xyz"} },
        .{ .name = "web", .command = &.{"definitely-no-such-icon-abc"} },
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

    drawDock(&cv, &m, 3, 0);
    cv.flush();

    // Tile 0 is the logo (dark), tile 1 the running app, tile 2 the other.
    const logo = px(data, w * 4, 32, 4);
    const app = px(data, w * 4, 32, tile + 4);
    try std.testing.expectEqual(@as(u32, 0xff), logo >> 24);
    try std.testing.expectEqual(@as(u32, 0xff), app >> 24);
    try std.testing.expect((logo & 0xff) < 0x80); // dark
    try std.testing.expect((app & 0xff) > 0x80); // light
    // Dots at x = 4, 9, 14 and y = tile - 6 of the tile that is NOT running.
    for ([_]i32{ 4, 9, 14 }) |dx| {
        try std.testing.expectEqual(@as(u32, 0xffffffff), px(data, w * 4, dx + 1, 2 * tile + tile - 6));
        // ... and none on the running one.
        try std.testing.expect(px(data, w * 4, dx + 1, tile + tile - 6) != 0xffffffff);
    }
}

test "drawClip paints both arrows and the application tiles" {
    const apps = [_]dockapp.DockApp{.{ .name = "notes", .command = &.{"definitely-no-such-icon-xyz"}, .place = .clip }};
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();

    const w = tile * 2;
    const h = tile;
    const data = try std.testing.allocator.alloc(u8, @intCast(w * h * 4));
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var cv = try gfx.Canvas.initForData(data.ptr, w, h, w * 4);
    defer cv.deinit();

    const idx = [_]usize{0};
    drawClip(&cv, &m, .{ .workspace = 1, .name = "Web", .apps = &idx, .on_left = true });
    cv.flush();

    // Upper-right arrow of the workspace tile (dark), lower-left arrow (dark).
    try std.testing.expectEqual(@as(u32, 0xff303030), px(data, w * 4, tile - 4, 5));
    try std.testing.expectEqual(@as(u32, 0xff303030), px(data, w * 4, 5, tile - 4));
    // The second tile is an opaque application tile.
    try std.testing.expectEqual(@as(u32, 0xff), px(data, w * 4, tile + 32, 4) >> 24);

    // Hovering an arrow lights it up.
    drawClip(&cv, &m, .{ .workspace = 1, .name = null, .apps = &idx, .on_left = true, .hover = 0, .hover_arrow = .next });
    cv.flush();
    try std.testing.expectEqual(@as(u32, 0xffffffff), px(data, w * 4, tile - 4, 5));
    // The other arrow stays dark.
    try std.testing.expectEqual(@as(u32, 0xff303030), px(data, w * 4, 5, tile - 4));
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

test "dockedRect: a fixed-size dockapp lands centred in its tile" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "above", .command = &.{"x"}, .y = -1 },
        .{ .name = "clock", .command = &.{"wl-clock"}, .y = 1 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    // Tiles: above, LOGO, clock.
    const dock: Rect = .{ .x = 1856, .y = 100, .w = 64, .h = 192 };

    const full = dockedRect(&m, dock, 3, "dockapp:clock", 64, 64, 64, 64).?;
    try std.testing.expectEqual(Rect{ .x = 1856, .y = 100 + 128, .w = 64, .h = 64 }, full);
    const small = dockedRect(&m, dock, 3, "dockapp:clock", 48, 40, 48, 40).?;
    try std.testing.expectEqual(Rect{ .x = 1856 + 8, .y = 100 + 128 + 12, .w = 48, .h = 40 }, small);
    // The entry above the logo is tile 0.
    try std.testing.expectEqual(@as(i32, 100), dockedRect(&m, dock, 3, "dockapp:above", 64, 64, 64, 64).?.y);

    // Not fixed, too big, not a dockapp, no such entry, tile cut off.
    try std.testing.expect(dockedRect(&m, dock, 3, "dockapp:clock", 0, 0, 64, 64) == null);
    try std.testing.expect(dockedRect(&m, dock, 3, "dockapp:clock", 0, 0, 0, 0) == null);
    try std.testing.expect(dockedRect(&m, dock, 3, "dockapp:clock", 65, 64, 65, 64) == null);
    try std.testing.expect(dockedRect(&m, dock, 3, "wl-clock", 64, 64, 64, 64) == null);
    try std.testing.expect(dockedRect(&m, dock, 3, "dockapp:none", 64, 64, 64, 64) == null);
    try std.testing.expect(dockedRect(&m, dock, 2, "dockapp:clock", 64, 64, 64, 64) == null);
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

test "wl-clock: --name picks the Dock tile, several clocks do not mix" {
    // Entry names are what `dockapp:<name>` is matched against; the command
    // line (here wl-clock's own --name/--tz/--label) plays no part.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const apps = [_]dockapp.DockApp{
        .{ .name = "clock", .command = try config.parseCommand(a, "wl-clock"), .y = 1 },
        .{ .name = "tokyo", .command = try config.parseCommand(a, "wl-clock --name tokyo --tz Asia/Tokyo --label tokyo"), .y = 2 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();

    try std.testing.expectEqual(@as(?usize, 0), m.dockSlotFor("dockapp:clock"));
    try std.testing.expectEqual(@as(?usize, 1), m.dockSlotFor("dockapp:tokyo"));

    // Tiles: LOGO, clock, tokyo. The tokyo window lands in tile 2.
    const dock: Rect = .{ .x = 1856, .y = 0, .w = 64, .h = 192 };
    const r = dockedRect(&m, dock, 3, "dockapp:tokyo", 64, 64, 64, 64).?;
    try std.testing.expectEqual(@as(i32, 128), r.y);

    // Both are "running" only when their own window exists.
    _ = m.setRunning(&.{"dockapp:tokyo"});
    try std.testing.expect(!m.dock[0].running);
    try std.testing.expect(m.dock[1].running);
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
    try std.testing.expect(m.dock[0].icon != null);
    try std.testing.expectEqual(@as(i32, 2), m.dock[0].icon.?.w);
    try std.testing.expect(m.dock[1].icon == null);
}

// ----------------------------------------------------------------------------
// Tests: dragging, removing, adding, launching
// ----------------------------------------------------------------------------

fn tileNames(m: *const Model, out: *[8][]const u8) []const []const u8 {
    var n: usize = 0;
    for (0..m.dockTiles()) |t| {
        out[n] = switch (m.dockTile(t).?) {
            .logo => "LOGO",
            .app => |i| m.dock[i].app.name,
        };
        n += 1;
    }
    return out[0..n];
}

fn expectOrder(m: *const Model, want: []const []const u8) !void {
    var buf: [8][]const u8 = undefined;
    const got = tileNames(m, &buf);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "reorderIndex: moving down and up shifts the tiles in between" {
    // [0 1 2 3 4], move tile 1 to position 3 -> [0 2 3 1 4]
    const down = [_]usize{ 0, 2, 3, 1, 4 };
    for (down, 0..) |want, t| try std.testing.expectEqual(want, reorderIndex(1, 3, t));
    // move tile 3 to position 1 -> [0 3 1 2 4]
    const up = [_]usize{ 0, 3, 1, 2, 4 };
    for (up, 0..) |want, t| try std.testing.expectEqual(want, reorderIndex(3, 1, t));
    // from == to: nothing changes
    for (0..5) |t| try std.testing.expectEqual(t, reorderIndex(2, 2, t));
}

test "reorderIndex is a permutation for every from/to" {
    const n = 6;
    for (0..n) |from| for (0..n) |to| {
        var seen = [_]bool{false} ** n;
        for (0..n) |t| {
            const i = reorderIndex(from, to, t);
            try std.testing.expect(i < n);
            try std.testing.expect(!seen[i]);
            seen[i] = true;
        }
    };
}

test "Model.moveDockTile: reorder, and crossing the logo changes what is above it" {
    const apps = [_]dockapp.DockApp{
        testApp("a", .dock, 0, 0, null),
        testApp("b", .dock, 0, 1, null),
        testApp("c", .dock, 0, 2, null),
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    try expectOrder(&m, &.{ "LOGO", "a", "b", "c" });

    try std.testing.expect(m.moveDockTile(1, 3)); // a to the bottom
    try expectOrder(&m, &.{ "LOGO", "b", "c", "a" });
    try std.testing.expectEqual(@as(usize, 0), m.above_logo);

    try std.testing.expect(m.moveDockTile(3, 0)); // a above the logo
    try expectOrder(&m, &.{ "a", "LOGO", "b", "c" });
    try std.testing.expectEqual(@as(usize, 1), m.above_logo);

    // y numbering round-trips through Model.init: -1 above, 0, 1 below.
    try std.testing.expectEqual(@as(i32, -1), m.dock[0].app.y);
    try std.testing.expectEqual(@as(i32, 0), m.dock[1].app.y);
    try std.testing.expectEqual(@as(i32, 1), m.dock[2].app.y);
    var export_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer export_arena.deinit();
    var again = try Model.init(std.testing.allocator, try m.exportList(export_arena.allocator()), &.{}, 4);
    defer again.deinit();
    try expectOrder(&again, &.{ "a", "LOGO", "b", "c" });

    // The logo never moves by itself; bad indices and no-ops are refused.
    try std.testing.expect(!m.moveDockTile(1, 3));
    try std.testing.expect(!m.moveDockTile(0, 0));
    try std.testing.expect(!m.moveDockTile(0, 9));
}

test "Model.removeDock / removeClip: gone, indices stay valid, locked stays" {
    const apps = [_]dockapp.DockApp{
        testApp("a", .dock, 0, -1, null),
        testApp("b", .dock, 0, 0, null),
        .{ .name = "c", .command = &.{"c"}, .y = 1, .locked = true },
        testApp("x", .clip, 0, 0, null),
        testApp("y", .clip, 1, 0, null),
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    try expectOrder(&m, &.{ "a", "LOGO", "b", "c" });

    try std.testing.expect(m.removeDock(0)); // above the logo
    try expectOrder(&m, &.{ "LOGO", "b", "c" });
    try std.testing.expectEqual(@as(usize, 0), m.above_logo);
    try std.testing.expect(!m.removeDock(1)); // "c" is locked
    try std.testing.expect(!m.removeDock(7));
    try expectOrder(&m, &.{ "LOGO", "b", "c" });

    try std.testing.expect(m.removeClip(0));
    try std.testing.expectEqual(@as(usize, 1), m.clip.len);
    try std.testing.expectEqualStrings("y", m.clip[0].app.name);
    try std.testing.expect(!m.removeClip(1));
}

test "Model.addApp: appended at the end, has a position, is seen by hasApp" {
    var m = try Model.init(std.testing.allocator, .{}, &.{}, 4);
    defer m.deinit();
    const i = try m.addApp(std.testing.allocator, .{ .name = "firefox", .command = &.{"firefox"} });
    try std.testing.expectEqual(@as(usize, 0), i);
    const j = try m.addApp(std.testing.allocator, .{ .name = "foot", .command = &.{"foot"}, .place = .clip });
    try std.testing.expectEqual(@as(usize, 0), j);
    try expectOrder(&m, &.{ "LOGO", "firefox" });
    try std.testing.expect(m.hasApp("firefox"));
    try std.testing.expect(m.hasApp("foot"));
    try std.testing.expect(!m.hasApp("gimp"));
    const k = try m.addApp(std.testing.allocator, .{ .name = "gimp", .command = &.{"gimp"} });
    try std.testing.expectEqual(@as(i32, 1), m.dock[k].app.y);
}

test "Model: launching is set, cleared by a window, and times out" {
    const apps = [_]dockapp.DockApp{.{ .name = "term", .command = &.{"foot"} }};
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();

    m.markLaunching(false, 0, 10);
    try std.testing.expect(m.dock[0].launching);
    try std.testing.expect(!m.expireLaunching(12, 5));
    try std.testing.expect(m.dock[0].launching);
    try std.testing.expect(m.expireLaunching(20, 5)); // too old
    try std.testing.expect(!m.dock[0].launching);

    m.markLaunching(false, 0, 30);
    try std.testing.expect(m.setRunning(&.{"foot"})); // window appeared
    try std.testing.expect(!m.dock[0].launching);
    // Already running: a click only focuses, nothing to wait for.
    m.markLaunching(false, 0, 31);
    try std.testing.expect(!m.dock[0].launching);
    // Out of range is ignored, not a crash.
    m.markLaunching(true, 5, 1);
}

test "detached / dropTile / dockPlacementFor" {
    try std.testing.expect(!detached(30, 100, tile, 256));
    try std.testing.expect(!detached(-detach_distance, 10, tile, 256));
    try std.testing.expect(detached(-detach_distance - 1, 10, tile, 256));
    try std.testing.expect(detached(tile + detach_distance + 1, 10, tile, 256));
    try std.testing.expect(detached(10, 256 + detach_distance + 1, tile, 256));

    try std.testing.expectEqual(@as(usize, 0), dropTile(-30, 4));
    try std.testing.expectEqual(@as(usize, 2), dropTile(2 * tile + 3, 4));
    try std.testing.expectEqual(@as(usize, 3), dropTile(9999, 4));
    try std.testing.expectEqual(@as(usize, 0), dropTile(5, 0));

    const out: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const left = dockPlacementFor(out, 100, 300);
    try std.testing.expectEqual(config.DockEdge.left, left.edge);
    try std.testing.expectEqual(@as(i32, 300), left.offset);
    const right = dockPlacementFor(out, 1700, -50);
    try std.testing.expectEqual(config.DockEdge.right, right.edge);
    try std.testing.expectEqual(@as(i32, 0), right.offset);
    // Applying a placement gives a rectangle on that edge.
    const r = dockRectAt(out, 3, left.edge, left.offset);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 300), r.y);
}

test "drawDockDrag: the gap follows the drop position, detaching fades in place" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "a", .command = &.{"definitely-no-such-icon-a"} },
        .{ .name = "b", .command = &.{"definitely-no-such-icon-b"} },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();

    const w = tile;
    const h = tile * 3;
    const data = try std.testing.allocator.alloc(u8, @intCast(w * h * 4));
    defer std.testing.allocator.free(data);
    var cv = try gfx.Canvas.initForData(data.ptr, w, h, w * 4);
    defer cv.deinit();

    // Drag tile 1 ("a") to position 2: the slot at 2 is the recessed gap.
    @memset(data, 0);
    drawDockDrag(&cv, &m, 3, null, .{ .from = 1, .to = 2, .x = 30, .y = 2 * tile + 10 });
    cv.flush();
    const gap = px(data, w * 4, 32, 2 * tile + 32);
    const normal = px(data, w * 4, 32, tile + 4);
    try std.testing.expect(gap != normal);
    try std.testing.expectEqual(@as(u32, 0xff), normal >> 24);

    // Detached: nothing is moved, the tile is veiled (alpha < 0xff blend
    // over the gradient still opaque), and the gap is not drawn.
    @memset(data, 0);
    drawDockDrag(&cv, &m, 3, null, .{ .from = 1, .to = 2, .x = -200, .y = 10, .detached = true });
    cv.flush();
    try std.testing.expect(px(data, w * 4, 32, 2 * tile + 4) != gap);
    try std.testing.expect(px(data, w * 4, 32, tile + 32) != px(data, w * 4, 32, 2 * tile + 32));
}

test "drawClip marks an omnipresent entry and a launching tile" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "all", .command = &.{"definitely-no-such-icon-1"}, .place = .clip },
        .{ .name = "one", .command = &.{"definitely-no-such-icon-2"}, .place = .clip, .workspace = 0 },
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    m.markLaunching(true, 1, 0);

    const w = tile * 3;
    const h = tile;
    const data = try std.testing.allocator.alloc(u8, @intCast(w * h * 4));
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var cv = try gfx.Canvas.initForData(data.ptr, w, h, w * 4);
    defer cv.deinit();
    const idx = [_]usize{ 0, 1 };
    drawClip(&cv, &m, .{ .workspace = 0, .name = null, .apps = &idx, .on_left = true });
    cv.flush();

    // Folded corner (dark) at the upper right of tile 1 ("all") only.
    try std.testing.expectEqual(@as(u32, 0xff555555), px(data, w * 4, 2 * tile - 3, 8));
    try std.testing.expect(px(data, w * 4, 3 * tile - 3, 8) != 0xff555555);
    // The raster darkens every other pixel of the launching tile (tile 2).
    const a = px(data, w * 4, 2 * tile + 20, 20);
    const b = px(data, w * 4, 2 * tile + 21, 20);
    try std.testing.expect(a != b);
}

test "clipDropTile / clipCornerFor / Model.moveClipEntry" {
    // 4 tiles: workspace + 3 apps, anchored left: x picks the tile, 0 is never returned.
    try std.testing.expectEqual(@as(usize, 1), clipDropTile(-20, 4, true));
    try std.testing.expectEqual(@as(usize, 1), clipDropTile(10, 4, true)); // over the workspace tile
    try std.testing.expectEqual(@as(usize, 1), clipDropTile(tile + 5, 4, true));
    try std.testing.expectEqual(@as(usize, 2), clipDropTile(2 * tile + 5, 4, true));
    try std.testing.expectEqual(@as(usize, 3), clipDropTile(9999, 4, true));
    // Anchored right the workspace tile is the rightmost one.
    try std.testing.expectEqual(@as(usize, 3), clipDropTile(-5, 4, false));
    try std.testing.expectEqual(@as(usize, 1), clipDropTile(9999, 4, false));
    try std.testing.expectEqual(@as(usize, 1), clipDropTile(5, 1, true));

    const out: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    try std.testing.expectEqual(config.ClipCorner.top_left, clipCornerFor(out, 10, 10));
    try std.testing.expectEqual(config.ClipCorner.top_right, clipCornerFor(out, 900, 10));
    try std.testing.expectEqual(config.ClipCorner.bottom_left, clipCornerFor(out, 10, 700));
    try std.testing.expectEqual(config.ClipCorner.bottom_right, clipCornerFor(out, 900, 700));

    const apps = [_]dockapp.DockApp{
        testApp("a", .clip, 0, 0, null),
        testApp("b", .clip, 1, 0, 0),
        testApp("c", .clip, 2, 0, null),
        testApp("d", .clip, 3, 0, 1),
    };
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    try std.testing.expect(m.moveClipEntry(0, 2)); // a after c
    try std.testing.expectEqualStrings("b", m.clip[0].app.name);
    try std.testing.expectEqualStrings("c", m.clip[1].app.name);
    try std.testing.expectEqualStrings("a", m.clip[2].app.name);
    try std.testing.expectEqualStrings("d", m.clip[3].app.name);
    try std.testing.expect(m.moveClipEntry(3, 0)); // d first
    try std.testing.expectEqualStrings("d", m.clip[0].app.name);
    try std.testing.expectEqualStrings("b", m.clip[1].app.name);
    for (m.clip, 0..) |sl, i| try std.testing.expectEqual(@as(i32, @intCast(i)), sl.app.x);
    try std.testing.expect(!m.moveClipEntry(1, 1));
    try std.testing.expect(!m.moveClipEntry(1, 9));
}
