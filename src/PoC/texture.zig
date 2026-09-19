// SPDX-License-Identifier: 0BSD
//
// Window Maker "textures" and colours, as they appear in the defaults
// domain and in theme files:
//
//   FTitleBack = (solid, black);
//   UTitleBack = (dgradient, "rgb:a6/a6/b6", "rgb:51/55/61");
//   IconBack   = (hgradient, gray80, gray40);
//   WorkspaceBack = (tpixmap, "wallpaper.png", gray50);
//
// C origin: src/texture.c, src/misc.c (wGetColor), wrlib/ (rendering).
// Rendering lives in canvas.zig so this file stays parse-only and testable:

const std = @import("std");
const Allocator = std.mem.Allocator;
const plist = @import("plist.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };

    /// Packed 0xAARRGGBB with alpha PRE-multiplied - the format river and
    /// wl_shm expect for WL_SHM_FORMAT_ARGB8888.
    pub fn argb(c: Color) u32 {
        const a: u32 = c.a;
        const r: u32 = (@as(u32, c.r) * a + 127) / 255;
        const g: u32 = (@as(u32, c.g) * a + 127) / 255;
        const b: u32 = (@as(u32, c.b) * a + 127) / 255;
        return (a << 24) | (r << 16) | (g << 8) | b;
    }

    pub fn lerp(a: Color, b: Color, num: u32, den: u32) Color {
        if (den == 0) return a;
        const t = @min(num, den);
        return .{
            .r = mix(a.r, b.r, t, den),
            .g = mix(a.g, b.g, t, den),
            .b = mix(a.b, b.b, t, den),
            .a = mix(a.a, b.a, t, den),
        };
    }

    fn mix(x: u8, y: u8, t: u32, den: u32) u8 {
        const xi: i64 = x;
        const yi: i64 = y;
        return @intCast(xi + @divTrunc((yi - xi) * @as(i64, t), @as(i64, den)));
    }

    /// Darker/lighter variants used for bevels.
    pub fn scaled(c: Color, num: u32, den: u32) Color {
        return .{
            .r = @intCast(@min(255, @as(u32, c.r) * num / den)),
            .g = @intCast(@min(255, @as(u32, c.g) * num / den)),
            .b = @intCast(@min(255, @as(u32, c.b) * num / den)),
            .a = c.a,
        };
    }
};

const NamedColor = struct { name: []const u8, c: Color };
const named_colors = [_]NamedColor{
    .{ .name = "black", .c = .{ .r = 0, .g = 0, .b = 0 } },
    .{ .name = "white", .c = .{ .r = 255, .g = 255, .b = 255 } },
    .{ .name = "gray", .c = .{ .r = 190, .g = 190, .b = 190 } },
    .{ .name = "grey", .c = .{ .r = 190, .g = 190, .b = 190 } },
    .{ .name = "lightgray", .c = .{ .r = 211, .g = 211, .b = 211 } },
    .{ .name = "darkgray", .c = .{ .r = 169, .g = 169, .b = 169 } },
    .{ .name = "red", .c = .{ .r = 255, .g = 0, .b = 0 } },
    .{ .name = "green", .c = .{ .r = 0, .g = 255, .b = 0 } },
    .{ .name = "blue", .c = .{ .r = 0, .g = 0, .b = 255 } },
    .{ .name = "yellow", .c = .{ .r = 255, .g = 255, .b = 0 } },
    .{ .name = "cyan", .c = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .name = "magenta", .c = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .name = "orange", .c = .{ .r = 255, .g = 165, .b = 0 } },
};

