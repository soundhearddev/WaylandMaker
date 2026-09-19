// SPDX-License-Identifier: 0BSD
//
// Tiny software renderer for window decorations, menus, the dock and
// mini-windows. Pure Zig, no Wayland: it draws into a caller-supplied
// `[]u32` (an shm buffer in production, a test array in unit tests).
//
// Pixel format: ARGB8888, alpha PRE-multiplied (WL_SHM_FORMAT_ARGB8888).
//
// C origin: wrlib (RImage, RBevelImage, RRenderGradient) and the drawing
// code scattered over src/framewin.c, src/menu.c, src/texture.c. The wrlib
// C code can also be reused unchanged: render into an RImage, then push the
// pixels here with blitRgb8()/blitRgba8().
//
//   zig test src/wm/canvas.zig

const std = @import("std");
const tex = @import("texture.zig");
const Color = tex.Color;
const Texture = tex.Texture;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }

    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
};

pub const Canvas = struct {
    pixels: []u32,
    width: i32,
    height: i32,
    /// Row length in PIXELS (shm stride / 4).
    stride: i32,

    pub fn init(pixels: []u32, width: i32, height: i32) Canvas {
        return .{ .pixels = pixels, .width = width, .height = height, .stride = width };
    }

    fn clip(c: *const Canvas, r: Rect) Rect {
        const x0 = @max(0, r.x);
        const y0 = @max(0, r.y);
        const x1 = @min(c.width, r.x + r.w);
        const y1 = @min(c.height, r.y + r.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    fn idx(c: *const Canvas, x: i32, y: i32) usize {
        return @intCast(y * c.stride + x);
    }

    pub fn clear(c: *Canvas, color: Color) void {
        c.fillRect(.{ .x = 0, .y = 0, .w = c.width, .h = c.height }, color);
    }

    pub fn setPixel(c: *Canvas, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0 or x >= c.width or y >= c.height) return;
        c.pixels[c.idx(x, y)] = color.argb();
    }

    /// Overwrites (no blending) - use for opaque UI.
    pub fn fillRect(c: *Canvas, r: Rect, color: Color) void {
        const cr = c.clip(r);
        if (cr.isEmpty()) return;
        const px = color.argb();
        var y = cr.y;
        while (y < cr.y + cr.h) : (y += 1) {
            const start = c.idx(cr.x, y);
            @memset(c.pixels[start .. start + @as(usize, @intCast(cr.w))], px);
        }
    }

    pub fn hline(c: *Canvas, x: i32, y: i32, len: i32, color: Color) void {
        c.fillRect(.{ .x = x, .y = y, .w = len, .h = 1 }, color);
    }

    pub fn vline(c: *Canvas, x: i32, y: i32, len: i32, color: Color) void {
        c.fillRect(.{ .x = x, .y = y, .w = 1, .h = len }, color);
    }

    pub fn strokeRect(c: *Canvas, r: Rect, color: Color) void {
        if (r.isEmpty()) return;
        c.hline(r.x, r.y, r.w, color);
        c.hline(r.x, r.y + r.h - 1, r.w, color);
        c.vline(r.x, r.y, r.h, color);
        c.vline(r.x + r.w - 1, r.y, r.h, color);
    }

    /// NeXTSTEP style 1px bevel: light on top/left, dark on bottom/right
    /// when raised, swapped when sunken. This is what makes it "Window
    /// Maker" rather than "flat". C origin: wDrawBevel().
    pub fn bevel(c: *Canvas, r: Rect, raised: bool, light: Color, dark: Color) void {
        if (r.isEmpty()) return;
        const tl = if (raised) light else dark;
        const br = if (raised) dark else light;
        c.hline(r.x, r.y, r.w, tl);
        c.vline(r.x, r.y, r.h, tl);
        c.hline(r.x, r.y + r.h - 1, r.w, br);
        c.vline(r.x + r.w - 1, r.y, r.h, br);
    }

    // ---- gradients -------------------------------------------------------

    pub fn gradient(c: *Canvas, r: Rect, dir: tex.GradientDir, from: Color, to: Color) void {
        const cr = c.clip(r);
        if (cr.isEmpty()) return;
        var y = cr.y;
        while (y < cr.y + cr.h) : (y += 1) {
            var x = cr.x;
            while (x < cr.x + cr.w) : (x += 1) {
                const lx: u32 = @intCast(x - r.x);
                const ly: u32 = @intCast(y - r.y);
                const t: u32, const den: u32 = switch (dir) {
                    .horizontal => .{ lx, @as(u32, @intCast(@max(1, r.w - 1))) },
                    .vertical => .{ ly, @as(u32, @intCast(@max(1, r.h - 1))) },
                    .diagonal => .{ lx + ly, @as(u32, @intCast(@max(1, r.w + r.h - 2))) },
                };
                c.pixels[c.idx(x, y)] = Color.lerp(from, to, t, den).argb();
            }
        }
    }

    pub fn multiGradient(c: *Canvas, r: Rect, dir: tex.GradientDir, colors: []const Color) void {
        if (colors.len == 0) return;
        if (colors.len == 1) return c.fillRect(r, colors[0]);
        const cr = c.clip(r);
        if (cr.isEmpty()) return;
        const segs: u32 = @intCast(colors.len - 1);
        var y = cr.y;
        while (y < cr.y + cr.h) : (y += 1) {
            var x = cr.x;
            while (x < cr.x + cr.w) : (x += 1) {
                const lx: u32 = @intCast(x - r.x);
                const ly: u32 = @intCast(y - r.y);
                const t: u32, const den: u32 = switch (dir) {
                    .horizontal => .{ lx, @as(u32, @intCast(@max(1, r.w - 1))) },
                    .vertical => .{ ly, @as(u32, @intCast(@max(1, r.h - 1))) },
                    .diagonal => .{ lx + ly, @as(u32, @intCast(@max(1, r.w + r.h - 2))) },
                };
                // Position inside the whole ramp, in units of 1/den.
                const scaled = @min(t, den) * segs;
                var seg: u32 = scaled / den;
                if (seg >= segs) seg = segs - 1;
                const local = scaled - seg * den;
                c.pixels[c.idx(x, y)] = Color.lerp(colors[seg], colors[seg + 1], local, den).argb();
            }
        }
    }

    /// Paint a parsed texture. Pixmap textures need an image loader, which
    /// is not part of this file: they fall back to their colour until you
    /// plug one in (see TODO in theme.zig).
    pub fn drawTexture(c: *Canvas, r: Rect, t: Texture) void {
        switch (t) {
            .solid => |col| c.fillRect(r, col),
            .gradient => |g| c.gradient(r, g.dir, g.from, g.to),
            .multi => |m| c.multiGradient(r, m.dir, m.colors),
            .pixmap, .unsupported => c.fillRect(r, t.baseColor()),
        }
    }

    // ---- image blitting (RImage bridge) -----------------------------------

    /// Straight-alpha RGBA bytes (wrlib RImage with alpha) -> canvas,
    /// source-over blended.
    pub fn blitRgba8(c: *Canvas, dx: i32, dy: i32, src: []const u8, sw: i32, sh: i32) void {
        c.blitBytes(dx, dy, src, sw, sh, 4);
    }

    /// Opaque RGB bytes (wrlib RImage without alpha).
    pub fn blitRgb8(c: *Canvas, dx: i32, dy: i32, src: []const u8, sw: i32, sh: i32) void {
        c.blitBytes(dx, dy, src, sw, sh, 3);
    }

    fn blitBytes(c: *Canvas, dx: i32, dy: i32, src: []const u8, sw: i32, sh: i32, bpp: usize) void {
        if (sw <= 0 or sh <= 0) return;
        if (src.len < @as(usize, @intCast(sw)) * @as(usize, @intCast(sh)) * bpp) return;
        var y: i32 = 0;
        while (y < sh) : (y += 1) {
            const ty = dy + y;
            if (ty < 0 or ty >= c.height) continue;
            var x: i32 = 0;
            while (x < sw) : (x += 1) {
                const tx = dx + x;
                if (tx < 0 or tx >= c.width) continue;
                const o = (@as(usize, @intCast(y)) * @as(usize, @intCast(sw)) + @as(usize, @intCast(x))) * bpp;
                const a: u8 = if (bpp == 4) src[o + 3] else 255;
                const col: Color = .{ .r = src[o], .g = src[o + 1], .b = src[o + 2], .a = a };
                c.blendPixel(tx, ty, col);
            }
        }
    }

    /// Source-over of a straight-alpha colour onto a premultiplied pixel.
    fn blendPixel(c: *Canvas, x: i32, y: i32, col: Color) void {
        const i = c.idx(x, y);
        if (col.a == 255) {
            c.pixels[i] = col.argb();
            return;
        }
        if (col.a == 0) return;
        const s = col.argb();
        const d = c.pixels[i];
        const inv: u32 = 255 - col.a;
        const ch = struct {
            fn f(sv: u32, dv: u32, inv_a: u32) u32 {
                return @min(255, sv + (dv * inv_a + 127) / 255);
            }
        }.f;
        const a = ch(s >> 24, d >> 24, inv);
        const r = ch((s >> 16) & 0xff, (d >> 16) & 0xff, inv);
        const g = ch((s >> 8) & 0xff, (d >> 8) & 0xff, inv);
        const b = ch(s & 0xff, d & 0xff, inv);
        c.pixels[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }
};

// ============================================================================
// Text hook
// ============================================================================

/// Fonts need FreeType/Pango/fontconfig, which we do not want as a hard
/// dependency of the base. Plug a backend in here (or bridge to WINGs'
/// WMDrawString via compat/c_api). With no backend, titles are skipped.
pub const TextBackend = struct {
    ctx: ?*anyopaque = null,
    /// Pixel height of one line (used for titlebar/menu row heights).
    line_height: i32 = 14,
    measure: *const fn (ctx: ?*anyopaque, text: []const u8) i32 = noMeasure,
    draw: *const fn (ctx: ?*anyopaque, canvas: *Canvas, x: i32, y: i32, text: []const u8, color: Color) void = noDraw,

    fn noMeasure(_: ?*anyopaque, text: []const u8) i32 {
        // Rough fixed-width guess so layout stays sane without a font.
        return @intCast(text.len * 7);
    }
    fn noDraw(_: ?*anyopaque, _: *Canvas, _: i32, _: i32, _: []const u8, _: Color) void {}
};

// ============================================================================
// Tests
// ============================================================================

test "fill and clip" {
    var buf: [16 * 16]u32 = undefined;
    var c = Canvas.init(&buf, 16, 16);
    c.clear(Color.black);
    c.fillRect(.{ .x = -5, .y = -5, .w = 10, .h = 10 }, Color.white);
    try std.testing.expectEqual(Color.white.argb(), buf[0]);
    try std.testing.expectEqual(Color.white.argb(), buf[4 * 16 + 4]);
    try std.testing.expectEqual(Color.black.argb(), buf[5 * 16 + 5]);
    // completely outside: no crash
    c.fillRect(.{ .x = 100, .y = 100, .w = 5, .h = 5 }, Color.white);
}

test "horizontal gradient endpoints" {
    var buf: [32 * 4]u32 = undefined;
    var c = Canvas.init(&buf, 32, 4);
    c.gradient(.{ .x = 0, .y = 0, .w = 32, .h = 4 }, .horizontal, Color.black, Color.white);
    try std.testing.expectEqual(Color.black.argb(), buf[0]);
    try std.testing.expectEqual(Color.white.argb(), buf[31]);
    const mid = buf[16] & 0xff;
    try std.testing.expect(mid > 100 and mid < 160);
}

test "multi gradient hits every stop" {
    var buf: [21 * 1]u32 = undefined;
    var c = Canvas.init(&buf, 21, 1);
    const red: Color = .{ .r = 255, .g = 0, .b = 0 };
    const green: Color = .{ .r = 0, .g = 255, .b = 0 };
    const blue: Color = .{ .r = 0, .g = 0, .b = 255 };
    c.multiGradient(.{ .x = 0, .y = 0, .w = 21, .h = 1 }, .horizontal, &.{ red, green, blue });
    try std.testing.expectEqual(red.argb(), buf[0]);
    try std.testing.expectEqual(green.argb(), buf[10]);
    try std.testing.expectEqual(blue.argb(), buf[20]);
}

test "bevel raised vs sunken" {
    var buf: [8 * 8]u32 = undefined;
    var c = Canvas.init(&buf, 8, 8);
    c.clear(Color.black);
    c.bevel(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, true, Color.white, Color.black);
    try std.testing.expectEqual(Color.white.argb(), buf[0]);
    c.bevel(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, false, Color.white, Color.black);
    try std.testing.expectEqual(Color.black.argb(), buf[0]);
    try std.testing.expectEqual(Color.white.argb(), buf[7 * 8 + 7]);
}

test "rgba blit blends" {
    var buf: [2 * 1]u32 = undefined;
    var c = Canvas.init(&buf, 2, 1);
    c.clear(Color.white);
    const px = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 0 }; // opaque black, transparent
    c.blitRgba8(0, 0, &px, 2, 1);
    try std.testing.expectEqual(Color.black.argb(), buf[0]);
    try std.testing.expectEqual(Color.white.argb(), buf[1]);
}

test "texture dispatch" {
    var buf: [4 * 4]u32 = undefined;
    var c = Canvas.init(&buf, 4, 4);
    c.drawTexture(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .solid = Color.white });
    try std.testing.expectEqual(Color.white.argb(), buf[5]);
}
