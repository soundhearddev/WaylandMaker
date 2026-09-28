// SPDX-License-Identifier: 0BSD
//
// "Menu Preferences" demo panel -- visual port of upstream
// WPrefs.app/MenuPreferences.c's createPanel(): same frames, same
// positions, same official images (xpm/speed*.xpm, menualign*.xpm).
//
// DEMO ONLY: it shows every knob Window Maker offers for menus
// (scrolling speed = the menu "animation", submenu alignment, wrap,
// scroll-on-hover, vi keys) in a fixed example state. Nothing is read
// from or written to any config yet.

const std = @import("std");
const gfx = @import("gfx.zig");

const face = gfx.Color.rgb(0xaeaeae);
const black = gfx.Color.rgb(0x000000);
const font = "Sans 10";

pub const speed_count = 5;

/// Example state shown by the demo (upstream: showData()).
pub const State = struct {
    speed: usize = 2, // MenuScrollSpeed, 0 = slowest .. 4 = fastest
    align_submenus: bool = false, // AlignSubmenus
    wrap: bool = true, // WrapMenus
    scrollable: bool = true, // ScrollableMenus
    vi_keys: bool = false, // ViKeyMenus
};

pub const Images = struct {
    speed: [speed_count]gfx.Image,
    speed_sel: [speed_count]gfx.Image,
    align_no: gfx.Image, // menualign1
    align_yes: gfx.Image, // menualign2

    pub fn load() !Images {
        var im: Images = undefined;
        im.speed[0] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed0.png"));
        im.speed[1] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed1.png"));
        im.speed[2] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed2.png"));
        im.speed[3] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed3.png"));
        im.speed[4] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed4.png"));
        im.speed_sel[0] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed0s.png"));
        im.speed_sel[1] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed1s.png"));
        im.speed_sel[2] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed2s.png"));
        im.speed_sel[3] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed3s.png"));
        im.speed_sel[4] = try gfx.Image.fromPngBytes(@embedFile("assets/menu/speed4s.png"));
        im.align_no = try gfx.Image.fromPngBytes(@embedFile("assets/menu/menualign1.png"));
        im.align_yes = try gfx.Image.fromPngBytes(@embedFile("assets/menu/menualign2.png"));
        return im;
    }

    pub fn deinit(im: *Images) void {
        for (&im.speed) |*i| i.deinit();
        for (&im.speed_sel) |*i| i.deinit();
        im.align_no.deinit();
        im.align_yes.deinit();
    }
};

/// WMFrame with a title: groove border starting half a text line down,
/// title text interrupting the top edge.
fn frame(cv: *gfx.Canvas, x: i32, y: i32, w: i32, h: i32, title: ?[:0]const u8) void {
    const top: i32 = if (title != null) 7 else 0;
    cv.relief(x, y + top, w, h - top, .groove);
    if (title) |t| {
        const size = gfx.measureText(t, font);
        cv.fillRect(x + 8, y, size.w + 6, size.h, face);
        cv.drawText(t, x + 11, y, font, black);
    }
}

/// WMCreateSwitchButton look: small sunken box (with a filled mark when
/// on) followed by the label, vertically centred in `h`.
fn switchButton(cv: *gfx.Canvas, x: i32, y: i32, h: i32, label: [:0]const u8, on: bool) void {
    const box: i32 = 14;
    const by = y + @divTrunc(h - box, 2);
    cv.fillRect(x, by, box, box, face);
    cv.relief(x, by, box, box, .sunken);
    if (on) cv.fillRect(x + 4, by + 4, box - 8, box - 8, black);
    const th = gfx.measureText(label, font).h;
    cv.drawText(label, x + box + 8, y + @divTrunc(h - th, 2), font, black);
}

/// `ox`,`oy` = top-left of the panel box (the content frame + 2px, as
/// WMSetViewExpandsToParent(box, 2, 2, 2, 2) does upstream).
pub fn paint(cv: *gfx.Canvas, ox: i32, oy: i32, st: State, im: *const Images) void {
    // ---- Menu Scrolling Speed -------------------------------------------
    const sx = ox + 25;
    const sy = oy + 20;
    frame(cv, sx, sy, 235, 90, "Menu Scrolling Speed");
    var i: usize = 0;
    while (i < speed_count) : (i += 1) {
        const bx = sx + 15 + 40 * @as(i32, @intCast(i));
        const by = sy + 30;
        // WBBStateChangeMask, unbordered: selected shows the "s" image.
        const img = if (i == st.speed) im.speed_sel[i] else im.speed[i];
        cv.drawImage(img, bx + @divTrunc(40 - img.width, 2), by + @divTrunc(40 - img.height, 2));
    }

    // ---- Submenu Alignment ----------------------------------------------
    const ax = ox + 280;
    const ay = oy + 20;
    frame(cv, ax, ay, 220, 90, "Submenu Alignment");
    alignButton(cv, ax + 56, ay + 25, im.align_no, !st.align_submenus);
    alignButton(cv, ax + 120, ay + 25, im.align_yes, st.align_submenus);

    // ---- options ----------------------------------------------------------
    const px = ox + 25;
    const py = oy + 120;
    frame(cv, px, py, 475, 96, null);
    switchButton(cv, px + 25, py + 8, 32, "Always open submenus inside the screen, instead of scrolling.", st.wrap);
    switchButton(cv, px + 25, py + 34, 32, "Scroll off-screen menus when pointer is moved over them.", st.scrollable);
    switchButton(cv, px + 25, py + 58, 32, "Use h/j/k/l keys to select menu options.", st.vi_keys);
}

/// 48x48 WBTOnOff image button: pushed when on, raised when off.
fn alignButton(cv: *gfx.Canvas, x: i32, y: i32, img: gfx.Image, on: bool) void {
    cv.fillRect(x, y, 48, 48, face);
    cv.relief(x, y, 48, 48, if (on) .pushed else .raised);
    cv.drawImage(img, x + @divTrunc(48 - img.width, 2), y + @divTrunc(48 - img.height, 2));
}
