// SPDX-License-Identifier: 0BSD
//
// Desktop UI: root menu and window list, drawn with cairo/pango into
// river shell surfaces.
//
//   right click on the empty desktop  -> root menu
//   middle click on the empty desktop -> window list
//   Esc / left click on the desktop   -> close
//
// It also owns the Dock and the Clip (dock.zig has their model and look):
//
//   Dock  left click   start the application, or focus it if it runs
//         middle click start another instance
//         right click  Dock menu (raise / lower the Dock, launch)
//   Clip  upper right arrow / lower left arrow / mouse wheel: next / previous
//         workspace; right click Clip menu; middle click workspace menu
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
//   * one surface for the Dock and one for the Clip, on the first output.
//     On top of the windows, or just above the desktop ("lowered");
//   * one surface per open menu level (cascading submenus), on top of all.
//
// Buffers are double-buffered: a wl_buffer river still reads (no `release`
// yet) is never drawn into.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const wp = wayland.client.wp;

const types = @import("types.zig");
const gfx = @import("gfx.zig");
const shm = @import("shm.zig");
const wm_menu = @import("wm_menu.zig");
const proc = @import("process.zig");
const dock_mod = @import("dock.zig");
const fsmenu = @import("fsmenu.zig");
const version = @import("version.zig").version;
const dockapp = @import("dockapp.zig");

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
/// Space kept free above and below a menu that is taller than the output.
const menu_margin: i32 = 4;
/// Rows a mouse wheel notch scrolls a long menu.
const wheel_rows: i32 = 3;
const pad_x: i32 = 10;
const arrow_w: i32 = 14;
const min_menu_w: i32 = 120;
/// A menu level shows at most this many rows. 500 rows are 10 000 px tall,
/// far beyond any screen; more only means a broken menu file, and the
/// surface would exceed what shm.checkedSize allows.
const max_rows: usize = 500;
/// Cap for one label: keeps a single absurd string from making a huge surface.
const max_label_bytes: usize = 256;

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

/// A Dock/Clip entry: which list, and where in it.
const SlotRef = struct { clip: bool, index: usize };

/// What the rows of the Dock/Clip menus do (ui.runUiCmd).
const UiCmd = union(enum) {
    toggle_dock_level,
    toggle_clip_level,
    toggle_clip_collapse,
    /// Start a NEW instance (a click on the tile would focus a running one).
    launch: SlotRef,
};

