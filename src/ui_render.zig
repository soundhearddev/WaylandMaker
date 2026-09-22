// SPDX-License-Identifier: 0BSD
//
// UI Rendering: menus, titlebars, dock.
// Phase 3 (titlebars), Phase 4 (root menu), Phase 5 (dock).

const std = @import("std");
const wm_menu = @import("wm_menu.zig");
const gfx = @import("gfx.zig");

pub const RootMenuState = struct {
    visible: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 250,
    height: i32 = 400,

    surface: ?gfx.Surface = null,
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) RootMenuState {
        return .{ .alloc = alloc };
    }

    pub fn destroy(self: *RootMenuState) void {
        if (self.surface) |*surf| {
            surf.destroy(self.alloc);
            self.surface = null;
        }
    }

    pub fn render(self: *RootMenuState, menu: ?*const wm_menu.Menu) !void {
        if (menu == null) return;

        // Create Cairo surface if not exists
        if (self.surface == null) {
            self.surface = try gfx.Surface.create(self.alloc, self.width, self.height);
        }

        const surf = &(self.surface.?);

        // Clear background
        const bg = gfx.Color{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.95 };
        surf.clear(bg);

        // TODO: Recursively render menu items
        // TODO: Handle focus/highlight state
        // TODO: Draw SHORTCUT hints

        surf.flush();
    }

    pub fn setPosition(self: *RootMenuState, x: i32, y: i32) void {
        self.x = x;
        self.y = y;
    }

    pub fn show(self: *RootMenuState) void {
        self.visible = true;
    }

    pub fn hide(self: *RootMenuState) void {
        self.visible = false;
    }
};

pub const TitlebarStyle = struct {
    height: i32 = 22,
    border_width: i32 = 1,
    bg_focused: gfx.Color = gfx.Color{ .r = 0.0, .g = 0.0, .b = 0.0 }, // black
    bg_unfocused: gfx.Color = gfx.Color{ .r = 0.5, .g = 0.5, .b = 0.5 }, // gray
    text_color: gfx.Color = gfx.Color{ .r = 1.0, .g = 1.0, .b = 1.0 }, // white
};

pub fn renderTitlebar(
    surf: *gfx.Surface,
    rect: gfx.Rect,
    title: ?[]const u8,
    style: TitlebarStyle,
    focused: bool,
) void {
    _ = title;
    const bg = if (focused) style.bg_focused else style.bg_unfocused;
    surf.fillRect(rect, bg);

    // TODO: Draw title text centered
    // TODO: Draw minimize/close buttons
}

test "root menu state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var menu = RootMenuState.create(alloc);
    defer menu.destroy();

    menu.show();
    menu.setPosition(100, 100);
}
