// SPDX-License-Identifier: 0BSD
//
// Cairo/Pango drawing into a wl_shm-backed ARGB32 buffer.
// Copied from wmaker-wl's src/gfx.zig (trimmed to what wlprefs needs) so
// this project has no build-time dependency on the main executable module.

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

    /// Blit a decoded `Image` with its top-left corner at (x, y), clipped to a bounding box.
    pub fn drawImageClipped(
        cv: *Canvas,
        img: *const Image,
        x: i32,
        y: i32,
        clip_x: i32,
        clip_y: i32,
        clip_w: i32,
        clip_h: i32,
    ) void {
        c.cairo_save(cv.cr);
        c.cairo_rectangle(
            cv.cr,
            @floatFromInt(clip_x),
            @floatFromInt(clip_y),
            @floatFromInt(clip_w),
            @floatFromInt(clip_h),
        );
        c.cairo_clip(cv.cr);

        c.cairo_set_source_surface(cv.cr, img.surface, @floatFromInt(x), @floatFromInt(y));
        c.cairo_paint(cv.cr);

        c.cairo_restore(cv.cr);
    }

    /// Beveled frame: light on top/left, dark on bottom/right (NeXT
    /// "raised" look), matching wmaker-wl's own widget style.
    pub fn bevel(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, light: Color, dark: Color) void {
        cv.fillRect(x, y, w, 1, light);
        cv.fillRect(x, y, 1, h, light);
        cv.fillRect(x, y + h - 1, w, 1, dark);
        cv.fillRect(x + w - 1, y, 1, h, dark);
    }

    /// The exact NeXTSTEP/WINGs widget frame, ported line-for-line from
    /// libWINGs' `W_DrawReliefWithGC` (WINGs/wmisc.c in the wmaker source
    /// tree): a 1px outer edge in all cases, plus a second 1px edge one
    /// pixel further in for every relief *except* `.raised`/`.pushed`
    /// (those single-line reliefs are what WPrefs uses for its command
    /// buttons and section icons; `.sunken` -- with the double edge -- is
    /// what it uses for the icon scroll strip and, inverted, "pressed").
    pub const Relief = enum { raised, sunken, pushed, ridge, groove };

    pub fn relief(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, rel: Relief) void {
        const black = Color.rgb(0x000000);
        const dark = Color.rgb(0x848484); // WINGs "darkGray"
        const light = Color.rgb(0xc0c0c0); // WINGs "gray" (widget face)
        const white = Color.rgb(0xffffff);

        // top_left / bottom_right colour, and whether the inner second
        // line is drawn at all -- exactly W_DrawReliefWithGC's `switch`
        // (wgc = outer top-left, lgc = inner top-left, bgc = outer
        // bottom-right, dgc = inner bottom-right; inner lines are
        // skipped for .raised/.pushed exactly as upstream skips them).
        const outer_tl: Color, const inner_tl: Color, const outer_br: Color, const inner_br: Color, const has_inner: bool = switch (rel) {
            .raised => .{ white, white, black, black, false },
            .sunken => .{ dark, black, white, light, true },
            .pushed => .{ black, black, white, white, false },
            .ridge => .{ white, dark, dark, white, true },
            .groove => .{ dark, white, white, dark, true },
        };

        cv.fillRect(x, y, w, 1, outer_tl);
        cv.fillRect(x, y, 1, h, outer_tl);
        cv.fillRect(x, y + h - 1, w, 1, outer_br);
        cv.fillRect(x + w - 1, y, 1, h, outer_br);

        if (has_inner and w > 2 and h > 2) {
            cv.fillRect(x + 1, y + 1, w - 2, 1, inner_tl);
            cv.fillRect(x + 1, y + 1, 1, h - 2, inner_tl);
            cv.fillRect(x + 1, y + h - 2, w - 2, 1, inner_br);
            cv.fillRect(x + w - 2, y + 1, 1, h - 2, inner_br);
        }
    }

    pub fn drawText(cv: *Canvas, text: [:0]const u8, x: i32, y: i32, font: [:0]const u8, col: Color) void {
        cv.setColor(col);
        c.wm_draw_text(cv.cr, text.ptr, x, y, font.ptr);
    }

    /// Centered text, for icon-tile labels. `text` still needs a null
    /// terminator (pass a `[:0]const u8`).
    pub fn drawTextCentered(cv: *Canvas, text: [:0]const u8, cx: i32, y: i32, font: [:0]const u8, col: Color) void {
        const size = measureText(text, font);
        cv.drawText(text, cx - @divTrunc(size.w, 2), y, font, col);
    }

    pub fn strokeLine(cv: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, width: f64, col: Color) void {
        cv.setColor(col);
        c.cairo_set_line_width(cv.cr, width);
        c.cairo_move_to(cv.cr, @floatFromInt(x0), @floatFromInt(y0));
        c.cairo_line_to(cv.cr, @floatFromInt(x1), @floatFromInt(y1));
        c.cairo_stroke(cv.cr);
    }

    pub fn strokeRect(cv: *Canvas, x: i32, y: i32, w: i32, h: i32, width: f64, col: Color) void {
        cv.setColor(col);
        c.cairo_set_line_width(cv.cr, width);
        c.cairo_rectangle(cv.cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h));
        c.cairo_stroke(cv.cr);
    }

    pub fn strokeCircle(cv: *Canvas, cx: i32, cy: i32, r: i32, width: f64, col: Color) void {
        cv.setColor(col);
        c.cairo_set_line_width(cv.cr, width);
        c.cairo_arc(cv.cr, @floatFromInt(cx), @floatFromInt(cy), @floatFromInt(r), 0, 2 * std.math.pi);
        c.cairo_stroke(cv.cr);
    }

    pub fn fillCircle(cv: *Canvas, cx: i32, cy: i32, r: i32, col: Color) void {
        cv.setColor(col);
        c.cairo_arc(cv.cr, @floatFromInt(cx), @floatFromInt(cy), @floatFromInt(r), 0, 2 * std.math.pi);
        c.cairo_fill(cv.cr);
    }

    pub fn flush(cv: *Canvas) void {
        c.cairo_surface_flush(cv.surface);
    }

    /// Blit a decoded `Image` with its top-left corner at (x, y).
    pub fn drawImage(cv: *Canvas, img: Image, x: i32, y: i32) void {
        c.cairo_save(cv.cr);
        c.cairo_set_source_surface(cv.cr, img.surface, @floatFromInt(x), @floatFromInt(y));
        c.cairo_paint(cv.cr);
        c.cairo_restore(cv.cr);
    }
};

