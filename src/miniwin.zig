// SPDX-License-Identifier: 0BSD
//
// The strip of minimized windows (Window Maker's "miniwindows" / icon yard):
// one tile per minimized window, in a row at the bottom edge of the primary
// output. A click on a tile brings the window back (ui.zig does that, with
// the same `UiAction.focus` the Windows menu and the Dock tiles use).
//
// Deliberately simple:
//
//   * Nothing is stored. The list is rebuilt from `wm.windows` on every
//     sync, so it can never disagree with `Window.minimized`.
//   * Oldest minimized window on the left, the newest on the right (the one
//     `restore` brings back first).
//   * At most `limit` tiles, so the row never reaches the Dock or the Clip
//     at the screen edges; if there are more, the NEWEST ones are shown
//     (the others stay reachable through the Windows menu / `show_all`).
//   * The strip does not reserve screen space.
//
// No Wayland types in here, like dock.zig and gfx.zig, so all of it is
// unit-testable without a compositor.

const std = @import("std");
const gfx = @import("gfx.zig");
const types = @import("types.zig");
const dock = @import("dock.zig");

/// Most tiles there can ever be.
pub const max_tiles: usize = 16;

/// Tiles kept free at each side of the row (room for the Dock column and the
/// Clip's tiles in the screen corners).
const edge_margin_tiles: i32 = 2;

const col_clear: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
const col_text = gfx.Color.rgb(0x000000);

/// Side of the icon inside a tile: half of it, so the title fits below.
fn iconSide() i32 {
    return @divTrunc(dock.tile, 2);
}

// ----------------------------------------------------------------------------
// The list
// ----------------------------------------------------------------------------

/// How many tiles fit on an output `out_w` px wide, 1 .. max_tiles.
pub fn limitFor(out_w: i32) usize {
    const room = @divTrunc(out_w, dock.tile) - 2 * edge_margin_tiles;
    return @intCast(std.math.clamp(room, 1, @as(i32, max_tiles)));
}

/// The minimized windows, oldest first, into `out`. At most `limit`
/// (clamped to `max_tiles`); when there are more, the newest are kept.
/// Returns how many were written.
pub fn collect(wm: *types.WindowManager, limit: usize, out: *[max_tiles]*types.Window) usize {
    const lim = @min(limit, max_tiles);
    if (lim == 0) return 0;
    var n: usize = 0;
    var it = wm.windows.first();
    while (it) |w| : (it = types.nextWindow(w, wm)) {
        if (!w.minimized or w.closed) continue;
        if (n == lim) {
            // Full: the new one only counts if it is newer than the oldest.
            if (w.min_order <= out[0].min_order) continue;
            var k: usize = 1;
            while (k < n) : (k += 1) out[k - 1] = out[k];
            n -= 1;
        }
        // Insert keeping the order (oldest first).
        var i = n;
        while (i > 0 and out[i - 1].min_order > w.min_order) : (i -= 1) out[i] = out[i - 1];
        out[i] = w;
        n += 1;
    }
    return n;
}

/// A cheap fingerprint of what is drawn (which windows, in which order, with
/// which title), so ui.zig only redraws when it changed.
pub fn signature(wins: []const *types.Window) u64 {
    var h = std.hash.Wyhash.init(0);
    for (wins) |w| {
        h.update(std.mem.asBytes(&w));
        h.update(w.title orelse "");
        h.update("\x00");
        h.update(w.app_id orelse "");
        h.update("\x00");
    }
    return h.final();
}

// ----------------------------------------------------------------------------
// Geometry
// ----------------------------------------------------------------------------

/// Global rectangle of the strip for `n` tiles: centred on the bottom edge
/// of `out`.
pub fn rectFor(out: types.Rect, n: usize) types.Rect {
    const w: i32 = @as(i32, @intCast(n)) * dock.tile;
    return .{
        .x = out.x + @divTrunc(out.w - w, 2),
        .y = out.y + out.h - dock.tile,
        .w = w,
        .h = dock.tile,
    };
}

/// The tile under a surface-local point, if any.
pub fn tileAt(n: usize, x: i32, y: i32) ?usize {
    if (x < 0 or y < 0 or y >= dock.tile) return null;
    const i: usize = @intCast(@divTrunc(x, dock.tile));
    return if (i < n) i else null;
}

// ----------------------------------------------------------------------------
// Drawing
// ----------------------------------------------------------------------------

/// The first character of `s` (upper-cased when it is plain ASCII), as a
/// NUL-terminated string in `buf`; "?" for an empty `s`.
fn firstChar(buf: *[8:0]u8, s: []const u8) [:0]const u8 {
    @memset(buf[0..8], 0);
    if (s.len == 0) {
        buf[0] = '?';
        return buf[0..1 :0];
    }
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    const n = @min(@as(usize, len), s.len, 4);
    @memcpy(buf[0..n], s[0..n]);
    if (n == 1) buf[0] = std.ascii.toUpper(buf[0]);
    // A NUL inside would cut the letter off: show "?" instead.
    if (std.mem.indexOfScalar(u8, buf[0..n], 0) != null) {
        @memset(buf[0..8], 0);
        buf[0] = '?';
        return buf[0..1 :0];
    }
    return buf[0..n :0];
}

