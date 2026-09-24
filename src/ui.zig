// SPDX-License-Identifier: 0BSD
//
// Desktop UI: root menu and window list, drawn with cairo/pango into
// river shell surfaces.
//
//   right click on the empty desktop  -> root menu
//   middle click on the empty desktop -> window list
//   Esc / left click on the desktop   -> close
//
// DESIGN
// ------
// Input callbacks (wl_pointer / wl_keyboard) run OUTSIDE manage/render
// sequences, where river forbids rendering state
// (node.set_position / place_top) and management state (focus_shell_surface).
// So callbacks never touch river objects. They only change plain data
// (`request`, `hover`, `open`) and call manage_dirty().
//
// Everything that talks to river happens in `sync()`, called from
// main.onManage(): create/destroy surfaces, position, stack, draw, commit,
// keyboard focus. One place, one rule.
//
// Surfaces:
//   * one transparent "desktop" surface per output, at the bottom of the
//     render list. Windows are stacked above it, so it only receives
//     clicks on the free desktop;
//   * one surface per open menu level (cascading submenus), on top.
//
// Buffers are double-buffered: a wl_buffer river still reads (no `release`
// yet) is never drawn into.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const gfx = @import("gfx.zig");
const shm = @import("shm.zig");
const wm_menu = @import("wm_menu.zig");
const proc = @import("process.zig");

const WindowManager = types.WindowManager;
const Allocator = std.mem.Allocator;

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

const KEY_ESC: u32 = 1;
const KEY_ENTER: u32 = 28;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_UP: u32 = 103;
const KEY_DOWN: u32 = 108;

// ----------------------------------------------------------------------------
// Look (Window Maker / NeXT)
// ----------------------------------------------------------------------------

const font_title: [:0]const u8 = "Sans Bold 10";
const font_item: [:0]const u8 = "Sans 10";

const title_h: i32 = 22;
const item_h: i32 = 20;
const pad_x: i32 = 10;
const arrow_w: i32 = 14;
const min_menu_w: i32 = 120;

const col_bg = gfx.Color.rgb(0xaeaaae);
const col_light = gfx.Color.rgb(0xffffff);
const col_dark = gfx.Color.rgb(0x555555);
const col_text = gfx.Color.rgb(0x000000);
const col_disabled = gfx.Color.rgb(0x707070);
const col_hi_bg = gfx.Color.rgb(0x000000);
const col_hi_text = gfx.Color.rgb(0xffffff);
const col_title_top = gfx.Color.rgb(0x000000);
const col_title_bot = gfx.Color.rgb(0x444444);
const col_clear: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

// ----------------------------------------------------------------------------
// Menu model (what is shown right now)
// ----------------------------------------------------------------------------

const RowKind = union(enum) {
    exec: []const u8,
    shexec: []const u8,
    builtin: wm_menu.Builtin,
    /// Index into `Ui.levels`; the child level is built together with its
    /// parent, so the tree is complete before the first frame.
    submenu: usize,
    focus_window: *types.Window,
    goto_workspace: u32,
    none,
};

const Row = struct {
    label: [:0]const u8,
    shortcut: ?[:0]const u8 = null,
    enabled: bool = true,
    kind: RowKind,
};

const Level = struct {
    title: [:0]const u8,
    rows: []Row,
    /// Parent level and the row in it that opened this one.
    parent: ?usize = null,
    parent_row: usize = 0,
    /// Global top-left; assigned when the level is opened.
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    hover: ?usize = null,
    /// Open = has (or will get) a surface.
    open: bool = false,
    /// Needs a redraw + commit at the next sync.
    dirty: bool = true,
    /// Output this menu belongs to (for clamping).
    output: ?*types.Output = null,
};

// ----------------------------------------------------------------------------
// One shell surface with two shm buffers
// ----------------------------------------------------------------------------

const Slot = struct {
    buf: shm.Buffer,
    canvas: gfx.Canvas,
    /// river may still be reading it.
    busy: bool = false,
};