/// Parse an X11-style colour: "#rgb", "#rrggbb", "rgb:r/g/b" (1-4 hex
/// digits per channel), a small set of names, and "grayNN"/"greyNN".
pub fn parseColor(text: []const u8) ?Color {
    const s = std.mem.trim(u8, text, " \t\"");
    if (s.len == 0) return null;

    if (s[0] == '#') {
        const hex = s[1..];
        if (hex.len == 0 or hex.len % 3 != 0 or hex.len > 12) return null;
        const d = hex.len / 3;
        return .{
            .r = hexChannel(hex[0..d]) orelse return null,
            .g = hexChannel(hex[d .. 2 * d]) orelse return null,
            .b = hexChannel(hex[2 * d ..]) orelse return null,
        };
    }

    if (std.ascii.startsWithIgnoreCase(s, "rgb:")) {
        var it = std.mem.splitScalar(u8, s[4..], '/');
        const r = it.next() orelse return null;
        const g = it.next() orelse return null;
        const b = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{
            .r = hexChannel(r) orelse return null,
            .g = hexChannel(g) orelse return null,
            .b = hexChannel(b) orelse return null,
        };
    }

    // grayNN / greyNN, NN in 0..100 (X11: gray50 == 127).
    if (s.len > 4 and (std.ascii.startsWithIgnoreCase(s, "gray") or std.ascii.startsWithIgnoreCase(s, "grey"))) {
        if (std.fmt.parseInt(u32, s[4..], 10)) |n| {
            if (n > 100) return null;
            const v: u8 = @intCast(n * 255 / 100);
            return .{ .r = v, .g = v, .b = v };
        } else |_| {}
    }

    for (named_colors) |nc| {
        if (std.ascii.eqlIgnoreCase(nc.name, s)) return nc.c;
    }
    return null;
}

fn hexChannel(digits: []const u8) ?u8 {
    if (digits.len == 0 or digits.len > 4) return null;
    const v = std.fmt.parseInt(u32, digits, 16) catch return null;
    var max: u32 = 1;
    for (digits) |_| max *= 16;
    max -= 1;
    return @intCast(v * 255 / max);
}

// ============================================================================
// Textures
// ============================================================================

pub const GradientDir = enum { horizontal, vertical, diagonal };

pub const PixmapMode = enum {
    tile, // tpixmap
    scale, // spixmap
    center, // cpixmap
    maximize, // mpixmap
};

pub const Texture = union(enum) {
    solid: Color,
    gradient: struct { dir: GradientDir, from: Color, to: Color },
    /// Multi-colour gradient: mhgradient / mvgradient / mdgradient.
    multi: struct { dir: GradientDir, colors: []const Color },
    pixmap: struct { mode: PixmapMode, path: []const u8, fallback: Color },
    /// A texture type we parse but do not render yet (igradient, thgradient,
    /// cgradient, ...). `fallback` keeps themes usable in the meantime.
    unsupported: struct { kind: []const u8, fallback: Color },

    pub fn solidColor(c: Color) Texture {
        return .{ .solid = c };
    }

    /// One representative colour, used for borders, text backgrounds and
    /// as fallback when a renderer cannot draw the real texture.
    pub fn baseColor(t: Texture) Color {
        return switch (t) {
            .solid => |c| c,
            .gradient => |g| g.from,
            .multi => |m| if (m.colors.len > 0) m.colors[0] else Color.black,
            .pixmap => |p| p.fallback,
            .unsupported => |u| u.fallback,
        };
    }
};

pub const ParseError = error{ BadTexture, OutOfMemory };

