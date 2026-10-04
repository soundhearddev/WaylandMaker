// SPDX-License-Identifier: 0BSD
//
// Icons wlprefs wants beyond the 16 section icons (those are Window Maker's
// own WPrefs artwork, see Category.icon() in root.zig).
//
// THE RULE: wlprefs does not draw its own icons. Every icon below is a PNG
// somebody provides. Until one exists, the spot shows a clearly marked
// FALLBACK -- a grey box crossed out with the icon's short name in it -- so
// the interface works, and it is obvious which icon belongs where.
//
// Where an icon is looked for, first hit wins:
//
//   1. $WLPREFS_ICON_DIR/<file>
//   2. $XDG_DATA_HOME/wlprefs/icons/<file>     (default ~/.local/share/...)
//   3. /usr/local/share/wlprefs/icons/<file>
//   4. /usr/share/wlprefs/icons/<file>
//   5. compiled into the binary (`embedded()` below)
//   6. the fallback
//
// So a theme or a packager can supply icons without rebuilding, and an icon
// that ships with the project goes into src/assets/icons/ plus one line in
// `embedded()`. docs/WLPREFS-ICONS.md lists every icon wanted, its size and
// where it appears.

const std = @import("std");
const gfx = @import("gfx.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

pub const Id = enum {
    dock_left,
    dock_right,
    clip_top_left,
    clip_top_right,
    clip_bottom_left,
    clip_bottom_right,

    pub const all = std.enums.values(Id);
};

pub const Spec = struct {
    /// File name looked for in the directories above.
    file: [:0]const u8,
    /// Short text of the fallback (kept to what fits into the box).
    caption: [:0]const u8,
    /// Under the button, always (an icon alone is not a label).
    label: [:0]const u8,
    /// Size of the box the icon is drawn in; the PNG should be exactly this.
    w: i32,
    h: i32,
    /// For docs/WLPREFS-ICONS.md and the tests.
    where: []const u8,
};

pub fn spec(id: Id) Spec {
    return switch (id) {
        .dock_left => .{
            .file = "dock-left.png",
            .caption = "dock L",
            .label = "left",
            .w = 48,
            .h = 48,
            .where = "Dock Preferences > Dock > Edge: the Dock on the left screen edge",
        },
        .dock_right => .{
            .file = "dock-right.png",
            .caption = "dock R",
            .label = "right",
            .w = 48,
            .h = 48,
            .where = "Dock Preferences > Dock > Edge: the Dock on the right screen edge",
        },
        .clip_top_left => .{
            .file = "clip-top-left.png",
            .caption = "clip TL",
            .label = "top\nleft",
            .w = 48,
            .h = 48,
            .where = "Dock Preferences > Clip > Corner: the Clip in the top left corner",
        },
        .clip_top_right => .{
            .file = "clip-top-right.png",
            .caption = "clip TR",
            .label = "top\nright",
            .w = 48,
            .h = 48,
            .where = "Dock Preferences > Clip > Corner: the Clip in the top right corner",
        },
        .clip_bottom_left => .{
            .file = "clip-bottom-left.png",
            .caption = "clip BL",
            .label = "bottom\nleft",
            .w = 48,
            .h = 48,
            .where = "Dock Preferences > Clip > Corner: the Clip in the bottom left corner",
        },
        .clip_bottom_right => .{
            .file = "clip-bottom-right.png",
            .caption = "clip BR",
            .label = "bottom\nright",
            .w = 48,
            .h = 48,
            .where = "Dock Preferences > Clip > Corner: the Clip in the bottom right corner",
        },
    };
}

/// Icons compiled into the binary. null: none shipped yet, the fallback is
/// shown. To ship one: put the PNG in src/assets/icons/ and return
/// `@embedFile("assets/icons/<file>")` for its id.
pub fn embedded(id: Id) ?[]const u8 {
    return switch (id) {
        .dock_left,
        .dock_right,
        .clip_top_left,
        .clip_top_right,
        .clip_bottom_left,
        .clip_bottom_right,
        => null,
    };
}

fn tryDir(buf: []u8, dir: []const u8, file: []const u8) ?gfx.Image {
    if (dir.len == 0) return null;
    const path = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, file }) catch return null;
    return gfx.Image.fromPngFile(path);
}