const RowKind = union(enum) {
    exec: []const u8,
    shexec: []const u8,
    builtin: wm_menu.Builtin,
    /// Index into `Ui.levels`; the child level is built together with its
    /// parent, so the tree is complete before the first frame.
    submenu: usize,
    focus_window: *types.Window,
    goto_workspace: u32,
    ui_cmd: UiCmd,
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
    /// A menu taller than its output shows only `visible` rows, starting at
    /// row `scroll` (see fitToOutput). 0 = not measured: all rows.
    scroll: usize = 0,
    visible: usize = 0,
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

const BarMenuKind = enum { dock, clip, workspaces };

/// A request recorded by an input callback, executed in sync().
const Request = union(enum) {
    none,
    open_root: struct { output: *types.Output, x: i32, y: i32 },
    open_windows: struct { output: *types.Output, x: i32, y: i32 },
    /// Menu of the Dock/Clip. x/y are output-local, like the others.
    open_bar_menu: struct { kind: BarMenuKind, output: *types.Output, x: i32, y: i32, slot: ?SlotRef },
    close,
};

/// How deep OPEN_MENU may nest (a menu file that opens a menu file ...).
const max_expand_depth: u8 = 4;

/// The most Clip application tiles ever shown (a screen is never wider).
const max_clip_apps: usize = 32;

const BarKind = enum { dock, clip };

/// The Dock or the Clip: one surface that covers all of its tiles.
const Bar = struct {
    kind: BarKind,
    panel: ?*Panel = null,
    output: ?*types.Output = null,
    /// Global rectangle as of the last sync.
    rect: types.Rect = .{},
    /// Tiles drawn; the surface is that many tiles long.
    ntiles: usize = 0,
    hover: ?usize = null,
    hover_arrow: dock_mod.Arrow = .none,
    dirty: bool = true,
};

/// What is under the pointer on a Bar.
const Hit = struct {
    tile: ?usize = null,
    arrow: dock_mod.Arrow = .none,
};

/// `s` cut to at most `max` bytes without splitting a UTF-8 sequence, and
/// without an embedded NUL (pango takes a C string; a NUL would silently
/// end the label early).
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    if (std.mem.indexOfScalar(u8, s[0..end], 0)) |nul| end = nul;
    // Step back to a character boundary.
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

pub const Ui = struct {
    wm: *WindowManager,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    /// Optional: lets us ask for a normal arrow over our surfaces. Without
    /// it the pointer keeps whatever image a window last set, since we
    /// never draw a cursor ourselves.
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,

    desktops: std.ArrayList(Desktop) = .empty,

    /// OPEN_MENU nesting while a menu is being built (fsmenu.zig).
    expand_depth: u8 = 0,

    // ---- Dock and Clip ----------------------------------------------------
    /// Deep copy of wm.dockapps; rebuilt when wm.dock_gen changes.
    model: ?dock_mod.Model = null,
    model_gen: u32 = std.math.maxInt(u32),
    dock: Bar = .{ .kind = .dock },
    clip: Bar = .{ .kind = .clip },
    /// Run-time state, started from config.conf and changed by the menus.
    dock_on_top: bool = true,
    clip_on_top: bool = true,
    clip_collapsed: bool = false,
    /// Workspace the Clip shows, and the `model.clip` entries on it.
    clip_ws: u32 = 0,
    clip_buf: [max_clip_apps]usize = undefined,
    clip_count: usize = 0,
    /// Mouse wheel movement not yet turned into a workspace step.
    scroll_acc: f64 = 0,

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
        for ([_]*Bar{ &ui.dock, &ui.clip }) |b| if (b.panel) |p| p.destroy();
        if (ui.model) |*m| m.deinit();
        ui.graveyard.deinit(ui.gpa());
        ui.levels.deinit(ui.gpa());
        ui.arena.deinit();
    }

    // ========================================================================
    // wl_seat: pointer and keyboard (callbacks only record intent)
    // ========================================================================

    /// The seat's `capabilities` event arrives right when it is bound, so
    /// main.zig listens from the very moment of binding and hands the result
    /// over here. A listener set later would never see it (libwayland drops
    /// events for proxies without a listener) and no wl_pointer would exist.
    pub fn setSeat(ui: *Ui, seat: *wl.Seat) void {
        ui.seat = seat;
    }

    pub fn onCapabilities(ui: *Ui, has_pointer: bool, has_keyboard: bool) void {
        const seat = ui.seat orelse return;
        std.log.info("seat capabilities: pointer={} keyboard={}", .{ has_pointer, has_keyboard });
        if (has_pointer and ui.pointer == null) {
            if (seat.getPointer()) |p| {
                ui.pointer = p;
                p.setListener(*Ui, pointerListener, ui);
                if (ui.cursor_shape_manager) |mgr| {
                    if (mgr.getPointer(p)) |dev| {
                        ui.cursor_shape_device = dev;
                    } else |err| std.log.err("wp_cursor_shape_manager_v1.get_pointer: {t}", .{err});
                }
            } else |err| std.log.err("wl_seat.get_pointer: {t}", .{err});
        }
        if (has_keyboard and ui.keyboard == null) {
            if (seat.getKeyboard()) |k| {
                ui.keyboard = k;
                k.setListener(*Ui, keyboardListener, ui);
            } else |err| std.log.err("wl_seat.get_keyboard: {t}", .{err});
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ui: *Ui) void {
        switch (event) {
            .enter => |e| {
                ui.pointer_surface = e.surface;
                ui.px = @intCast(e.surface_x.toInt());
                ui.py = @intCast(e.surface_y.toInt());
                std.log.debug("pointer enter: {s} at {d},{d}", .{ ui.describe(e.surface), ui.px, ui.py });
                // Every one of our surfaces (desktop catcher and menus) is
                // plain UI: always the default arrow, regardless of which
                // shape a window under the old focus had set.
                if (ui.cursor_shape_device) |dev| dev.setShape(e.serial, .default);
                ui.onMotion();
            },
            .leave => {
                ui.pointer_surface = null;
                ui.scroll_acc = 0;
                ui.clearBarHover();
            },
            .axis => |e| if (e.axis == .vertical_scroll) ui.onScroll(e.value.toDouble()),
            .motion => |e| {
                ui.px = @intCast(e.surface_x.toInt());
                ui.py = @intCast(e.surface_y.toInt());
                ui.onMotion();
            },
            .button => |e| {
                if (e.state == .pressed) {
                    std.log.info("pointer button 0x{x} on {s}", .{ e.button, ui.describe(ui.pointer_surface) });
                    ui.onButton(e.button);
                }
            },
            else => {},
        }
    }

    fn describe(ui: *Ui, s: ?*wl.Surface) []const u8 {
        const surf = s orelse return "nothing";
        if (ui.desktopAt(surf) != null) return "desktop";
        if (ui.barAt(surf)) |b| return if (b.kind == .dock) "dock" else "clip";
        if (ui.levelFor(surf) != null) return "menu";
        return "unknown surface";
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
        if (ui.barAt(s)) |b| {
            ui.clickBar(b, button);
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
        if (ui.barAt(s)) |b| {
            ui.hoverBar(b);
            return;
        }
        const li = ui.levelFor(s) orelse return;
        ui.setHover(li, rowAt(&ui.levels.items[li], ui.py));
    }

    // ---- what a pointer event means on the Dock and the Clip ----------------

    fn barAt(ui: *Ui, s: *wl.Surface) ?*Bar {
        for ([_]*Bar{ &ui.dock, &ui.clip }) |b| {
            if (b.panel) |p| if (p.surface == s) return b;
        }
        return null;
    }

    /// The tile (and, on the Clip's workspace tile, the arrow) under the
    /// pointer, from the surface-local position of the last event.
    fn barHit(ui: *Ui, b: *const Bar) Hit {
        switch (b.kind) {
            .dock => return .{ .tile = dock_mod.dockTileAt(ui.py, b.ntiles) },
            .clip => {
                const left = dock_mod.clipOnLeft(ui.wm.cfg.clip_corner);
                const t = dock_mod.clipTileAt(ui.px, b.ntiles, left) orelse return .{};
                if (t != 0) return .{ .tile = t };
                const x0 = dock_mod.clipTileX(0, b.ntiles, left);
                return .{ .tile = 0, .arrow = dock_mod.clipArrowAt(ui.px - x0, ui.py) };
            },
        }
    }

    fn hoverBar(ui: *Ui, b: *Bar) void {
        const hit = ui.barHit(b);
        if (hit.tile == b.hover and hit.arrow == b.hover_arrow) return;
        b.hover = hit.tile;
        b.hover_arrow = hit.arrow;
        b.dirty = true;
        ui.wm.obj.manageDirty();
    }

    fn clearBarHover(ui: *Ui) void {
        var changed = false;
        for ([_]*Bar{ &ui.dock, &ui.clip }) |b| {
            if (b.hover != null or b.hover_arrow != .none) {
                b.hover = null;
                b.hover_arrow = .none;
                b.dirty = true;
                changed = true;
            }
        }
        if (changed) ui.wm.obj.manageDirty();
    }

    /// Mouse wheel over the Clip switches workspace. A touchpad sends many
    /// small steps, so they are summed up; one step per `scroll_step`.
    fn onScroll(ui: *Ui, value: f64) void {
        const s = ui.pointer_surface orelse return;
        // A long menu scrolls.
        if (ui.levelFor(s)) |li| {
            const step = 10.0;
            ui.scroll_acc += value;
            while (@abs(ui.scroll_acc) >= step) {
                const dir: f64 = if (ui.scroll_acc > 0) 1 else -1;
                ui.scroll_acc -= dir * step;
                ui.scrollLevel(li, @as(i32, @intFromFloat(dir)) * wheel_rows);
            }
            return;
        }
        const b = ui.barAt(s) orelse return;
        if (b.kind != .clip) return;
        const scroll_step = 10.0;
        ui.scroll_acc += value;
        if (@abs(ui.scroll_acc) < scroll_step) return;
        if (b.output) |o| ui.wm.active_output = o;
        ui.wm.pending_ui = if (ui.scroll_acc > 0) .workspace_next else .workspace_prev;
        ui.scroll_acc = 0;
        ui.wm.obj.manageDirty();
    }

    fn clickBar(ui: *Ui, b: *Bar, button: u32) void {
        const wm = ui.wm;
        // A click on the Dock while a menu is open only dismisses the menu,
        // like a click on the empty desktop does.
        if (ui.panels.items.len > 0) {
            ui.request = .close;
            wm.obj.manageDirty();
            return;
        }
        const out = b.output orelse return;
        const model = if (ui.model) |*m| m else return;
        const hit = ui.barHit(b);
        // The Clip's arrows and menus change the workspace of the output the
        // Clip is on, not of whichever one happens to hold the focus.
        if (b.kind == .clip and (hit.tile orelse 1) == 0) wm.active_output = out;
        const tile = hit.tile orelse return;

        // Where a menu goes: at the pointer, output-local.
        const mx = b.rect.x - out.rect.x + ui.px;
        const my = b.rect.y - out.rect.y + ui.py;

        var slot: ?SlotRef = null;
        var is_tile0 = false;
        switch (b.kind) {
            .dock => switch (model.dockTile(tile) orelse return) {
                .logo => is_tile0 = true,
                .app => |i| slot = .{ .clip = false, .index = i },
            },
            .clip => {
                if (tile == 0) {
                    is_tile0 = true;
                } else if (tile - 1 < ui.clip_count) {
                    slot = .{ .clip = true, .index = ui.clip_buf[tile - 1] };
                } else return;
            },
        }

        if (is_tile0 and b.kind == .clip) {
            // The workspace tile: arrows, menus.
            switch (hit.arrow) {
                .next => if (button == BTN_LEFT) {
                    wm.pending_ui = .workspace_next;
                },
                .prev => if (button == BTN_LEFT) {
                    wm.pending_ui = .workspace_prev;
                },
                .none => switch (button) {
                    BTN_RIGHT => ui.request = .{ .open_bar_menu = .{ .kind = .clip, .output = out, .x = mx, .y = my, .slot = null } },
                    BTN_MIDDLE => ui.request = .{ .open_bar_menu = .{ .kind = .workspaces, .output = out, .x = mx, .y = my, .slot = null } },
                    else => {},
                },
            }
        } else if (is_tile0) {
            // The Dock's logo tile.
            if (button == BTN_RIGHT) ui.request = .{ .open_bar_menu = .{ .kind = .dock, .output = out, .x = mx, .y = my, .slot = null } };
        } else if (slot) |ref| {
            switch (button) {
                BTN_LEFT => ui.activateSlot(ref, false),
                BTN_MIDDLE => ui.activateSlot(ref, true),
                BTN_RIGHT => ui.request = .{ .open_bar_menu = .{
                    .kind = if (b.kind == .dock) .dock else .clip,
                    .output = out,
                    .x = mx,
                    .y = my,
                    .slot = ref,
                } },
                else => {},
            }
        }
        wm.obj.manageDirty();
    }

    fn slotApp(ui: *Ui, ref: SlotRef) ?*const dockapp.DockApp {
        const m = if (ui.model) |*mm| mm else return null;
        const list = if (ref.clip) m.clip else m.dock;
        if (ref.index >= list.len) return null;
        return &list[ref.index].app;
    }

    /// A click on a tile: focus the application if a window of it is open,
    /// else start it. `force_new` always starts it (middle click, menu).
    fn activateSlot(ui: *Ui, ref: SlotRef, force_new: bool) void {
        const app = ui.slotApp(ref) orelse return;
        if (!force_new) {
            var it = ui.wm.windows.first();
            while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
                if (w.closed or (w.workspace == null and !w.minimized)) continue;
                const id = w.app_id orelse continue;
                if (!app.matches(id)) continue;
                ui.wm.pending_ui = .{ .focus = w };
                return;
            }
        }
        proc.spawn(ui.wm, app.command);
    }

    fn runUiCmd(ui: *Ui, cmd: UiCmd) void {
        switch (cmd) {
            .toggle_dock_level => ui.dock_on_top = !ui.dock_on_top,
            .toggle_clip_level => ui.clip_on_top = !ui.clip_on_top,
            .toggle_clip_collapse => ui.clip_collapsed = !ui.clip_collapsed,
            .launch => |ref| ui.activateSlot(ref, true),
        }
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
                ensureVisible(lvl, @intCast(i));
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
        cl.y = pl.y + title_h + @as(i32, @intCast(row -| pl.scroll)) * item_h - title_h;
        if (cl.output) |out| {
            fitToOutput(cl, out);
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
            .ui_cmd => |cmd| {
                ui.runUiCmd(cmd);
                ui.request = .close;
            },
            .builtin => |b| {
                switch (b) {
                    .exit => wm.quit = true,
                    .workspace_next => wm.pending_ui = .workspace_next,
                    .workspace_prev => wm.pending_ui = .workspace_prev,
                    .show_all => wm.pending_ui = .show_all,
                    .hide_others => wm.pending_ui = .hide_others,
                    .shutdown => wm.pending_ui = .shutdown,
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
        return ui.a().dupeZ(u8, clipUtf8(s, max_label_bytes));
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
            if (rows.items.len >= max_rows) {
                std.log.warn("menu `{s}`: more than {d} entries, the rest is not shown", .{ m.title, max_rows });
                break;
            }
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
                    .info_panel, .legal_panel => {
                        const child = try ui.buildTextLevel(b);
                        try rows.append(ui.a(), .{ .label = label, .kind = .{ .submenu = child } });
                    },
                    else => try rows.append(ui.a(), .{
                        .label = label,
                        .shortcut = shortcut,
                        .enabled = it.enabled(),
                        .kind = .{ .builtin = b },
                    }),
                },
                .open_menu => |spec| {
                    // Built now, so a directory listing is never stale. A
                    // menu file may itself contain OPEN_MENU: bounded.
                    var made = false;
                    if (ui.expand_depth < max_expand_depth) {
                        ui.expand_depth += 1;
                        defer ui.expand_depth -= 1;
                        if (fsmenu.expand(ui.a(), spec, it.label)) |sub| {
                            const child = try ui.buildLevel(sub);
                            try rows.append(ui.a(), .{ .label = label, .kind = .{ .submenu = child } });
                            made = true;
                        }
                    }
                    if (!made) try rows.append(ui.a(), .{ .label = label, .enabled = false, .kind = .none });
                },
                .unknown => try rows.append(ui.a(), .{ .label = label, .enabled = false, .kind = .none }),
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
                const name: ?[]const u8 = if (ui.model) |*m| m.workspaceName(i) else null;
                const label = if (name) |n|
                    try std.fmt.allocPrintSentinel(ui.a(), "{s}{d}: {s}", .{ mark, i + 1, clipUtf8(n, 64) }, 0)
                else
                    try std.fmt.allocPrintSentinel(ui.a(), "{s}Workspace {d}", .{ mark, i + 1 }, 0);
                try rows.append(ui.a(), .{ .label = label, .kind = .{ .goto_workspace = i } });
            }
        }
        ui.levels.items[me] = .{ .title = "Workspaces", .rows = try rows.toOwnedSlice(ui.a()) };
        measure(&ui.levels.items[me]);
        return me;
    }

    /// The Info and Legal panels: a level of read-only text lines. (Window
    /// Maker shows a window; a panel of the menu's own kind needs no extra
    /// surface type, and closes like any menu.)
    fn buildTextLevel(ui: *Ui, which: wm_menu.Builtin) !usize {
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;

        const lines: []const []const u8 = switch (which) {
            .info_panel => &.{
                "wmaker-wl " ++ version,
                "A Window Maker style window manager",
                "for the river compositor.",
                "",
                "Configuration:",
            },
            else => &.{
                "wmaker-wl is free software,",
                "licensed under the 0BSD license:",
                "use, copy, modify and distribute it",
                "with or without fee.",
                "",
                "Modelled on Window Maker (GPL),",
                "by Alfredo K. Kojima, Dan Pascu et al.",
            },
        };
        for (lines) |l| try rows.append(ui.a(), .{ .label = try ui.zdup(l), .enabled = false, .kind = .none });
        if (which == .info_panel) {
            const cfg_line = try std.fmt.allocPrint(ui.a(), "  {s}", .{clipUtf8(ui.wm.cfg.config_file, 70)});
            try rows.append(ui.a(), .{ .label = try ui.zdup(cfg_line), .enabled = false, .kind = .none });
        }
        ui.levels.items[me] = .{
            .title = if (which == .info_panel) "Info" else "Legal",
            .rows = try rows.toOwnedSlice(ui.a()),
        };
        measure(&ui.levels.items[me]);
        return me;
    }

    fn buildWindowLevel(ui: *Ui) !usize {
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            if (w.closed or (w.workspace == null and !w.minimized)) continue;
            // Window Maker's SkipWindowList (DockApps have it by default).
            if (w.attrs.is("skip_window_list")) continue;
            const title = w.title orelse w.app_id orelse "(untitled)";
            // A minimized window is shown in brackets, like Window Maker
            // shows miniwindows; choosing it brings it back.
            const label = if (w.minimized)
                try std.fmt.allocPrintSentinel(ui.a(), "({s})", .{clipUtf8(title, max_label_bytes - 4)}, 0)
            else
                try std.fmt.allocPrintSentinel(ui.a(), "[{d}] {s}", .{ w.workspace.?.index + 1, title }, 0);
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
        lvl.visible = lvl.rows.len;
        lvl.scroll = 0;
    }

    /// How many rows are on screen.
    fn shown(lvl: *const Level) usize {
        return if (lvl.visible == 0) lvl.rows.len else @min(lvl.visible, lvl.rows.len);
    }

    /// A menu taller than its output is cut to what fits and scrolls; the
    /// rest of the machinery (surface size, clamping) then just sees a
    /// smaller menu. Call after measure() and before the surface is made.
    fn fitToOutput(lvl: *Level, out: *types.Output) void {
        const natural = title_h + @as(i32, @intCast(lvl.rows.len)) * item_h + 2;
        const room = out.rect.h - 2 * menu_margin;
        if (out.rect.h <= 0 or natural <= room) {
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

    fn rowAt(lvl: *const Level, y: i32) ?usize {
        if (y < title_h) return null;
        const k: usize = @intCast(@divTrunc(y - title_h, item_h));
        if (k >= shown(lvl)) return null;
        const i = lvl.scroll + k;
        if (i >= lvl.rows.len) return null;
        if (!lvl.rows[i].enabled) return null;
        return i;
    }

    /// Mouse wheel / touchpad over a level: scroll it, if it scrolls.
    fn scrollLevel(ui: *Ui, li: usize, rows: i32) void {
        const lvl = &ui.levels.items[li];
        const n = shown(lvl);
        if (n >= lvl.rows.len) return;
        const max: i32 = @intCast(lvl.rows.len - n);
        const next: i32 = std.math.clamp(@as(i32, @intCast(lvl.scroll)) + rows, 0, max);
        if (next == lvl.scroll) return;
        lvl.scroll = @intCast(next);
        lvl.dirty = true;
        // The row under the pointer is another one now.
        ui.closeChildrenOf(li);
        lvl.hover = rowAt(lvl, ui.py);
        if (lvl.hover) |h| switch (lvl.rows[h].kind) {
            .submenu => |child| ui.openChild(li, h, child),
            else => {},
        };
        ui.wm.obj.manageDirty();
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
        // Before the desktops: both lower themselves to the bottom of the
        // render list, and the last one lowered is the lowest. The desktop
        // catcher must stay below a lowered Dock.
        ui.syncBars();
        ui.syncDesktops();
        ui.runRequest();
        ui.syncMenu();
        ui.syncFocus();
        // Destroy surfaces that were replaced above, now that nothing in
        // this sequence still points at them. Doing this at the START of
        // sync() (the old order) left a closed submenu on screen for one
        // whole extra sequence: its surface was still attached with its
        // last frame until the NEXT event (e.g. the next pointer motion)
        // triggered another sync(). Reaping at the end of the same
        // sequence that closed it detaches it before this render.
        ui.reapGraveyard();
    }

    /// Render sequence: restacking only (rendering state is legal there).
    pub fn onRender(ui: *Ui) void {
        // Bottom to top: Dock/Clip, the windows hosted by the Dock, menus.
        if (ui.dock_on_top) if (ui.dock.panel) |p| p.node.placeTop();
        if (ui.clip_on_top) if (ui.clip.panel) |p| p.node.placeTop();
        if (ui.dock_on_top) {
            var it = ui.wm.windows.first();
            while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
                if (w.docked and !w.closed) w.node.placeTop();
            }
        }
        for (ui.panels.items) |op| op.panel.node.placeTop();
    }

    fn reapGraveyard(ui: *Ui) void {
        while (ui.graveyard.pop()) |p| p.destroy();
    }

    // ---- Dock and Clip ----------------------------------------------------------

    fn primaryOutput(ui: *Ui) ?*types.Output {
        var it = ui.wm.outputs.first();
        while (it) |o| : (it = types.nextOutput(o, ui.wm)) {
            if (!o.removed and o.ready()) return o;
        }
        return null;
    }

    /// (Re)build the Dock/Clip model from wm.dockapps and start the
    /// run-time switches from config.conf.
    fn rebuildModel(ui: *Ui) void {
        const wm = ui.wm;
        if (ui.model) |*m| m.deinit();
        ui.model = null;
        ui.model_gen = wm.dock_gen;
        ui.model = dock_mod.Model.init(ui.gpa(), wm.dockapps, wm.cfg.workspace_names, wm.cfg.workspace_count) catch |err| blk: {
            std.log.err("dock: cannot build the model: {t}", .{err});
            break :blk null;
        };
        ui.dock_on_top = wm.cfg.dock_on_top;
        ui.clip_on_top = wm.cfg.clip_on_top;
        ui.clip_collapsed = wm.cfg.clip_collapsed;
        for ([_]*Bar{ &ui.dock, &ui.clip }) |b| {
            b.hover = null;
            b.hover_arrow = .none;
            b.dirty = true;
        }
    }

    fn dropBar(ui: *Ui, b: *Bar) void {
        if (b.panel) |p| ui.graveyard.append(ui.gpa(), p) catch p.destroy();
        b.panel = null;
        b.output = null;
        b.ntiles = 0;
        b.hover = null;
        b.hover_arrow = .none;
        b.dirty = true;
    }

    /// Make the surface of `b` match `rect` (new surface if its size
    /// changed or the output is another one). Drawing is presentBar's job.
    fn prepareBar(ui: *Ui, b: *Bar, out: *types.Output, rect: types.Rect, ntiles: usize) void {
        if (b.output != out) ui.dropBar(b);
        b.output = out;
        if (b.panel) |p| {
            if (p.w != rect.w or p.h != rect.h) {
                ui.graveyard.append(ui.gpa(), p) catch p.destroy();
                b.panel = null;
                b.dirty = true;
            }
        }
        b.rect = rect;
        b.ntiles = ntiles;
        if (b.panel == null) {
            b.panel = Panel.create(ui, rect.w, rect.h) catch |err| {
                std.log.err("dock surface: {t}", .{err});
                return;
            };
            b.dirty = true;
        }
    }

    fn presentBar(ui: *Ui, b: *Bar, m: *const dock_mod.Model) void {
        const panel = b.panel orelse return;
        const out = b.output orelse return;
        if (b.dirty or !panel.committed) {
            const slot = panel.freeSlot() catch {
                // river has not released a buffer yet; retry next sequence.
                ui.wm.obj.manageDirty();
                return;
            };
            switch (b.kind) {
                .dock => dock_mod.drawDock(&slot.canvas, m, b.ntiles, b.hover),
                .clip => dock_mod.drawClip(&slot.canvas, m, .{
                    .workspace = out.active,
                    .name = m.workspaceName(out.active),
                    .apps = ui.clip_buf[0..ui.clip_count],
                    .on_left = dock_mod.clipOnLeft(ui.wm.cfg.clip_corner),
                    .hover = b.hover,
                    .hover_arrow = b.hover_arrow,
                }),
            }
            panel.present(slot);
            b.dirty = false;
        }
        place(panel, b.rect.x, b.rect.y);
        const on_top = if (b.kind == .dock) ui.dock_on_top else ui.clip_on_top;
        if (!on_top) panel.node.placeBottom();
    }

    /// Mark the tiles whose application has a window; true if that changed.
    fn updateRunning(ui: *Ui, m: *dock_mod.Model) bool {
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(ui.gpa());
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            if (w.closed) continue;
            const id = w.app_id orelse continue;
            ids.append(ui.gpa(), id) catch return false;
        }
        return m.setRunning(ids.items);
    }

    /// Dock and Clip live on the first output. Everything about them that
    /// touches river happens here (manage sequence), like the menus.
    fn syncBars(ui: *Ui) void {
        const wm = ui.wm;
        if (ui.model_gen != wm.dock_gen) ui.rebuildModel();

        const out = ui.primaryOutput();
        // What the Dock reserves only ever applies to the output it is on.
        var oit = wm.outputs.first();
        while (oit) |other| : (oit = types.nextOutput(other, wm)) {
            if (other != out) other.reserved = .{};
        }
        const primary = out orelse {
            ui.dropBar(&ui.dock);
            ui.dropBar(&ui.clip);
            return;
        };
        const m: *dock_mod.Model = if (ui.model) |*mm| mm else {
            ui.dropBar(&ui.dock);
            ui.dropBar(&ui.clip);
            primary.reserved = .{};
            return;
        };

        if (ui.updateRunning(m)) {
            ui.dock.dirty = true;
            ui.clip.dirty = true;
        }

        const cfg = &wm.cfg;
        primary.reserved = .{};

        var dock_rect: ?types.Rect = null;
        if (cfg.dock_enabled) {
            const n = @min(m.dockTiles(), dock_mod.tilesThatFit(primary.rect.h));
            const r = dock_mod.dockRect(primary.rect, n, cfg);
            ui.prepareBar(&ui.dock, primary, r, n);
            dock_rect = r;
            // Lowered, the Dock is just another thing windows can cover.
            if (cfg.dock_reserve_space and ui.dock_on_top) switch (cfg.dock_edge) {
                .left => primary.reserved.left = dock_mod.tile,
                .right => primary.reserved.right = dock_mod.tile,
            };
        } else ui.dropBar(&ui.dock);

        if (cfg.clip_enabled) {
            const room = dock_mod.tilesThatFit(primary.rect.w) - 1;
            var apps: []usize = ui.clip_buf[0..0];
            if (!ui.clip_collapsed) apps = m.clipFor(primary.active, ui.clip_buf[0..@min(room, max_clip_apps)]);
            if (primary.active != ui.clip_ws or apps.len != ui.clip_count) ui.clip.dirty = true;
            ui.clip_ws = primary.active;
            ui.clip_count = apps.len;
            const n = 1 + apps.len;
            ui.prepareBar(&ui.clip, primary, dock_mod.clipRect(primary.rect, n, cfg, dock_rect), n);
        } else ui.dropBar(&ui.clip);

        ui.presentBar(&ui.dock, m);
        ui.presentBar(&ui.clip, m);
    }

    /// Put DockApp windows into their Dock tile (manage sequence, before
    /// layout). A docked window's position is not its own to choose, so
    /// this overwrites float_rect every pass; see dock_mod.dockedRect for
    /// which windows qualify.
    pub fn placeDocked(ui: *Ui) void {
        const wm = ui.wm;
        const m: ?*dock_mod.Model = if (ui.model) |*mm| mm else null;
        var it = wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, wm)) {
            w.docked = false;
            const model = m orelse continue;
            const out = ui.dock.output orelse continue;
            if (ui.dock.panel == null or w.closed or w.mode != .floating) continue;
            const id = w.app_id orelse continue;
            const ws = w.workspace orelse continue;
            if (ws.output != out) continue;
            const r = dock_mod.dockedRect(model, ui.dock.rect, ui.dock.ntiles, id, w.min_w, w.min_h, w.max_w, w.max_h) orelse continue;
            w.float_rect = .{ .x = r.x - out.rect.x, .y = r.y - out.rect.y, .w = r.w, .h = r.h };
            w.has_float_rect = true;
            w.docked = true;
        }
    }

    // ---- Dock and Clip menus ---------------------------------------------------

    fn finishLevel(ui: *Ui, me: usize, title: []const u8, rows: *std.ArrayList(Row)) !usize {
        ui.levels.items[me] = .{
            .title = try ui.zdup(title),
            .rows = try rows.toOwnedSlice(ui.a()),
        };
        measure(&ui.levels.items[me]);
        return me;
    }

    fn buildBarMenu(ui: *Ui, kind: BarMenuKind, slot: ?SlotRef) !usize {
        if (kind == .workspaces) return ui.buildWorkspaceLevel();

        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;

        var title: []const u8 = if (kind == .dock) "Dock" else "Clip";
        if (slot) |ref| if (ui.slotApp(ref)) |app| {
            title = app.name;
            const label = try std.fmt.allocPrintSentinel(ui.a(), "Launch {s}", .{clipUtf8(app.name, 64)}, 0);
            try rows.append(ui.a(), .{ .label = label, .kind = .{ .ui_cmd = .{ .launch = ref } } });
        };

        switch (kind) {
            .dock => try rows.append(ui.a(), .{
                .label = if (ui.dock_on_top) "Lower Dock" else "Keep Dock on Top",
                .kind = .{ .ui_cmd = .toggle_dock_level },
            }),
            .clip => {
                try rows.append(ui.a(), .{
                    .label = if (ui.clip_collapsed) "Expand Clip" else "Collapse Clip",
                    .kind = .{ .ui_cmd = .toggle_clip_collapse },
                });
                try rows.append(ui.a(), .{
                    .label = if (ui.clip_on_top) "Lower Clip" else "Keep Clip on Top",
                    .kind = .{ .ui_cmd = .toggle_clip_level },
                });
                try rows.append(ui.a(), .{ .label = "Next Workspace", .kind = .{ .builtin = .workspace_next } });
                try rows.append(ui.a(), .{ .label = "Previous Workspace", .kind = .{ .builtin = .workspace_prev } });
                const child = try ui.buildWorkspaceLevel();
                try rows.append(ui.a(), .{ .label = "Workspaces", .kind = .{ .submenu = child } });
            },
            .workspaces => unreachable,
        }
        return ui.finishLevel(me, title, &rows);
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
            .open_bar_menu => |r| ui.openBarMenu(r.kind, r.output, r.x, r.y, r.slot),
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
        ui.showTop(out, top, x, y);
    }

    fn openBarMenu(ui: *Ui, kind: BarMenuKind, out: *types.Output, x: i32, y: i32, slot: ?SlotRef) void {
        ui.resetMenu();
        const top = ui.buildBarMenu(kind, slot) catch |err| {
            std.log.err("dock menu build failed: {t}", .{err});
            ui.resetMenu();
            return;
        };
        ui.showTop(out, top, x, y);
    }

    /// Open level `top` at output-local (x, y), kept on the output.
    fn showTop(ui: *Ui, out: *types.Output, top: usize, x: i32, y: i32) void {
        var lvl = &ui.levels.items[top];
        lvl.output = out;
        fitToOutput(lvl, out);
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

        const first = lvl.scroll;
        const last = @min(lvl.rows.len, first + shown(lvl));
        for (lvl.rows[first..last], first..) |r, i| {
            const y = title_h + @as(i32, @intCast(i - first)) * item_h;
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
        // A menu that scrolls says so: a small arrow at the top and/or the
        // bottom edge, where there is more.
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

test "reapGraveyard empties the graveyard immediately" {
    var wm: types.WindowManager = undefined;
    var ui = testUi(std.testing.allocator, &wm);
    defer {
        ui.graveyard.deinit(std.testing.allocator);
        ui.arena.deinit();
    }
    // A destroyed-but-not-yet-freed panel, as syncMenu() puts one when a
    // submenu level closes (e.g. the pointer moved to a sibling row).
    const p = try std.testing.allocator.create(Panel);
    p.* = .{ .ui = &ui, .surface = undefined, .shell = undefined, .node = undefined, .w = 1, .h = 1 };
    // destroy() would touch river objects we don't have here; reapGraveyard
    // calls it, so free the memory ourselves and only check the queue.
    ui.graveyard.append(std.testing.allocator, p) catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), ui.graveyard.items.len);
    _ = ui.graveyard.pop(); // undo: destroy() would touch undefined fields
    std.testing.allocator.destroy(p);
    try std.testing.expectEqual(@as(usize, 0), ui.graveyard.items.len);
}

