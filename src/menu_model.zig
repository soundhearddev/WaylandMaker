// SPDX-License-Identifier: GPL-3.0
//
// The menu that is open: the root menu (right click on the empty desktop,
// `menu_root`) or the window list (middle click, `menu_windows`). Pure model,
// no wlroots: menu_scene.zig draws it and feeds it the pointer and the keys;
// this file knows the levels (a menu and each submenu that is open), where
// they lie, which row is lit, and what a click or a key asks for (`Effect`).
//
// The look and the arithmetic are Window Maker's, ported from the river-era
// ui (attic/ui.zig): a title bar of 22 px, rows of 20 px, a submenu opening
// at the row that asked for it, a menu taller than its output scrolling.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gfx = @import("gfx.zig");
const fsmenu = @import("fsmenu.zig");
const types = @import("types.zig");
const wm_menu = @import("wm_menu.zig");

pub const title_h: i32 = 22;
pub const item_h: i32 = 20;
pub const pad_x: i32 = 10;
pub const arrow_w: i32 = 14;
pub const min_menu_w: i32 = 120;
/// Space kept free above and below a menu that is taller than the output.
const menu_margin: i32 = 4;
/// A level shows at most this many rows; more is a broken menu file.
const max_rows: usize = 500;
/// Cap for one label: a single absurd string must not make a huge buffer.
const max_label_bytes: usize = 256;
/// How deep OPEN_MENU may nest (a menu file that opens a menu file ...).
const max_expand_depth: u32 = 4;
/// Rows a mouse wheel notch scrolls a long menu.
pub const wheel_rows: i32 = 3;

pub const Kind = union(enum) {
    exec: []const u8,
    shexec: []const u8,
    builtin: wm_menu.Builtin,
    /// Index into `Menu.levels`; built together with its parent.
    submenu: usize,
    focus_window: *types.Window,
    goto_workspace: u32,
    none,
};

pub const Row = struct {
    label: [:0]const u8,
    shortcut: ?[:0]const u8 = null,
    enabled: bool = true,
    kind: Kind,
};

pub const Level = struct {
    title: [:0]const u8,
    rows: []Row,
    /// The level and row that opened this one.
    parent: ?usize = null,
    parent_row: usize = 0,
    /// Global top-left; set when the level is opened.
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    hover: ?usize = null,
    /// A level taller than its output shows `visible` rows from row `scroll`.
    scroll: usize = 0,
    visible: usize = 0,
    open: bool = false,
    /// Needs drawing again.
    dirty: bool = true,
};

/// What a click or a key asks the compositor to do. The menu has closed
/// itself already where that is meant (`close` is the other way to say so).
pub const Effect = union(enum) {
    none,
    close,
    exec: []const u8,
    shexec: []const u8,
    builtin: wm_menu.Builtin,
    focus_window: *types.Window,
    goto_workspace: u32,
};

pub const Key = enum { up, down, left, right, enter, escape };