const Panel = struct {
    ui: *Ui,
    surface: *wl.Surface,
    shell: *river.ShellSurfaceV1,
    node: *river.NodeV1,
    w: i32,
    h: i32,
    slots: [2]?Slot = .{ null, null },
    /// Position sent to river last; minInt = never.
    sent_x: i32 = std.math.minInt(i32),
    sent_y: i32 = std.math.minInt(i32),
    /// The first commit (with a buffer) has been made.
    committed: bool = false,

    fn create(ui: *Ui, w: i32, h: i32) !*Panel {
        const p = try ui.gpa().create(Panel);
        errdefer ui.gpa().destroy(p);

        const surface = try ui.compositor.createSurface();
        errdefer surface.destroy();
        const shell = try ui.wm.obj.getShellSurface(surface);
        errdefer shell.destroy();
        const node = try shell.getNode();
        errdefer node.destroy();

        p.* = .{ .ui = ui, .surface = surface, .shell = shell, .node = node, .w = w, .h = h };
        return p;
    }

    /// Free every buffer and protocol object.
    fn destroy(p: *Panel) void {
        // Detach first so river drops its reference to the buffer.
        p.surface.attach(null, 0, 0);
        p.surface.commit();
        for (&p.slots) |*s| if (s.*) |*slot| {
            slot.canvas.deinit();
            slot.buf.destroy();
        };
        p.node.destroy();
        p.shell.destroy();
        p.surface.destroy();
        const gpa = p.ui.gpa();
        gpa.destroy(p);
    }

    fn slotIndexFor(p: *Panel, buffer: *wl.Buffer) ?usize {
        for (p.slots, 0..) |s, i| if (s) |slot| if (slot.buf.buffer == buffer) return i;
        return null;
    }

    /// A slot river is done with; created lazily.
    fn freeSlot(p: *Panel) !*Slot {
        for (&p.slots) |*s| {
            if (s.*) |*slot| {
                if (!slot.busy) return slot;
            }
        }
        for (&p.slots) |*s| {
            if (s.* == null) {
                var buf = try shm.Buffer.create(p.ui.shm, p.w, p.h);
                errdefer buf.destroy();
                const canvas = try gfx.Canvas.initForData(buf.data.ptr, p.w, p.h, buf.stride);
                s.* = .{ .buf = buf, .canvas = canvas };
                buf.buffer.setListener(*Panel, bufferListener, p);
                return &s.*.?;
            }
        }
        return error.AllBuffersBusy;
    }

    fn bufferListener(buffer: *wl.Buffer, event: wl.Buffer.Event, p: *Panel) void {
        switch (event) {
            .release => if (p.slotIndexFor(buffer)) |i| {
                p.slots[i].?.busy = false;
            },
        }
    }

    /// Attach `slot` and commit. The first commit must happen inside a
    /// manage/render sequence (no_commit error otherwise); sync() is only
    /// called from manage.
    fn present(p: *Panel, slot: *Slot) void {
        slot.canvas.flush();
        slot.busy = true;
        p.surface.attach(slot.buf.buffer, 0, 0);
        p.surface.damageBuffer(0, 0, p.w, p.h);
        p.surface.commit();
        p.committed = true;
    }
};

// ----------------------------------------------------------------------------
// Ui
// ----------------------------------------------------------------------------

const Desktop = struct {
    output: *types.Output,
    panel: *Panel,
};

const OpenPanel = struct {
    level: usize,
    panel: *Panel,
};

/// A request recorded by an input callback, executed in sync().
const Request = union(enum) {
    none,
    open_root: struct { output: *types.Output, x: i32, y: i32 },
    open_windows: struct { output: *types.Output, x: i32, y: i32 },
    close,
};

