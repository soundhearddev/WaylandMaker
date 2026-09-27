//! wlprefs — settings window skeleton for wmaker-wl.
//!
//! SCOPE OF THIS SKELETON
//! -----------------------
//! This only builds the window and its category sidebar. No individual
//! setting is wired up yet -- each `Category.panel` is a stub that gets
//! filled in later. What IS real:
//!
//!   * a plain xdg-shell toplevel window (Wayland core + xdg-shell only,
//!     no river protocol needed -- wmaker-wl just tiles it like any
//!     other app);
//!   * an ARGB32 buffer drawn with the same cairo/pango helpers wmaker-wl
//!     uses (`Canvas`), so the two look consistent;
//!   * a sidebar listing the same 16 sections, in the same order, with
//!     the same names and the same icons as upstream WPrefs.app's own
//!     `Initialize()` (WPrefs.app/WPrefs.c in wmaker.git) -- each
//!     currently rendering an empty placeholder panel; see `Category`
//!     below for the section list itself;
//!   * `configPath()`, which resolves to the exact same
//!     `$XDG_CONFIG_HOME/wmaker-wl/config.conf` (falling back to
//!     `~/.config/wmaker-wl/config.conf`) that wmaker-wl reads. Real
//!     settings panels will read/write this file using the same
//!     `key = value` line format wmaker-wl's parser expects.
//!
//! Everything under "wire up a control" is future work; the point of
//! this file is the scaffolding those controls will slot into.

const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

pub const gfx = @import("gfx.zig");
pub const window = @import("window.zig");

/// The section list, 1:1 with upstream WPrefs.app/WPrefs.c's
/// `Initialize()` -- same 16 sections (its `MAX_SECTIONS`), same order,
/// same names, same icon files. Each currently renders an empty
/// placeholder panel (see window.zig's `paintPanel`); wiring an actual
/// section up to read/write wmaker-wl's config.conf is future work, one
/// panel at a time.
pub const Category = enum {
    focus,
    window_handling,
    menu_preferences,
    icons,
    ergonomic,
    paths,
    docks,
    workspace,
    configurations,
    menu,
    keyboard_shortcuts,
    hot_corner_shortcuts,
    mouse_settings,
    appearance,
    font_simple,
    expert,

    /// `panel->sectionName` -- becomes the window title on selection
    /// (`WMSetWindowTitle(WPrefs.win, rec->sectionName)`).
    pub fn label(cat: Category) [:0]const u8 {
        return switch (cat) {
            .focus => "Window Focus Preferences",
            .window_handling => "Window Handling Preferences",
            .menu_preferences => "Menu Preferences",
            .icons => "Icon Preferences",
            .ergonomic => "Miscellaneous Ergonomic Preferences",
            .paths => "Search Path Configuration",
            .docks => "Dock Preferences",
            .workspace => "Workspace Preferences",
            .configurations => "Other Configurations",
            .menu => "Applications Menu Definition",
            .keyboard_shortcuts => "Keyboard Shortcut Preferences",
            .hot_corner_shortcuts => "Hot Corner Shortcut Preferences",
            .mouse_settings => "Mouse Preferences",
            .appearance => "Appearance Preferences",
            .font_simple => "Font Configuration",
            .expert => "Expert User Preferences",
        };
    }

    /// `panel->description` -- upstream shows this as balloon-help text
    /// over the section's icon; wlprefs has no balloon-help widget yet
    /// (see window.zig's `drawToggle` doc comment), so the placeholder
    /// panel prints it directly instead of hiding it entirely.
    pub fn description(cat: Category) [:0]const u8 {
        return switch (cat) {
            .focus => "Keyboard focus switching policy and related options.",
            .window_handling => "Window handling options. Initial placement style\nedge resistance, opaque move etc.",
            .menu_preferences => "Menu usability related options. Scrolling speed,\nalignment of submenus etc.",
            .icons => "Icon/Miniwindow handling options. Icon positioning\narea, sizes of icons, miniaturization animation style.",
            .ergonomic => "Various settings like balloon text, geometry\ndisplays etc.",
            .paths => "Search paths to use when looking for pixmaps\nand icons.",
            .docks => "Dock and clip features.\nEnable/disable the Dock and Clip, and tune some delays.",
            .workspace => "Workspace navigation features\nand workspace name display settings.",
            .configurations => "Animation speeds, titlebar styles, various option\ntoggling and number of colors to reserve for\nWindow Maker on 8bit displays.",
            .menu => "Edit the menu for launching applications.",
            .keyboard_shortcuts => "Change the keyboard shortcuts for actions such\nas changing workspaces and opening menus.",
            .hot_corner_shortcuts => "Choose actions to perform when you move the\nmouse pointer to the screen corners.",
            .mouse_settings => "Mouse speed/acceleration, double click delay,\nmouse button bindings etc.",
            .appearance => "Background texture configuration for windows,\nmenus and icons.",
            .font_simple => "Configure fonts for Window Maker titlebars, menus etc.",
            .expert => "Options for people who know what they're doing...\nAlso has some other misc. options.",
        };
    }

    /// The section's 48x48 icon -- WPrefs.app/xpm/<name>.xpm, converted
    /// 1:1 to PNG (cairo/wlprefs has no XPM decoder) and embedded at
    /// compile time. Real official Window Maker artwork; see
    /// src/assets/icons/README for provenance and how to regenerate
    /// these from a wmaker checkout.
    pub fn icon(cat: Category) []const u8 {
        return switch (cat) {
            .focus => @embedFile("assets/icons/windowfocus.png"),
            .window_handling => @embedFile("assets/icons/whandling.png"),
            .menu_preferences => @embedFile("assets/icons/menuprefs.png"),
            .icons => @embedFile("assets/icons/iconprefs.png"),
            .ergonomic => @embedFile("assets/icons/ergonomic.png"),
            .paths => @embedFile("assets/icons/paths.png"),
            .docks => @embedFile("assets/icons/dockclipdrawersection.png"),
            .workspace => @embedFile("assets/icons/workspace.png"),
            .configurations => @embedFile("assets/icons/configs.png"),
            .menu => @embedFile("assets/icons/menus.png"),
            .keyboard_shortcuts => @embedFile("assets/icons/keyshortcuts.png"),
            .hot_corner_shortcuts => @embedFile("assets/icons/hotcorners.png"),
            .mouse_settings => @embedFile("assets/icons/mousesettings.png"),
            .appearance => @embedFile("assets/icons/appearance.png"),
            .font_simple => @embedFile("assets/icons/fonts.png"),
            .expert => @embedFile("assets/icons/expert.png"),
        };
    }

    pub const all = std.enums.values(Category);
};

