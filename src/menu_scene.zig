// SPDX-License-Identifier: GPL-3.0
//
// The root menu and the window list on the screen: one `wlr_scene_buffer` per
// open level (a menu and its submenus), drawn with cairo/pango like the Dock's
// tiles (the pixel buffer is wm_pixbuf.c). The state, the geometry and what a
// click asks for are in menu_model.zig; this file draws that, feeds it the
// pointer and the keys, and carries out what it asks for.
//
// While a menu is open it owns the pointer and the keyboard: `Cursor` asks
// `motion` / `button` / `axis` first, `Keyboard` asks `key` first, and a click
// away from the menu closes it and is used up (the window under it does not
// see it), as in Window Maker.
//
// The menu is drawn at scale 1 and shown at that size: on a scaled output it
// is a little soft (the Dock draws at the output scale; the menu does not yet).

const std = @import("std");
const log = std.log.scoped(.menu);

const wlr = @import("wlroots");

const model = @import("model.zig");
const action = model.action;
const config = model.config;
const proc = model.proc;
const types = model.types;

const gfx = @import("gfx.zig");
const menu_model = @import("menu_model.zig");
const dock_scene = @import("dock_scene.zig");
const Server = @import("server.zig").Server;

const wm_pixbuf_create = dock_scene.wm_pixbuf_create;

const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;

// The look: Window Maker's (NeXT) grey menus.
const col_bg = gfx.Color.rgb(0xaeaaae);
const col_light = gfx.Color.rgb(0xffffff);
const col_dark = gfx.Color.rgb(0x555555);
const col_text = gfx.Color.rgb(0x000000);
const col_disabled = gfx.Color.rgb(0x707070);
const col_hi_bg = gfx.Color.rgb(0x000000);
const col_hi_text = gfx.Color.rgb(0xffffff);
const col_title_top = gfx.Color.rgb(0x000000);
const col_title_bot = gfx.Color.rgb(0x444444);

/// What a menu was asked for (`menu_root`, `menu_windows`, a click on the desktop).
pub const Request = types.MenuRequest;