pub const Ui = struct {
    wm: *WindowManager,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,

    desktops: std.ArrayList(Desktop) = .empty,

    // ---- menu state -------------------------------------------------------
    arena: std.heap.ArenaAllocator,
    levels: std.ArrayList(Level) = .empty,
    panels: std.ArrayList(OpenPanel) = .empty,
    /// Surfaces waiting for destruction (never destroyed inside a callback).
    graveyard: std.ArrayList(*Panel) = .empty,

    request: Request = .none,
    /// Give the menu keyboard focus at the next sync.
    want_focus: bool = false,
    /// Menu keyboard focus was taken; give it back when the menu closes.
    has_focus: bool = false,
    /// Window that had keyboard focus when the menu opened; it gets it back.
    return_focus: ?*types.Window = null,

    // ---- pointer ---------------------------------------------------------
    pointer_surface: ?*wl.Surface = null,
    px: i32 = 0,
    py: i32 = 0,

    pub fn init(wm: *WindowManager, compositor: *wl.Compositor, shm_global: *wl.Shm) Ui {
        return .{
            .wm = wm,
            .compositor = compositor,
            .shm = shm_global,
            .arena = std.heap.ArenaAllocator.init(wm.gpa),
        };
    }

    fn gpa(ui: *Ui) Allocator {
        return ui.wm.gpa;
    }

    /// True while a menu is shown or about to be: the keyboard belongs to it.
    pub fn menuOpen(ui: *const Ui) bool {
        return ui.panels.items.len > 0 or ui.want_focus;
    }

    pub fn deinit(ui: *Ui) void {
        ui.reapGraveyard();
        for (ui.panels.items) |op| op.panel.destroy();
        ui.panels.deinit(ui.gpa());
        for (ui.desktops.items) |d| d.panel.destroy();
        ui.desktops.deinit(ui.gpa());
        ui.graveyard.deinit(ui.gpa());
        ui.levels.deinit(ui.gpa());
        ui.arena.deinit();
    }

    // ========================================================================
    // wl_seat: pointer and keyboard (callbacks only record intent)
    // ========================================================================

    pub fn bindSeat(ui: *Ui, seat: *wl.Seat) void {
        ui.seat = seat;
        seat.setListener(*Ui, seatListener, ui);
    }

    fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, ui: *Ui) void {
        switch (event) {
            .capabilities => |c| {
                if (c.capabilities.pointer and ui.pointer == null) {
                    if (seat.getPointer()) |p| {
                        ui.pointer = p;
                        p.setListener(*Ui, pointerListener, ui);
                    } else |_| {}
                }
                if (c.capabilities.keyboard and ui.keyboard == null) {
                    if (seat.getKeyboard()) |k| {
                        ui.keyboard = k;
                        k.setListener(*Ui, keyboardListener, ui);
                    } else |_| {}
                }
            },
            else => {},
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ui: *Ui) void {
        switch (event) {
            .enter => |e| {
                ui.pointer_surface = e.surface;
                ui.px = @intCast(e.surface_x.toInt());
                ui.py = @intCast(e.surface_y.toInt());
                ui.onMotion();
            },
            .leave => ui.pointer_surface = null,
            .motion => |e| {
                ui.px = @intCast(e.surface_x.toInt());
                ui.py = @intCast(e.surface_y.toInt());
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
            // The keymap arrives as an fd we never read; close it or it leaks.
            .keymap => |k| _ = std.os.linux.close(k.fd),
            .key => |k| if (k.state == .pressed) ui.onKey(k.key),
            else => {},
        }
    }

    // ---- what a pointer event means -----------------------------------------

    fn desktopAt(ui: *Ui, s: *wl.Surface) ?*Desktop {
        for (ui.desktops.items) |*d| if (d.panel.surface == s) return d;
        return null;
    }

    fn levelFor(ui: *Ui, s: *wl.Surface) ?usize {
        for (ui.panels.items) |op| if (op.panel.surface == s) return op.level;
        return null;
    }

    fn onButton(ui: *Ui, button: u32) void {
        const s = ui.pointer_surface orelse return;

        if (ui.levelFor(s)) |li| {
            ui.clickLevel(li, button);
            return;
        }
        if (ui.desktopAt(s)) |d| {
            switch (button) {
                BTN_RIGHT => ui.request = .{ .open_root = .{ .output = d.output, .x = ui.px, .y = ui.py } },
                BTN_MIDDLE => ui.request = .{ .open_windows = .{ .output = d.output, .x = ui.px, .y = ui.py } },
                // A left click on the empty desktop dismisses the menu.
                else => if (ui.panels.items.len > 0) {
                    ui.request = .close;
                },
            }
            ui.wm.obj.manageDirty();
        }
    }

    fn onMotion(ui: *Ui) void {
        const s = ui.pointer_surface orelse return;
        const li = ui.levelFor(s) orelse return;
        ui.setHover(li, rowAt(&ui.levels.items[li], ui.py));
    }

    fn clickLevel(ui: *Ui, li: usize, button: u32) void {
        if (button != BTN_LEFT and button != BTN_RIGHT) return;
        const idx = rowAt(&ui.levels.items[li], ui.py) orelse return;
        ui.activate(li, idx);
    }

    fn onKey(ui: *Ui, key: u32) void {
        const li = ui.deepestOpen() orelse return;
        const lvl = &ui.levels.items[li];
        switch (key) {
            KEY_ESC => ui.request = .close,
            KEY_UP => ui.stepHover(li, -1),
            KEY_DOWN => ui.stepHover(li, 1),
            KEY_RIGHT, KEY_ENTER => if (lvl.hover) |i| ui.activate(li, i),
            KEY_LEFT => if (lvl.parent != null) ui.closeLevel(li),
            else => {},
        }
        ui.wm.obj.manageDirty();
    }

    fn deepestOpen(ui: *Ui) ?usize {
        var best: ?usize = null;
        for (ui.levels.items, 0..) |l, i| if (l.open) {
            best = i;
        };
        return best;
    }

    // ---- hover / navigation -----------------------------------------------

    fn setHover(ui: *Ui, li: usize, idx: ?usize) void {
        const lvl = &ui.levels.items[li];
        if (lvl.hover == idx) return;
        lvl.hover = idx;
        lvl.dirty = true;

        // Hovering another row closes what this level had opened.
        ui.closeChildrenOf(li);
        if (idx) |i| switch (lvl.rows[i].kind) {
            .submenu => |child| ui.openChild(li, i, child),
            else => {},
        };
        ui.wm.obj.manageDirty();
    }

    fn stepHover(ui: *Ui, li: usize, dir: i32) void {
        const lvl = &ui.levels.items[li];
        const n: i32 = @intCast(lvl.rows.len);
        if (n == 0) return;
        var i: i32 = if (lvl.hover) |h| @intCast(h) else if (dir > 0) -1 else n;
        var tries: i32 = 0;
        while (tries < n) : (tries += 1) {
            i = @mod(i + dir, n);
            if (lvl.rows[@intCast(i)].enabled) {
                ui.setHover(li, @intCast(i));
                return;
            }
        }
    }

    fn closeChildrenOf(ui: *Ui, li: usize) void {
        for (ui.levels.items, 0..) |*l, i| {
            if (l.open and l.parent != null and l.parent.? == li) ui.closeLevel(i);
        }
    }

    fn closeLevel(ui: *Ui, li: usize) void {
        const lvl = &ui.levels.items[li];
        if (!lvl.open) return;
        ui.closeChildrenOf(li);
        lvl.open = false;
        lvl.hover = null;
        ui.wm.obj.manageDirty();
    }

    fn openChild(ui: *Ui, parent: usize, row: usize, child: usize) void {
        const pl = ui.levels.items[parent];
        var cl = &ui.levels.items[child];
        cl.parent = parent;
        cl.parent_row = row;
        cl.hover = null;
        cl.dirty = true;
        cl.output = pl.output;
        cl.x = pl.x + pl.w - 2;
        cl.y = pl.y + title_h + @as(i32, @intCast(row)) * item_h - title_h;
        if (cl.output) |out| {
            // Flip to the left when it would leave the output.
            if (cl.x + cl.w > out.rect.right()) cl.x = pl.x - cl.w + 2;
            clampToOutput(cl, out);
        }
        cl.open = true;
    }

    fn activate(ui: *Ui, li: usize, idx: usize) void {
        const wm = ui.wm;
        const row = ui.levels.items[li].rows[idx];
        if (!row.enabled) return;

        switch (row.kind) {
            .submenu => |child| {
                ui.closeChildrenOf(li);
                ui.openChild(li, idx, child);
            },
            .exec => |cmd| {
                ui.spawnWords(cmd);
                ui.request = .close;
            },
            .shexec => |cmd| {
                proc.spawn(wm, &.{ "/bin/sh", "-c", cmd });
                ui.request = .close;
            },
            .focus_window => |w| {
                wm.pending_ui = .{ .focus = w };
                ui.request = .close;
            },
            .goto_workspace => |i| {
                wm.pending_ui = .{ .workspace = i };
                ui.request = .close;
            },
            .builtin => |b| {
                switch (b) {
                    .exit => wm.quit = true,
                    .workspace_next => wm.pending_ui = .workspace_next,
                    .workspace_prev => wm.pending_ui = .workspace_prev,
                    else => {},
                }
                ui.request = .close;
            },
            .none => {},
        }
        wm.obj.manageDirty();
    }

    fn spawnWords(ui: *Ui, cmd: []const u8) void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(ui.gpa());
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        while (it.next()) |w| argv.append(ui.gpa(), w) catch return;
        proc.spawn(ui.wm, argv.items);
    }

    // ========================================================================
    // Building the menu tree (runs in sync)
    // ========================================================================

    fn a(ui: *Ui) Allocator {
        return ui.arena.allocator();
    }

    fn zdup(ui: *Ui, s: []const u8) ![:0]const u8 {
        return ui.a().dupeZ(u8, s);
    }

    fn resetMenu(ui: *Ui) void {
        // Surfaces are destroyed at the start of the next sync, never here.
        for (ui.panels.items) |op| ui.graveyard.append(ui.gpa(), op.panel) catch op.panel.destroy();
        ui.panels.clearRetainingCapacity();
        ui.levels.clearRetainingCapacity();
        _ = ui.arena.reset(.retain_capacity);
    }

    /// Append a level for `m` (and, recursively, its submenus). Returns its index.
    fn buildLevel(ui: *Ui, m: *const wm_menu.Menu) !usize {
        const me = ui.levels.items.len;
        // Reserve our slot first so children get larger indices.
        try ui.levels.append(ui.gpa(), undefined);

        var rows: std.ArrayList(Row) = .empty;
        for (m.items) |it| {
            const label = try ui.zdup(it.label);
            const shortcut: ?[:0]const u8 = if (it.shortcut) |s| try ui.zdup(s) else null;
            switch (it.action) {
                .submenu => |sub| {
                    const child = try ui.buildLevel(sub);
                    try rows.append(ui.a(), .{ .label = label, .kind = .{ .submenu = child } });
                },
                .exec => |c| try rows.append(ui.a(), .{ .label = label, .shortcut = shortcut, .kind = .{ .exec = try ui.a().dupe(u8, c) } }),
                .shexec => |c| try rows.append(ui.a(), .{ .label = label, .shortcut = shortcut, .kind = .{ .shexec = try ui.a().dupe(u8, c) } }),
                .builtin => |b| switch (b) {
                    .workspace_menu => {
                        const child = try ui.buildWorkspaceLevel();
                        try rows.append(ui.a(), .{ .label = label, .kind = .{ .submenu = child } });
                    },
                    .windows_menu => {
                        const child = try ui.buildWindowLevel();
                        try rows.append(ui.a(), .{ .label = label, .kind = .{ .submenu = child } });
                    },
                    else => try rows.append(ui.a(), .{
                        .label = label,
                        .shortcut = shortcut,
                        .enabled = it.enabled(),
                        .kind = .{ .builtin = b },
                    }),
                },
                .open_menu, .unknown => try rows.append(ui.a(), .{ .label = label, .enabled = false, .kind = .none }),
            }
        }
        ui.levels.items[me] = .{
            .title = try ui.zdup(m.title),
            .rows = try rows.toOwnedSlice(ui.a()),
        };
        measure(&ui.levels.items[me]);
        return me;
    }

    fn buildWorkspaceLevel(ui: *Ui) !usize {
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        if (ui.wm.outputs.first()) |out| {
            var i: u32 = 0;
            while (i < out.workspace_count) : (i += 1) {
                const mark: []const u8 = if (i == out.active) "* " else "  ";
                const label = try std.fmt.allocPrintSentinel(ui.a(), "{s}Workspace {d}", .{ mark, i + 1 }, 0);
                try rows.append(ui.a(), .{ .label = label, .kind = .{ .goto_workspace = i } });
            }
        }
        ui.levels.items[me] = .{ .title = "Workspaces", .rows = try rows.toOwnedSlice(ui.a()) };
        measure(&ui.levels.items[me]);
        return me;
    }

    fn buildWindowLevel(ui: *Ui) !usize {
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            if (w.closed or w.workspace == null) continue;
            const title = w.title orelse w.app_id orelse "(untitled)";
            const label = try std.fmt.allocPrintSentinel(ui.a(), "[{d}] {s}", .{ w.workspace.?.index + 1, title }, 0);
            try rows.append(ui.a(), .{ .label = label, .kind = .{ .focus_window = w } });
        }
        if (rows.items.len == 0) {
            try rows.append(ui.a(), .{ .label = "(no windows)", .enabled = false, .kind = .none });
        }
        ui.levels.items[me] = .{ .title = "Windows", .rows = try rows.toOwnedSlice(ui.a()) };
        measure(&ui.levels.items[me]);
        return me;
    }

    // ---- geometry ----------------------------------------------------------

    fn measure(lvl: *Level) void {
        var w: i32 = gfx.measureText(lvl.title, font_title).w + 2 * pad_x;
        for (lvl.rows) |r| {
            var rw = gfx.measureText(r.label, font_item).w + 2 * pad_x;
            if (r.shortcut) |s| rw += gfx.measureText(s, font_item).w + 2 * pad_x;
            if (r.kind == .submenu) rw += arrow_w;
            w = @max(w, rw);
        }
        lvl.w = @max(w, min_menu_w);
        lvl.h = title_h + @as(i32, @intCast(lvl.rows.len)) * item_h + 2;
    }

    fn rowAt(lvl: *const Level, y: i32) ?usize {
        if (y < title_h) return null;
        const i: usize = @intCast(@divTrunc(y - title_h, item_h));
        if (i >= lvl.rows.len) return null;
        if (!lvl.rows[i].enabled) return null;
        return i;
    }

    fn clampToOutput(lvl: *Level, out: *types.Output) void {
        const r = out.rect;
        lvl.x = std.math.clamp(lvl.x, r.x, @max(r.x, r.right() - lvl.w));
        lvl.y = std.math.clamp(lvl.y, r.y, @max(r.y, r.bottom() - lvl.h));
    }

    // ========================================================================
    // sync(): the only place that talks to river. Manage sequence only.
    // ========================================================================

    pub fn sync(ui: *Ui) void {
        ui.reapGraveyard();
        ui.syncDesktops();
        ui.runRequest();
        ui.syncMenu();
        ui.syncFocus();
    }

    /// Render sequence: restacking only (rendering state is legal there).
    pub fn onRender(ui: *Ui) void {
        for (ui.panels.items) |op| op.panel.node.placeTop();
    }

    fn reapGraveyard(ui: *Ui) void {
        while (ui.graveyard.pop()) |p| p.destroy();
    }

    // ---- desktop catchers ---------------------------------------------------

    fn syncDesktops(ui: *Ui) void {
        // Drop desktops whose output is gone or changed size.
        var i: usize = 0;
        while (i < ui.desktops.items.len) {
            const d = ui.desktops.items[i];
            if (d.output.removed or d.panel.w != d.output.rect.w or d.panel.h != d.output.rect.h) {
                ui.graveyard.append(ui.gpa(), d.panel) catch d.panel.destroy();
                _ = ui.desktops.swapRemove(i);
            } else i += 1;
        }

        var it = ui.wm.outputs.first();
        while (it) |out| : (it = types.nextOutput(out, ui.wm)) {
            if (out.removed or !out.ready()) continue;
            var found = false;
            for (ui.desktops.items) |d| if (d.output == out) {
                found = true;
                break;
            };
            if (!found) ui.createDesktop(out);
        }

        for (ui.desktops.items) |d| {
            place(d.panel, d.output.rect.x, d.output.rect.y);
            d.panel.node.placeBottom();
        }
    }

    fn createDesktop(ui: *Ui, out: *types.Output) void {
        const panel = Panel.create(ui, out.rect.w, out.rect.h) catch |err| {
            std.log.err("desktop surface: {t}", .{err});
            return;
        };
        // A fully transparent surface still takes pointer input, and the
        // wallpaper (if any) stays visible.
        const slot = panel.freeSlot() catch |err| {
            std.log.err("desktop buffer: {t}", .{err});
            panel.destroy();
            return;
        };
        slot.canvas.clear(col_clear);
        panel.present(slot);
        ui.desktops.append(ui.gpa(), .{ .output = out, .panel = panel }) catch {
            panel.destroy();
            return;
        };
        std.log.info("desktop surface {d}x{d} at {d},{d}", .{ out.rect.w, out.rect.h, out.rect.x, out.rect.y });
    }

    fn place(p: *Panel, x: i32, y: i32) void {
        if (p.sent_x == x and p.sent_y == y) return;
        p.node.setPosition(x, y);
        p.sent_x = x;
        p.sent_y = y;
    }

    // ---- requests from callbacks ---------------------------------------------

    fn runRequest(ui: *Ui) void {
        const req = ui.request;
        ui.request = .none;
        switch (req) {
            .none => {},
            .close => {
                ui.resetMenu();
                ui.want_focus = false;
            },
            .open_root => |r| ui.openTop(r.output, r.x, r.y, false),
            .open_windows => |r| ui.openTop(r.output, r.x, r.y, true),
        }
    }

    fn openTop(ui: *Ui, out: *types.Output, x: i32, y: i32, windows_only: bool) void {
        ui.resetMenu();
        const built: anyerror!usize = if (windows_only)
            ui.buildWindowLevel()
        else if (ui.wm.root_menu) |menu|
            ui.buildLevel(menu)
        else {
            std.log.warn("root menu: none loaded", .{});
            return;
        };
        const top = built catch |err| {
            std.log.err("root menu build failed: {t}", .{err});
            ui.resetMenu();
            return;
        };
        var lvl = &ui.levels.items[top];
        lvl.output = out;
        lvl.x = out.rect.x + x;
        lvl.y = out.rect.y + y;
        clampToOutput(lvl, out);
        lvl.open = true;
        lvl.dirty = true;
        ui.want_focus = true;
        std.log.info("menu `{s}` at {d},{d} ({d} rows)", .{ lvl.title, lvl.x, lvl.y, lvl.rows.len });
    }

    // ---- menu surfaces --------------------------------------------------------

    fn panelFor(ui: *Ui, li: usize) ?*Panel {
        for (ui.panels.items) |op| if (op.level == li) return op.panel;
        return null;
    }

    fn syncMenu(ui: *Ui) void {
        // Close panels of levels that are no longer open.
        var i: usize = 0;
        while (i < ui.panels.items.len) {
            const op = ui.panels.items[i];
            if (op.level >= ui.levels.items.len or !ui.levels.items[op.level].open) {
                ui.graveyard.append(ui.gpa(), op.panel) catch op.panel.destroy();
                _ = ui.panels.orderedRemove(i);
            } else i += 1;
        }

        // Open / redraw open levels (parents first: lower index first).
        for (ui.levels.items, 0..) |*lvl, li| {
            if (!lvl.open) continue;
            const panel = ui.panelFor(li) orelse blk: {
                const p = Panel.create(ui, lvl.w, lvl.h) catch |err| {
                    std.log.err("menu surface: {t}", .{err});
                    lvl.open = false;
                    continue;
                };
                ui.panels.append(ui.gpa(), .{ .level = li, .panel = p }) catch {
                    p.destroy();
                    lvl.open = false;
                    continue;
                };
                lvl.dirty = true;
                break :blk p;
            };

            if (lvl.dirty or !panel.committed) {
                const slot = panel.freeSlot() catch {
                    // river has not released a buffer yet; retry next sequence.
                    ui.wm.obj.manageDirty();
                    continue;
                };
                draw(slot, lvl);
                panel.present(slot);
                lvl.dirty = false;
            }
            place(panel, lvl.x, lvl.y);
            panel.node.placeTop();
        }
    }

    fn syncFocus(ui: *Ui) void {
        const seat = ui.wm.seats.first() orelse return;
        if (ui.want_focus and ui.panels.items.len > 0) {
            if (!ui.has_focus) ui.return_focus = seat.focused;
            seat.obj.focusShellSurface(ui.panels.items[0].panel.shell);
            ui.want_focus = false;
            ui.has_focus = true;
        } else if (ui.has_focus and ui.panels.items.len == 0) {
            // Menu closed. seat.focus() skips a window that is already
            // `focused`, so clear it, then ask for the old window back
            // (a menu action such as "focus window" may already have
            // set its own request; that one wins).
            seat.focused = null;
            if (ui.wm.focus_request == null) {
                if (ui.return_focus) |w| {
                    if (!w.closed and w.workspace != null) ui.wm.focus_request = w;
                }
            }
            ui.return_focus = null;
            ui.has_focus = false;
        }
    }

    /// A window is going away: the menu must not keep a pointer to it.
    /// Rows that would focus it stay visible (the list is a snapshot) but
    /// can no longer be activated.
    pub fn forgetWindow(ui: *Ui, w: *types.Window) void {
        if (ui.return_focus == w) ui.return_focus = null;
        for (ui.levels.items) |*lvl| {
            for (lvl.rows) |*row| switch (row.kind) {
                .focus_window => |rw| if (rw == w) {
                    row.kind = .none;
                    row.enabled = false;
                    lvl.dirty = true;
                },
                else => {},
            };
        }
    }

    // ---- drawing --------------------------------------------------------------

    fn draw(slot: *Slot, lvl: *const Level) void {
        var cv = &slot.canvas;
        cv.clear(col_bg);

        cv.vGradient(1, 1, lvl.w - 2, title_h - 1, col_title_top, col_title_bot);
        const tw = gfx.measureText(lvl.title, font_title).w;
        cv.drawText(lvl.title, @divTrunc(lvl.w - tw, 2), 3, font_title, col_hi_text);

        for (lvl.rows, 0..) |r, i| {
            const y = title_h + @as(i32, @intCast(i)) * item_h;
            const hot = r.enabled and lvl.hover != null and lvl.hover.? == i;
            if (hot) cv.fillRect(2, y, lvl.w - 4, item_h, col_hi_bg);
            const tc = if (hot) col_hi_text else if (r.enabled) col_text else col_disabled;
            cv.drawText(r.label, pad_x, y + 2, font_item, tc);
            if (r.shortcut) |s| {
                const sw = gfx.measureText(s, font_item).w;
                cv.drawText(s, lvl.w - sw - pad_x, y + 2, font_item, tc);
            }
            if (r.kind == .submenu) {
                const cx = lvl.w - pad_x;
                const cy = y + @divTrunc(item_h, 2);
                cv.fillRect(cx - 4, cy - 3, 2, 6, tc);
                cv.fillRect(cx - 2, cy - 2, 2, 4, tc);
                cv.fillRect(cx, cy - 1, 2, 2, tc);
            }
        }
        cv.bevel(0, 0, lvl.w, lvl.h, col_light, col_dark);
    }
};