pub const Menu = struct {
    gpa: Allocator,
    /// Everything of the open menu (labels, rows, copies of EXEC lines).
    arena: std.heap.ArenaAllocator,
    levels: std.ArrayList(Level) = .empty,
    /// The output the menu opened on (global rectangle): where it may lie.
    bounds: types.Rect = .{},
    /// `menu_submenu_align = left`: the left side is tried first.
    left_first: bool = false,
    expand_depth: u32 = 0,

    pub fn init(gpa: Allocator) Menu {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(m: *Menu) void {
        m.levels.deinit(m.gpa);
        m.arena.deinit();
    }

    pub fn isOpen(m: *const Menu) bool {
        return m.levels.items.len > 0 and m.levels.items[0].open;
    }

    /// Forget the open menu.
    pub fn close(m: *Menu) void {
        m.levels.clearRetainingCapacity();
        _ = m.arena.reset(.retain_capacity);
        m.expand_depth = 0;
    }

    // ---- opening ---------------------------------------------------------------

    /// The root menu at the pointer (global x, y) on `bounds`'s output.
    pub fn openRoot(m: *Menu, wm: *types.WindowManager, bounds: types.Rect, x: i32, y: i32) !void {
        const root = wm.root_menu orelse return error.NoMenu;
        m.close();
        errdefer m.close();
        m.left_first = wm.cfg.menu_submenu_align == .left;
        const top = try m.buildLevel(wm, root);
        m.show(top, bounds, x, y);
    }

    /// The window list at the pointer.
    pub fn openWindows(m: *Menu, wm: *types.WindowManager, bounds: types.Rect, x: i32, y: i32) !void {
        m.close();
        errdefer m.close();
        m.left_first = wm.cfg.menu_submenu_align == .left;
        const top = try m.buildWindowLevel(wm);
        m.show(top, bounds, x, y);
    }

    fn show(m: *Menu, top: usize, bounds: types.Rect, x: i32, y: i32) void {
        m.bounds = bounds;
        const lvl = &m.levels.items[top];
        fitToBounds(lvl, bounds);
        // Window Maker puts the title bar's middle at the pointer.
        lvl.x = x - @divTrunc(lvl.w, 2);
        lvl.y = y - @divTrunc(title_h, 2);
        clampToBounds(lvl, bounds);
        lvl.open = true;
        lvl.dirty = true;
    }

    // ---- building the levels ---------------------------------------------------

    fn a(m: *Menu) Allocator {
        return m.arena.allocator();
    }

    fn zdup(m: *Menu, s: []const u8) ![:0]const u8 {
        return m.a().dupeZ(u8, clipUtf8(s, max_label_bytes));
    }

    fn buildLevel(m: *Menu, wm: *types.WindowManager, menu: *const wm_menu.Menu) Allocator.Error!usize {
        const me = m.levels.items.len;
        // Reserve our slot first so that children get larger indices.
        try m.levels.append(m.gpa, undefined);

        var rows: std.ArrayList(Row) = .empty;
        for (menu.items) |it| {
            if (rows.items.len >= max_rows) break;
            const label = try m.zdup(it.label);
            const shortcut: ?[:0]const u8 = if (it.shortcut) |s| try m.zdup(s) else null;
            switch (it.action) {
                .submenu => |sub| {
                    const child = try m.buildLevel(wm, sub);
                    try rows.append(m.a(), .{ .label = label, .kind = .{ .submenu = child } });
                },
                .exec => |c| try rows.append(m.a(), .{ .label = label, .shortcut = shortcut, .kind = .{ .exec = try m.a().dupe(u8, c) } }),
                .shexec => |c| try rows.append(m.a(), .{ .label = label, .shortcut = shortcut, .kind = .{ .shexec = try m.a().dupe(u8, c) } }),
                .builtin => |b| switch (b) {
                    .workspace_menu => {
                        const child = try m.buildWorkspaceLevel(wm);
                        try rows.append(m.a(), .{ .label = label, .kind = .{ .submenu = child } });
                    },
                    .windows_menu => {
                        const child = try m.buildWindowLevel(wm);
                        try rows.append(m.a(), .{ .label = label, .kind = .{ .submenu = child } });
                    },
                    .info_panel, .legal_panel => {
                        const child = try m.buildTextLevel(wm, b);
                        try rows.append(m.a(), .{ .label = label, .kind = .{ .submenu = child } });
                    },
                    else => try rows.append(m.a(), .{ .label = label, .shortcut = shortcut, .enabled = it.enabled(), .kind = .{ .builtin = b } }),
                },
                .open_menu => |spec| {
                    // Built now, so a directory listing is never stale.
                    var made = false;
                    if (m.expand_depth < max_expand_depth) {
                        m.expand_depth += 1;
                        defer m.expand_depth -= 1;
                        if (fsmenu.expand(m.a(), spec, it.label)) |sub| {
                            const child = try m.buildLevel(wm, sub);
                            try rows.append(m.a(), .{ .label = label, .kind = .{ .submenu = child } });
                            made = true;
                        }
                    }
                    if (!made) try rows.append(m.a(), .{ .label = label, .enabled = false, .kind = .none });
                },
                .unknown => try rows.append(m.a(), .{ .label = label, .enabled = false, .kind = .none }),
            }
        }
        m.levels.items[me] = .{ .title = try m.zdup(menu.title), .rows = try rows.toOwnedSlice(m.a()) };
        measure(&m.levels.items[me]);
        return me;
    }

    fn buildWorkspaceLevel(m: *Menu, wm: *types.WindowManager) Allocator.Error!usize {
        const me = m.levels.items.len;
        try m.levels.append(m.gpa, undefined);
        var rows: std.ArrayList(Row) = .empty;
        if (wm.outputs.first()) |out| {
            const names = types.workspaceNames(wm, out);
            var i: u32 = 0;
            while (i < out.workspace_count) : (i += 1) {
                const mark: []const u8 = if (i == out.active) "* " else "  ";
                const label = if (i < names.len and names[i].len > 0)
                    try std.fmt.allocPrintSentinel(m.a(), "{s}{d}: {s}", .{ mark, i + 1, clipUtf8(names[i], 64) }, 0)
                else
                    try std.fmt.allocPrintSentinel(m.a(), "{s}Workspace {d}", .{ mark, i + 1 }, 0);
                try rows.append(m.a(), .{ .label = label, .kind = .{ .goto_workspace = i } });
            }
        }
        m.levels.items[me] = .{ .title = "Workspaces", .rows = try rows.toOwnedSlice(m.a()) };
        measure(&m.levels.items[me]);
        return me;
    }

    /// The Info and Legal panels: read-only lines, closed like any menu.
    fn buildTextLevel(m: *Menu, wm: *types.WindowManager, which: wm_menu.Builtin) Allocator.Error!usize {
        const me = m.levels.items.len;
        try m.levels.append(m.gpa, undefined);
        var rows: std.ArrayList(Row) = .empty;
        const lines: []const []const u8 = switch (which) {
            .info_panel => &.{
                "wmaker-wl",
                "A Window Maker style window manager",
                "and Wayland compositor (wlroots).",
                "",
                "Configuration:",
            },
            else => &.{
                "wmaker-wl is free software,",
                "licensed under the GNU GPL,",
                "version 3.",
                "It comes with no warranty.",
                "",
                "Modelled on Window Maker (GPL),",
                "by Alfredo K. Kojima, Dan Pascu et al.",
            },
        };
        for (lines) |l| try rows.append(m.a(), .{ .label = try m.zdup(l), .enabled = false, .kind = .none });
        if (which == .info_panel) {
            const cfg_line = try std.fmt.allocPrint(m.a(), "  {s}", .{clipUtf8(wm.cfg.config_file, 70)});
            try rows.append(m.a(), .{ .label = try m.zdup(cfg_line), .enabled = false, .kind = .none });
        }
        m.levels.items[me] = .{
            .title = if (which == .info_panel) "Info" else "Legal",
            .rows = try rows.toOwnedSlice(m.a()),
        };
        measure(&m.levels.items[me]);
        return me;
    }

    fn buildWindowLevel(m: *Menu, wm: *types.WindowManager) Allocator.Error!usize {
        const me = m.levels.items.len;
        try m.levels.append(m.gpa, undefined);
        var rows: std.ArrayList(Row) = .empty;
        var it = wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, wm)) {
            if (rows.items.len >= max_rows) break;
            if (w.closed or (w.workspace == null and !w.minimized)) continue;
            // Window Maker's SkipWindowList (DockApps have it by default).
            if (w.attrs.is("skip_window_list")) continue;
            const title = w.title orelse w.app_id orelse "(untitled)";
            // A minimized window is shown in brackets, like Window Maker shows
            // miniwindows; choosing it brings it back.
            const label = if (w.minimized)
                try std.fmt.allocPrintSentinel(m.a(), "({s})", .{clipUtf8(title, max_label_bytes - 4)}, 0)
            else
                try std.fmt.allocPrintSentinel(m.a(), "[{d}] {s}", .{ w.workspace.?.index + 1, clipUtf8(title, max_label_bytes - 8) }, 0);
            try rows.append(m.a(), .{ .label = label, .kind = .{ .focus_window = w } });
        }
        if (rows.items.len == 0) try rows.append(m.a(), .{ .label = "(no windows)", .enabled = false, .kind = .none });
        m.levels.items[me] = .{ .title = "Windows", .rows = try rows.toOwnedSlice(m.a()) };
        measure(&m.levels.items[me]);
        return me;
    }

    // ---- input -----------------------------------------------------------------

    /// The topmost open level under a global point.
    pub fn levelAt(m: *const Menu, x: i32, y: i32) ?usize {
        var i = m.levels.items.len;
        while (i > 0) {
            i -= 1;
            const l = m.levels.items[i];
            if (!l.open) continue;
            if (x >= l.x and x < l.x + l.w and y >= l.y and y < l.y + l.h) return i;
        }
        return null;
    }

    /// The pointer moved. Returns whether anything has to be drawn again.
    pub fn pointerMotion(m: *Menu, x: i32, y: i32) bool {
        const li = m.levelAt(x, y) orelse return false;
        const lvl = &m.levels.items[li];
        const row = rowAt(lvl, y - lvl.y);
        // Over the title bar or a disabled row: the lit row stays as it was.
        if (row == null) return false;
        return m.setHover(li, row);
    }

    /// A button went down at a global point. A click outside every level
    /// closes the menu.
    pub fn click(m: *Menu, x: i32, y: i32, button_left_or_right: bool) Effect {
        const li = m.levelAt(x, y) orelse {
            m.close();
            return .close;
        };
        if (!button_left_or_right) return .none;
        const lvl = &m.levels.items[li];
        const row = rowAt(lvl, y - lvl.y) orelse return .none;
        return m.activate(li, row);
    }

    pub fn key(m: *Menu, k: Key) Effect {
        const li = m.deepestOpen() orelse return .none;
        const lvl = &m.levels.items[li];
        switch (k) {
            .escape => {
                m.close();
                return .close;
            },
            .up => m.stepHover(li, -1),
            .down => m.stepHover(li, 1),
            .right, .enter => if (lvl.hover) |i| return m.activate(li, i),
            .left => if (lvl.parent != null) m.closeLevel(li),
        }
        return .none;
    }

    /// The wheel over a level scrolls it, if it scrolls. True: draw again.
    pub fn scroll(m: *Menu, x: i32, y: i32, rows: i32) bool {
        const li = m.levelAt(x, y) orelse return false;
        const lvl = &m.levels.items[li];
        const n = shown(lvl);
        if (n >= lvl.rows.len) return false;
        const max: i32 = @intCast(lvl.rows.len - n);
        const next: i32 = std.math.clamp(@as(i32, @intCast(lvl.scroll)) + rows, 0, max);
        if (next == lvl.scroll) return false;
        lvl.scroll = @intCast(next);
        lvl.dirty = true;
        // The row under the pointer is another one now.
        m.closeChildrenOf(li);
        lvl.hover = rowAt(lvl, y - lvl.y);
        if (lvl.hover) |h| switch (lvl.rows[h].kind) {
            .submenu => |child| m.openChild(li, h, child),
            else => {},
        };
        return true;
    }

    fn deepestOpen(m: *const Menu) ?usize {
        var best: ?usize = null;
        for (m.levels.items, 0..) |l, i| if (l.open) {
            best = i;
        };
        return best;
    }

    fn setHover(m: *Menu, li: usize, idx: ?usize) bool {
        const lvl = &m.levels.items[li];
        if (lvl.hover == idx) return false;
        lvl.hover = idx;
        lvl.dirty = true;
        // Hovering another row closes what this level had opened.
        m.closeChildrenOf(li);
        if (idx) |i| switch (lvl.rows[i].kind) {
            .submenu => |child| m.openChild(li, i, child),
            else => {},
        };
        return true;
    }

    fn stepHover(m: *Menu, li: usize, dir: i32) void {
        const lvl = &m.levels.items[li];
        const n: i32 = @intCast(lvl.rows.len);
        if (n == 0) return;
        var i: i32 = if (lvl.hover) |h| @intCast(h) else if (dir > 0) -1 else n;
        var tries: i32 = 0;
        while (tries < n) : (tries += 1) {
            i = @mod(i + dir, n);
            if (lvl.rows[@intCast(i)].enabled) {
                ensureVisible(lvl, @intCast(i));
                _ = m.setHover(li, @intCast(i));
                return;
            }
        }
    }

    fn closeChildrenOf(m: *Menu, li: usize) void {
        for (m.levels.items, 0..) |*l, i| {
            if (l.open and l.parent != null and l.parent.? == li) m.closeLevel(i);
        }
    }

    fn closeLevel(m: *Menu, li: usize) void {
        const lvl = &m.levels.items[li];
        if (!lvl.open) return;
        m.closeChildrenOf(li);
        lvl.open = false;
        lvl.hover = null;
    }

    fn openChild(m: *Menu, parent: usize, row: usize, child: usize) void {
        const pl = m.levels.items[parent];
        var cl = &m.levels.items[child];
        cl.parent = parent;
        cl.parent_row = row;
        cl.hover = null;
        cl.dirty = true;
        const right_x = pl.x + pl.w - 2;
        const left_x = pl.x - cl.w + 2;
        cl.y = pl.y + @as(i32, @intCast(row -| pl.scroll)) * item_h;
        fitToBounds(cl, m.bounds);
        // `menu_submenu_align` is the side tried first; flip to the other one
        // when the submenu would leave the output on that side.
        if (m.left_first) {
            cl.x = left_x;
            if (cl.x < m.bounds.x) cl.x = right_x;
        } else {
            cl.x = right_x;
            if (cl.x + cl.w > m.bounds.right()) cl.x = left_x;
        }
        clampToBounds(cl, m.bounds);
        cl.open = true;
    }

    fn activate(m: *Menu, li: usize, idx: usize) Effect {
        const row = m.levels.items[li].rows[idx];
        if (!row.enabled) return .none;
        const effect: Effect = switch (row.kind) {
            .submenu => |child| {
                m.closeChildrenOf(li);
                m.openChild(li, idx, child);
                return .none;
            },
            .exec => |c| .{ .exec = c },
            .shexec => |c| .{ .shexec = c },
            .focus_window => |w| .{ .focus_window = w },
            .goto_workspace => |i| .{ .goto_workspace = i },
            .builtin => |b| .{ .builtin = b },
            .none => return .none,
        };
        // The effect's strings live in the arena: copy what the caller needs
        // before it calls `close` (the compositor runs it first, then closes).
        return effect;
    }

    /// Mark every level drawn.
    pub fn clean(m: *Menu) void {
        for (m.levels.items) |*l| l.dirty = false;
    }
};

