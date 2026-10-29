// SPDX-License-Identifier: GPL-3.0
//
// The pixels of ONE dock tile. A function of its `Look` (dock_view.zig) and of
// the two things a `Look` only names by a hash: the icon and the Clip's
// workspace name. Nothing about where the tile is, nothing about Wayland: the
// compositor renders a `Look` once per `Look.key()` into a buffer and shows
// that buffer wherever the look is needed (dock_scene.zig).
//
// The tile is designed on Window Maker's 64 x 64 grid. `scale.Metrics` turns
// those design units into whole device pixels for any tile size and any output
// scale, so edges of neighbours still touch and a line is never thinner than
// one pixel. At 64 px and scale 1 the result is pixel for pixel the tile of
// Window Maker's NeXT look.

const std = @import("std");

const gfx = @import("gfx.zig");
const scale_mod = @import("scale.zig");
const dock_view = @import("dock_view.zig");
const style = @import("style.zig");

pub const Look = dock_view.Look;
pub const Content = struct {
    /// App tiles: the icon found for `Look.icon_key`; null draws the placeholder.
    icon: ?gfx.Icon = null,
    /// Clip tile: the workspace's name (shown under the number).
    name: ?[]const u8 = null,
};

const Color = gfx.Color;

// ---- palette ------------------------------------------------------------------------
//
// What a theme can change lives in style.zig (`style.palette`, NeXT by
// default). These stay fixed: they are overlays on top of whatever the theme
// colours, not part of a look.

const col_shadow = Color.rgb(0x000000);
const col_stipple: Color = .{ .r = 0, .g = 0, .b = 0, .a = 112.0 / 255.0 };
const col_gap: Color = .{ .r = 64.0 / 255.0, .g = 64.0 / 255.0, .b = 68.0 / 255.0, .a = 176.0 / 255.0 };
const col_fade: Color = .{ .r = 216.0 / 255.0, .g = 216.0 / 255.0, .b = 220.0 / 255.0, .a = 176.0 / 255.0 };

/// Device pixels of one side of the tile `look` at `scale` (the output's
/// integer scale: 1, 2, ...).
pub fn deviceSide(look: Look, scale: i32) i32 {
    return look.size * @max(1, scale);
}

/// Bytes a buffer for `look` needs (ARGB32, stride = side * 4).
pub fn byteLen(look: Look, scale: i32) usize {
    const s: usize = @intCast(deviceSide(look, scale));
    return s * s * 4;
}

/// Draw `look` into `pixels` (`byteLen` bytes, ARGB32 premultiplied, as cairo
/// and wl_shm / DRM_FORMAT_ARGB8888 want it). The old content is replaced.
pub fn render(pixels: []u8, look: Look, content: Content, scale: i32) !void {
    const side = deviceSide(look, scale);
    std.debug.assert(pixels.len >= byteLen(look, scale));
    var cv = try gfx.Canvas.initForData(pixels.ptr, side, side, side * 4);
    defer cv.deinit();
    cv.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });

    const m: scale_mod.Metrics = .{ .side = side };
    switch (look.kind) {
        .gap => drawGap(&cv, m),
        .logo => {
            frame(&cv, m, look.hot, style.palette.logo_from, style.palette.logo_to);
            centred(&cv, m, "WM", 16, gfx.fonts.dockLogo(), style.palette.logo_text);
        },
        .clip => drawClip(&cv, m, look, content),
        .drawer => drawDrawer(&cv, m, look),
        .app => drawApp(&cv, m, look, content),
    }
    if (look.faded) cv.fillRect(0, 0, side, side, col_fade);
    cv.flush();
}

// ---- pieces -----------------------------------------------------------------------

/// The tile body: a diagonal gradient and the two-line NeXT bevel.
fn frame(cv: *gfx.Canvas, m: scale_mod.Metrics, hot: bool, from: ?Color, to: ?Color) void {
    const pal = style.palette;
    const f = from orelse if (hot) pal.tile_hot_from else pal.tile_from;
    const t = to orelse if (hot) pal.tile_hot_to else pal.tile_to;
    const s = m.side;
    cv.dGradient(0, 0, s, s, f, t);
    const b = m.stroke(1);
    bevel(cv, 0, 0, s, s, b, pal.light, pal.dark);
    bevel(cv, b, b, s - 2 * b, s - 2 * b, b, pal.light, pal.dark);
}