// ----------------------------------------------------------------------------
// Tests: everything that can go wrong without a compositor. The protocol
// side (surfaces, commits) cannot be run here; the model, layout and the
// pixels that end up in the buffer can.
// ----------------------------------------------------------------------------

fn testLevel(rows: []Row) Level {
    var l: Level = .{ .title = "Applications", .rows = rows };
    Ui.measure(&l);
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

test "rowAt maps y to rows, skips title and disabled rows" {
    var rows = [_]Row{
        .{ .label = "one", .kind = .none },
        .{ .label = "two", .enabled = false, .kind = .none },
        .{ .label = "three", .kind = .none },
    };
    const l = testLevel(&rows);
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, 5)); // title bar
    try std.testing.expectEqual(@as(?usize, 0), Ui.rowAt(&l, title_h + 1));
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, title_h + item_h + 1)); // disabled
    try std.testing.expectEqual(@as(?usize, 2), Ui.rowAt(&l, title_h + 2 * item_h + 1));
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, title_h + 3 * item_h + 1)); // below
}

test "clampToOutput keeps the menu on screen" {
    var rows = [_]Row{.{ .label = "x", .kind = .none }};
    var l = testLevel(&rows);
    var out: types.Output = .{ .obj = undefined };
    out.rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    l.x = 790;
    l.y = 590;
    Ui.clampToOutput(&l, &out);
    try std.testing.expect(l.x + l.w <= 800);
    try std.testing.expect(l.y + l.h <= 600);
    l.x = -50;
    l.y = -50;
    Ui.clampToOutput(&l, &out);
    try std.testing.expectEqual(@as(i32, 0), l.x);
    try std.testing.expectEqual(@as(i32, 0), l.y);
}

