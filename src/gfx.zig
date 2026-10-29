// SPDX-License-Identifier: GPL-3.0
//
// Cairo/Pango drawing into a wl_shm-backed ARGB32 buffer.
// No Wayland types here, so it can be unit-tested without a compositor.

const std = @import("std");

pub const c = @cImport({
    @cInclude("cairo.h");
    @cInclude("wm_text.h");
});

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    pub fn rgb(hex: u32) Color {
        return .{
            .r = @as(f64, @floatFromInt((hex >> 16) & 0xff)) / 255.0,
            .g = @as(f64, @floatFromInt((hex >> 8) & 0xff)) / 255.0,
            .b = @as(f64, @floatFromInt(hex & 0xff)) / 255.0,
        };
    }
};

pub const Canvas = struct {
    surface: *c.cairo_surface_t,
    cr: *c.cairo_t,
    width: i32,
    height: i32,

    /// Wrap existing pixel memory (e.g. an mmap'd wl_shm pool).
    /// `stride` must be width*4 for ARGB32.
    pub fn initForData(data: [*]u8, width: i32, height: i32, stride: i32) !Canvas {
        const s = c.cairo_image_surface_create_for_data(data, c.CAIRO_FORMAT_ARGB32, width, height, stride) orelse
            return error.CairoSurface;
        if (c.cairo_surface_status(s) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(s);
            return error.CairoSurface;
        }
        const cr = c.cairo_create(s) orelse {
            c.cairo_surface_destroy(s);
            return error.CairoContext;
        };
        return .{ .surface = s, .cr = cr, .width = width, .height = height };
    }

    pub fn deinit(cv: *Canvas) void {
        c.cairo_destroy(cv.cr);
        c.cairo_surface_destroy(cv.surface);
    }

    fn setColor(cv: *Canvas, col: Color) void {
        c.cairo_set_source_rgba(cv.cr, col.r, col.g, col.b, col.a);
    }

    pub fn clear(cv: *Canvas, col: Color) void {
        c.cairo_save(cv.cr);
        c.cairo_set_operator(cv.cr, c.CAIRO_OPERATOR_SOURCE);
        cv.setColor(col);
        c.cairo_paint(cv.cr);
        c.cairo_restore(cv.cr);
    }

    pub fn fillRect(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, col: Color) void {
        cv.setColor(col);
        c.cairo_rectangle(cv.cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h));
        c.cairo_fill(cv.cr);
    }

    /// Vertical gradient (Window Maker "vgradient").
    pub fn vGradient(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, top: Color, bottom: Color) void {
        const pat = c.cairo_pattern_create_linear(0, @floatFromInt(y), 0, @floatFromInt(y + h)) orelse return;
        defer c.cairo_pattern_destroy(pat);
        c.cairo_pattern_add_color_stop_rgba(pat, 0, top.r, top.g, top.b, top.a);
        c.cairo_pattern_add_color_stop_rgba(pat, 1, bottom.r, bottom.g, bottom.b, bottom.a);
        c.cairo_set_source(cv.cr, pat);
        c.cairo_rectangle(cv.cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h));
        c.cairo_fill(cv.cr);
    }

    /// Beveled frame: light on top/left, dark on bottom/right (NeXT look).
    pub fn bevel(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, light: Color, dark: Color) void {
        cv.fillRect(x, y, w, 1, light);
        cv.fillRect(x, y, 1, h, light);
        cv.fillRect(x, y + h - 1, w, 1, dark);
        cv.fillRect(x + w - 1, y, 1, h, dark);
    }

    pub fn drawText(cv: *Canvas, text: [:0]const u8, x: i32, y: i32, font: [:0]const u8, col: Color) void {
        cv.setColor(col);
        c.wm_draw_text(cv.cr, text.ptr, x, y, font.ptr);
    }

    pub fn flush(cv: *Canvas) void {
        c.cairo_surface_flush(cv.surface);
    }

    /// Diagonal gradient, top-left to bottom-right (Window Maker tiles).
    pub fn dGradient(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, from: Color, to: Color) void {
        const pat = c.cairo_pattern_create_linear(
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(x + w),
            @floatFromInt(y + h),
        ) orelse return;
        defer c.cairo_pattern_destroy(pat);
        c.cairo_pattern_add_color_stop_rgba(pat, 0, from.r, from.g, from.b, from.a);
        c.cairo_pattern_add_color_stop_rgba(pat, 1, to.r, to.g, to.b, to.a);
        c.cairo_set_source(cv.cr, pat);
        c.cairo_rectangle(cv.cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h));
        c.cairo_fill(cv.cr);
    }

    /// Filled polygon through `points` (at least 3).
    pub fn fillPolygon(cv: *Canvas, points: []const [2]f64, col: Color) void {
        if (points.len < 3) return;
        cv.setColor(col);
        c.cairo_move_to(cv.cr, points[0][0], points[0][1]);
        for (points[1..]) |pt| c.cairo_line_to(cv.cr, pt[0], pt[1]);
        c.cairo_close_path(cv.cr);
        c.cairo_fill(cv.cr);
    }

    /// Outline through `points` (at least 2 of them) with a line `width`
    /// pixels wide; `closed` joins the last point back to the first. Round
    /// joins and caps, so a thick line does not show spikes at its corners.
    pub fn strokePath(cv: *Canvas, points: []const [2]f64, closed: bool, width: f64, col: Color) void {
        if (points.len < 2) return;
        c.cairo_save(cv.cr);
        defer c.cairo_restore(cv.cr);
        cv.setColor(col);
        c.cairo_set_line_width(cv.cr, width);
        c.cairo_set_line_join(cv.cr, c.CAIRO_LINE_JOIN_ROUND);
        c.cairo_set_line_cap(cv.cr, c.CAIRO_LINE_CAP_ROUND);
        c.cairo_move_to(cv.cr, points[0][0], points[0][1]);
        for (points[1..]) |pt| c.cairo_line_to(cv.cr, pt[0], pt[1]);
        if (closed) c.cairo_close_path(cv.cr);
        c.cairo_stroke(cv.cr);
    }

    /// Draw `icon` scaled to fit a `size` x `size` box at (x, y), keeping
    /// its aspect ratio and centring it in the box. The drawn size and the
    /// position are whole pixels (a fractional edge would smear the picture
    /// over two rows of pixels), and the resampling is the best cairo has.
    ///
    /// That resampling is slow (a 256 px icon in a 48 px tile takes about
    /// 3 ms), and a Dock redraws all its tiles whenever one of them changes.
    /// So the scaled picture is made once per size and kept with the icon
    /// (see `scaledFor`); drawing it again is a plain copy.
    pub fn drawIcon(cv: *Canvas, icon: Icon, x: i32, y: i32, size: i32) void {
        const fs: f64 = @floatFromInt(size);
        const iw: f64 = @floatFromInt(icon.w);
        const ih: f64 = @floatFromInt(icon.h);
        const fit = @min(fs / iw, fs / ih);
        const dw = @max(1.0, @round(iw * fit));
        const dh = @max(1.0, @round(ih * fit));
        const ox = @as(f64, @floatFromInt(x)) + @floor((fs - dw) / 2);
        const oy = @as(f64, @floatFromInt(y)) + @floor((fs - dh) / 2);

        if (dw == iw and dh == ih) {
            // Drawn 1:1: no resampling to save.
            c.cairo_set_source_surface(cv.cr, icon.surface, ox, oy);
        } else if (scaledFor(icon.surface, @intFromFloat(dw), @intFromFloat(dh), iw, ih)) |scaled| {
            c.cairo_set_source_surface(cv.cr, scaled, ox, oy);
        } else {
            cv.drawIconDirect(icon, ox, oy, dw, dh);
            return;
        }
        c.cairo_rectangle(cv.cr, ox, oy, dw, dh);
        c.cairo_fill(cv.cr);
    }

    /// The slow way, straight from the source (used if the scaled copy cannot
    /// be made).
    fn drawIconDirect(cv: *Canvas, icon: Icon, ox: f64, oy: f64, dw: f64, dh: f64) void {
        const iw: f64 = @floatFromInt(icon.w);
        const ih: f64 = @floatFromInt(icon.h);
        c.cairo_save(cv.cr);
        c.cairo_translate(cv.cr, ox, oy);
        c.cairo_scale(cv.cr, dw / iw, dh / ih);
        c.cairo_set_source_surface(cv.cr, icon.surface, 0, 0);
        if (c.cairo_get_source(cv.cr)) |pat| {
            c.cairo_pattern_set_filter(pat, c.CAIRO_FILTER_BEST);
            // Edge pixels continue outwards instead of fading to transparent.
            c.cairo_pattern_set_extend(pat, c.CAIRO_EXTEND_PAD);
        }
        c.cairo_rectangle(cv.cr, 0, 0, iw, ih);
        c.cairo_fill(cv.cr);
        c.cairo_restore(cv.cr);
    }
};

