// SPDX-License-Identifier: 0BSD
//
// Desktop UI: a background shell surface that catches clicks on the empty
// desktop, and the root menu (also a shell surface) drawn with cairo/pango.
//
//   right click on the desktop  -> root menu
//   middle click on the desktop -> window list
//   left click / Esc            -> close menu
//
// Shell surfaces are river's way to show window-manager UI. They receive
// normal wl_pointer events directly. Windows are stacked above the
// background node, so a click only reaches it on free desktop.
//
// Protocol rules honoured here:
//   * get_shell_surface takes a wl_surface WITHOUT buffer/role;
//   * every shell surface must be committed once before render_finish
//     (no_commit error otherwise) -> we attach + commit right after creating;
//   * node.setPosition / placeTop are rendering state: manage or render only;
//   * focus_shell_surface is management state: manage only.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const gfx = @import("gfx.zig");
const shm = @import("shm.zig");
const wm_menu = @import("wm_menu.zig");
const proc = @import("process.zig");
const workspace = @import("workspace.zig");

const WindowManager = types.WindowManager;

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

// Window Maker-ish metrics (NeXT look).
const font: [:0]const u8 = "Sans Bold 10";
const font_item: [:0]const u8 = "Sans 10";
const title_h: i32 = 22;
const item_h: i32 = 20;
const pad_x: i32 = 10;
const arrow_w: i32 = 14;

const col_bg = gfx.Color.rgb(0xaeaaae);
const col_light = gfx.Color.rgb(0xffffff);
const col_dark = gfx.Color.rgb(0x555555);
const col_text = gfx.Color.rgb(0x000000);
const col_disabled = gfx.Color.rgb(0x707070);
const col_hi_bg = gfx.Color.rgb(0x000000);
const col_hi_text = gfx.Color.rgb(0xffffff);
const col_title_top = gfx.Color.rgb(0x000000);
const col_title_bot = gfx.Color.rgb(0x333333);

// ----------------------------------------------------------------------------
// Dynamic entries (window list / workspaces)
// ----------------------------------------------------------------------------

/// One row as drawn. Built fresh whenever a menu opens.
const Row = struct {
    label: [:0]const u8,
    shortcut: ?[:0]const u8 = null,
    enabled: bool = true,
    kind: union(enum) {
        exec: []const u8,
        shexec: []const u8,
        builtin: wm_menu.Builtin,
        submenu: *const Level,
        focus_window: *types.Window,
        goto_workspace: u32,
    },
};

/// One open (cascaded) menu level.
const Level = struct {
    title: [:0]const u8,
    rows: []Row,
    /// Position of the menu's top-left in global coordinates.
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    hover: ?usize = null,
};

// ----------------------------------------------------------------------------
// A shell surface with its own shm buffer
// ----------------------------------------------------------------------------

const Panel = struct {
    surface: *wl.Surface,
    shell: *river.ShellSurfaceV1,
    node: *river.NodeV1,
    buf: shm.Buffer,
    canvas: gfx.Canvas,
    x: i32 = 0,
    y: i32 = 0,
    shown: bool = false,
    committed: bool = false,

    fn create(ui: *Ui, w: i32, h: i32) !Panel {
        const surface = try ui.compositor.createSurface();
        errdefer surface.destroy();
        const shell = try ui.wm.obj.getShellSurface(surface);
        errdefer shell.destroy();
        const node = try shell.getNode();
        errdefer node.destroy();
        var buf = try shm.Buffer.create(ui.shm, w, h);
        errdefer buf.destroy();
        const canvas = try gfx.Canvas.initForData(buf.data.ptr, w, h, buf.stride);
        return .{ .surface = surface, .shell = shell, .node = node, .buf = buf, .canvas = canvas };
    }

    fn destroy(p: *Panel) void {
        p.canvas.deinit();
        p.buf.destroy();
        p.node.destroy();
        p.shell.destroy();
        p.surface.destroy();
    }

    fn commit(p: *Panel) void {
        p.canvas.flush();
        p.surface.attach(p.buf.buffer, 0, 0);
        p.surface.damageBuffer(0, 0, p.buf.width, p.buf.height);
        p.surface.commit();
        p.committed = true;
    }
};

