// SPDX-License-Identifier: GPL-3.0
//
// ATTIC: the drawing and icon loading of the Dock, Clip and Drawers. The model
// (tiles, slots, grid, geometry, hit testing) now lives in src/dock_model.zig
// and the DockApp hosting in src/dockhost.zig; what is left here still names
// `Model`, `Slot`, `tile` and `Cells` from there and is ported when the
// compositor draws the Dock (see docs/TODO wlroots.md, section 4).
//
// Every dock is drawn on one surface that covers its tiles plus a margin
// where a dragged tile can still snap to.

const std = @import("std");
const log = std.log.scoped(.dock);
const gfx = @import("gfx.zig");
const config = @import("config.zig");
const dockapp = @import("dockapp.zig");
const xpm = @import("xpm.zig");
const appicon = @import("appicon.zig");
const svg = @import("svg.zig");
const types = @import("types.zig");
const wdock = @import("wm_dock.zig");

const Rect = types.Rect;

// ----------------------------------------------------------------------------
// Look (Window Maker / NeXT, same palette as the menu in ui.zig)
// ----------------------------------------------------------------------------

/// Default tile size (Window Maker's default icon size).
pub const default_tile: i32 = 64;
/// Edge length of a tile in px. Set from `dock_size` in config.lua (see
/// `setSize`); a plain variable because the whole Dock geometry is derived
/// from it and the compositor is single-threaded.
pub var tile: i32 = default_tile;
/// Side of the (square) icon inside a tile: 3/4 of the tile (48 of 64).
pub var icon_size: i32 = 48;

/// Apply the configured tile size. Everything is recomputed from `tile`
/// on the next layout pass (ui.prepareBar re-creates surfaces whose size changed).
pub fn setSize(size: i32) void {
    tile = size;
    icon_size = @divTrunc(size * 3, 4);
    // The Dock grid in wm_dock.zig must use the same cell size as the drawing.
    wdock.icon_size = size;
    log.debug("tile size {d} px (icon {d} px)", .{ tile, icon_size });
}
/// Edge length of the workspace arrow buttons in the Clip's corners.
pub const arrow: i32 = 16;

const font_logo: [:0]const u8 = "Sans Bold 22";
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
/// own format, see xpm.zig) and SVG (through librsvg, see svg.zig); a tile
/// without an icon shows `drawPlaceholder`.
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
    // directory for a PNG, then an SVG, then an XPM.
    var stem = wanted;
    inline for (.{ ".png", ".svg", ".xpm" }) |ext| {
        if (std.mem.endsWith(u8, stem, ext)) stem = stem[0 .. stem.len - ext.len];
    }
    inline for (.{ ".png", ".svg", ".xpm" }) |ext| {
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
    if (std.ascii.endsWithIgnoreCase(path, ".svg")) return svg.load(path, svg.render_size);
    return gfx.Icon.loadPng(path);
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

pub fn drawCentered(cv: *gfx.Canvas, text: [:0]const u8, x: i32, y: i32, w: i32, font: [:0]const u8, col: gfx.Color) void {
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
        drawPlaceholder(cv, x + off, y + off, icon_size);
    }
    // Only an entry that can be started says "not running" (a hand-made
    // entry without a command has nothing to show).
    if (!slot.running and slot.app.command.len > 0) drawNotRunning(cv, x, y);
    if (slot.gi.omnipresent) drawOmnipresent(cv, x, y);
    if (slot.launching) drawLaunching(cv, x, y);
}