// ---- scaled copies of icons ---------------------------------------------------

/// The scaled copies of ONE icon: normally a Dock tile and a miniwindow tile
/// are the only sizes asked for, so two are kept (the older goes when a third
/// is asked for). It hangs on the icon's cairo surface as user data and goes
/// when that surface is destroyed, so no bookkeeping by the owners of icons
/// is needed and a stale copy can never outlive its icon.
const Scaled = struct {
    const keep = 2;
    w: [keep]i32 = .{ 0, 0 },
    h: [keep]i32 = .{ 0, 0 },
    surface: [keep]?*c.cairo_surface_t = .{ null, null },
    next: usize = 0,

    fn free(p: ?*anyopaque) callconv(.c) void {
        const sc: *Scaled = @ptrCast(@alignCast(p orelse return));
        for (sc.surface) |s| if (s) |surf| c.cairo_surface_destroy(surf);
        std.heap.c_allocator.destroy(sc);
    }
};

var scaled_key: c.cairo_user_data_key_t = undefined;

/// `src` drawn into a new `dw` x `dh` surface with the best filter, from
/// the kept copies or made now. null if it cannot be made.
fn scaledFor(src: *c.cairo_surface_t, dw: i32, dh: i32, iw: f64, ih: f64) ?*c.cairo_surface_t {
    var sc: *Scaled = blk: {
        if (c.cairo_surface_get_user_data(src, &scaled_key)) |p| break :blk @ptrCast(@alignCast(p));
        const fresh = std.heap.c_allocator.create(Scaled) catch return null;
        fresh.* = .{};
        if (c.cairo_surface_set_user_data(src, &scaled_key, fresh, Scaled.free) != c.CAIRO_STATUS_SUCCESS) {
            std.heap.c_allocator.destroy(fresh);
            return null;
        }
        break :blk fresh;
    };

    for (0..Scaled.keep) |i| {
        if (sc.surface[i] != null and sc.w[i] == dw and sc.h[i] == dh) return sc.surface[i];
    }

    const out = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, dw, dh) orelse return null;
    if (c.cairo_surface_status(out) != c.CAIRO_STATUS_SUCCESS) {
        c.cairo_surface_destroy(out);
        return null;
    }
    const cr = c.cairo_create(out) orelse {
        c.cairo_surface_destroy(out);
        return null;
    };
    c.cairo_scale(cr, @as(f64, @floatFromInt(dw)) / iw, @as(f64, @floatFromInt(dh)) / ih);
    c.cairo_set_source_surface(cr, src, 0, 0);
    if (c.cairo_get_source(cr)) |pat| {
        c.cairo_pattern_set_filter(pat, c.CAIRO_FILTER_BEST);
        // Edge pixels continue outwards instead of fading to transparent.
        c.cairo_pattern_set_extend(pat, c.CAIRO_EXTEND_PAD);
    }
    c.cairo_rectangle(cr, 0, 0, iw, ih);
    c.cairo_fill(cr);
    c.cairo_destroy(cr);

    const slot = sc.next;
    sc.next = (sc.next + 1) % Scaled.keep;
    if (sc.surface[slot]) |old| c.cairo_surface_destroy(old);
    sc.surface[slot] = out;
    sc.w[slot] = dw;
    sc.h[slot] = dh;
    return out;
}