// ---- geometry ----------------------------------------------------------------

pub fn measure(lvl: *Level) void {
    var w: i32 = gfx.measureText(lvl.title, gfx.fonts.menuTitle()).w + 2 * pad_x;
    for (lvl.rows) |r| {
        var rw = gfx.measureText(r.label, gfx.fonts.menuItem()).w + 2 * pad_x;
        if (r.shortcut) |s| rw += gfx.measureText(s, gfx.fonts.menuItem()).w + 2 * pad_x;
        if (r.kind == .submenu) rw += arrow_w;
        w = @max(w, rw);
    }
    lvl.w = @max(w, min_menu_w);
    lvl.h = title_h + @as(i32, @intCast(lvl.rows.len)) * item_h + 2;
    lvl.visible = lvl.rows.len;
    lvl.scroll = 0;
}

/// How many rows are on screen.
pub fn shown(lvl: *const Level) usize {
    return if (lvl.visible == 0) lvl.rows.len else @min(lvl.visible, lvl.rows.len);
}

/// A level taller than its output is cut to what fits and scrolls.
pub fn fitToBounds(lvl: *Level, bounds: types.Rect) void {
    const natural = title_h + @as(i32, @intCast(lvl.rows.len)) * item_h + 2;
    const room = bounds.h - 2 * menu_margin;
    if (bounds.h <= 0 or natural <= room) {
        lvl.h = natural;
        lvl.visible = lvl.rows.len;
        lvl.scroll = 0;
        return;
    }
    const fit: usize = @intCast(@max(1, @divTrunc(room - title_h - 2, item_h)));
    lvl.visible = @min(fit, lvl.rows.len);
    lvl.h = title_h + @as(i32, @intCast(lvl.visible)) * item_h + 2;
    lvl.scroll = @min(lvl.scroll, lvl.rows.len - lvl.visible);
}