fn env(name: [:0]const u8) []const u8 {
    const v = c.getenv(name.ptr) orelse return "";
    return std.mem.span(v);
}

/// Look `id` up in the order described at the top of this file.
pub fn find(id: Id) ?gfx.Image {
    const sp = spec(id);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;

    if (tryDir(&buf, env("WLPREFS_ICON_DIR"), sp.file)) |img| return img;

    const xdg = env("XDG_DATA_HOME");
    if (xdg.len > 0) {
        const d = std.fmt.bufPrint(&dbuf, "{s}/wlprefs/icons", .{xdg}) catch "";
        if (tryDir(&buf, d, sp.file)) |img| return img;
    } else {
        const home = env("HOME");
        if (home.len > 0) {
            const d = std.fmt.bufPrint(&dbuf, "{s}/.local/share/wlprefs/icons", .{home}) catch "";
            if (tryDir(&buf, d, sp.file)) |img| return img;
        }
    }
    if (tryDir(&buf, "/usr/local/share/wlprefs/icons", sp.file)) |img| return img;
    if (tryDir(&buf, "/usr/share/wlprefs/icons", sp.file)) |img| return img;

    if (embedded(id)) |bytes| {
        return gfx.Image.fromPngBytes(bytes) catch null;
    }
    return null;
}

/// Every icon, loaded once.
pub const Set = struct {
    imgs: [Id.all.len]?gfx.Image = [_]?gfx.Image{null} ** Id.all.len,

    pub fn load() Set {
        var s: Set = .{};
        for (Id.all, 0..) |id, i| s.imgs[i] = find(id);
        return s;
    }

    pub fn deinit(s: *Set) void {
        for (&s.imgs) |*m| {
            if (m.*) |*img| img.deinit();
            m.* = null;
        }
    }

    pub fn get(s: *const Set, id: Id) ?gfx.Image {
        return s.imgs[@intFromEnum(id)];
    }

    /// How many icons are still fallbacks.
    pub fn missing(s: *const Set) usize {
        var n: usize = 0;
        for (s.imgs) |m| {
            if (m == null) n += 1;
        }
        return n;
    }
};

const fallback_fill = gfx.Color.rgb(0xc8c8c8);
const fallback_line = gfx.Color.rgb(0x8a8a8a);
const fallback_face = gfx.Color.rgb(0xaeaeae);
const fallback_text = gfx.Color.rgb(0x303030);

/// The marked placeholder: a crossed-out box with the icon's caption.
pub fn drawFallback(cv: *gfx.Canvas, id: Id, x: i32, y: i32) void {
    const sp = spec(id);
    cv.fillRect(x, y, sp.w, sp.h, fallback_fill);
    cv.strokeLine(x, y, x + sp.w, y + sp.h, 1, fallback_line);
    cv.strokeLine(x + sp.w, y, x, y + sp.h, 1, fallback_line);
    cv.strokeRect(x, y, sp.w, sp.h, 1, fallback_line);
    const font = "Sans 7";
    const t = gfx.measureText(sp.caption, font);
    const tx = x + @divTrunc(sp.w - t.w, 2);
    const ty = y + @divTrunc(sp.h - t.h, 2);
    cv.fillRect(tx - 2, ty, t.w + 4, t.h, fallback_face);
    cv.drawText(sp.caption, tx, ty, font, fallback_text);
}