/// A bevel `w` px thick: light on top and left, dark on bottom and right.
fn bevel(cv: *gfx.Canvas, x: i32, y: i32, width: i32, height: i32, w: i32, light: Color, dark: Color) void {
    cv.fillRect(x, y, width, w, light);
    cv.fillRect(x, y, w, height, light);
    cv.fillRect(x, y + height - w, width, w, dark);
    cv.fillRect(x + width - w, y, w, height, dark);
}

/// `text` centred horizontally; `y` is a design unit.
fn centred(cv: *gfx.Canvas, m: scale_mod.Metrics, text: [:0]const u8, y: i32, font: []const u8, col: Color) void {
    var fb: [96]u8 = undefined;
    const desc = m.fontDesc(&fb, font);
    centredIn(cv, m, text, m.pos(y), desc, col);
}

fn centredIn(cv: *gfx.Canvas, m: scale_mod.Metrics, text: [:0]const u8, y_px: i32, desc: [:0]const u8, col: Color) void {
    const tw = gfx.measureText(text, desc).w;
    cv.drawText(text, @divTrunc(m.side - tw, 2), y_px, desc, col);
}

/// Window Maker's mark for "docked, can be started, is not running": three
/// small dots in the lower left corner (appicon.c, `dock_dots`).
fn drawNotRunning(cv: *gfx.Canvas, m: scale_mod.Metrics) void {
    var dx: i32 = 4;
    while (dx <= 14) : (dx += 5) {
        const sh = m.box(dx + 1, 64 - 6 + 1, 3, 2);
        const dot = m.box(dx, 64 - 6, 3, 2);
        cv.fillRect(sh.x, sh.y, sh.w, sh.h, col_shadow);
        cv.fillRect(dot.x, dot.y, dot.w, dot.h, style.palette.light);
    }
}

/// The raster Window Maker lays over an icon while its program starts
/// (`stipple_gc`): every second pixel darkened.
fn drawLaunching(cv: *gfx.Canvas, m: scale_mod.Metrics) void {
    const lo = m.pos(2);
    const hi = m.side - lo;
    var py = lo;
    while (py < hi) : (py += 1) {
        var qx = lo + @mod(py, 2);
        while (qx < hi) : (qx += 2) cv.fillRect(qx, py, 1, 1, col_stipple);
    }
}

/// The folded corner (appicon.c `drawCorner`) of a Clip tile that is on every
/// workspace.
fn drawOmnipresent(cv: *gfx.Canvas, m: scale_mod.Metrics) void {
    const fx: f64 = m.f(64 - 2);
    const fy: f64 = m.f(2);
    const a = m.f(10);
    const b = m.f(8);
    const o = m.f(1);
    cv.fillPolygon(&.{ .{ fx - a, fy }, .{ fx, fy }, .{ fx, fy + a } }, style.palette.dark);
    cv.fillPolygon(&.{ .{ fx - b, fy + o }, .{ fx - o, fy + o }, .{ fx - o, fy + b } }, style.palette.light);
}

/// What a tile shows when no icon can be found: a small window in the Dock's
/// own colours. Never a letter. (x, y) is the top left of the icon area.
pub fn drawPlaceholder(cv: *gfx.Canvas, x: i32, y: i32, size: i32) void {
    const mg = @divTrunc(size, 8);
    const gx = x + mg;
    const gy = y + mg + @divTrunc(mg, 2);
    const gw = size - 2 * mg;
    const gh = size - 3 * mg;
    if (gw < 12 or gh < 12) return;
    const bar = @max(@divTrunc(gh, 4), 4);

    const pal = style.palette;
    cv.fillRect(gx + 2, gy + 2, gw, gh, pal.dark);
    cv.fillRect(gx, gy, gw, gh, pal.tile_from);
    cv.vGradient(gx + 1, gy + 1, gw - 2, bar, pal.logo_from, pal.logo_to);
    cv.bevel(gx, gy, gw, gh, pal.light, pal.dark);

    const gap = @max(mg, 3);
    const full = gw - 2 * gap;
    var ly = gy + bar + gap;
    var i: i32 = 0;
    while (i < 3 and ly + 2 <= gy + gh - 2) : (i += 1) {
        const len = if (i == 2) @divTrunc(full * 2, 3) else full;
        cv.fillRect(gx + gap, ly, len, 2, pal.tile_to);
        ly += gap;
    }
}

