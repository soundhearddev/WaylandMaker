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
const col_running = gfx.Color.rgb(0x000000);
const col_arrow = gfx.Color.rgb(0x303030);
const col_arrow_hot = gfx.Color.rgb(0xffffff);

// ----------------------------------------------------------------------------
// Model
// ----------------------------------------------------------------------------

pub const Slot = struct {
    app: dockapp.DockApp,
    icon: ?gfx.Icon = null,
    /// A window of this application is open (set by ui.zig every sync).
    running: bool = false,
};

/// What one Dock tile is.
pub const Tile = union(enum) {
    logo,
    /// Index into `Model.dock`.
    app: usize,
};

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

        const names = if (cfg_names.len > 0) cfg_names else list.workspace_names;
        var names_copy = try a.alloc([]const u8, names.len);
        for (names, 0..) |n, i| names_copy[i] = try a.dupe(u8, n);

        return .{
            .arena = arena,
            .dock = try dock.toOwnedSlice(a),
            .clip = try clip.toOwnedSlice(a),
            .names = names_copy,
            .above_logo = above,
            .workspace_count = workspace_count,
        };
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
            }
        }
        return changed;
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
    const h: i32 = @as(i32, @intCast(ntiles)) * tile;
    const x = switch (cfg.dock_edge) {
        .left => out.x,
        .right => out.right() - tile,
    };
    const y = std.math.clamp(out.y + cfg.dock_offset, out.y, @max(out.y, out.bottom() - h));
    return .{ .x = x, .y = y, .w = tile, .h = h };
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

/// "running" mark: a small black triangle in the lower left corner.
fn drawRunning(cv: *gfx.Canvas, x: i32, y: i32) void {
    const fx: f64 = @floatFromInt(x + 5);
    const fy: f64 = @floatFromInt(y + tile - 5);
    cv.fillPolygon(&.{
        .{ fx, fy },
        .{ fx + 9, fy },
        .{ fx, fy - 9 },
    }, col_running);
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
    if (slot.running) drawRunning(cv, x, y);
}

/// The whole Dock surface (tile * ntiles high). `hover` is a tile index.
pub fn drawDock(cv: *gfx.Canvas, m: *const Model, ntiles: usize, hover: ?usize) void {
    cv.clear(col_clear);
    var t: usize = 0;
    while (t < ntiles) : (t += 1) {
        const y: i32 = @as(i32, @intCast(t)) * tile;
        const hot = hover != null and hover.? == t;
        switch (m.dockTile(t) orelse break) {
            .logo => {
                drawFrame(cv, 0, y, hot, col_logo_from, col_logo_to);
                drawCentered(cv, "WM", 0, y + 16, tile, font_logo, col_light);
            },
            .app => |i| drawAppTile(cv, 0, y, &m.dock[i], hot),
        }
    }
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
    for (v.apps, 0..) |si, k| {
        const i = k + 1;
        const x = clipTileX(i, n, v.on_left);
        const hot = v.hover != null and v.hover.? == i;
        drawAppTile(cv, x, 0, &m.clip[si], hot);
    }
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

test "drawDock paints tiles, the running mark, and leaves the rest transparent" {
    const apps = [_]dockapp.DockApp{.{ .name = "term", .command = &.{"definitely-no-such-icon-xyz"} }};
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    _ = m.setRunning(&.{"definitely-no-such-icon-xyz"});

    const w = tile;
    const h = tile * 2;
    const data = try std.testing.allocator.alloc(u8, @intCast(w * h * 4));
    defer std.testing.allocator.free(data);
    @memset(data, 0xff);
    var cv = try gfx.Canvas.initForData(data.ptr, w, h, w * 4);
    defer cv.deinit();

    drawDock(&cv, &m, 2, 0);
    cv.flush();

    // Tile 0 is the logo (dark), tile 1 the app (light grey, opaque).
    const logo = px(data, w * 4, 32, 4);
    const app = px(data, w * 4, 32, tile + 4);
    try std.testing.expectEqual(@as(u32, 0xff), logo >> 24);
    try std.testing.expectEqual(@as(u32, 0xff), app >> 24);
    try std.testing.expect((logo & 0xff) < 0x80); // dark
    try std.testing.expect((app & 0xff) > 0x80); // light
    // The running mark: black pixel in the lower left of the app tile.
    try std.testing.expectEqual(@as(u32, 0xff000000), px(data, w * 4, 7, tile + tile - 7));
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
