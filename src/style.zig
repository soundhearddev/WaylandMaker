// SPDX-License-Identifier: GPL-3.0
//
// The look of what wmaker-wl draws itself: the Dock, the Clip and the Drawers
// (and, once they are ported, the menus and title bars).
//
// Window Maker keeps its look apart from its behaviour: a style is a handful
// of named textures, colours and fonts that can be swapped without touching
// anything else. Here the same idea:
//
//   config.lua / Themes/NAME.lua   set the options (`tile_from`, `font_dock`, ...)
//         |
//         v
//   config.Config                  the values, one reload = one set
//         |  style.apply(cfg)      once per (re)load, from boot.loadModel
//         v
//   style.palette, gfx.fonts       what the drawing code reads
//
// The drawing code never sees the Config: it reads `palette` and the fonts,
// copied out of the config arena, so a reload that frees the old arena can
// never leave a dangling pointer behind (the same rule as `gfx.fonts`).
// The tile cache (dock_scene) is dropped on every reload, so a new look shows
// up with the next `reload_config` / SIGHUP and nothing else needs telling.
//
// The defaults are Window Maker's NeXT look, pixel for pixel what dock_draw
// had hard-coded before.

const std = @import("std");
const config = @import("config.zig");
const gfx = @import("gfx.zig");

const Color = gfx.Color;

/// Every colour the Dock draws with. Overlays that are not part of a theme
/// (the dark raster of a launching tile, the translucent gap, the fade) stay
/// in dock_draw.zig.
pub const Palette = struct {
    tile_from: Color = Color.rgb(0xc6c2c6),
    tile_to: Color = Color.rgb(0x9a969a),
    tile_hot_from: Color = Color.rgb(0xdedade),
    tile_hot_to: Color = Color.rgb(0xaeaaae),
    logo_from: Color = Color.rgb(0x5a5a62),
    logo_to: Color = Color.rgb(0x1e1e24),
    logo_text: Color = Color.rgb(0xffffff),
    text: Color = Color.rgb(0x000000),
    light: Color = Color.rgb(0xffffff),
    dark: Color = Color.rgb(0x555555),
    arrow: Color = Color.rgb(0x303030),
    arrow_hot: Color = Color.rgb(0xffffff),

    pub fn fromConfig(cfg: *const config.Config) Palette {
        return .{
            .tile_from = Color.rgb(cfg.tile_from),
            .tile_to = Color.rgb(cfg.tile_to),
            .tile_hot_from = Color.rgb(cfg.tile_hot_from),
            .tile_hot_to = Color.rgb(cfg.tile_hot_to),
            .logo_from = Color.rgb(cfg.logo_from),
            .logo_to = Color.rgb(cfg.logo_to),
            .logo_text = Color.rgb(cfg.logo_text),
            .text = Color.rgb(cfg.tile_text),
            .light = Color.rgb(cfg.bevel_light),
            .dark = Color.rgb(cfg.bevel_dark),
            .arrow = Color.rgb(cfg.arrow),
            .arrow_hot = Color.rgb(cfg.arrow_hot),
        };
    }
};

/// What is drawn with right now. Process-wide, replaced by `apply`.
pub var palette: Palette = .{};

/// Take the look out of `cfg`: the palette and every font. Call it whenever a
/// config has been loaded, before anything is drawn with it.
pub fn apply(cfg: *const config.Config) void {
    palette = Palette.fromConfig(cfg);
    gfx.fonts.set(cfg.font_menu_title, cfg.font_menu, cfg.font_dock);
    gfx.fonts.setDockFaces(cfg.font_dock_logo, cfg.font_dock_number);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn sameColor(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "the default config gives the NeXT palette dock_draw used to hard-code" {
    var cfg: config.Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    const p = Palette.fromConfig(&cfg);
    const d: Palette = .{};
    try std.testing.expect(sameColor(p.tile_from, d.tile_from));
    try std.testing.expect(sameColor(p.tile_to, d.tile_to));
    try std.testing.expect(sameColor(p.tile_hot_from, d.tile_hot_from));
    try std.testing.expect(sameColor(p.tile_hot_to, d.tile_hot_to));
    try std.testing.expect(sameColor(p.logo_from, d.logo_from));
    try std.testing.expect(sameColor(p.logo_to, d.logo_to));
    try std.testing.expect(sameColor(p.logo_text, d.logo_text));
    try std.testing.expect(sameColor(p.text, d.text));
    try std.testing.expect(sameColor(p.light, d.light));
    try std.testing.expect(sameColor(p.dark, d.dark));
    try std.testing.expect(sameColor(p.arrow, d.arrow));
    try std.testing.expect(sameColor(p.arrow_hot, d.arrow_hot));
}

test "apply takes colours and fonts from the config" {
    const saved_palette = palette;
    const saved_fonts = gfx.fonts;
    defer {
        palette = saved_palette;
        gfx.fonts = saved_fonts;
    }

    var cfg: config.Config = .{ .arena = .init(std.testing.allocator) };
    defer cfg.deinit();
    cfg.tile_from = 0x102030;
    cfg.bevel_dark = 0xff0000;
    cfg.font_menu = "Serif 11";
    cfg.font_dock = "Mono 7";
    cfg.font_dock_logo = "Serif Bold 30";
    cfg.font_dock_number = "Serif Bold 12";
    apply(&cfg);

    try std.testing.expect(sameColor(palette.tile_from, Color.rgb(0x102030)));
    try std.testing.expect(sameColor(palette.dark, Color.rgb(0xff0000)));
    try std.testing.expectEqualStrings("Serif 11", gfx.fonts.menuItem());
    try std.testing.expectEqualStrings("Mono 7", gfx.fonts.dockLabel());
    try std.testing.expectEqualStrings("Serif Bold 30", gfx.fonts.dockLogo());
    try std.testing.expectEqualStrings("Serif Bold 12", gfx.fonts.dockNumber());
}