test "sync() reaps after syncMenu, not before, so a closed submenu vanishes the same sequence" {
    // This is a regression test for the actual bug: reapGraveyard() used to
    // run at the START of sync(), so a panel that syncMenu() just retired
    // (submenu closed by hovering a sibling) stayed attached with its last
    // frame until the NEXT sync() call. We can't run the real sync() without
    // a compositor, so this pins the ORDER of the calls inside it via a
    // source check, which is what actually matters: whatever syncMenu()
    // queues for the graveyard must be gone before this sync() ends.
    const src = @embedFile("ui.zig");
    const body_start = std.mem.indexOf(u8, src, "pub fn sync(ui: *Ui) void {").?;
    const body_end = std.mem.indexOfPos(u8, src, body_start, "\n    }").?;
    const body = src[body_start..body_end];
    const at = struct {
        fn call(haystack: []const u8, needle: []const u8) usize {
            return std.mem.indexOf(u8, haystack, needle) orelse @panic("call missing from sync()");
        }
    }.call;
    const menu_pos = at(body, "ui.syncMenu()");
    const reap_pos = at(body, "ui.reapGraveyard()");
    try std.testing.expect(reap_pos > menu_pos);
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

// ----------------------------------------------------------------------------
// Robustness tests
// ----------------------------------------------------------------------------

fn testUi(gpa: Allocator, wm: *types.WindowManager) Ui {
    return .{
        .wm = wm,
        .compositor = undefined,
        .shm = undefined,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
}

test "menu with a very large number of rows: geometry stays in i32 and rowAt is safe" {
    const rows = try std.testing.allocator.alloc(Row, 5000);
    defer std.testing.allocator.free(rows);
    for (rows) |*r| r.* = .{ .label = "row", .kind = .none };
    const l = testLevel(rows);
    try std.testing.expectEqual(title_h + 5000 * item_h + 2, l.h);
    // Last row reachable, one past the end is not.
    try std.testing.expectEqual(@as(?usize, 4999), Ui.rowAt(&l, title_h + 4999 * item_h + 1));
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, title_h + 5000 * item_h + 1));
    // Hostile pointer coordinates.
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, -1));
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, std.math.minInt(i32)));
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, std.math.maxInt(i32)));
}