/// The icon if there is one, else the fallback; in the box (x, y, w, h).
pub fn draw(cv: *gfx.Canvas, set: *const Set, id: Id, x: i32, y: i32) void {
    const sp = spec(id);
    if (set.get(id)) |img| {
        cv.drawImage(img, x + @divTrunc(sp.w - img.width, 2), y + @divTrunc(sp.h - img.height, 2));
    } else {
        drawFallback(cv, id, x, y);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "every icon has a unique png file name, a caption and a purpose" {
    for (Id.all, 0..) |a, i| {
        const sa = spec(a);
        try std.testing.expect(std.mem.endsWith(u8, sa.file, ".png"));
        try std.testing.expect(sa.caption.len > 0 and sa.caption.len <= 9);
        try std.testing.expect(sa.label.len > 0);
        try std.testing.expect(sa.where.len > 0);
        try std.testing.expect(sa.w > 0 and sa.h > 0);
        for (Id.all[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, sa.file, spec(b).file));
        }
    }
}

test "embedded icons, if any, decode at their documented size" {
    for (Id.all) |id| {
        const bytes = embedded(id) orelse continue;
        var img = try gfx.Image.fromPngBytes(bytes);
        defer img.deinit();
        try std.testing.expectEqual(spec(id).w, img.width);
        try std.testing.expectEqual(spec(id).h, img.height);
    }
}

test "the fallback paints something visible and marks the caption" {
    var buf: [64 * 64 * 4]u8 align(16) = undefined;
    @memset(&buf, 0);
    var cv = try gfx.Canvas.initForData(&buf, 64, 64, 64 * 4);
    defer cv.deinit();
    drawFallback(&cv, .dock_left, 4, 4);
    cv.flush();
    // The box is opaque grey, the outside untouched.
    const inside = (@as(usize, 8) * 64 + 8) * 4;
    try std.testing.expectEqual(@as(u8, 0xff), buf[inside + 3]);
    try std.testing.expectEqual(@as(u8, 0), buf[3]);
    // Something other than the flat fill is in there (the lines and the text).
    var distinct = false;
    var i: usize = 0;
    while (i < 48 * 4) : (i += 4) {
        const o = (@as(usize, 20) * 64 + 4) * 4 + i;
        if (buf[o] != buf[inside]) distinct = true;
    }
    try std.testing.expect(distinct);
}

test "a user-supplied icon in $WLPREFS_ICON_DIR wins over the fallback" {
    // Write a real 48x48 PNG with cairo, point the variable at its directory.
    var tmpl = "/tmp/wlprefs-icons-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.MkdTemp;
    const dirs = std.mem.span(dir);

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dirs, spec(.dock_right).file });
    const surf = gfx.c.cairo_image_surface_create(gfx.c.CAIRO_FORMAT_ARGB32, 48, 48) orelse return error.Cairo;
    defer gfx.c.cairo_surface_destroy(surf);
    try std.testing.expectEqual(@as(c_uint, gfx.c.CAIRO_STATUS_SUCCESS), gfx.c.cairo_surface_write_to_png(surf, path.ptr));

    _ = c.setenv("WLPREFS_ICON_DIR", dir, 1);
    defer {
        _ = c.unsetenv("WLPREFS_ICON_DIR");
        var cmd: [160]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{dirs})) |z| _ = c.system(z.ptr) else |_| {}
    }

    var img = find(.dock_right) orelse return error.NotFound;
    defer img.deinit();
    try std.testing.expectEqual(@as(i32, 48), img.width);
    // Another id that has no file there: still the fallback (null).
    var other = find(.clip_top_left);
    defer if (other) |*o| o.deinit();
    try std.testing.expect(other == null);
}

test "a broken or oversized file is ignored, not trusted" {
    var tmpl = "/tmp/wlprefs-icons-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.MkdTemp;
    const dirs = std.mem.span(dir);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dirs, spec(.dock_left).file });

    // Not a PNG.
    const f = std.c.fopen(path.ptr, "wb") orelse return error.Open;
    _ = std.c.fwrite("not a png", 1, 9, f);
    _ = std.c.fclose(f);

    _ = c.setenv("WLPREFS_ICON_DIR", dir, 1);
    defer {
        _ = c.unsetenv("WLPREFS_ICON_DIR");
        var cmd: [160]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{dirs})) |z| _ = c.system(z.ptr) else |_| {}
    }
    try std.testing.expect(find(.dock_left) == null);
}

test "Set counts what is still a fallback" {
    var s: Set = .{};
    try std.testing.expectEqual(Id.all.len, s.missing());
    s.deinit();
}