/// Parse a texture description from an already-parsed plist array, e.g.
/// the value of `FTitleBack`. A bare colour string is accepted as "solid".
pub fn parse(alloc: Allocator, v: plist.Value) ParseError!Texture {
    if (v.asString()) |s| {
        return .{ .solid = parseColor(s) orelse return error.BadTexture };
    }

    const it = v.items();
    if (it.len < 2) return error.BadTexture;
    const kind = it[0].asString() orelse return error.BadTexture;
    const eq = std.ascii.eqlIgnoreCase;

    if (eq(kind, "solid")) {
        return .{ .solid = try colorAt(it, 1) };
    }

    if (eq(kind, "hgradient") or eq(kind, "vgradient") or eq(kind, "dgradient")) {
        if (it.len < 3) return error.BadTexture;
        return .{ .gradient = .{
            .dir = dirOf(kind[0]),
            .from = try colorAt(it, 1),
            .to = try colorAt(it, 2),
        } };
    }

    if (kind.len == 10 and (kind[0] == 'm' or kind[0] == 'M') and eq(kind[2..], "gradient")) {
        // mhgradient / mvgradient / mdgradient
        const colors = try alloc.alloc(Color, it.len - 1);
        for (it[1..], 0..) |cv, i| {
            colors[i] = parseColor(cv.asString() orelse return error.BadTexture) orelse return error.BadTexture;
        }
        return .{ .multi = .{ .dir = dirOf(kind[1]), .colors = colors } };
    }

    if (kind.len == 7 and eq(kind[1..], "pixmap")) {
        const mode: PixmapMode = switch (std.ascii.toLower(kind[0])) {
            't' => .tile,
            's' => .scale,
            'c' => .center,
            'm' => .maximize,
            else => return error.BadTexture,
        };
        if (it.len < 3) return error.BadTexture;
        return .{ .pixmap = .{
            .mode = mode,
            .path = it[1].asString() orelse return error.BadTexture,
            .fallback = try colorAt(it, 2),
        } };
    }

    // Everything else: keep the first colour we can find.
    var fallback: Color = Color.black;
    for (it[1..]) |cv| {
        if (cv.asString()) |cs| {
            if (parseColor(cs)) |c| {
                fallback = c;
                break;
            }
        }
    }
    return .{ .unsupported = .{ .kind = kind, .fallback = fallback } };
}

fn colorAt(it: []const plist.Value, i: usize) ParseError!Color {
    if (i >= it.len) return error.BadTexture;
    const s = it[i].asString() orelse return error.BadTexture;
    return parseColor(s) orelse error.BadTexture;
}

fn dirOf(c: u8) GradientDir {
    return switch (std.ascii.toLower(c)) {
        'h' => .horizontal,
        'v' => .vertical,
        else => .diagonal,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "colours" {
    try std.testing.expectEqual(Color{ .r = 0xa6, .g = 0xa6, .b = 0xb6 }, parseColor("rgb:a6/a6/b6").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, parseColor("#ff0000").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, parseColor("#fff").?);
    try std.testing.expectEqual(@as(u8, 127), parseColor("gray50").?.r);
    try std.testing.expectEqual(@as(u8, 102), parseColor("gray40").?.g);
    try std.testing.expectEqual(Color.black, parseColor("black").?);
    try std.testing.expectEqual(Color.white, parseColor("\"white\"").?);
    try std.testing.expect(parseColor("nosuchcolour") == null);
    try std.testing.expect(parseColor("rgb:zz/00/00") == null);
}

test "premultiplied argb" {
    const half: Color = .{ .r = 255, .g = 0, .b = 0, .a = 128 };
    try std.testing.expectEqual(@as(u32, 0x80800000), half.argb());
    try std.testing.expectEqual(@as(u32, 0xff000000), Color.black.argb());
}

test "texture specs from real defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const solid = try parse(a, try plist.parse(a, "(solid, black)"));
    try std.testing.expectEqual(Color.black, solid.solid);

    const g = try parse(a, try plist.parse(a, "(dgradient, \"rgb:a6/a6/b6\", \"rgb:51/55/61\")"));
    try std.testing.expectEqual(GradientDir.diagonal, g.gradient.dir);
    try std.testing.expectEqual(@as(u8, 0x51), g.gradient.to.r);

    const m = try parse(a, try plist.parse(a, "(mhgradient, red, green, blue)"));
    try std.testing.expectEqual(@as(usize, 3), m.multi.colors.len);

    const p = try parse(a, try plist.parse(a, "(tpixmap, \"back.png\", gray50)"));
    try std.testing.expectEqual(PixmapMode.tile, p.pixmap.mode);
    try std.testing.expectEqualStrings("back.png", p.pixmap.path);

    const u = try parse(a, try plist.parse(a, "(igradient, white, black, 2, red, 3)"));
    try std.testing.expectEqualStrings("igradient", u.unsupported.kind);

    const bare = try parse(a, try plist.parse(a, "white"));
    try std.testing.expectEqual(Color.white, bare.solid);
}
