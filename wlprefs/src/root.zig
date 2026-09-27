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
//!   * a sidebar listing the categories that mirror wmaker-wl's
//!     `Config` struct sections (see ../../src/config.zig), each
//!     currently rendering an empty placeholder panel;
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

/// Sections of wmaker-wl's config.conf that wlprefs will eventually expose
/// as editable panels. Kept in the same order/naming as the `// ---- foo
/// ---` section comments in wmaker-wl's src/config.zig so the two stay
/// easy to cross-reference while filling panels in.
pub const Category = enum {
    layout,
    look,
    workspaces,
    programs,
    bindings,
    wmaker_compat,

    pub fn label(cat: Category) [:0]const u8 {
        return switch (cat) {
            .layout => "Layout",
            .look => "Look",
            .workspaces => "Workspaces",
            .programs => "Programs",
            .bindings => "Key Bindings",
            .wmaker_compat => "WindowMaker Compat",
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

test {
    _ = gfx;
    _ = window;
}
