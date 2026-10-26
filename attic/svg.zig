// SPDX-License-Identifier: GPL-3.0
//
// SVG icons, drawn by librsvg. Almost every modern icon theme (Adwaita,
// Papirus, breeze, ...) ships its application icons as SVG only, which cairo
// cannot read.
//
// librsvg is loaded at run time (dlopen) and not linked: the build needs
// nothing new, and a machine without it simply does not find SVG icons (the
// Dock then shows its own placeholder). The first `available()` says which of
// the two it is in the log.
//
// No Wayland types in here, so it is unit-testable without a compositor.

const std = @import("std");
const log = std.log.scoped(.svg);
const gfx = @import("gfx.zig");
const c = gfx.c;

/// Side, in px, an SVG is drawn at: a little more than the biggest tile icon
/// (the Dock scales it down once and keeps the result, see gfx.Canvas.drawIcon).
pub const render_size: i32 = 128;

/// RsvgRectangle
const Rect = extern struct { x: f64, y: f64, width: f64, height: f64 };

const NewFromFile = *const fn ([*:0]const u8, ?*?*anyopaque) callconv(.c) ?*anyopaque;
const RenderDocument = *const fn (*anyopaque, *c.cairo_t, *const Rect, ?*?*anyopaque) callconv(.c) c_int;
const Unref = *const fn (?*anyopaque) callconv(.c) void;

const Api = struct {
    lib: std.DynLib,
    new_from_file: NewFromFile,
    render_document: RenderDocument,
    unref: Unref,
};

var api: ?Api = null;
var tried = false;

fn openLibrary() ?Api {
    const names = [_][]const u8{ "librsvg-2.so.2", "librsvg-2.so" };
    for (names) |name| {
        var lib = std.DynLib.open(name) catch continue;
        const new_from_file = lib.lookup(NewFromFile, "rsvg_handle_new_from_file");
        const render_document = lib.lookup(RenderDocument, "rsvg_handle_render_document");
        // g_object_unref lives in libgobject, which librsvg depends on.
        const unref = lib.lookup(Unref, "g_object_unref");
        if (new_from_file != null and render_document != null and unref != null) {
            return .{
                .lib = lib,
                .new_from_file = new_from_file.?,
                .render_document = render_document.?,
                .unref = unref.?,
            };
        }
        lib.close();
    }
    return null;
}

/// Is librsvg there? Looked for once.
pub fn available() bool {
    if (!tried) {
        tried = true;
        api = openLibrary();
        if (api != null) {
            log.info("svg icons: librsvg found", .{});
        } else {
            log.info("svg icons: librsvg (librsvg-2.so.2) not found, SVG-only icons get the placeholder", .{});
        }
    }
    return api != null;
}

/// The SVG at `path`, drawn `size` x `size` px (the whole picture, its aspect
/// ratio kept). null if there is no librsvg, the file is missing or no SVG.
pub fn load(path: [:0]const u8, size: i32) ?gfx.Icon {
    if (!available()) return null;
    const a = api.?;
    if (size <= 0 or size > gfx.Icon.max_side) return null;

    const handle = a.new_from_file(path.ptr, null) orelse return null;
    defer a.unref(handle);

    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, size, size) orelse return null;
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        c.cairo_surface_destroy(surface);
        return null;
    }
    const cr = c.cairo_create(surface) orelse {
        c.cairo_surface_destroy(surface);
        return null;
    };
    defer c.cairo_destroy(cr);

    const side: f64 = @floatFromInt(size);
    const viewport: Rect = .{ .x = 0, .y = 0, .width = side, .height = side };
    if (a.render_document(handle, cr, &viewport, null) == 0) {
        c.cairo_surface_destroy(surface);
        return null;
    }
    c.cairo_surface_flush(surface);
    return .{ .surface = surface, .w = size, .h = size };
}

/// A red 16 x 16 square, for the tests here and in appicon.zig.
pub const test_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><rect width="16" height="16" fill="#ff0000"/></svg>
;

/// Write `text` to `path` (tests only).
pub fn writeTestFile(path: [:0]const u8, text: []const u8) !void {
    const fh = std.c.fopen(path.ptr, "wb") orelse return error.CannotWrite;
    defer _ = std.c.fclose(fh);
    if (std.c.fwrite(text.ptr, 1, text.len, fh) != text.len) return error.CannotWrite;
}

test "load: an SVG is drawn at render_size when librsvg is there, else it is not found" {
    var buf: [96:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/tmp/wmaker-wl-svg-test-{d}.svg", .{std.c.getpid()});
    try writeTestFile(path, test_svg);
    defer _ = std.c.unlink(path.ptr);

    if (!available()) {
        // Nothing to draw it with: null, never a made-up icon.
        try std.testing.expect(load(path, render_size) == null);
        return;
    }
    var ic = load(path, render_size) orelse return error.SvgNotDrawn;
    defer ic.deinit();
    try std.testing.expectEqual(render_size, ic.w);
    try std.testing.expectEqual(render_size, ic.h);

    // The red square fills the whole picture: the middle is opaque red.
    const data = c.cairo_image_surface_get_data(ic.surface) orelse return error.NoPixels;
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(ic.surface));
    const mid: usize = @intCast(@divTrunc(render_size, 2));
    const pixel = (data + (mid * stride + mid * 4))[0..4];
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, pixel, .little));
}

test "load: something that is no SVG gives null, with or without librsvg" {
    var buf: [96:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/tmp/wmaker-wl-svg-bad-{d}.svg", .{std.c.getpid()});
    try writeTestFile(path, "this is not an svg at all");
    defer _ = std.c.unlink(path.ptr);
    try std.testing.expect(load(path, render_size) == null);
}

test "load: a file that is not there gives null, with or without librsvg" {
    try std.testing.expect(load("/nonexistent/wmaker-wl-test.svg", 64) == null);
    try std.testing.expect(load("/nonexistent/wmaker-wl-test.svg", 0) == null);
}