// ----------------------------------------------------------------------------
// Ui
// ----------------------------------------------------------------------------

pub const Ui = struct {
    wm: *WindowManager,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,

    /// Desktop catcher, one per output (created lazily, output-sized).
    background: std.ArrayList(Background) = .empty,

    /// Open menu panels, outermost first. Empty = no menu.
    panels: std.ArrayList(OpenLevel) = .empty,
    /// Arena for rows/labels of the currently open menu.
    menu_arena: ?std.heap.ArenaAllocator = null,

    /// Where the pointer is inside which surface (surface-local).
    focus_surface: ?*wl.Surface = null,
    px: i32 = 0,
    py: i32 = 0,

    /// Something to do in the next manage sequence.
    want_focus_menu: bool = false,
    want_layout: bool = false,

    const Background = struct {
        output: *types.Output,
        panel: Panel,
        w: i32,
        h: i32,
    };

    const OpenLevel = struct {
        level: *Level,
        panel: Panel,
    };

    pub fn init(wm: *WindowManager, compositor: *wl.Compositor, shm_g: *wl.Shm) Ui {
        return .{ .wm = wm, .compositor = compositor, .shm = shm_g };
    }

    pub fn bindSeat(ui: *Ui, seat: *wl.Seat) void {
        ui.seat = seat;
        seat.setListener(*Ui, seatListener, ui);
    }

    // ---- wl_seat ----------------------------------------------------------

    fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, ui: *Ui) void {
        switch (event) {
            .capabilities => |c| {
                if (c.capabilities.pointer and ui.pointer == null) {
                    const p = seat.getPointer() catch return;
                    ui.pointer = p;
                    p.setListener(*Ui, pointerListener, ui);
                }
                if (c.capabilities.keyboard and ui.keyboard == null) {
                    const k = seat.getKeyboard() catch return;
                    ui.keyboard = k;
                    k.setListener(*Ui, keyboardListener, ui);
                }
            },
            else => {},
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ui: *Ui) void {
        switch (event) {
            .enter => |e| {
                ui.focus_surface = e.surface;
                ui.px = e.surface_x.toInt();
                ui.py = e.surface_y.toInt();
            },
            .leave => ui.focus_surface = null,
            .motion => |e| {
                ui.px = e.surface_x.toInt();
                ui.py = e.surface_y.toInt();
                ui.onMotion();
            },
            .button => |e| {
                if (e.state == .pressed) ui.onButton(e.button);
            },
            else => {},
        }
    }

    fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, ui: *Ui) void {
        switch (event) {
            .key => |k| {
                if (k.state != .pressed) return;
                ui.onKey(k.key);
            },
            else => {},
        }
    }

    // ---- background --------------------------------------------------------

    /// Ensure every ready output has a transparent, output-sized catcher
    /// at the very bottom. Manage or render sequence only.
    pub fn syncBackgrounds(ui: *Ui) void {
        var it = ui.wm.outputs.first();
        while (it) |out| : (it = types.nextOutput(out, ui.wm)) {
            if (out.removed or !out.ready()) continue;

            var found: ?*Background = null;
            for (ui.background.items) |*b| {
                if (b.output == out) found = b;
            }
            if (found) |b| {
                if (b.w == out.rect.w and b.h == out.rect.h) {
                    b.panel.node.setPosition(out.rect.x, out.rect.y);
                    b.panel.node.placeBottom();
                    continue;
                }
                // Output changed size: rebuild.
                b.panel.destroy();
                _ = ui.background.swapRemove(indexOfBg(ui, b));
            }
            ui.createBackground(out) catch |err| {
                std.log.err("background surface: {t}", .{err});
            };
        }
        ui.dropOrphanBackgrounds();
    }

    fn indexOfBg(ui: *Ui, b: *Background) usize {
        return (@intFromPtr(b) - @intFromPtr(ui.background.items.ptr)) / @sizeOf(Background);
    }

    fn dropOrphanBackgrounds(ui: *Ui) void {
        var i: usize = 0;
        while (i < ui.background.items.len) {
            if (ui.background.items[i].output.removed) {
                ui.background.items[i].panel.destroy();
                _ = ui.background.swapRemove(i);
            } else i += 1;
        }
    }

    fn createBackground(ui: *Ui, out: *types.Output) !void {
        var panel = try Panel.create(ui, out.rect.w, out.rect.h);
        errdefer panel.destroy();
        // Fully transparent: the wallpaper (if any) stays visible, but the
        // surface still has an input region and receives clicks.
        panel.canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        panel.commit();
        panel.node.setPosition(out.rect.x, out.rect.y);
        panel.node.placeBottom();
        try ui.background.append(ui.wm.gpa, .{ .output = out, .panel = panel, .w = out.rect.w, .h = out.rect.h });
    }

    // ---- input -------------------------------------------------------------

    fn isBackground(ui: *Ui, s: *wl.Surface) ?*Background {
        for (ui.background.items) |*b| if (b.panel.surface == s) return b;
        return null;
    }

    fn levelIndexFor(ui: *Ui, s: *wl.Surface) ?usize {
        for (ui.panels.items, 0..) |p, i| if (p.panel.surface == s) return i;
        return null;
    }

    fn onButton(ui: *Ui, button: u32) void {
        const s = ui.focus_surface orelse return;

        if (ui.levelIndexFor(s)) |li| {
            ui.clickMenu(li, button);
            return;
        }
        if (ui.isBackground(s)) |bg| {
            // Any click on the desktop first closes an open menu.
            const had_menu = ui.panels.items.len > 0;
            ui.closeMenu();
            switch (button) {
                BTN_RIGHT => ui.openRoot(bg, ui.px, ui.py),
                BTN_MIDDLE => ui.openWindowList(bg, ui.px, ui.py),
                else => {},
            }
            _ = had_menu;
            ui.wm.obj.manageDirty();
        }
    }

    fn onMotion(ui: *Ui) void {
        const s = ui.focus_surface orelse return;
        const li = ui.levelIndexFor(s) orelse return;
        const lvl = ui.panels.items[li].level;
        const idx = rowAt(lvl, ui.py);
        if (idx == lvl.hover) return;
        lvl.hover = idx;

        // Moving over a row closes deeper levels; a submenu row opens one.
        ui.closeAbove(li);
        if (idx) |i| {
            switch (lvl.rows[i].kind) {
                .submenu => |sub| ui.openSubmenu(li, i, sub) catch {},
                else => {},
            }
        }
        ui.redraw(li);
        ui.wm.obj.manageDirty();
    }

    fn onKey(ui: *Ui, key: u32) void {
        if (ui.panels.items.len == 0) return;
        // evdev codes: Esc=1, Enter=28, Up=103, Down=108, Left=105, Right=106
        const last = ui.panels.items.len - 1;
        const lvl = ui.panels.items[last].level;
        switch (key) {
            1 => ui.closeMenu(),
            103 => ui.stepHover(last, -1),
            108 => ui.stepHover(last, 1),
            106, 28 => if (lvl.hover) |i| ui.activate(last, i),
            105 => if (last > 0) {
                ui.closeAbove(last - 1);
            },
            else => {},
        }
        ui.wm.obj.manageDirty();
    }

    fn stepHover(ui: *Ui, li: usize, dir: i32) void {
        const lvl = ui.panels.items[li].level;
        const n: i32 = @intCast(lvl.rows.len);
        if (n == 0) return;
        var i: i32 = if (lvl.hover) |h| @intCast(h) else if (dir > 0) -1 else n;
        var tries: i32 = 0;
        while (tries < n) : (tries += 1) {
            i = @mod(i + dir, n);
            if (lvl.rows[@intCast(i)].enabled) break;
        }
        lvl.hover = @intCast(i);
        ui.redraw(li);
    }

    fn clickMenu(ui: *Ui, li: usize, button: u32) void {
        if (button != BTN_LEFT and button != BTN_RIGHT) return;
        const lvl = ui.panels.items[li].level;
        const idx = rowAt(lvl, ui.py) orelse return;
        ui.activate(li, idx);
        ui.wm.obj.manageDirty();
    }

    // ---- menu building ------------------------------------------------------

    fn arena(ui: *Ui) std.mem.Allocator {
        return ui.menu_arena.?.allocator();
    }

    fn resetArena(ui: *Ui) void {
        if (ui.menu_arena) |*a| a.deinit();
        ui.menu_arena = std.heap.ArenaAllocator.init(ui.wm.gpa);
    }

    fn openRoot(ui: *Ui, bg: *Background, x: i32, y: i32) void {
        const menu = ui.wm.root_menu orelse return;
        ui.resetArena();
        const lvl = ui.buildLevel(menu) catch |err| {
            std.log.err("root menu: {t}", .{err});
            return;
        };
        ui.showLevel(lvl, bg.output.rect.x + x, bg.output.rect.y + y, bg.output) catch |err| {
            std.log.err("show menu: {t}", .{err});
        };
    }

    fn openWindowList(ui: *Ui, bg: *Background, x: i32, y: i32) void {
        ui.resetArena();
        const lvl = ui.buildWindowList() catch return;
        ui.showLevel(lvl, bg.output.rect.x + x, bg.output.rect.y + y, bg.output) catch {};
    }

    fn zdup(ui: *Ui, s: []const u8) ![:0]const u8 {
        return try ui.arena().dupeZ(u8, s);
    }

    fn buildLevel(ui: *Ui, m: *const wm_menu.Menu) !*Level {
        const a = ui.arena();
        var rows: std.ArrayList(Row) = .empty;
        for (m.items) |it| {
            switch (it.action) {
                .submenu => |sub| {
                    const child = try ui.buildLevel(sub);
                    try rows.append(a, .{ .label = try ui.zdup(it.label), .kind = .{ .submenu = child } });
                },
                .exec => |cmd| try rows.append(a, .{
                    .label = try ui.zdup(it.label),
                    .shortcut = if (it.shortcut) |s| try ui.zdup(s) else null,
                    .kind = .{ .exec = cmd },
                }),
                .shexec => |cmd| try rows.append(a, .{
                    .label = try ui.zdup(it.label),
                    .shortcut = if (it.shortcut) |s| try ui.zdup(s) else null,
                    .kind = .{ .shexec = cmd },
                }),
                .builtin => |b| switch (b) {
                    .workspace_menu => try rows.append(a, .{
                        .label = try ui.zdup(it.label),
                        .kind = .{ .submenu = try ui.buildWorkspaceMenu() },
                    }),
                    .windows_menu => try rows.append(a, .{
                        .label = try ui.zdup(it.label),
                        .kind = .{ .submenu = try ui.buildWindowList() },
                    }),
                    else => try rows.append(a, .{
                        .label = try ui.zdup(it.label),
                        .enabled = it.enabled(),
                        .kind = .{ .builtin = b },
                    }),
                },
                .open_menu, .unknown => try rows.append(a, .{
                    .label = try ui.zdup(it.label),
                    .enabled = false,
                    .kind = .{ .builtin = .open_menu },
                }),
            }
        }
        const lvl = try a.create(Level);
        lvl.* = .{
            .title = try ui.zdup(m.title),
            .rows = try rows.toOwnedSlice(a),
            .x = 0,
            .y = 0,
            .w = 0,
            .h = 0,
        };
        measure(lvl);
        return lvl;
    }

    fn buildWorkspaceMenu(ui: *Ui) !*Level {
        const a = ui.arena();
        var rows: std.ArrayList(Row) = .empty;
        const out = ui.wm.outputs.first() orelse return error.NoOutput;
        var i: u32 = 0;
        while (i < out.workspace_count) : (i += 1) {
            const mark: []const u8 = if (i == out.active) "* " else "  ";
            const label = try std.fmt.allocPrintSentinel(a, "{s}Workspace {d}", .{ mark, i + 1 }, 0);
            try rows.append(a, .{ .label = label, .kind = .{ .goto_workspace = i } });
        }
        const lvl = try a.create(Level);
        lvl.* = .{ .title = "Workspaces", .rows = try rows.toOwnedSlice(a), .x = 0, .y = 0, .w = 0, .h = 0 };
        measure(lvl);
        return lvl;
    }

    fn buildWindowList(ui: *Ui) !*Level {
        const a = ui.arena();
        var rows: std.ArrayList(Row) = .empty;
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            if (w.closed or w.workspace == null) continue;
            const title = w.title orelse w.app_id orelse "(untitled)";
            const ws_no = w.workspace.?.index + 1;
            const label = try std.fmt.allocPrintSentinel(a, "[{d}] {s}", .{ ws_no, title }, 0);
            try rows.append(a, .{ .label = label, .kind = .{ .focus_window = w } });
        }
        if (rows.items.len == 0) {
            try rows.append(a, .{ .label = "(no windows)", .enabled = false, .kind = .{ .builtin = .open_menu } });
        }
        const lvl = try a.create(Level);
        lvl.* = .{ .title = "Windows", .rows = try rows.toOwnedSlice(a), .x = 0, .y = 0, .w = 0, .h = 0 };
        measure(lvl);
        return lvl;
    }

    // ---- geometry ----------------------------------------------------------

    fn measure(lvl: *Level) void {
        var w: i32 = gfx.measureText(lvl.title, font).w + 2 * pad_x;
        for (lvl.rows) |r| {
            var rw = gfx.measureText(r.label, font_item).w + 2 * pad_x;
            if (r.shortcut) |s| rw += gfx.measureText(s, font_item).w + 2 * pad_x;
            if (r.kind == .submenu) rw += arrow_w;
            w = @max(w, rw);
        }
        lvl.w = @max(w, 120);
        lvl.h = title_h + @as(i32, @intCast(lvl.rows.len)) * item_h + 2;
    }

    fn rowAt(lvl: *const Level, y: i32) ?usize {
        if (y < title_h) return null;
        const i: usize = @intCast(@divTrunc(y - title_h, item_h));
        if (i >= lvl.rows.len) return null;
        if (!lvl.rows[i].enabled) return null;
        return i;
    }

    // ---- showing / closing ---------------------------------------------------

    /// Keep the menu on its output.
    fn clampToOutput(lvl: *Level, out: *types.Output) void {
        const r = out.rect;
        lvl.x = std.math.clamp(lvl.x, r.x, @max(r.x, r.right() - lvl.w));
        lvl.y = std.math.clamp(lvl.y, r.y, @max(r.y, r.bottom() - lvl.h));
    }

    fn showLevel(ui: *Ui, lvl: *Level, x: i32, y: i32, out: *types.Output) !void {
        lvl.x = x;
        lvl.y = y;
        clampToOutput(lvl, out);
        try ui.pushPanel(lvl);
        ui.want_focus_menu = true;
        ui.want_layout = true;
    }

    fn openSubmenu(ui: *Ui, li: usize, row: usize, sub: *const Level) !void {
        const parent = ui.panels.items[li].level;
        const child: *Level = @constCast(sub);
        child.x = parent.x + parent.w - 2;
        child.y = parent.y + title_h + @as(i32, @intCast(row)) * item_h - title_h;
        if (ui.wm.outputs.first()) |out| {
            // Flip to the left side if it would leave the output.
            if (child.x + child.w > out.rect.right()) child.x = parent.x - child.w + 2;
            clampToOutput(child, out);
        }
        child.hover = null;
        try ui.pushPanel(child);
    }

    fn pushPanel(ui: *Ui, lvl: *Level) !void {
        var panel = try Panel.create(ui, lvl.w, lvl.h);
        errdefer panel.destroy();
        panel.x = lvl.x;
        panel.y = lvl.y;
        try ui.panels.append(ui.wm.gpa, .{ .level = lvl, .panel = panel });
        const idx = ui.panels.items.len - 1;
        ui.redraw(idx);
        ui.panels.items[idx].panel.node.setPosition(lvl.x, lvl.y);
        ui.panels.items[idx].panel.node.placeTop();
    }

    fn closeAbove(ui: *Ui, li: usize) void {
        while (ui.panels.items.len > li + 1) {
            var last = ui.panels.pop().?;
            last.panel.destroy();
        }
    }

    pub fn closeMenu(ui: *Ui) void {
        while (ui.panels.pop()) |p| {
            var pp = p;
            pp.panel.destroy();
        }
        ui.focus_surface = null;
        ui.want_focus_menu = false;
        ui.want_layout = true;
        if (ui.menu_arena) |*a| a.deinit();
        ui.menu_arena = null;
    }

    pub fn menuOpen(ui: *const Ui) bool {
        return ui.panels.items.len > 0;
    }

    // ---- actions ------------------------------------------------------------

    fn activate(ui: *Ui, li: usize, idx: usize) void {
        const lvl = ui.panels.items[li].level;
        const row = lvl.rows[idx];
        if (!row.enabled) return;
        const wm = ui.wm;
        switch (row.kind) {
            .submenu => |sub| {
                ui.closeAbove(li);
                ui.openSubmenu(li, idx, sub) catch {};
                return;
            },
            .exec => |cmd| {
                ui.spawnWords(cmd);
                ui.closeMenu();
            },
            .shexec => |cmd| {
                proc.spawn(wm, &.{ "/bin/sh", "-c", cmd });
                ui.closeMenu();
            },
            .focus_window => |w| {
                ui.closeMenu();
                wm.pending_ui = .{ .focus = w };
            },
            .goto_workspace => |i| {
                ui.closeMenu();
                wm.pending_ui = .{ .workspace = i };
            },
            .builtin => |b| {
                ui.closeMenu();
                switch (b) {
                    .exit => wm.quit = true,
                    .workspace_next => wm.pending_ui = .workspace_next,
                    .workspace_prev => wm.pending_ui = .workspace_prev,
                    .refresh => {},
                    else => {},
                }
            },
        }
    }

    /// Split `cmd` on whitespace (EXEC semantics) and start it.
    fn spawnWords(ui: *Ui, cmd: []const u8) void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(ui.wm.gpa);
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        while (it.next()) |w| argv.append(ui.wm.gpa, w) catch return;
        proc.spawn(ui.wm, argv.items);
    }

    // ---- drawing --------------------------------------------------------------

    fn redraw(ui: *Ui, li: usize) void {
        const p = &ui.panels.items[li];
        const lvl = p.level;
        var cv = &p.panel.canvas;

        cv.clear(col_bg);
        cv.vGradient(1, 1, lvl.w - 2, title_h - 1, col_title_top, col_title_bot);
        const tw = gfx.measureText(lvl.title, font).w;
        cv.drawText(lvl.title, @divTrunc(lvl.w - tw, 2), 3, font, col_hi_text);

        for (lvl.rows, 0..) |r, i| {
            const y = title_h + @as(i32, @intCast(i)) * item_h;
            const hot = lvl.hover != null and lvl.hover.? == i and r.enabled;
            if (hot) cv.fillRect(2, y, lvl.w - 4, item_h, col_hi_bg);
            const tc = if (hot) col_hi_text else if (r.enabled) col_text else col_disabled;
            cv.drawText(r.label, pad_x, y + 2, font_item, tc);
            if (r.shortcut) |s| {
                const sw = gfx.measureText(s, font_item).w;
                cv.drawText(s, lvl.w - sw - pad_x, y + 2, font_item, tc);
            }
            if (r.kind == .submenu) {
                // small triangle
                const cx = lvl.w - pad_x;
                const cy = y + @divTrunc(item_h, 2);
                cv.fillRect(cx - 4, cy - 1, 4, 2, tc);
            }
        }
        cv.bevel(0, 0, lvl.w, lvl.h, col_light, col_dark);
        p.panel.commit();
    }

    // ---- per-sequence hooks (called from main.zig) ----------------------------------

    /// Manage sequence: keyboard focus for the menu.
    pub fn onManage(ui: *Ui) void {
        ui.syncBackgrounds();
        if (ui.want_focus_menu and ui.panels.items.len > 0) {
            if (ui.wm.seats.first()) |s| s.obj.focusShellSurface(ui.panels.items[0].panel.shell);
            ui.want_focus_menu = false;
        }
        // Keep menu panels on top after window restacking.
        for (ui.panels.items) |*p| {
            p.panel.node.setPosition(p.panel.x, p.panel.y);
            p.panel.node.placeTop();
        }
    }

    /// Render sequence: restack menu above windows that were raised.
    pub fn onRender(ui: *Ui) void {
        for (ui.panels.items) |*p| p.panel.node.placeTop();
    }

    pub fn deinit(ui: *Ui) void {
        ui.closeMenu();
        for (ui.background.items) |*b| b.panel.destroy();
        ui.background.deinit(ui.wm.gpa);
        ui.panels.deinit(ui.wm.gpa);
    }
};