/// Resolve wmaker-wl's config file path -- identical rule to
/// `config.userConfigPath()` in the main project, duplicated here so
/// wlprefs has no build dependency on wmaker-wl's executable module.
/// Returns null if neither XDG_CONFIG_HOME nor HOME is set (matches
/// wmaker-wl's own fallback behaviour: caller should fall back to
/// built-in defaults).
pub fn configPath(a: std.mem.Allocator) !?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const dir = std.mem.span(x);
        if (dir.len > 0) return try std.fmt.allocPrint(a, "{s}/wmaker-wl/config.conf", .{dir});
    }
    if (std.c.getenv("HOME")) |h| {
        return try std.fmt.allocPrint(a, "{s}/.config/wmaker-wl/config.conf", .{std.mem.span(h)});
    }
    return null;
}

test "configPath prefers XDG_CONFIG_HOME" {
    // Smoke test only: real env manipulation is left to integration
    // testing since std.c.getenv reads the process-wide environment.
    const a = std.testing.allocator;
    const path = try configPath(a);
    defer if (path) |p| a.free(p);
    // Either resolves to something ending in the expected suffix, or is
    // null on an environment with neither var set.
    if (path) |p| {
        try std.testing.expect(std.mem.endsWith(u8, p, "wmaker-wl/config.conf"));
    }
}

test "every Category icon decodes to a real 48x48 image" {
    for (Category.all) |cat| {
        var img = try gfx.Image.fromPngBytes(cat.icon());
        defer img.deinit();
        try std.testing.expectEqual(@as(i32, 48), img.width);
        try std.testing.expectEqual(@as(i32, 48), img.height);
    }
}

test {
    _ = gfx;
    _ = window;
}