pub const MenuUi = struct {
    server: *Server,
    menu: menu_model.Menu,
    /// Above the windows, the panels and the Dock; below a screen lock.
    tree: *wlr.SceneTree,
    /// One scene buffer per level of `menu.levels`, by index.
    nodes: std.ArrayList(?*wlr.SceneBuffer) = .empty,

    pub fn create(server: *Server) !*MenuUi {
        const ui = try server.gpa.create(MenuUi);
        errdefer server.gpa.destroy(ui);
        ui.* = .{
            .server = server,
            .menu = .init(server.gpa),
            .tree = try server.scene.tree.createSceneTree(),
        };
        return ui;
    }

    pub fn destroy(ui: *MenuUi) void {
        ui.nodes.deinit(ui.server.gpa);
        ui.menu.deinit();
        ui.server.gpa.destroy(ui);
    }

    pub fn isOpen(ui: *const MenuUi) bool {
        return ui.menu.isOpen();
    }

    // ---- opening and closing ---------------------------------------------------

    /// Open at the pointer, on the output it is on.
    pub fn openAtPointer(ui: *MenuUi, req: Request) void {
        const server = ui.server;
        if (server.lock.locked) return;
        const x: i32 = @intFromFloat(server.cursor.wlr_cursor.x);
        const y: i32 = @intFromFloat(server.cursor.wlr_cursor.y);
        const bounds = ui.boundsAt(x, y) orelse return;
        const result = switch (req) {
            .root => ui.menu.openRoot(server.wm, bounds, x, y),
            .windows => ui.menu.openWindows(server.wm, bounds, x, y),
        };
        result catch |err| {
            switch (err) {
                error.NoMenu => log.warn("root menu: none loaded (see RootMenu in `wmaker-wl --paths`)", .{}),
                else => log.err("cannot build the menu: {t}", .{err}),
            }
            return;
        };
        // The keyboard belongs to the menu while it is open.
        server.seat.keyboardNotifyClearFocus();
        server.seat.pointerNotifyClearFocus();
        ui.sync();
    }

    /// The output rectangle (desk coordinates) at a point.
    fn boundsAt(ui: *MenuUi, x: i32, y: i32) ?types.Rect {
        const server = ui.server;
        const out = server.output_layout.outputAt(@floatFromInt(x), @floatFromInt(y)) orelse
            server.output_layout.outputAt(0, 0) orelse return null;
        var box: wlr.Box = undefined;
        server.output_layout.getBox(out, &box);
        return .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height };
    }

    pub fn closeMenu(ui: *MenuUi) void {
        if (!ui.menu.isOpen() and ui.menu.levels.items.len == 0) return;
        ui.menu.close();
        ui.sync();
        // The window that had the focus gets the keyboard back.
        ui.server.restoreKeyboardFocus();
        ui.server.cursor.refresh();
    }

    // ---- input -----------------------------------------------------------------

    /// The pointer moved. True: the menu has it.
    pub fn motion(ui: *MenuUi, x: f64, y: f64) bool {
        if (!ui.menu.isOpen()) return false;
        if (ui.menu.pointerMotion(@intFromFloat(x), @intFromFloat(y))) ui.sync();
        return true;
    }

    /// A button. True: the menu took it (every button, while it is open).
    pub fn button(ui: *MenuUi, x: f64, y: f64, btn: u32, pressed: bool) bool {
        if (!ui.menu.isOpen()) return false;
        // The release of a click that opened or closed the menu is used up too.
        if (!pressed) return true;
        const effect = ui.menu.click(@intFromFloat(x), @intFromFloat(y), btn == btn_left or btn == btn_right);
        ui.run(effect);
        return true;
    }

    pub fn axis(ui: *MenuUi, x: f64, y: f64, delta: f64) bool {
        if (!ui.menu.isOpen()) return false;
        const rows: i32 = if (delta > 0) menu_model.wheel_rows else if (delta < 0) -menu_model.wheel_rows else 0;
        if (rows != 0 and ui.menu.scroll(@intFromFloat(x), @intFromFloat(y), rows)) ui.sync();
        return true;
    }

    /// A key went down while the menu is open (keysyms of the press). It takes
    /// every key: the windows must not see what is typed into the menu.
    pub fn key(ui: *MenuUi, syms: []const u32) bool {
        if (!ui.menu.isOpen()) return false;
        for (syms) |sym| {
            const k: menu_model.Key = switch (sym) {
                0xff52 => .up,
                0xff54 => .down,
                0xff51 => .left,
                0xff53 => .right,
                0xff0d, 0xff8d => .enter,
                0xff1b => .escape,
                else => continue,
            };
            ui.run(ui.menu.key(k));
            break;
        }
        return true;
    }

    /// Carry out what a click or key asked for. The menu closes after
    /// anything that does something; a submenu opening only redraws.
    fn run(ui: *MenuUi, effect: menu_model.Effect) void {
        const server = ui.server;
        const wm = server.wm;
        switch (effect) {
            .none => {
                ui.sync();
                return;
            },
            // The model closed the menu already.
            .close => {
                ui.sync();
                ui.server.restoreKeyboardFocus();
                ui.server.cursor.refresh();
                return;
            },
            .exec => |cmd| {
                var tmp: std.heap.ArenaAllocator = .init(server.gpa);
                defer tmp.deinit();
                if (config.parseCommand(tmp.allocator(), cmd)) |argv| {
                    proc.spawn(wm, argv);
                } else |err| log.warn("EXEC `{s}` cannot be run: {t}", .{ cmd, err });
            },
            .shexec => |cmd| proc.spawnShell(wm, cmd),
            .focus_window => |w| {
                // Restores it when minimized, changes to its workspace, focuses.
                wm.dock_activate = w;
            },
            .goto_workspace => |i| ui.queue(.{ .workspace = i }),
            .builtin => |b| switch (b) {
                .exit, .shutdown => wm.quit = true,
                .workspace_next => ui.queue(.workspace_next),
                .workspace_prev => ui.queue(.workspace_prev),
                .show_all => ui.queue(.show_all),
                .hide_others => ui.queue(.hide_others),
                .refresh => server.requestFrames(),
                else => {},
            },
        }
        ui.closeMenu();
        server.scheduleManage();
    }

    fn queue(ui: *MenuUi, cmd: types.Command) void {
        const wm = ui.server.wm;
        wm.pending.append(wm.gpa, cmd) catch log.err("out of memory: a menu command is lost", .{});
    }

    // ---- drawing ---------------------------------------------------------------

    /// Bring the scene in line with the model: levels that appeared, moved,
    /// changed or went away.
    pub fn sync(ui: *MenuUi) void {
        const levels = ui.menu.levels.items;
        const gpa = ui.server.gpa;
        // One slot per level; a closed menu has none.
        while (ui.nodes.items.len < levels.len) ui.nodes.append(gpa, null) catch return;
        for (ui.nodes.items, 0..) |slot, i| {
            const open = i < levels.len and levels[i].open;
            if (!open) {
                if (slot) |node| node.node.setEnabled(false);
                continue;
            }
            const lvl = &levels[i];
            const node = slot orelse blk: {
                const n = ui.tree.createSceneBuffer(null) catch {
                    log.err("out of memory: a menu level is not shown", .{});
                    continue;
                };
                ui.nodes.items[i] = n;
                break :blk n;
            };
            if (lvl.dirty or !node.node.enabled) ui.draw(node, lvl);
            node.node.setPosition(lvl.x, lvl.y);
            node.node.setEnabled(true);
        }
        if (levels.len == 0) {
            for (ui.nodes.items) |slot| if (slot) |node| node.node.destroy();
            ui.nodes.clearRetainingCapacity();
        }
        ui.menu.clean();
    }

    fn draw(ui: *MenuUi, node: *wlr.SceneBuffer, lvl: *const menu_model.Level) void {
        const gpa = ui.server.gpa;
        const w: usize = @intCast(@max(lvl.w, 1));
        const h: usize = @intCast(@max(lvl.h, 1));
        const stride = w * 4;
        const bytes = gpa.alloc(u8, stride * h) catch return;
        defer gpa.free(bytes);
        @memset(bytes, 0);
        var cv = gfx.Canvas.initForData(bytes.ptr, @intCast(w), @intCast(h), @intCast(stride)) catch return;
        defer cv.deinit();
        paint(&cv, lvl);
        cv.flush();
        const buf = wm_pixbuf_create(@intCast(w), @intCast(h), bytes.ptr, stride) orelse return;
        node.setBuffer(buf);
        buf.drop();
        node.setDestSize(lvl.w, lvl.h);
    }
};