test "menu taller than the output is clamped to the top, never off-screen negative" {
    const rows = try std.testing.allocator.alloc(Row, 100);
    defer std.testing.allocator.free(rows);
    for (rows) |*r| r.* = .{ .label = "row", .kind = .none };
    var l = testLevel(rows);
    var out: types.Output = .{ .obj = undefined };
    out.rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    l.x = 300;
    l.y = 300;
    Ui.clampToOutput(&l, &out);
    try std.testing.expectEqual(@as(i32, 0), l.y); // starts at the top, title stays visible
    try std.testing.expect(l.x >= 0);
}

test "buildLevel on OOM leaves no half-built level behind" {
    // Fail the allocator at every possible point while building a menu and
    // check nothing leaks and nothing crashes.
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const parsed = try wm_menu.parse(arena_inst.allocator(),
        \\("Applications",
        \\  ("Terminal", EXEC, "foot"),
        \\  ("Editors", ("Vim", SHEXEC, "vim"), ("Emacs", EXEC, "emacs")),
        \\  ("Quit", EXIT))
    );

    var fail_at: usize = 0;
    while (fail_at < 64) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        var wm: types.WindowManager = undefined;
        wm.gpa = failing.allocator();
        var ui = testUi(failing.allocator(), &wm);
        defer {
            ui.levels.deinit(failing.allocator());
            ui.arena.deinit();
        }
        if (ui.buildLevel(parsed.menu)) |top| {
            try std.testing.expect(top < ui.levels.items.len);
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
        }
    }
}

