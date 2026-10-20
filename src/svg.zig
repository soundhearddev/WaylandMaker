// SPDX-License-Identifier: 0BSD
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
            std.log.info("svg icons: librsvg found", .{});
        } else {
            std.log.info("svg icons: librsvg (librsvg-2.so.2) not found, SVG-only icons get the placeholder", .{});
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

test "load: a file that is not there gives null, with or without librsvg" {
    try std.testing.expect(load("/nonexistent/wmaker-wl-test.svg", 64) == null);
    try std.testing.expect(load("/nonexistent/wmaker-wl-test.svg", 0) == null);
}