/// One level, as Window Maker draws it.
fn paint(cv: *gfx.Canvas, lvl: *const menu_model.Level) void {
    const title_h = menu_model.title_h;
    const item_h = menu_model.item_h;
    const pad_x = menu_model.pad_x;

    cv.clear(col_bg);
    cv.vGradient(1, 1, lvl.w - 2, title_h - 1, col_title_top, col_title_bot);
    const tw = gfx.measureText(lvl.title, gfx.fonts.menuTitle()).w;
    cv.drawText(lvl.title, @divTrunc(lvl.w - tw, 2), 3, gfx.fonts.menuTitle(), col_hi_text);

    const first = lvl.scroll;
    const last = @min(lvl.rows.len, first + menu_model.shown(lvl));
    for (lvl.rows[first..last], first..) |r, i| {
        const y = title_h + @as(i32, @intCast(i - first)) * item_h;
        const hot = r.enabled and lvl.hover != null and lvl.hover.? == i;
        if (hot) cv.fillRect(2, y, lvl.w - 4, item_h, col_hi_bg);
        const tc = if (hot) col_hi_text else if (r.enabled) col_text else col_disabled;
        cv.drawText(r.label, pad_x, y + 2, gfx.fonts.menuItem(), tc);
        if (r.shortcut) |s| {
            const sw = gfx.measureText(s, gfx.fonts.menuItem()).w;
            cv.drawText(s, lvl.w - sw - pad_x, y + 2, gfx.fonts.menuItem(), tc);
        }
        if (r.kind == .submenu) {
            const cx = lvl.w - pad_x;
            const cy = y + @divTrunc(item_h, 2);
            cv.fillRect(cx - 4, cy - 3, 2, 6, tc);
            cv.fillRect(cx - 2, cy - 2, 2, 4, tc);
            cv.fillRect(cx, cy - 1, 2, 2, tc);
        }
    }
    // A level that scrolls says so: a small arrow where there is more.
    if (first > 0) scrollArrow(cv, lvl.w - pad_x, title_h - 8, true);
    if (last < lvl.rows.len) scrollArrow(cv, lvl.w - pad_x, lvl.h - 9, false);
    cv.bevel(0, 0, lvl.w, lvl.h, col_light, col_dark);
}

fn scrollArrow(cv: *gfx.Canvas, cx: i32, y: i32, up: bool) void {
    const fx: f64 = @floatFromInt(cx);
    const fy: f64 = @floatFromInt(y);
    const pts: [3][2]f64 = if (up)
        .{ .{ fx - 4, fy + 5 }, .{ fx + 4, fy + 5 }, .{ fx, fy } }
    else
        .{ .{ fx - 4, fy }, .{ fx + 4, fy }, .{ fx, fy + 5 } };
    cv.fillPolygon(&pts, col_hi_text);
}