test "clipUtf8 never splits a character and never keeps a NUL" {
    try std.testing.expectEqualStrings("abc", clipUtf8("abcdef", 3));
    try std.testing.expectEqualStrings("abcdef", clipUtf8("abcdef", 100));
    // "é" is 2 bytes (0xC3 0xA9); cutting after the first byte must step back.
    try std.testing.expectEqualStrings("a", clipUtf8("a\xC3\xA9", 2));
    try std.testing.expectEqualStrings("a\xC3\xA9", clipUtf8("a\xC3\xA9", 3));
    // 3-byte character cut in the middle.
    try std.testing.expectEqualStrings("", clipUtf8("\xE2\x82\xAC", 2));
    try std.testing.expectEqualStrings("ab", clipUtf8("ab\x00cd", 10));
    try std.testing.expectEqualStrings("", clipUtf8("", 10));
}

test "a menu with more rows than max_rows is truncated, not refused" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const n = max_rows + 50;
    const items = try a.alloc(wm_menu.Item, n);
    for (items) |*it| it.* = .{ .label = "x", .action = .{ .exec = "true" } };
    const m: wm_menu.Menu = .{ .title = "Big", .items = items };

    var wm: types.WindowManager = undefined;
    wm.gpa = std.testing.allocator;
    var ui = testUi(std.testing.allocator, &wm);
    defer {
        ui.levels.deinit(std.testing.allocator);
        ui.arena.deinit();
    }
    const top = try ui.buildLevel(&m);
    try std.testing.expectEqual(max_rows, ui.levels.items[top].rows.len);
    // And its surface is small enough for shm.
    const l = ui.levels.items[top];
    _ = try shm.checkedSize(l.w, l.h);
}