fn drawApp(cv: *gfx.Canvas, m: scale_mod.Metrics, look: Look, content: Content) void {
    frame(cv, m, look.hot, null, null);
    // The icon is 3/4 of the tile, centred.
    const icon_px = @divTrunc(m.side * 3, 4);
    const off = @divTrunc(m.side - icon_px, 2);
    if (content.icon) |icon| {
        cv.drawIcon(icon, off, off, icon_px);
    } else {
        drawPlaceholder(cv, off, off, icon_px);
    }
    if (look.not_running) drawNotRunning(cv, m);
    if (look.omnipresent) drawOmnipresent(cv, m);
    if (look.launching) drawLaunching(cv, m);
}

fn drawClip(cv: *gfx.Canvas, m: scale_mod.Metrics, look: Look, content: Content) void {
    frame(cv, m, look.hot, null, null);

    var num_buf: [12:0]u8 = undefined;
    const num = std.fmt.bufPrintZ(&num_buf, "{d}", .{look.workspace + 1}) catch "?";
    if (content.name) |name| {
        centred(cv, m, num, 10, gfx.fonts.dockNumber(), style.palette.text);
        var name_buf: [24:0]u8 = undefined;
        const clipped = clipName(&name_buf, name);
        var fb: [96]u8 = undefined;
        const desc = m.fontDesc(&fb, gfx.fonts.dockLabel());
        centredIn(cv, m, clipped, m.pos(41), desc, style.palette.text);
    } else {
        centred(cv, m, num, 20, gfx.fonts.dockNumber(), style.palette.text);
    }

    // The two arrows: upper right = next workspace, lower left = previous.
    const a = m.f(16);
    const e = m.f(3);
    const t = m.f(64);
    const pal = style.palette;
    const next_col = if (look.arrow == .next) pal.arrow_hot else pal.arrow;
    const prev_col = if (look.arrow == .prev) pal.arrow_hot else pal.arrow;
    cv.fillPolygon(&.{ .{ t - e - a, e }, .{ t - e, e }, .{ t - e, e + a } }, next_col);
    cv.fillPolygon(&.{ .{ e, t - e - a }, .{ e, t - e }, .{ e + a, t - e } }, prev_col);
}

fn drawDrawer(cv: *gfx.Canvas, m: scale_mod.Metrics, look: Look) void {
    frame(cv, m, look.hot, null, null);
    const c = m.f(32);
    const s = m.f(10);
    if (look.chevron_left) {
        cv.fillPolygon(&.{ .{ c - s, c }, .{ c + s, c - s }, .{ c + s, c + s } }, style.palette.arrow);
    } else {
        cv.fillPolygon(&.{ .{ c + s, c }, .{ c - s, c - s }, .{ c - s, c + s } }, style.palette.arrow);
    }
}

/// The empty cell a dragged tile will drop into: a recessed tile.
fn drawGap(cv: *gfx.Canvas, m: scale_mod.Metrics) void {
    cv.fillRect(0, 0, m.side, m.side, col_gap);
    bevel(cv, 0, 0, m.side, m.side, m.stroke(1), style.palette.dark, style.palette.light);
}