/// A PNG loaded through cairo (Dock/Clip tile icons).
pub const Icon = struct {
    surface: *c.cairo_surface_t,
    w: i32,
    h: i32,

    /// Largest side we accept; a bigger "icon" is a mistake or an attack.
    pub const max_side: i32 = 2048;

    /// null if the file is missing, not a PNG, or absurdly large.
    pub fn loadPng(path: [:0]const u8) ?Icon {
        const s = c.cairo_image_surface_create_from_png(path.ptr) orelse return null;
        if (c.cairo_surface_status(s) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(s);
            return null;
        }
        const w: i32 = c.cairo_image_surface_get_width(s);
        const h: i32 = c.cairo_image_surface_get_height(s);
        if (w <= 0 or h <= 0 or w > max_side or h > max_side) {
            c.cairo_surface_destroy(s);
            return null;
        }
        return .{ .surface = s, .w = w, .h = h };
    }

    /// An icon from decoded pixels: `width * height` premultiplied ARGB32
    /// (what the XPM reader produces). The data is copied.
    pub fn fromPixels(width: u32, height: u32, pixels: []const u32) ?Icon {
        if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
        if (pixels.len != @as(usize, width) * height) return null;
        const w: c_int = @intCast(width);
        const h: c_int = @intCast(height);
        const s = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h) orelse return null;
        if (c.cairo_surface_status(s) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(s);
            return null;
        }
        c.cairo_surface_flush(s);
        const data = c.cairo_image_surface_get_data(s) orelse {
            c.cairo_surface_destroy(s);
            return null;
        };
        const stride: usize = @intCast(c.cairo_image_surface_get_stride(s));
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const row: [*]u32 = @ptrCast(@alignCast(data + y * stride));
            @memcpy(row[0..width], pixels[y * width ..][0..width]);
        }
        c.cairo_surface_mark_dirty(s);
        return .{ .surface = s, .w = w, .h = h };
    }

    pub fn deinit(i: *Icon) void {
        c.cairo_surface_destroy(i.surface);
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Canvas mit eigenem Pixelspeicher (für Offscreen-Rendering).
pub const Surface = struct {
    pixels: []u32,
    canvas: Canvas,

    pub fn create(alloc: std.mem.Allocator, width: i32, height: i32) !Surface {
        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        const pixels = try alloc.alloc(u32, w * h);
        errdefer alloc.free(pixels);
        @memset(pixels, 0);

        const bytes = std.mem.sliceAsBytes(pixels);
        const canvas = try Canvas.initForData(bytes.ptr, width, height, width * 4);
        return .{ .pixels = pixels, .canvas = canvas };
    }

    pub fn destroy(s: *Surface, alloc: std.mem.Allocator) void {
        s.canvas.deinit();
        alloc.free(s.pixels);
    }

    pub fn clear(s: *Surface, col: Color) void {
        s.canvas.clear(col);
    }

    pub fn fillRect(s: *Surface, r: Rect, col: Color) void {
        s.canvas.fillRect(r.x, r.y, r.w, r.h, col);
    }

    pub fn flush(s: *Surface) void {
        s.canvas.flush();
    }
};

/// The fonts chosen in config.lua (`font_*`). They are copied here, not
/// pointed to, so a config reload (which frees the old arena) can never
/// leave a dangling font name behind; menu and Clip drawing read them
/// through the getters below.
pub const Fonts = struct {
    menu_title: [64:0]u8 = [_:0]u8{0} ** 64,
    menu: [64:0]u8 = [_:0]u8{0} ** 64,
    dock: [64:0]u8 = [_:0]u8{0} ** 64,
    dock_logo: [64:0]u8 = [_:0]u8{0} ** 64,
    dock_number: [64:0]u8 = [_:0]u8{0} ** 64,

    fn put(dst: *[64:0]u8, src: []const u8) void {
        const n = @min(src.len, 63);
        @memcpy(dst[0..n], src[0..n]);
        dst[n] = 0;
    }

    pub fn set(f: *Fonts, menu_title: []const u8, menu: []const u8, dock: []const u8) void {
        put(&f.menu_title, menu_title);
        put(&f.menu, menu);
        put(&f.dock, dock);
    }

    pub fn setDockFaces(f: *Fonts, logo: []const u8, number: []const u8) void {
        put(&f.dock_logo, logo);
        put(&f.dock_number, number);
    }

    pub fn dockLogo(f: *const Fonts) [:0]const u8 {
        return std.mem.sliceTo(&f.dock_logo, 0);
    }
    pub fn dockNumber(f: *const Fonts) [:0]const u8 {
        return std.mem.sliceTo(&f.dock_number, 0);
    }

    pub fn menuTitle(f: *const Fonts) [:0]const u8 {
        return std.mem.sliceTo(&f.menu_title, 0);
    }
    pub fn menuItem(f: *const Fonts) [:0]const u8 {
        return std.mem.sliceTo(&f.menu, 0);
    }
    pub fn dockLabel(f: *const Fonts) [:0]const u8 {
        return std.mem.sliceTo(&f.dock, 0);
    }
};

/// Process-wide, set once per (re)load of the configuration. Defaults are
/// those of default_config.lua.
pub var fonts: Fonts = blk: {
    var f: Fonts = .{};
    f.set("Sans Bold 10", "Sans 10", "Sans 8");
    f.setDockFaces("Sans Bold 22", "Sans Bold 20");
    break :blk f;
};

/// Pixel size of `text` in `font`, measured on a scratch surface.
///
/// Measuring is what building a menu spends its time on (every row, twice for
/// one with a shortcut) and the same strings come back whenever a menu is
/// rebuilt, redrawn or opened again, so the answers are remembered: a table
/// of 1024 sets of 4 slots, keyed by a 64-bit hash of font and text. A string
/// that finds its set full replaces one of its entries.
pub fn measureText(text: [:0]const u8, font: [:0]const u8) struct { w: i32, h: i32 } {
    var hasher = std.hash.Wyhash.init(0x6d656173);
    hasher.update(font);
    hasher.update("\x00");
    hasher.update(text);
    const key = hasher.final();

    const set = &measure_cache[@intCast(key % measure_cache.len)];
    var free: ?*MeasureSlot = null;
    for (set) |*slot| {
        if (!slot.used) {
            if (free == null) free = slot;
        } else if (slot.key == key) return .{ .w = slot.w, .h = slot.h };
    }

    var w: c_int = 0;
    var h: c_int = 0;
    c.wm_measure_text(text.ptr, font.ptr, &w, &h);
    const target = free orelse &set[@intCast((key >> 32) % set.len)];
    target.* = .{ .used = true, .key = key, .w = w, .h = h };
    return .{ .w = w, .h = h };
}

const MeasureSlot = struct { used: bool = false, key: u64 = 0, w: i32 = 0, h: i32 = 0 };
var measure_cache: [1024][4]MeasureSlot = [_][4]MeasureSlot{[_]MeasureSlot{.{}} ** 4} ** 1024;

test "canvas draws into plain memory" {
    var buf: [16 * 16 * 4]u8 = undefined;
    @memset(&buf, 0);
    var cv = try Canvas.initForData(&buf, 16, 16, 16 * 4);
    defer cv.deinit();
    cv.clear(Color.rgb(0xff0000));
    cv.flush();
    // ARGB32 little-endian: B, G, R, A
    try std.testing.expectEqual(@as(u8, 0xff), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[3]);
}

test "measureText: the cached answer is the measured one" {
    const a = measureText("A cache test string", "Sans 10");
    const b = measureText("A cache test string", "Sans 10");
    try std.testing.expectEqual(a.w, b.w);
    try std.testing.expectEqual(a.h, b.h);
    try std.testing.expect(a.w > 0);
    // Another font or text is not served from this answer.
    const wide = measureText("A cache test string, but a good deal longer than before", "Sans 10");
    try std.testing.expect(wide.w > a.w);
    const big = measureText("A cache test string", "Sans 24");
    try std.testing.expect(big.w > a.w);
}

test "drawIcon: the kept scaled copy looks exactly like scaling on the spot" {
    var px: [64 * 48]u32 = undefined;
    for (&px, 0..) |*p, i| {
        const v: u32 = @truncate(i *% 2654435761);
        p.* = 0xff000000 | (v & 0x00ffffff);
    }
    var icon = Icon.fromPixels(64, 48, &px).?;
    defer icon.deinit();

    var a: [40 * 40 * 4]u8 = undefined;
    var b: [40 * 40 * 4]u8 = undefined;
    @memset(&a, 0);
    @memset(&b, 0);
    var ca = try Canvas.initForData(&a, 40, 40, 160);
    defer ca.deinit();
    var cb = try Canvas.initForData(&b, 40, 40, 160);
    defer cb.deinit();

    // 64x48 into a 32 box: 32x24, centred; first through the cache (twice),
    // then the old way.
    ca.drawIcon(icon, 4, 4, 32);
    ca.drawIcon(icon, 4, 4, 32);
    cb.drawIconDirect(icon, 4, 4 + 4, 32, 24);
    ca.flush();
    cb.flush();
    try std.testing.expectEqualSlices(u8, &b, &a);

    // A different size is made and kept next to it; both stay right.
    var c2: [40 * 40 * 4]u8 = undefined;
    @memset(&c2, 0);
    var cc = try Canvas.initForData(&c2, 40, 40, 160);
    defer cc.deinit();
    cc.drawIcon(icon, 0, 0, 16);
    cc.drawIcon(icon, 0, 0, 24);
    cc.drawIcon(icon, 0, 0, 32); // a third size: the oldest copy goes
    cc.drawIcon(icon, 0, 0, 16); // ... and comes back when asked for
}

test "drawIcon: an icon in its own size is drawn as it is" {
    var px: [8 * 8]u32 = undefined;
    @memset(&px, 0xff112233);
    var icon = Icon.fromPixels(8, 8, &px).?;
    defer icon.deinit();
    var buf: [8 * 8 * 4]u8 = undefined;
    @memset(&buf, 0);
    var cv = try Canvas.initForData(&buf, 8, 8, 32);
    defer cv.deinit();
    cv.drawIcon(icon, 0, 0, 8);
    cv.flush();
    try std.testing.expectEqual(@as(u8, 0x33), buf[0]); // B of 0xff112233, little-endian
    try std.testing.expectEqual(@as(u8, 0xff), buf[3]);
}

test "strokePath: an open and a closed outline" {
    var buf: [20 * 20 * 4]u8 = undefined;
    @memset(&buf, 0);
    var cv = try Canvas.initForData(&buf, 20, 20, 80);
    defer cv.deinit();
    const tri = [_][2]f64{ .{ 2, 2 }, .{ 17, 2 }, .{ 10, 17 } };
    cv.strokePath(&tri, true, 3, Color.rgb(0xffffff));
    cv.flush();
    const alpha = struct {
        fn at(b: []const u8, x: usize, y: usize) u8 {
            return b[(y * 20 + x) * 4 + 3];
        }
    }.at;
    try std.testing.expect(alpha(&buf, 10, 2) > 200); // on the top edge
    try std.testing.expect(alpha(&buf, 10, 8) == 0); // inside: only an outline
    // Closed: the edge from the last point back to the first is drawn.
    try std.testing.expect(alpha(&buf, 6, 9) > 100);

    var open_buf: [20 * 20 * 4]u8 = undefined;
    @memset(&open_buf, 0);
    var co = try Canvas.initForData(&open_buf, 20, 20, 80);
    defer co.deinit();
    co.strokePath(&tri, false, 3, Color.rgb(0xffffff));
    co.flush();
    try std.testing.expect(alpha(&open_buf, 6, 9) == 0); // not closed: no such edge
    co.strokePath(tri[0..1], true, 3, Color.rgb(0xffffff)); // fewer than 2 points: nothing, no crash
}