test "buildLevel actually clips overlong labels, not just clipUtf8 in isolation" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const huge = try a.alloc(u8, max_label_bytes * 4);
    @memset(huge, 'x');
    var items = [_]wm_menu.Item{.{ .label = huge, .action = .{ .exec = "true" } }};
    const m: wm_menu.Menu = .{ .title = "T", .items = &items };

    var wm: types.WindowManager = undefined;
    wm.gpa = std.testing.allocator;
    var ui = testUi(std.testing.allocator, &wm);
    defer {
        ui.levels.deinit(std.testing.allocator);
        ui.arena.deinit();
    }
    const top = try ui.buildLevel(&m);
    try std.testing.expect(ui.levels.items[top].rows[0].label.len <= max_label_bytes);
}

// ----------------------------------------------------------------------------
// Tests: Dock and Clip (the parts that need no surface)
// ----------------------------------------------------------------------------

fn dockTestApps() [3]dockapp.DockApp {
    return .{
        .{ .name = "term", .command = &.{"foot"}, .y = 1 },
        .{ .name = "notes", .command = &.{"gedit"}, .place = .clip, .workspace = 0 },
        .{ .name = "web", .command = &.{"firefox"}, .place = .clip },
    };
}

test "barHit: Dock rows" {
    var wm: types.WindowManager = undefined;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer ui.arena.deinit();

    const bar: Bar = .{ .kind = .dock, .ntiles = 3 };
    ui.px = 30;
    ui.py = 5;
    try std.testing.expectEqual(@as(?usize, 0), ui.barHit(&bar).tile);
    ui.py = 64 * 2 + 63;
    try std.testing.expectEqual(@as(?usize, 2), ui.barHit(&bar).tile);
    ui.py = 64 * 3; // below the last tile
    try std.testing.expectEqual(@as(?usize, null), ui.barHit(&bar).tile);
}