pub fn clampToBounds(lvl: *Level, r: types.Rect) void {
    lvl.x = std.math.clamp(lvl.x, r.x, @max(r.x, r.right() - lvl.w));
    lvl.y = std.math.clamp(lvl.y, r.y, @max(r.y, r.bottom() - lvl.h));
}

/// Scroll just enough that row `idx` is on screen.
fn ensureVisible(lvl: *Level, idx: usize) void {
    const n = shown(lvl);
    if (n == 0) return;
    if (idx < lvl.scroll) {
        lvl.scroll = idx;
    } else if (idx >= lvl.scroll + n) {
        lvl.scroll = idx + 1 - n;
    }
    lvl.dirty = true;
}

/// The enabled row at a y inside the level (0 = its top edge).
pub fn rowAt(lvl: *const Level, y: i32) ?usize {
    if (y < title_h) return null;
    const k: usize = @intCast(@divTrunc(y - title_h, item_h));
    if (k >= shown(lvl)) return null;
    const i = lvl.scroll + k;
    if (i >= lvl.rows.len) return null;
    if (!lvl.rows[i].enabled) return null;
    return i;
}

/// At most `max` bytes of `s`, cut on a character boundary.
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1;
    return s[0..n];
}

// ---- tests ---------------------------------------------------------------------