/// `text` cut (never inside a UTF-8 character) until it is at most `max_w`
/// px wide in `font`. Returns a slice of `buf`.
fn fitLabel(buf: *[24:0]u8, text: []const u8, font: [:0]const u8, max_w: i32) [:0]const u8 {
    var label = dock.clipName(buf, text);
    while (label.len > 0 and gfx.measureText(label, font).w > max_w) {
        var end = label.len - 1;
        while (end > 0 and (label[end] & 0xC0) == 0x80) end -= 1;
        buf[end] = 0;
        label = buf[0..end :0];
    }
    return label;
}

/// One miniwindow tile at (x, y).
fn drawTile(cv: *gfx.Canvas, x: i32, y: i32, w: *const types.Window, icon: ?gfx.Icon, hot: bool) void {
    dock.drawFrame(cv, x, y, hot, null, null);

    const name: []const u8 = w.title orelse w.app_id orelse "";
    const side = iconSide();
    const ix = x + @divTrunc(dock.tile - side, 2);
    const iy = y + 6;
    if (icon) |ic| {
        cv.drawIcon(ic, ix, iy, side);
    } else {
        dock.drawPlaceholder(cv, ix, iy, side);
    }

    // The title below, cut so it fits the tile.
    var label_buf: [24:0]u8 = undefined;
    const font = gfx.fonts.dockLabel();
    const label = fitLabel(&label_buf, name, font, dock.tile - 8);
    dock.drawCentered(cv, label, x, y + dock.tile - 20, dock.tile, font, col_text);
}

/// The whole strip: `wins.len` tiles side by side. `icons` is parallel to
/// `wins` (null = no icon known). Everything outside the tiles is transparent.
pub fn draw(cv: *gfx.Canvas, wins: []const *types.Window, icons: []const ?gfx.Icon, hover: ?usize) void {
    cv.clear(col_clear);
    for (wins, 0..) |w, i| {
        const ic: ?gfx.Icon = if (i < icons.len) icons[i] else null;
        drawTile(cv, @as(i32, @intCast(i)) * dock.tile, 0, w, ic, hover != null and hover.? == i);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "limitFor keeps two tiles free at each side, and always allows one" {
    const t = dock.tile;
    try std.testing.expectEqual(@as(usize, 1), limitFor(0));
    try std.testing.expectEqual(@as(usize, 1), limitFor(3 * t));
    try std.testing.expectEqual(@as(usize, 1), limitFor(5 * t));
    try std.testing.expectEqual(@as(usize, 2), limitFor(6 * t));
    try std.testing.expectEqual(max_tiles, limitFor(1000 * t));
}

test "rectFor centres the row on the bottom edge" {
    const t = dock.tile;
    const out: types.Rect = .{ .x = 100, .y = 50, .w = 1920, .h = 1080 };
    const r = rectFor(out, 3);
    try std.testing.expectEqual(3 * t, r.w);
    try std.testing.expectEqual(t, r.h);
    try std.testing.expectEqual(100 + @divTrunc(1920 - 3 * t, 2), r.x);
    try std.testing.expectEqual(50 + 1080 - t, r.y);
}

test "tileAt: tiles side by side, nothing outside the row" {
    const t = dock.tile;
    try std.testing.expectEqual(@as(?usize, 0), tileAt(3, 0, 0));
    try std.testing.expectEqual(@as(?usize, 0), tileAt(3, t - 1, t - 1));
    try std.testing.expectEqual(@as(?usize, 1), tileAt(3, t, 10));
    try std.testing.expectEqual(@as(?usize, 2), tileAt(3, 3 * t - 1, 10));
    try std.testing.expectEqual(@as(?usize, null), tileAt(3, 3 * t, 10));
    try std.testing.expectEqual(@as(?usize, null), tileAt(3, -1, 10));
    try std.testing.expectEqual(@as(?usize, null), tileAt(3, 10, -1));
    try std.testing.expectEqual(@as(?usize, null), tileAt(3, 10, t));
    try std.testing.expectEqual(@as(?usize, null), tileAt(0, 0, 0));
}

test "firstChar: upper-cased ASCII, whole UTF-8 characters, '?' for nothing" {
    var buf: [8:0]u8 = undefined;
    try std.testing.expectEqualStrings("F", firstChar(&buf, "firefox"));
    try std.testing.expectEqualStrings("?", firstChar(&buf, ""));
    try std.testing.expectEqualStrings("Ä", firstChar(&buf, "Äpfel"));
    try std.testing.expectEqualStrings("?", firstChar(&buf, "\x00abc"));
}