/// `name` cut so it still fits the tile; never splits a UTF-8 sequence.
pub fn clipName(buf: *[24:0]u8, name: []const u8) [:0]const u8 {
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

const testing = std.testing;

fn pixelAt(data: []const u8, side: i32, x: i32, y: i32) u32 {
    const off: usize = @intCast((y * side + x) * 4);
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

fn draw(look: Look, content: Content, scale: i32) ![]u8 {
    const buf = try testing.allocator.alloc(u8, byteLen(look, scale));
    @memset(buf, 0xff);
    try render(buf, look, content, scale);
    return buf;
}

test "a logo tile is opaque and dark, an app tile light" {
    const logo = try draw(.{ .kind = .logo, .size = 64 }, .{}, 1);
    defer testing.allocator.free(logo);
    const app = try draw(.{ .kind = .app, .size = 64 }, .{}, 1);
    defer testing.allocator.free(app);
    try testing.expectEqual(@as(u32, 0xff), pixelAt(logo, 64, 32, 4) >> 24);
    try testing.expect((pixelAt(logo, 64, 32, 4) & 0xff) < 0x80);
    try testing.expect((pixelAt(app, 64, 32, 4) & 0xff) > 0x80);
}

test "only a not running tile gets the three dots" {
    const run = try draw(.{ .kind = .app, .size = 64 }, .{}, 1);
    defer testing.allocator.free(run);
    const idle = try draw(.{ .kind = .app, .size = 64, .not_running = true }, .{}, 1);
    defer testing.allocator.free(idle);
    for ([_]i32{ 4, 9, 14 }) |dx| {
        try testing.expectEqual(@as(u32, 0xffffffff), pixelAt(idle, 64, dx + 1, 64 - 6));
        try testing.expect(pixelAt(run, 64, dx + 1, 64 - 6) != 0xffffffff);
    }
}

test "hot is lighter than idle; the other marks change the pixels" {
    const idle = try draw(.{ .kind = .app, .size = 64 }, .{}, 1);
    defer testing.allocator.free(idle);
    const hot = try draw(.{ .kind = .app, .size = 64, .hot = true }, .{}, 1);
    defer testing.allocator.free(hot);
    try testing.expect((pixelAt(hot, 64, 60, 60) & 0xff) > (pixelAt(idle, 64, 60, 60) & 0xff));

    const base: Look = .{ .kind = .app, .size = 64 };
    const variants = [_]Look{
        .{ .kind = .app, .size = 64, .launching = true },
        .{ .kind = .app, .size = 64, .omnipresent = true },
        .{ .kind = .app, .size = 64, .faded = true },
    };
    for (variants) |v| {
        const a = try draw(base, .{}, 1);
        defer testing.allocator.free(a);
        const b = try draw(v, .{}, 1);
        defer testing.allocator.free(b);
        try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "a tile without an icon shows the placeholder's dark title bar at both ends" {
    const t = try draw(.{ .kind = .app, .size = 64 }, .{}, 1);
    defer testing.allocator.free(t);
    // icon area 48 px at offset 8; the placeholder's bar runs across it.
    const icon: i32 = 48;
    const mg = @divTrunc(icon, 8);
    const y = 8 + mg + @divTrunc(mg, 2) + 3;
    try testing.expect((pixelAt(t, 64, 8 + mg + 3, y) & 0xff) < 0x80);
    try testing.expect((pixelAt(t, 64, 8 + icon - mg - 3, y) & 0xff) < 0x80);
}

test "an icon is drawn into the tile instead of the placeholder" {
    var pixels = [_]u32{0xffff0000} ** 16; // 4x4 solid red
    var icon = gfx.Icon.fromPixels(4, 4, &pixels).?;
    defer icon.deinit();
    const t = try draw(.{ .kind = .app, .size = 64 }, .{ .icon = icon }, 1);
    defer testing.allocator.free(t);
    const centre = pixelAt(t, 64, 32, 32);
    try testing.expectEqual(@as(u32, 0xffff0000), centre);
}

test "a gap is translucent and recessed" {
    const g = try draw(.{ .kind = .gap, .size = 64 }, .{}, 1);
    defer testing.allocator.free(g);
    const a = pixelAt(g, 64, 32, 32) >> 24;
    try testing.expect(a > 0 and a < 0xff);
}

test "the Clip's arrows light up on their side only" {
    const none = try draw(.{ .kind = .clip, .size = 64 }, .{}, 1);
    defer testing.allocator.free(none);
    const next = try draw(.{ .kind = .clip, .size = 64, .hot = true, .arrow = .next }, .{}, 1);
    defer testing.allocator.free(next);
    // inside the upper right triangle: dark arrow becomes white.
    try testing.expect((pixelAt(none, 64, 58, 8) & 0xff) < 0x60);
    try testing.expectEqual(@as(u32, 0xffffffff), pixelAt(next, 64, 58, 8));
    // the lower left one stays dark.
    try testing.expect((pixelAt(next, 64, 6, 58) & 0xff) < 0x60);
}

test "the Clip draws the number, and a name under it" {
    const plain = try draw(.{ .kind = .clip, .size = 64, .workspace = 2 }, .{}, 1);
    defer testing.allocator.free(plain);
    const named = try draw(.{ .kind = .clip, .size = 64, .workspace = 2 }, .{ .name = "Web" }, 1);
    defer testing.allocator.free(named);
    try testing.expect(!std.mem.eql(u8, plain, named));
}

test "the chevron of a Drawer points the way the look says" {
    const l = try draw(.{ .kind = .drawer, .size = 64, .chevron_left = true }, .{}, 1);
    defer testing.allocator.free(l);
    const r = try draw(.{ .kind = .drawer, .size = 64 }, .{}, 1);
    defer testing.allocator.free(r);
    try testing.expect(!std.mem.eql(u8, l, r));
    // near the left edge a right chevron is wide, a left one is still a point.
    try testing.expect((pixelAt(r, 64, 24, 26) & 0xff) < 0x60);
    try testing.expect((pixelAt(l, 64, 24, 26) & 0xff) > 0x60);
}

test "output scale 2 draws the same tile on twice the pixels" {
    const look: Look = .{ .kind = .app, .size = 64, .not_running = true };
    const one = try draw(look, .{}, 1);
    defer testing.allocator.free(one);
    const two = try draw(look, .{}, 2);
    defer testing.allocator.free(two);
    try testing.expectEqual(@as(usize, 64 * 64 * 4), one.len);
    try testing.expectEqual(@as(usize, 128 * 128 * 4), two.len);
    // the first dot at design (4, 58): 2x as far in device pixels.
    try testing.expectEqual(@as(u32, 0xffffffff), pixelAt(two, 128, 2 * 4 + 1, 2 * 58));
}

test "other tile sizes: edges stay on the tile, nothing is drawn outside" {
    for ([_]i32{ 16, 32, 48, 96, 128 }) |size| {
        const t = try draw(.{ .kind = .app, .size = size, .not_running = true, .omnipresent = true, .launching = true }, .{}, 1);
        defer testing.allocator.free(t);
        try testing.expectEqual(@as(u32, 0xff), pixelAt(t, size, size - 1, size - 1) >> 24);
        try testing.expectEqual(@as(u32, 0xff), pixelAt(t, size, 0, 0) >> 24);
    }
}

test "clipName cuts on a character boundary and drops NULs" {
    var buf: [24:0]u8 = undefined;
    try testing.expectEqualStrings("Main", clipName(&buf, "Main"));
    try testing.expectEqualStrings("a", clipName(&buf, "a\x00b"));
    const cut = clipName(&buf, "äääääääääääääääääääääääää");
    try testing.expect(cut.len <= 24);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "the palette decides the colours of a tile, the fonts of the Clip come from gfx.fonts" {
    const saved = style.palette;
    defer style.palette = saved;

    const before = try draw(.{ .kind = .app, .size = 64 }, .{}, 1);
    defer testing.allocator.free(before);

    style.palette.tile_from = Color.rgb(0x204060);
    style.palette.tile_to = Color.rgb(0x204060);
    const after = try draw(.{ .kind = .app, .size = 64 }, .{}, 1);
    defer testing.allocator.free(after);

    // inside the bevel the tile is the gradient's colour: blue now, grey before.
    try testing.expect(!std.mem.eql(u8, before, after));
    const px = pixelAt(after, 64, 3, 3);
    try testing.expect((px & 0xff) > ((px >> 16) & 0xff)); // blue beats red
}