fn testLevel(rows: []Row) Level {
    var l: Level = .{ .title = "Applications", .rows = rows };
    measure(&l);
    return l;
}

test "menu layout: height follows the row count, width follows the text" {
    var rows = [_]Row{
        .{ .label = "Terminal", .kind = .none },
        .{ .label = "A much longer entry than the others", .kind = .none },
    };
    const l = testLevel(&rows);
    try std.testing.expectEqual(title_h + 2 * item_h + 2, l.h);
    try std.testing.expect(l.w > min_menu_w);
}

test "rowAt maps y to rows, skips the title and disabled rows" {
    var rows = [_]Row{
        .{ .label = "one", .kind = .none },
        .{ .label = "two", .enabled = false, .kind = .none },
        .{ .label = "three", .kind = .none },
    };
    const l = testLevel(&rows);
    try std.testing.expectEqual(@as(?usize, null), rowAt(&l, 5));
    try std.testing.expectEqual(@as(?usize, 0), rowAt(&l, title_h + 1));
    try std.testing.expectEqual(@as(?usize, null), rowAt(&l, title_h + item_h + 1));
    try std.testing.expectEqual(@as(?usize, 2), rowAt(&l, title_h + 2 * item_h + 1));
    try std.testing.expectEqual(@as(?usize, null), rowAt(&l, title_h + 3 * item_h + 1));
}

