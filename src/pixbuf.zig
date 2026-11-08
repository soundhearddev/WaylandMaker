// SPDX-License-Identifier: GPL-3.0
//
// Any other picture format an icon may be in: JPEG, GIF, BMP, ICO, TIFF,
// WebP, PNM, SVGZ ... whatever gdk-pixbuf has a loader for. Like librsvg
// (svg.zig) it is loaded at run time (dlopen), not linked: the build needs
// nothing new, and a machine without it just reads the formats that are
// built in (PNG, XPM) and SVG through librsvg.
//
// This is only the last resort of `appicon.loadFile`; PNG and XPM are read
// directly, which is faster and needs no library.
//
// No Wayland types in here, so it is unit-testable without a compositor.

const std = @import("std");
const log = std.log.scoped(.pixbuf);
const gfx = @import("gfx.zig");

const NewFromFile = *const fn ([*:0]const u8, ?*?*anyopaque) callconv(.c) ?*anyopaque;
const GetInt = *const fn (*const anyopaque) callconv(.c) c_int;
const GetPixels = *const fn (*const anyopaque) callconv(.c) ?[*]const u8;
const Unref = *const fn (?*anyopaque) callconv(.c) void;

const Api = struct {
    lib: std.DynLib,
    new_from_file: NewFromFile,
    width: GetInt,
    height: GetInt,
    rowstride: GetInt,
    channels: GetInt,
    bits: GetInt,
    pixels: GetPixels,
    unref: Unref,
};

var api: ?Api = null;
var tried = false;

fn openLibrary() ?Api {
    const names = [_][]const u8{ "libgdk_pixbuf-2.0.so.0", "libgdk_pixbuf-2.0.so" };
    for (names) |name| {
        var lib = std.DynLib.open(name) catch continue;
        const new_from_file = lib.lookup(NewFromFile, "gdk_pixbuf_new_from_file");
        const width = lib.lookup(GetInt, "gdk_pixbuf_get_width");
        const height = lib.lookup(GetInt, "gdk_pixbuf_get_height");
        const rowstride = lib.lookup(GetInt, "gdk_pixbuf_get_rowstride");
        const channels = lib.lookup(GetInt, "gdk_pixbuf_get_n_channels");
        const bits = lib.lookup(GetInt, "gdk_pixbuf_get_bits_per_sample");
        const pixels = lib.lookup(GetPixels, "gdk_pixbuf_get_pixels");
        const unref = lib.lookup(Unref, "g_object_unref");
        if (new_from_file != null and width != null and height != null and rowstride != null and
            channels != null and bits != null and pixels != null and unref != null)
        {
            return .{
                .lib = lib,
                .new_from_file = new_from_file.?,
                .width = width.?,
                .height = height.?,
                .rowstride = rowstride.?,
                .channels = channels.?,
                .bits = bits.?,
                .pixels = pixels.?,
                .unref = unref.?,
            };
        }
        lib.close();
    }
    return null;
}

/// Is gdk-pixbuf there? Looked for once.
pub fn available() bool {
    if (!tried) {
        tried = true;
        api = openLibrary();
        if (api != null) {
            log.info("other icon formats: gdk-pixbuf found", .{});
        } else {
            log.info("other icon formats: gdk-pixbuf not found, only PNG, XPM and SVG icons are read", .{});
        }
    }
    return api != null;
}

/// 8-bit straight RGB(A) -> premultiplied ARGB32 (what cairo wants).
fn argb(r: u8, g: u8, b: u8, a: u8) u32 {
    const av: u32 = a;
    const pr = (@as(u32, r) * av + 127) / 255;
    const pg = (@as(u32, g) * av + 127) / 255;
    const pb = (@as(u32, b) * av + 127) / 255;
    return (av << 24) | (pr << 16) | (pg << 8) | pb;
}

/// The picture in `path`, in its own size, or null (no gdk-pixbuf, no loader
/// for the format, missing or broken file, absurd size). The caller owns it.
pub fn load(gpa: std.mem.Allocator, path: [:0]const u8) ?gfx.Icon {
    if (!available()) return null;
    const a = api.?;
    const pb = a.new_from_file(path.ptr, null) orelse return null;
    defer a.unref(pb);

    const w = a.width(pb);
    const h = a.height(pb);
    const stride = a.rowstride(pb);
    const n = a.channels(pb);
    if (a.bits(pb) != 8 or (n != 3 and n != 4)) return null;
    if (w <= 0 or h <= 0 or w > gfx.Icon.max_side or h > gfx.Icon.max_side) return null;
    const src = a.pixels(pb) orelse return null;

    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    const out = gpa.alloc(u32, uw * uh) catch return null;
    defer gpa.free(out);
    const un: usize = @intCast(n);
    const ustride: usize = @intCast(stride);
    for (0..uh) |y| {
        const row = src + y * ustride;
        for (0..uw) |x| {
            const p = row + x * un;
            out[y * uw + x] = argb(p[0], p[1], p[2], if (un == 4) p[3] else 255);
        }
    }
    return gfx.Icon.fromPixels(@intCast(w), @intCast(h), out);
}

test "argb premultiplies" {
    try std.testing.expectEqual(@as(u32, 0xffff0000), argb(255, 0, 0, 255));
    try std.testing.expectEqual(@as(u32, 0x00000000), argb(255, 255, 255, 0));
    try std.testing.expectEqual(@as(u32, 0x80800000), argb(255, 0, 0, 128));
}

test "load: a PNM file is read when gdk-pixbuf is there, else it is not found" {
    var buf: [96:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/tmp/wmaker-wl-pixbuf-test-{d}.ppm", .{std.c.getpid()});
    // 2 x 1: a red and a blue pixel.
    const data = "P6\n2 1\n255\n" ++ "\xff\x00\x00" ++ "\x00\x00\xff";
    const fh = std.c.fopen(path.ptr, "wb") orelse return error.CannotWrite;
    _ = std.c.fwrite(data.ptr, 1, data.len, fh);
    _ = std.c.fclose(fh);
    defer _ = std.c.unlink(path.ptr);

    if (!available()) {
        try std.testing.expect(load(std.testing.allocator, path) == null);
        return;
    }
    var ic = load(std.testing.allocator, path) orelse return error.NotLoaded;
    defer ic.deinit();
    try std.testing.expectEqual(@as(i32, 2), ic.w);
    try std.testing.expectEqual(@as(i32, 1), ic.h);
    const px = gfx.c.cairo_image_surface_get_data(ic.surface) orelse return error.NoPixels;
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, px[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), std.mem.readInt(u32, px[4..8], .little));
}

test "load: a missing or broken file gives null" {
    try std.testing.expect(load(std.testing.allocator, "/nonexistent/none.jpg") == null);
}