/// Read one ARGB32 pixel (premultiplied, little endian) as 0xAARRGGBB.
fn pixel(data: []const u8, stride: i32, x: i32, y: i32) u32 {
    const o: usize = @intCast(y * stride + x * 4);
    return std.mem.readInt(u32, data[o..][0..4], .little);
}

test "Ui.draw() actually paints: title gradient, highlight, text, bevel" {
    var rows = [_]Row{
        .{ .label = "Terminal", .kind = .none },
        .{ .label = "Firefox", .kind = .none },
    };
    var l = testLevel(&rows);
    l.hover = 1;

    const stride = l.w * 4;
    const bytes = try std.testing.allocator.alloc(u8, @intCast(stride * l.h));
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    var canvas = try gfx.Canvas.initForData(bytes.ptr, l.w, l.h, stride);
    defer canvas.deinit();
    var slot: Slot = .{ .buf = undefined, .canvas = canvas };
    Ui.draw(&slot, &l);

    // Every pixel is opaque: nothing was left transparent.
    try std.testing.expectEqual(@as(u32, 0xff), pixel(bytes, stride, @divTrunc(l.w, 2), 5) >> 24);
    // Title bar is dark (gradient black -> 0x444444), the body is light grey.
    const title_px = pixel(bytes, stride, 4, 4) & 0xffffff;
    const body_px = pixel(bytes, stride, l.w - 6, title_h + 2) & 0xffffff;
    try std.testing.expect(title_px < 0x505050);
    try std.testing.expectEqual(@as(u32, 0xaeaaae), body_px);
    // Hovered row (index 1) is black, the other is not.
    const hi = pixel(bytes, stride, l.w - 6, title_h + item_h + 2) & 0xffffff;
    try std.testing.expectEqual(@as(u32, 0x000000), hi);
    // Bevel: light top-left edge, dark bottom-right edge.
    try std.testing.expectEqual(@as(u32, 0xffffff), pixel(bytes, stride, 0, 0) & 0xffffff);
    try std.testing.expectEqual(@as(u32, 0x555555), pixel(bytes, stride, l.w - 1, l.h - 1) & 0xffffff);

    // Text really was rendered: some pixel in the first row differs from
    // the plain background (glyph antialiasing).
    var text_pixels: usize = 0;
    var x: i32 = pad_x;
    while (x < pad_x + 40) : (x += 1) {
        var y: i32 = title_h + 2;
        while (y < title_h + item_h - 2) : (y += 1) {
            if (pixel(bytes, stride, x, y) & 0xffffff != 0xaeaaae) text_pixels += 1;
        }
    }
    try std.testing.expect(text_pixels > 20);
}

test "forgetWindow disables window rows and drops the focus to return" {
    var wm: types.WindowManager = undefined;
    var ui: Ui = .{
        .wm = &wm,
        .compositor = undefined,
        .shm = undefined,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer ui.arena.deinit();
    defer ui.levels.deinit(std.testing.allocator);

    var w1: types.Window = .{ .obj = undefined, .node = undefined };
    var w2: types.Window = .{ .obj = undefined, .node = undefined };
    var rows = [_]Row{
        .{ .label = "[1] one", .kind = .{ .focus_window = &w1 } },
        .{ .label = "[1] two", .kind = .{ .focus_window = &w2 } },
    };
    try ui.levels.append(std.testing.allocator, .{ .title = "Windows", .rows = &rows });
    ui.return_focus = &w1;
    ui.levels.items[0].dirty = false;

    ui.forgetWindow(&w1);

    try std.testing.expect(ui.return_focus == null);
    try std.testing.expect(!rows[0].enabled);
    try std.testing.expect(rows[0].kind == .none);
    try std.testing.expect(ui.levels.items[0].dirty); // will be redrawn greyed out
    // The other window is untouched.
    try std.testing.expect(rows[1].enabled);
    try std.testing.expect(rows[1].kind == .focus_window);
}