test "clampToBounds keeps a level on its output" {
    var rows = [_]Row{.{ .label = "x", .kind = .none }};
    var l = testLevel(&rows);
    const out: types.Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    l.x = 790;
    l.y = 590;
    clampToBounds(&l, out);
    try std.testing.expect(l.x + l.w <= 800);
    try std.testing.expect(l.y + l.h <= 600);
    l.x = -50;
    l.y = -50;
    clampToBounds(&l, out);
    try std.testing.expectEqual(@as(i32, 0), l.x);
    try std.testing.expectEqual(@as(i32, 0), l.y);
}

test "a level taller than its output is cut and scrolls" {
    var rows: [100]Row = undefined;
    for (&rows) |*r| r.* = .{ .label = "row", .kind = .none };
    var l = testLevel(&rows);
    fitToBounds(&l, .{ .x = 0, .y = 0, .w = 800, .h = 300 });
    try std.testing.expect(l.visible < 100);
    try std.testing.expect(l.h <= 300);
    ensureVisible(&l, 99);
    try std.testing.expectEqual(@as(usize, 100 - l.visible), l.scroll);
    ensureVisible(&l, 0);
    try std.testing.expectEqual(@as(usize, 0), l.scroll);
}

test "keys step over disabled rows, wrap, and escape closes" {
    var m = Menu.init(std.testing.allocator);
    defer m.deinit();
    var rows = [_]Row{
        .{ .label = "a", .kind = .none },
        .{ .label = "b", .enabled = false, .kind = .none },
        .{ .label = "c", .kind = .{ .builtin = .exit } },
    };
    try m.levels.append(m.gpa, testLevel(&rows));
    m.levels.items[0].open = true;
    _ = m.key(.down);
    try std.testing.expectEqual(@as(?usize, 0), m.levels.items[0].hover);
    _ = m.key(.down);
    try std.testing.expectEqual(@as(?usize, 2), m.levels.items[0].hover);
    _ = m.key(.down);
    try std.testing.expectEqual(@as(?usize, 0), m.levels.items[0].hover);
    _ = m.key(.up);
    try std.testing.expectEqual(@as(?usize, 2), m.levels.items[0].hover);
    switch (m.key(.enter)) {
        .builtin => |b| try std.testing.expectEqual(wm_menu.Builtin.exit, b),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(Effect.close, m.key(.escape));
    try std.testing.expect(!m.isOpen());
}

test "a click outside closes, a click on a row acts, hover opens a submenu" {
    var m = Menu.init(std.testing.allocator);
    defer m.deinit();
    var child_rows = [_]Row{.{ .label = "child", .kind = .{ .builtin = .exit } }};
    var rows = [_]Row{
        .{ .label = "plain", .kind = .{ .builtin = .refresh } },
        .{ .label = "more", .kind = .{ .submenu = 1 } },
    };
    var top = testLevel(&rows);
    top.x = 100;
    top.y = 100;
    top.open = true;
    var child = testLevel(&child_rows);
    child.title = "More";
    m.bounds = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    try m.levels.append(m.gpa, top);
    try m.levels.append(m.gpa, child);

    // Hovering the submenu row opens the child next to it.
    try std.testing.expect(m.pointerMotion(110, 100 + title_h + item_h + 2));
    try std.testing.expect(m.levels.items[1].open);
    try std.testing.expectEqual(m.levels.items[0].x + m.levels.items[0].w - 2, m.levels.items[1].x);
    // Hovering the other row closes it again.
    try std.testing.expect(m.pointerMotion(110, 100 + title_h + 2));
    try std.testing.expect(!m.levels.items[1].open);

    // A click on a row asks for its action; the title bar does nothing.
    switch (m.click(110, 100 + title_h + 2, true)) {
        .builtin => |b| try std.testing.expectEqual(wm_menu.Builtin.refresh, b),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(Effect.none, m.click(110, 105, true));
    // A click away from every level closes the menu.
    try std.testing.expectEqual(Effect.close, m.click(900, 700, true));
    try std.testing.expect(!m.isOpen());
}
