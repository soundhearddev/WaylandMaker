//! wlprefs -- the settings window of wmaker-wl, modelled on Window Maker's
//! WPrefs.app.
//!
//!   * a plain xdg-shell toplevel (Wayland core + xdg-shell only; wmaker-wl
//!     tiles it like any other app);
//!   * the same 16 sections, in the same order, with the same names and
//!     icons as upstream WPrefs.app's `Initialize()` (see `Category`);
//!   * REAL pages for everything wmaker-wl has a setting for: focus, window
//!     handling, workspaces, appearance, mouse, default applications,
//!     Dock and Clip, session; a read-only list of the key bindings in
//!     effect. Sections without a counterpart say why instead of showing
//!     dead controls;
//!   * it edits exactly the file wmaker-wl reads (`$XDG_CONFIG_HOME/
//!     wmaker-wl/config.conf`), touching only the lines of the keys the user
//!     changed -- comments, binds and unknown keys stay (see prefs.zig and
//!     settings.zig), and the compositor is told to reload afterwards.

const std = @import("std");
const wayland = @import("wayland");
const xkb = @import("xkbcommon");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

pub const gfx = @import("gfx.zig");
pub const window = @import("window.zig");
pub const settings = @import("settings.zig");
pub const prefs = @import("prefs.zig");
pub const configfile = @import("configfile.zig");
pub const icons = @import("icons.zig");
pub const binds = @import("binds.zig");

pub const version_string = "0.2.0";

/// The section list, 1:1 with upstream WPrefs.app/WPrefs.c's
/// `Initialize()` -- same 16 sections (its `MAX_SECTIONS`), same order,
/// same names, same icon files. `window.zig`'s `runPanel` says which of them
/// have a page; the others show why they have none.
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
    /// over the section's icon; wlprefs has no balloon-help widget yet.
    pub fn description(cat: Category) [:0]const u8 {
        return switch (cat) {
            .focus => "Keyboard focus switching policy and related options.",
            .window_handling => "Window handling options. Initial placement style\nedge resistance, opaque move etc.",
            .menu_preferences => "Menu usability related options. Scrolling speed,\nalignment of submenus etc.",
            .icons => "Icon/Miniwindow handling options. Icon positioning\narea, sizes of icons, miniaturization animation style.",
            .ergonomic => "Various settings like balloon text, geometry\ndisplays etc.",
            .paths => "Search paths to use when looking for pixmaps\nand icons.",
            .docks => "Dock and Clip features.\nShow or hide them, choose their edge or corner and level.",
            .workspace => "Workspace navigation features\nand workspace name display settings.",
            .configurations => "Session and compatibility: DockApps, autostart script,\nreading Window Maker's own files.",
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
    _ = @import("panel_menu.zig");
    _ = @import("panels.zig");
    _ = @import("settings.zig");
    _ = @import("configfile.zig");
    _ = @import("icons.zig");
    _ = @import("binds.zig");
    _ = @import("actions.zig");
    _ = @import("prefs.zig");
}
