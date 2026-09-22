// SPDX-License-Identifier: 0BSD
//
// Graphics abstraction: cairo + pango for text rendering.

const std = @import("std");
const c = @cImport({
    @cInclude("cairo.h");
    @cInclude("pango/pango.h");
    @cInclude("pango/pangocairo.h");
});

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    pub fn fromArgb32(argb: u32) Color {
        const a: f64 = @floatFromInt((argb >> 24) & 0xFF);
        const r: f64 = @floatFromInt((argb >> 16) & 0xFF);
        const g: f64 = @floatFromInt((argb >> 8) & 0xFF);
        const b: f64 = @floatFromInt(argb & 0xFF);
        return .{
            .r = r / 255.0,
            .g = g / 255.0,
            .b = b / 255.0,
            .a = a / 255.0,
        };
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Surface = struct {
    cairo: *c.cairo_t,
    pango_layout: *c.PangoLayout,
    buffer: []align(@alignOf(u32)) u8,

    pub fn create(
        alloc: std.mem.Allocator,
        width: i32,
        height: i32,
    ) !Surface {
        if (width <= 0 or height <= 0) return error.InvalidDimensions;

        const stride = c.cairo_format_stride_for_width(c.CAIRO_FORMAT_ARGB32, width);
        if (stride < 0) return error.CairoInvalidStride;

        const buffer_size: usize = @intCast(stride * height);
        // Cairo ARGB32 benötigt 4-Byte (u32) Alignment
        const buffer = try alloc.alignedAlloc(u8, @alignOf(u32), buffer_size);
        errdefer alloc.free(buffer);

        const cairo_surf = c.cairo_image_surface_create_for_data(
            buffer.ptr,
            c.CAIRO_FORMAT_ARGB32,
            width,
            height,
            stride,
        );
        if (c.cairo_surface_status(cairo_surf) != c.CAIRO_STATUS_SUCCESS) {
            return error.CairoSurfaceCreationFailed;
        }
        defer c.cairo_surface_destroy(cairo_surf);

        const cairo_ctx = c.cairo_create(cairo_surf) orelse return error.CairoContextCreationFailed;
        if (c.cairo_status(cairo_ctx) != c.CAIRO_STATUS_SUCCESS) {
            return error.CairoContextCreationFailed;
        }
        errdefer c.cairo_destroy(cairo_ctx);

        const pango_context = c.pango_cairo_create_context(cairo_ctx) orelse return error.PangoContextCreationFailed;
        defer c.g_object_unref(pango_context);

        const pango_layout = c.pango_layout_new(pango_context) orelse return error.PangoLayoutCreationFailed;

        return .{
            .cairo = cairo_ctx,
            .pango_layout = pango_layout,
            .buffer = buffer,
        };
    }

    pub fn destroy(self: *Surface, alloc: std.mem.Allocator) void {
        c.g_object_unref(self.pango_layout);

        const surf = c.cairo_get_target(self.cairo);
        c.cairo_destroy(self.cairo);
        c.cairo_surface_destroy(surf);

        alloc.free(self.buffer);
        self.* = undefined;
    }

    pub fn clear(self: Surface, color: Color) void {
        c.cairo_set_source_rgba(self.cairo, color.r, color.g, color.b, color.a);
        c.cairo_paint(self.cairo);
    }

    pub fn fillRect(self: Surface, rect: Rect, color: Color) void {
        c.cairo_set_source_rgba(self.cairo, color.r, color.g, color.b, color.a);
        c.cairo_rectangle(
            self.cairo,
            @floatFromInt(rect.x),
            @floatFromInt(rect.y),
            @floatFromInt(rect.w),
            @floatFromInt(rect.h),
        );
        c.cairo_fill(self.cairo);
    }

    pub fn drawText(self: Surface, x: i32, y: i32, text: [*:0]const u8, color: Color) void {
        c.pango_layout_set_text(self.pango_layout, text, -1);

        c.cairo_set_source_rgba(self.cairo, color.r, color.g, color.b, color.a);
        c.cairo_move_to(self.cairo, @floatFromInt(x), @floatFromInt(y));
        c.pango_cairo_show_layout(self.cairo, self.pango_layout);
    }

    pub fn flush(self: Surface) void {
        const surf = c.cairo_get_target(self.cairo);
        c.cairo_surface_flush(surf);
    }

    pub fn getData(self: Surface) []u8 {
        return self.buffer;
    }
};
