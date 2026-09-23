// SPDX-License-Identifier: 0BSD
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
};

/// Pixel size of `text` in `font`, measured on a scratch surface.
pub fn measureText(text: [:0]const u8, font: [:0]const u8) struct { w: i32, h: i32 } {
    var w: c_int = 0;
    var h: c_int = 0;
    c.wm_measure_text(text.ptr, font.ptr, &w, &h);
    return .{ .w = w, .h = h };
}

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