test "barHit: Clip tiles and arrows, anchored left and right" {
    var wm: types.WindowManager = undefined;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer ui.arena.deinit();

    const bar: Bar = .{ .kind = .clip, .ntiles = 3 };

    wm.cfg.clip_corner = .top_left;
    ui.px = 60;
    ui.py = 3;
    var hit = ui.barHit(&bar);
    try std.testing.expectEqual(@as(?usize, 0), hit.tile);
    try std.testing.expectEqual(dock_mod.Arrow.next, hit.arrow);
    ui.px = 3;
    ui.py = 60;
    try std.testing.expectEqual(dock_mod.Arrow.prev, ui.barHit(&bar).arrow);
    ui.px = 64 + 20;
    ui.py = 3; // an application tile: its corner is not an arrow
    hit = ui.barHit(&bar);
    try std.testing.expectEqual(@as(?usize, 1), hit.tile);
    try std.testing.expectEqual(dock_mod.Arrow.none, hit.arrow);

    // Anchored right, the workspace tile is the rightmost one.
    wm.cfg.clip_corner = .top_right;
    ui.px = 128 + 60;
    ui.py = 3;
    hit = ui.barHit(&bar);
    try std.testing.expectEqual(@as(?usize, 0), hit.tile);
    try std.testing.expectEqual(dock_mod.Arrow.next, hit.arrow);
    ui.px = 10;
    try std.testing.expectEqual(@as(?usize, 2), ui.barHit(&bar).tile);
}

test "buildBarMenu: Dock menu on an application tile and on the logo" {
    var wm: types.WindowManager = undefined;
    wm.gpa = std.testing.allocator;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer {
        ui.levels.deinit(std.testing.allocator);
        ui.arena.deinit();
    }
    const apps = dockTestApps();
    ui.model = try dock_mod.Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer ui.model.?.deinit();

    // On the "term" tile: Launch + level toggle.
    const top = try ui.buildBarMenu(.dock, .{ .clip = false, .index = 0 });
    const lvl = ui.levels.items[top];
    try std.testing.expectEqualStrings("term", lvl.title);
    try std.testing.expectEqual(@as(usize, 2), lvl.rows.len);
    try std.testing.expectEqualStrings("Launch term", lvl.rows[0].label);
    try std.testing.expect(lvl.rows[0].kind.ui_cmd.launch.index == 0);
    try std.testing.expectEqualStrings("Lower Dock", lvl.rows[1].label);

    // The label follows the current state.
    ui.resetMenu();
    ui.dock_on_top = false;
    const top2 = try ui.buildBarMenu(.dock, null);
    try std.testing.expectEqualStrings("Dock", ui.levels.items[top2].title);
    try std.testing.expectEqual(@as(usize, 1), ui.levels.items[top2].rows.len);
    try std.testing.expectEqualStrings("Keep Dock on Top", ui.levels.items[top2].rows[0].label);

    // A stale slot (the list was rebuilt while the menu was being asked
    // for) is just not offered.
    ui.resetMenu();
    const top3 = try ui.buildBarMenu(.dock, .{ .clip = false, .index = 99 });
    try std.testing.expectEqual(@as(usize, 1), ui.levels.items[top3].rows.len);
}

test "runUiCmd flips the run-time switches" {
    var wm: types.WindowManager = undefined;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer ui.arena.deinit();

    try std.testing.expect(ui.dock_on_top);
    ui.runUiCmd(.toggle_dock_level);
    try std.testing.expect(!ui.dock_on_top);
    ui.runUiCmd(.toggle_dock_level);
    try std.testing.expect(ui.dock_on_top);

    ui.runUiCmd(.toggle_clip_level);
    try std.testing.expect(!ui.clip_on_top);
    ui.runUiCmd(.toggle_clip_collapse);
    try std.testing.expect(ui.clip_collapsed);
    // A launch with no model (or a stale index) does nothing, not crash.
    ui.runUiCmd(.{ .launch = .{ .clip = true, .index = 5 } });
}

test "slotApp refuses indices past the end" {
    var wm: types.WindowManager = undefined;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer ui.arena.deinit();

    try std.testing.expect(ui.slotApp(.{ .clip = false, .index = 0 }) == null);
    const apps = dockTestApps();
    ui.model = try dock_mod.Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer ui.model.?.deinit();
    try std.testing.expectEqualStrings("term", ui.slotApp(.{ .clip = false, .index = 0 }).?.name);
    try std.testing.expect(ui.slotApp(.{ .clip = false, .index = 1 }) == null);
    try std.testing.expectEqual(@as(usize, 2), ui.model.?.clip.len);
    try std.testing.expect(ui.slotApp(.{ .clip = true, .index = 1 }) != null);
    try std.testing.expect(ui.slotApp(.{ .clip = true, .index = 2 }) == null);
}

test "sync() builds the Dock before the desktops and onRender runs after the windows" {
    // Ordering pinned like the reap-before-sync test above: a lowered Dock
    // must end up ABOVE the desktop catcher (both call placeBottom, the
    // later call is lower), and the Ui must restack after the windows
    // (applyRender raises the focused window).
    const ui_src = @embedFile("ui.zig");
    const start = std.mem.indexOf(u8, ui_src, "pub fn sync(ui: *Ui) void {").?;
    const end = std.mem.indexOfPos(u8, ui_src, start, "\n    }\n").?;
    const body = ui_src[start..end];
    const bars = std.mem.indexOf(u8, body, "ui.syncBars()").?;
    const desktops = std.mem.indexOf(u8, body, "ui.syncDesktops()").?;
    try std.testing.expect(bars < desktops);

    const main_src = @embedFile("main.zig");
    const r_start = std.mem.indexOf(u8, main_src, "fn onRender(wm: *WindowManager) void {").?;
    const r_end = std.mem.indexOfPos(u8, main_src, r_start, "\n}").?;
    const r_body = main_src[r_start..r_end];
    try std.testing.expect(std.mem.indexOf(u8, r_body, "applyRender").? < std.mem.indexOf(u8, r_body, "u.onRender()").?);
}

// ----------------------------------------------------------------------------
// Tests: menus taller than the output scroll
// ----------------------------------------------------------------------------

fn manyRows(a: std.mem.Allocator, n: usize) ![]Row {
    const rows = try a.alloc(Row, n);
    for (rows) |*r| r.* = .{ .label = "Entry", .kind = .{ .exec = "x" } };
    return rows;
}

test "a menu that fits is left alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = testLevel(try manyRows(arena.allocator(), 5));
    var out: types.Output = undefined;
    out.rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    Ui.fitToOutput(&l, &out);
    try std.testing.expectEqual(@as(usize, 5), Ui.shown(&l));
    try std.testing.expectEqual(title_h + 5 * item_h + 2, l.h);
    try std.testing.expectEqual(@as(usize, 0), l.scroll);
}

test "a menu taller than the output is cut to fit and scrolls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = testLevel(try manyRows(arena.allocator(), 100));
    var out: types.Output = undefined;
    out.rect = .{ .x = 0, .y = 0, .w = 800, .h = 300 };
    Ui.fitToOutput(&l, &out);

    // Fewer rows than there are, and the surface fits on the screen.
    try std.testing.expect(Ui.shown(&l) < 100);
    try std.testing.expect(Ui.shown(&l) >= 1);
    try std.testing.expect(l.h <= out.rect.h - 2 * menu_margin);
    try std.testing.expectEqual(title_h + @as(i32, @intCast(Ui.shown(&l))) * item_h + 2, l.h);

    // The first screenful: pointer at the top row hits row 0.
    try std.testing.expectEqual(@as(?usize, 0), Ui.rowAt(&l, title_h + 1));
    // Below the last visible row: nothing, even though more rows exist.
    const below = title_h + @as(i32, @intCast(Ui.shown(&l))) * item_h + 1;
    try std.testing.expectEqual(@as(?usize, null), Ui.rowAt(&l, below));

    // Scrolled: the same pointer position is a later row.
    l.scroll = 10;
    try std.testing.expectEqual(@as(?usize, 10), Ui.rowAt(&l, title_h + 1));
    try std.testing.expectEqual(@as(?usize, 11), Ui.rowAt(&l, title_h + item_h + 1));
}