/// What a tile shows when no icon can be found at all (no icon theme, or only
/// SVG icons and no librsvg): a small window in the Dock's own colours. Never
/// a letter. (x, y) is the top left of the `size` x `size` icon area.
pub fn drawPlaceholder(cv: *gfx.Canvas, x: i32, y: i32, size: i32) void {
    const m = @divTrunc(size, 8);
    const gx = x + m;
    const gy = y + m + @divTrunc(m, 2);
    const gw = size - 2 * m;
    const gh = size - 3 * m;
    if (gw < 12 or gh < 12) return;
    const bar = @max(@divTrunc(gh, 4), 4);

    cv.fillRect(gx + 2, gy + 2, gw, gh, col_dark); // shadow
    cv.fillRect(gx, gy, gw, gh, col_tile_from); // the window
    cv.vGradient(gx + 1, gy + 1, gw - 2, bar, col_logo_from, col_logo_to); // its title bar
    cv.bevel(gx, gy, gw, gh, col_light, col_dark);

    // Three lines of "text" in it, the last one shorter.
    const gap = @max(m, 3);
    const full = gw - 2 * gap;
    var ly = gy + bar + gap;
    var i: i32 = 0;
    while (i < 3 and ly + 2 <= gy + gh - 2) : (i += 1) {
        const len = if (i == 2) @divTrunc(full * 2, 3) else full;
        cv.fillRect(gx + gap, ly, len, 2, col_tile_to);
        ly += gap;
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

// `name` is comptime on purpose: `&.{name}` is then a constant in the binary.
// With a runtime name it would point into this function's stack frame, which
// is gone when `mk` returns (it only seemed to work in Debug builds).
fn mk(comptime name: []const u8, place: dockapp.Place, x: i32, y: i32) dockapp.DockApp {
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

test "drawPlaceholder: a small window in the Dock's colours (never a letter), and safe at any size" {
    const side: i32 = 48;
    const data = try std.testing.allocator.alloc(u8, @intCast(side * side * 4));
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var cv = try gfx.Canvas.initForData(data.ptr, side, side, side * 4);
    defer cv.deinit();

    drawPlaceholder(&cv, 0, 0, side);
    cv.flush();
    // The middle of the window is opaque, the corner of the icon area is untouched.
    try std.testing.expectEqual(@as(u32, 0xff), px(data, side * 4, 24, 24) >> 24);
    try std.testing.expectEqual(@as(u32, 0), px(data, side * 4, 1, 1));
    // A dark title bar over a light body.
    try std.testing.expect((px(data, side * 4, 24, 12) & 0xff) < 0x80);
    try std.testing.expect((px(data, side * 4, 8, 35) & 0xff) > 0xa0);

    // Too small to be a window: nothing is drawn, and nothing breaks.
    const small = try std.testing.allocator.alloc(u8, @intCast(side * side * 4));
    defer std.testing.allocator.free(small);
    @memset(small, 0);
    var cv2 = try gfx.Canvas.initForData(small.ptr, side, side, side * 4);
    defer cv2.deinit();
    for ([_]i32{ -5, 0, 1, 8, 14 }) |s| drawPlaceholder(&cv2, 0, 0, s);
    cv2.flush();
    for (small) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "a tile without an icon shows the placeholder, and a minimized window's tile has no mark in its corner" {
    const apps = [_]dockapp.DockApp{.{ .name = "definitely-no-such-icon-plain", .command = &.{}, .y = 1 }};
    var m = try Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer m.deinit();
    const mini_idx = try m.attachWindow("definitely-no-such-icon-mini", "definitely-no-such-icon-mini", 7);

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

    const plain = cellPx(cells, 0, rowOf(&m, "definitely-no-such-icon-plain").?);
    const mini = cellPx(cells, 0, m.slot(mini_idx).?.gi.yindex);

    // No icon: the placeholder's dark title bar crosses the icon area, at its
    // left and at its right end (a letter could not be in both places).
    const off = @divTrunc(tile - icon_size, 2);
    const m8 = @divTrunc(icon_size, 8);
    const bar_y = off + m8 + @divTrunc(m8, 2) + 3;
    const left_x = off + m8 + 3;
    const right_x = off + icon_size - m8 - 3;
    try std.testing.expect((px(data, w * 4, plain[0] + left_x, plain[1] + bar_y) & 0xff) < 0x80);
    try std.testing.expect((px(data, w * 4, plain[0] + right_x, plain[1] + bar_y) & 0xff) < 0x80);

    // The corner where the old "minimized" bar sat (left of the icon area, so
    // whatever icon the tile has cannot be in the way) is drawn exactly like
    // the same corner of an ordinary tile.
    const spots = [_][2]i32{ .{ 5, tile - 11 }, .{ 6, tile - 9 }, .{ 7, tile - 7 }, .{ 6, tile - 6 } };
    for (spots) |sp| {
        try std.testing.expectEqual(
            px(data, w * 4, plain[0] + sp[0], plain[1] + sp[1]),
            px(data, w * 4, mini[0] + sp[0], mini[1] + sp[1]),
        );
    }
}