/// A decoded raster image (wlprefs' section icons). Loaded once from an
/// `@embedFile`d PNG -- see `Category.icon()` in root.zig -- and kept
/// around as a cairo image surface for repeated `Canvas.drawImage` calls.
pub const Image = struct {
    surface: *c.cairo_surface_t,
    width: i32,
    height: i32,

    const ReadCtx = struct {
        data: []const u8,
        pos: usize,
    };

    fn readCb(closure: ?*anyopaque, data: [*c]u8, length: c_uint) callconv(.c) c.cairo_status_t {
        const ctx: *ReadCtx = @ptrCast(@alignCast(closure orelse return c.CAIRO_STATUS_READ_ERROR));
        const n: usize = length;
        if (ctx.pos + n > ctx.data.len) return c.CAIRO_STATUS_READ_ERROR;
        @memcpy(data[0..n], ctx.data[ctx.pos .. ctx.pos + n]);
        ctx.pos += n;
        return c.CAIRO_STATUS_SUCCESS;
    }

    /// Decode a PNG held in memory. wlprefs has no XPM/TIFF decoder, so
    /// section icons are WPrefs.app/xpm/*.xpm converted to PNG ahead of
    /// time (see src/assets/icons/) -- real official Window Maker
    /// artwork, not generated placeholder glyphs.
    pub fn fromPngBytes(bytes: []const u8) !Image {
        var ctx = ReadCtx{ .data = bytes, .pos = 0 };
        const s = c.cairo_image_surface_create_from_png_stream(readCb, &ctx) orelse
            return error.CairoSurface;
        if (c.cairo_surface_status(s) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(s);
            return error.CairoSurface;
        }
        return .{
            .surface = s,
            .width = c.cairo_image_surface_get_width(s),
            .height = c.cairo_image_surface_get_height(s),
        };
    }

    /// Largest side we accept for an icon file.
    pub const max_side: i32 = 512;

    /// Load a PNG from disk (user-supplied icons, see icons.zig). null if
    /// the file is missing, not a PNG, or implausibly large.
    pub fn fromPngFile(path: [:0]const u8) ?Image {
        const s = c.cairo_image_surface_create_from_png(path.ptr) orelse return null;
        if (c.cairo_surface_status(s) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(s);
            return null;
        }
        const w = c.cairo_image_surface_get_width(s);
        const h = c.cairo_image_surface_get_height(s);
        if (w <= 0 or h <= 0 or w > max_side or h > max_side) {
            c.cairo_surface_destroy(s);
            return null;
        }
        return .{ .surface = s, .width = w, .height = h };
    }

    pub fn deinit(img: *Image) void {
        c.cairo_surface_destroy(img.surface);
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
    var buf: [16 * 16 * 4]u8 align(16) = undefined; // cairo wants aligned memory
    @memset(&buf, 0);
    var cv = try Canvas.initForData(&buf, 16, 16, 16 * 4);
    defer cv.deinit();
    cv.clear(Color.rgb(0xff0000));
    cv.flush();
    // ARGB32 little-endian: B, G, R, A
    try std.testing.expectEqual(@as(u8, 0xff), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[3]);
}