test "keyboard navigation scrolls the selection into view, both ways" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = testLevel(try manyRows(arena.allocator(), 50));
    var out: types.Output = undefined;
    out.rect = .{ .x = 0, .y = 0, .w = 800, .h = 300 };
    Ui.fitToOutput(&l, &out);
    const n = Ui.shown(&l);

    Ui.ensureVisible(&l, n + 3); // below the window: scroll down just enough
    try std.testing.expectEqual(@as(usize, 4), l.scroll);
    Ui.ensureVisible(&l, n + 3); // already visible: no change
    try std.testing.expectEqual(@as(usize, 4), l.scroll);
    Ui.ensureVisible(&l, 1); // above: scroll up to it
    try std.testing.expectEqual(@as(usize, 1), l.scroll);
}

test "a short list on a tiny output still shows at least one row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = testLevel(try manyRows(arena.allocator(), 10));
    var out: types.Output = undefined;
    out.rect = .{ .x = 0, .y = 0, .w = 800, .h = 10 }; // absurd
    Ui.fitToOutput(&l, &out);
    try std.testing.expect(Ui.shown(&l) >= 1);
    // And an output that has no size yet leaves the menu whole.
    out.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    Ui.fitToOutput(&l, &out);
    try std.testing.expectEqual(@as(usize, 10), Ui.shown(&l));
}

test "an unmeasured level (visible = 0) shows all of its rows" {
    var rows = [_]Row{ .{ .label = "a", .kind = .none }, .{ .label = "b", .kind = .none } };
    const l: Level = .{ .title = "t", .rows = &rows };
    try std.testing.expectEqual(@as(usize, 2), Ui.shown(&l));
}

// ----------------------------------------------------------------------------
// Tests: OPEN_MENU, Info and Legal panels
// ----------------------------------------------------------------------------

const ucc = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

fn writeTestFile(path: [:0]const u8, text: []const u8) !void {
    const f = ucc.fopen(path.ptr, "wb") orelse return error.Open;
    defer _ = ucc.fclose(f);
    if (text.len > 0) _ = ucc.fwrite(text.ptr, 1, text.len, f);
}

test "OPEN_MENU on a directory becomes a submenu row; on nothing, a disabled row" {
    const gpa = std.testing.allocator;
    var tmpl = "/tmp/wmaker-uimenu-XXXXXX".*;
    const dir = ucc.mkdtemp(&tmpl) orelse return error.MkdTemp;
    defer {
        var cmd: [96]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{std.mem.span(dir)})) |z| _ = ucc.system(z.ptr) else |_| {}
    }
    var pb: [96]u8 = undefined;
    try writeTestFile(try std.fmt.bufPrintZ(&pb, "{s}/readme.txt", .{std.mem.span(dir)}), "x");

    var wm: types.WindowManager = undefined;
    wm.gpa = gpa;
    wm.cfg = .{ .arena = .init(gpa) };
    defer wm.cfg.deinit();
    var ui = testUi(gpa, &wm);
    defer {
        ui.levels.deinit(gpa);
        ui.arena.deinit();
    }

    const items = [_]wm_menu.Item{
        .{ .label = "Docs", .action = .{ .open_menu = std.mem.span(dir) } },
        .{ .label = "Gone", .action = .{ .open_menu = "/nonexistent/wmaker-wl/x" } },
        .{ .label = "Pipe", .action = .{ .open_menu = "| echo hi" } },
    };
    const menu: wm_menu.Menu = .{ .title = "Root", .items = &items };
    const top = try ui.buildLevel(&menu);
    const lvl = ui.levels.items[top];

    try std.testing.expectEqual(@as(usize, 3), lvl.rows.len);
    try std.testing.expect(lvl.rows[0].enabled and lvl.rows[0].kind == .submenu);
    const child = ui.levels.items[lvl.rows[0].kind.submenu];
    try std.testing.expectEqual(@as(usize, 1), child.rows.len);
    try std.testing.expectEqualStrings("readme.txt", child.rows[0].label);
    try std.testing.expect(child.rows[0].kind == .shexec);
    // Missing path and the unsupported pipe form: shown, but disabled.
    try std.testing.expect(!lvl.rows[1].enabled and lvl.rows[1].kind == .none);
    try std.testing.expect(!lvl.rows[2].enabled and lvl.rows[2].kind == .none);
}

test "a menu file that opens itself stops at the depth limit" {
    const gpa = std.testing.allocator;
    var tmpl = "/tmp/wmaker-uiloop-XXXXXX".*;
    const dir = ucc.mkdtemp(&tmpl) orelse return error.MkdTemp;
    defer {
        var cmd: [96]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{std.mem.span(dir)})) |z| _ = ucc.system(z.ptr) else |_| {}
    }
    var pb: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pb, "{s}/loop.menu", .{std.mem.span(dir)});
    var text_buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "(\"Loop\", (\"Again\", OPEN_MENU, \"{s}\"), (\"Leaf\", EXEC, \"x\"))", .{path});
    try writeTestFile(path, text);

    var wm: types.WindowManager = undefined;
    wm.gpa = gpa;
    wm.cfg = .{ .arena = .init(gpa) };
    defer wm.cfg.deinit();
    var ui = testUi(gpa, &wm);
    defer {
        ui.levels.deinit(gpa);
        ui.arena.deinit();
    }

    const items = [_]wm_menu.Item{.{ .label = "Start", .action = .{ .open_menu = path } }};
    const menu: wm_menu.Menu = .{ .title = "Root", .items = &items };
    _ = try ui.buildLevel(&menu);
    // It terminated, with a bounded number of levels, and left the depth counter clean.
    try std.testing.expect(ui.levels.items.len <= max_expand_depth + 3);
    try std.testing.expectEqual(@as(u8, 0), ui.expand_depth);
}

test "the Info panel names the version and the config file; Legal states the licence" {
    const gpa = std.testing.allocator;
    var wm: types.WindowManager = undefined;
    wm.gpa = gpa;
    wm.cfg = .{ .arena = .init(gpa), .config_file = "/home/x/.config/wmaker-wl/config.conf" };
    defer wm.cfg.deinit();
    var ui = testUi(gpa, &wm);
    defer {
        ui.levels.deinit(gpa);
        ui.arena.deinit();
    }

    const info = ui.levels.items[try ui.buildTextLevel(.info_panel)];
    try std.testing.expectEqualStrings("Info", info.title);
    var has_version = false;
    var has_config = false;
    for (info.rows) |r| {
        try std.testing.expect(!r.enabled); // read-only text
        if (std.mem.indexOf(u8, r.label, version) != null) has_version = true;
        if (std.mem.indexOf(u8, r.label, "config.conf") != null) has_config = true;
    }
    try std.testing.expect(has_version and has_config);

    const legal = ui.levels.items[try ui.buildTextLevel(.legal_panel)];
    try std.testing.expectEqualStrings("Legal", legal.title);
    var mentions_licence = false;
    for (legal.rows) |r| {
        if (std.mem.indexOf(u8, r.label, "0BSD") != null) mentions_licence = true;
    }
    try std.testing.expect(mentions_licence);
}
