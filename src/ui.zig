// SPDX-License-Identifier: GPL-3.0
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
const log = std.log.scoped(.ui);
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
const wdock = @import("wm_dock.zig");
const dockhost = @import("dockhost.zig");
const fsmenu = @import("fsmenu.zig");
const version = @import("version.zig").version;
const dockapp = @import("dockapp.zig");
const workspace = @import("workspace.zig");
const config_mod = @import("config.zig");
const wm_files = @import("wm_files.zig");
const anim = @import("anim.zig");

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

/// A Dock/Clip/Drawer entry: its index in `Model.slots`. (In the menu of a
/// Drawer's own tile it is the Drawer's index instead.)
const SlotRef = struct { index: usize };

/// What a Dock/Clip menu row does to the windows of an entry. These touch
/// river state, so they only record a request that sync() runs inside the
/// manage sequence (see `runAppRequest`).
const AppOp = enum {
    /// Move the windows of the application to the workspace the user is on
    /// (Window Maker's "Bring Here" / "Unhide Here") and focus one.
    bring_here,
    hide,
    unhide,
    /// Ask every window of the application to close ("Kill").
    kill,
};

const AppRequest = struct { op: AppOp, ref: SlotRef };

/// What the rows of the Dock/Clip menus do (ui.runUiCmd).
const UiCmd = union(enum) {
    /// Window Maker's "Dock position" menu.
    set_dock_level: dock_mod.Level,
    toggle_clip_level,
    toggle_clip_collapse,
    toggle_clip_auto_collapse,
    toggle_clip_auto_raise,
    /// Start a NEW instance (a click on the tile would focus a running one).
    launch: SlotRef,
    app_op: AppRequest,
    toggle_lock: SlotRef,
    /// "Keep Icon" on a temporary DockApp tile: make it permanent.
    keep_attached: SlotRef,
    /// Window Maker's "Add a drawer".
    add_drawer,
    /// The Drawer with this index: remove it / its two switches.
    remove_drawer: usize,
    toggle_drawer_collapse: usize,
    toggle_drawer_auto_collapse: usize,
    /// "Remove Icon".
    remove: SlotRef,
    /// Clip only: show the entry on this workspace only / on all (null).
    set_workspace: struct { ref: SlotRef, ws: ?u32 },
    /// "Keep Application": make an entry for a running program. `app_id` is
    /// a slice of `Ui.arena`, valid while the menu is.
    keep: struct { app_id: []const u8, clip: bool },
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

const BarMenuKind = enum { dock, clip, drawer, workspaces, info };

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

/// Rows of the "Keep Application" and "Move Icon To" menus at most.
const max_keep_rows: usize = 16;
const max_move_rows: u32 = 32;

const BarKind = enum { dock, clip, drawer };

/// The Dock, the Clip or a Drawer: one surface that covers all of its tiles
/// (and the margin a dragged tile can snap to, see dock.cellsOf).
const Bar = struct {
    kind: BarKind,
    /// The wdock.Dock this bar shows; set by every sync.
    wd: ?*wdock.Dock = null,
    panel: ?*Panel = null,
    output: ?*types.Output = null,
    /// Global rectangle of the surface as of the last sync.
    rect: types.Rect = .{},
    /// The grid cells the surface covers (margin included) and the ones
    /// that hold tiles (what takes pointer input).
    cells: dock_mod.Cells = .{},
    visible: dock_mod.Cells = .{},
    /// Collapsed Clip / Drawer: only its own tile.
    only_main: bool = false,
    hover: ?*wdock.Icon = null,
    hover_arrow: dock_mod.Arrow = .none,
    dirty: bool = true,
    /// A tile is being dragged on this bar.
    drag: ?dock_mod.DragView = null,
    /// Autocollapse: when (`Ui.nowMs`) this Clip/Drawer folds up after the
    /// pointer left it, or unfolds after it came. null = nothing pending.
    fold_at: ?u32 = null,
    unfold_at: ?u32 = null,
};

/// Autocollapse waits a moment, like Window Maker: a pointer that only
/// passes over the Clip does not unfold it, and one that slips off for an
/// instant does not fold it up.
const fold_delay_ms: u32 = 700;
const unfold_delay_ms: u32 = 250;

/// Has `at` (on the wrapping millisecond clock) been reached at `now`?
fn timeDue(now: u32, at: u32) bool {
    return now -% at < 0x8000_0000;
}

/// Lower `best` to the time left until `at`, if that is less.
fn sooner(best: *?u32, now: u32, at: ?u32) void {
    const t = at orelse return;
    const left: u32 = if (timeDue(now, t)) 0 else t -% now;
    if (best.* == null or left < best.*.?) best.* = left;
}

/// Window Maker's double click: two presses of the same button on the same
/// tile within this many milliseconds.
const double_click_ms: u32 = 400;

/// How long (ms) a tile stays covered by the launching raster when no window
/// ever shows up.
const launch_timeout_ms: u32 = 8000;

/// Most windows that fly to or from the Dock at the same moment.
const anim_max: usize = 8;
/// The surface an animation is drawn on is never bigger than this (px).
const anim_max_px: i32 = 8192;

/// A window that was minimized or restored: found by `animCollect`, turned
/// into a running animation by `animLaunch`.
const AnimReq = struct {
    win: *types.Window,
    restore: bool,
    /// Where it starts (the window's frame, or the Dock tile).
    from: anim.Box,
};

const ActiveAnim = struct {
    plan: anim.Plan,
    start_ms: u32,
    /// The picture that is on the surface now; maxInt = none yet.
    drawn: u32 = std.math.maxInt(u32),
    /// A window that comes back stays hidden until its animation is over
    /// (Window Maker maps it afterwards).
    hold: ?*types.Window = null,
};

/// Which picture is due `now`.
fn animIndex(a: *const ActiveAnim, now: u32) u32 {
    return (now -% a.start_ms) / a.plan.delay_ms;
}

/// The animation of a window's frame for the configured style; null for none.
fn animStyle(style: config_mod.IconifyStyle, now: u32) ?anim.Style {
    return switch (style) {
        .zoom => .zoom,
        .twist => .twist,
        .flip => .flip,
        .none => null,
        .random => switch (now % 3) {
            0 => .zoom,
            1 => .twist,
            else => .flip,
        },
    };
}

/// A window's frame on the screen: its content and the border.
fn frameBox(wm: *const types.WindowManager, w: *const types.Window) anim.Box {
    const bw: i32 = if (w.mode == .fullscreen) 0 else w.borderWidth(&wm.cfg);
    return .{ .x = w.target.x - bw, .y = w.target.y - bw, .w = w.target.w + 2 * bw, .h = w.target.h + 2 * bw };
}

/// A tile that was started this recently ignores a second start from a
/// plain click (a double click in single-click mode, an impatient second
/// click): without this the program would run twice. Window Maker ignores
/// clicks for as long as a tile is launching; a shorter time here lets a
/// launch that failed be retried at once. Middle click and the menu's
/// Launch always start a new instance.
const relaunch_guard_ms: u32 = 1500;

const LastClick = struct {
    time: u32 = 0,
    button: u32 = 0,
    kind: BarKind = .dock,
    /// The tile: the address of its wdock.Icon.
    tile: usize = 0,
    valid: bool = false,
};

/// Is a press at `time` on (`kind`, `tile`) with `button` the second half of
/// a double click after `last`?
fn isDoubleClick(last: LastClick, time: u32, button: u32, kind: BarKind, tile: usize) bool {
    return last.valid and last.button == button and last.kind == kind and last.tile == tile and
        time -% last.time <= double_click_ms;
}

/// What a pressed button on a bar may turn into when the pointer moves.
const PressKind = enum {
    /// An application tile: moves to a slot of some dock, or is taken away.
    tile,
    /// The Dock's logo tile: moves the whole Dock.
    main_dock,
    /// The Clip's workspace tile: moves the Clip to another corner.
    main_clip,
    /// A Drawer's tile: moves the Drawer to another row of the Dock.
    main_drawer,
};

const Press = struct {
    kind: PressKind,
    bar: *Bar,
    icon: *wdock.Icon,
    slot: ?SlotRef,
    /// Surface-local position of the press.
    x: i32,
    y: i32,
    /// Where on its tile the press was (the tile is carried by that point).
    off_x: i32 = 0,
    off_y: i32 = 0,
    dragging: bool = false,
    /// Single-click mode: launch when the button is released without a drag.
    activate_on_release: bool = false,
};

/// What is under the pointer on a Bar.
const Hit = struct {
    icon: ?*wdock.Icon = null,
    arrow: dock_mod.Arrow = .none,
};

/// Where a dragged tile would land.
const DropTarget = struct { dock: *wdock.Dock, xy: [2]i32 };

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

const validAppId = dockapp.validAppId;

/// The program to start for an entry made from a running window with this
/// app_id: the id itself, or for a reverse-DNS id (`org.mozilla.firefox`)
/// its last part in lower case. A guess -- the user fixes it in the state
/// file if it is wrong (docs/DOCKAPPS.md). Written into `buf`.
fn guessCommand(buf: []u8, id: []const u8) ?[]const u8 {
    var tail = id;
    if (std.mem.lastIndexOfScalar(u8, id, '.')) |dot| {
        if (dot + 1 < id.len) tail = id[dot + 1 ..];
    }
    if (tail.len == 0 or tail.len > buf.len) return null;
    for (tail, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..tail.len];
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
    /// What the Dock reserved at the last sync (only to log changes).
    last_reserved: types.Output.Insets = .{},
    dock: Bar = .{ .kind = .dock },
    clip: Bar = .{ .kind = .clip },
    /// One bar per Drawer, parallel to model.scr.drawers.
    drawer_bars: std.ArrayList(*Bar) = .empty,
    /// Where the tile being dragged would land (any bar).
    drop_target: ?DropTarget = null,
    /// Run-time state, started from config.lua (or the saved state) and
    /// changed by the menus.
    dock_level: dock_mod.Level = .top,
    clip_on_top: bool = true,
    clip_collapsed: bool = false,
    clip_auto_collapse: bool = false,
    clip_auto_raise: bool = false,
    /// A click raised a Dock/Clip that is not on top (level `normal`); it
    /// stays up until the keyboard focus moves to another window.
    dock_clicked: bool = false,
    clip_clicked: bool = false,
    raise_focus: ?*types.Window = null,
    /// Button press in progress on a bar, and the last click (double click).
    press: ?Press = null,
    last_click: LastClick = .{},
    /// A menu row asked for something to be done to an application's
    /// windows; sync() does it.
    app_request: ?AppRequest = null,
    /// Mouse wheel movement not yet turned into a workspace step.
    scroll_acc: f64 = 0,

    // ---- minimize / restore animation (anim.zig) ---------------------------------
    anim_req: [anim_max]AnimReq = undefined,
    anim_req_n: usize = 0,
    anims: [anim_max]ActiveAnim = undefined,
    anim_n: usize = 0,
    /// The transparent surface the frames are drawn on, and the global box
    /// it covers. It exists only while something flies.
    anim_panel: ?*Panel = null,
    anim_box: anim.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    anim_redraw: bool = false,

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
        if (ui.anim_panel) |p| p.destroy();
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
        log.debug("seat capabilities: pointer={} keyboard={}", .{ has_pointer, has_keyboard });
        if (has_pointer and ui.pointer == null) {
            if (seat.getPointer()) |p| {
                ui.pointer = p;
                p.setListener(*Ui, pointerListener, ui);
                if (ui.cursor_shape_manager) |mgr| {
                    if (mgr.getPointer(p)) |dev| {
                        ui.cursor_shape_device = dev;
                    } else |err| log.err("wp_cursor_shape_manager_v1.get_pointer: {t}", .{err});
                }
            } else |err| log.err("wl_seat.get_pointer: {t}", .{err});
        }
        if (has_keyboard and ui.keyboard == null) {
            if (seat.getKeyboard()) |k| {
                ui.keyboard = k;
                k.setListener(*Ui, keyboardListener, ui);
            } else |err| log.err("wl_seat.get_keyboard: {t}", .{err});
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ui: *Ui) void {
        switch (event) {
            .enter => |e| {
                ui.pointer_surface = e.surface;
                ui.px = @intCast(e.surface_x.toInt());
                ui.py = @intCast(e.surface_y.toInt());
                log.debug("pointer enter: {s} at {d},{d}", .{ ui.describe(e.surface), ui.px, ui.py });
                // Every one of our surfaces (desktop catcher and menus) is
                // plain UI: always the default arrow, regardless of which
                // shape a window under the old focus had set.
                if (ui.cursor_shape_device) |dev| dev.setShape(e.serial, .default);
                if (e.surface) |sf| if (ui.barAt(sf)) |b| ui.onBarEnter(b);
                ui.onMotion();
            },
            .leave => {
                const left = ui.pointer_surface;
                ui.pointer_surface = null;
                ui.scroll_acc = 0;
                ui.clearBarHover();
                if (left) |sf| if (ui.barAt(sf)) |b| ui.onBarLeave(b);
            },
            .axis => |e| if (e.axis == .vertical_scroll) ui.onScroll(e.value.toDouble()),
            .motion => |e| {
                ui.px = @intCast(e.surface_x.toInt());
                ui.py = @intCast(e.surface_y.toInt());
                ui.onMotion();
            },
            .button => |e| {
                if (e.state == .pressed) {
                    log.debug("pointer button 0x{x} on {s}", .{ e.button, ui.describe(ui.pointer_surface) });
                    ui.onButton(e.button, e.time);
                } else ui.onRelease(e.button);
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

    fn onButton(ui: *Ui, button: u32, time: u32) void {
        const s = ui.pointer_surface orelse return;

        if (ui.levelFor(s)) |li| {
            ui.clickLevel(li, button);
            return;
        }
        if (ui.barAt(s)) |b| {
            ui.clickBar(b, button, time);
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
            ui.dragMotion(b);
            return;
        }
        const li = ui.levelFor(s) orelse return;
        ui.setHover(li, rowAt(&ui.levels.items[li], ui.py));
    }

    // ---- what a pointer event means on the Dock and the Clip ----------------

    /// Every bar: the Dock, the Clip, then the Drawers.
    fn allBars(ui: *Ui, buf: *[2 + dock_mod.max_drawers]*Bar) []*Bar {
        buf[0] = &ui.dock;
        buf[1] = &ui.clip;
        var n: usize = 2;
        for (ui.drawer_bars.items) |b| {
            if (n >= buf.len) break;
            buf[n] = b;
            n += 1;
        }
        return buf[0..n];
    }

    fn barAt(ui: *Ui, s: *wl.Surface) ?*Bar {
        var buf: [2 + dock_mod.max_drawers]*Bar = undefined;
        for (ui.allBars(&buf)) |b| {
            if (b.panel) |p| if (p.surface == s) return b;
        }
        return null;
    }

    fn markBarsDirty(ui: *Ui) void {
        var buf: [2 + dock_mod.max_drawers]*Bar = undefined;
        for (ui.allBars(&buf)) |b| b.dirty = true;
    }

    /// The tile (and, on the Clip's workspace tile, the arrow) under the
    /// pointer, from the surface-local position of the last event.
    fn barHit(ui: *Ui, b: *const Bar) Hit {
        const d = b.wd orelse return .{};
        if (ui.px < 0 or ui.py < 0) return .{};
        const gi = dock_mod.iconAt(d, dock_mod.cellAt(b.cells, ui.px, ui.py)) orelse return .{};
        if (b.only_main and !gi.main) return .{};
        if (b.kind == .clip and gi.main) {
            const o = dock_mod.cellPx(b.cells, gi.xindex, gi.yindex);
            return .{ .icon = gi, .arrow = dock_mod.clipArrowAt(ui.px - o[0], ui.py - o[1]) };
        }
        return .{ .icon = gi };
    }

    fn hoverBar(ui: *Ui, b: *Bar) void {
        const hit = ui.barHit(b);
        if (hit.icon == b.hover and hit.arrow == b.hover_arrow) return;
        b.hover = hit.icon;
        b.hover_arrow = hit.arrow;
        b.dirty = true;
        ui.wm.obj.manageDirty();
    }

    fn clearBarHover(ui: *Ui) void {
        var changed = false;
        var buf: [2 + dock_mod.max_drawers]*Bar = undefined;
        for (ui.allBars(&buf)) |b| {
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
        if (b.kind != .clip or !ui.wm.cfg.clip_scroll_workspaces) return;
        const scroll_step = 10.0;
        ui.scroll_acc += value;
        if (@abs(ui.scroll_acc) < scroll_step) return;
        if (b.output) |o| ui.wm.active_output = o;
        ui.wm.pending_ui = if (ui.scroll_acc > 0) .workspace_next else .workspace_prev;
        ui.scroll_acc = 0;
        ui.wm.obj.manageDirty();
    }

    fn raiseBar(ui: *Ui, kind: BarKind) void {
        if (kind == .clip) ui.clip_clicked = true else ui.dock_clicked = true;
        ui.raise_focus = if (ui.wm.seats.first()) |sd| sd.focused else null;
    }

    /// Is this Clip/Drawer folded (only its own tile shown)?
    fn isFolded(ui: *const Ui, b: *const Bar) bool {
        return switch (b.kind) {
            .clip => ui.clip_collapsed,
            .drawer => if (b.wd) |d| d.collapsed else false,
            .dock => false,
        };
    }

    /// Does it fold and unfold by itself (Autocollapse)?
    fn autoFolds(ui: *const Ui, b: *const Bar) bool {
        return switch (b.kind) {
            .clip => ui.clip_auto_collapse,
            .drawer => if (b.wd) |d| d.auto_collapse else false,
            .dock => false,
        };
    }

    fn setFolded(ui: *Ui, b: *Bar, folded: bool) void {
        switch (b.kind) {
            .clip => ui.clip_collapsed = folded,
            .drawer => if (b.wd) |d| {
                d.collapsed = folded;
            } else return,
            .dock => return,
        }
        b.dirty = true;
        ui.wm.obj.manageDirty();
    }

    fn onBarEnter(ui: *Ui, b: *Bar) void {
        b.fold_at = null;
        if (!ui.autoFolds(b) or !ui.isFolded(b)) return;
        if (unfold_delay_ms == 0) {
            ui.setFolded(b, false);
        } else {
            b.unfold_at = ui.nowMs() +% unfold_delay_ms;
        }
    }

    fn onBarLeave(ui: *Ui, b: *Bar) void {
        b.unfold_at = null;
        // A drag keeps the pointer on the bar it started on; the release
        // is followed by a leave event of its own.
        if (ui.press != null) return;
        if (!ui.autoFolds(b) or ui.isFolded(b)) return;
        b.fold_at = ui.nowMs() +% fold_delay_ms;
    }

    /// How long the event loop may sleep: the time to the next thing the
    /// Dock does on its own (a delayed fold or unfold, a launch mark that
    /// runs out), -1 if there is none. Never longer than a minute.
    pub fn nextTimeoutMs(ui: *Ui) i32 {
        const now = ui.nowMs();
        var best: ?u32 = null;
        var buf: [2 + dock_mod.max_drawers]*Bar = undefined;
        for (ui.allBars(&buf)) |b| {
            sooner(&best, now, b.fold_at);
            sooner(&best, now, b.unfold_at);
        }
        if (ui.model) |*m| {
            if (m.nextLaunchExpiry(now, launch_timeout_ms)) |ms| sooner(&best, now, now +% ms);
        }
        if (ui.animWaitMs(now)) |ms| {
            // At least 1 ms: a picture that cannot be drawn yet (river still
            // holds both buffers) must not make the loop spin.
            const wait = @max(ms, 1);
            if (best == null or wait < best.?) best = wait;
        }
        const left = best orelse return -1;
        return @intCast(@min(left, 60_000));
    }

    /// Called by the event loop after every wake-up: does whatever has come
    /// due. Cheap when nothing has.
    pub fn onTimer(ui: *Ui) void {
        const now = ui.nowMs();
        var buf: [2 + dock_mod.max_drawers]*Bar = undefined;
        for (ui.allBars(&buf)) |b| {
            if (b.unfold_at) |t| if (timeDue(now, t)) {
                b.unfold_at = null;
                if (ui.autoFolds(b) and ui.isFolded(b)) ui.setFolded(b, false);
            };
            if (b.fold_at) |t| if (timeDue(now, t)) {
                b.fold_at = null;
                if (ui.press == null and ui.autoFolds(b) and !ui.isFolded(b)) ui.setFolded(b, true);
            };
        }
        if (ui.model) |*m| {
            if (m.expireLaunching(now, launch_timeout_ms)) {
                ui.markBarsDirty();
                ui.wm.obj.manageDirty();
            }
        }
        // The next picture of an animation is due: a manage sequence draws it.
        if (ui.animWaitMs(now)) |ms| {
            if (ms == 0) ui.wm.obj.manageDirty();
        }
    }

    fn clickBar(ui: *Ui, b: *Bar, button: u32, time: u32) void {
        const wm = ui.wm;
        // A click on a bar while a menu is open only dismisses the menu,
        // like a click on the empty desktop does.
        if (ui.panels.items.len > 0) {
            ui.request = .close;
            wm.obj.manageDirty();
            return;
        }
        // Another button while a tile is held (a drag, or a press that may
        // still become one) must not open a menu in the middle of it. A
        // second LEFT press is let through: it means the release of the
        // first one never arrived, and the Dock must not stay stuck.
        if (ui.press != null and button != BTN_LEFT) return;
        const out = b.output orelse return;
        const model = if (ui.model) |*m| m else return;
        const hit = ui.barHit(b);
        const gi = hit.icon orelse return;
        // The Clip's arrows and menus change the workspace of the output the
        // Clip is on, not of whichever one happens to hold the focus.
        if (b.kind == .clip and gi.main) wm.active_output = out;

        // Where a menu goes: at the pointer, output-local.
        const mx = b.rect.x - out.rect.x + ui.px;
        const my = b.rect.y - out.rect.y + ui.py;

        const slot: ?SlotRef = if (model.slotOf(gi) != null) .{ .index = gi.tag } else null;

        // Window Maker: a press raises the Dock/Clip.
        ui.raiseBar(b.kind);
        const key = @intFromPtr(gi);
        const dbl = isDoubleClick(ui.last_click, time, button, b.kind, key);
        ui.last_click = if (dbl) .{} else .{ .time = time, .button = button, .kind = b.kind, .tile = key, .valid = true };
        const left = button == BTN_LEFT;
        const cp = dock_mod.cellPx(b.cells, gi.xindex, gi.yindex);
        const base: Press = .{
            .kind = .tile,
            .bar = b,
            .icon = gi,
            .slot = slot,
            .x = ui.px,
            .y = ui.py,
            .off_x = ui.px - cp[0],
            .off_y = ui.py - cp[1],
        };

        if (gi.main) {
            switch (b.kind) {
                .clip => switch (hit.arrow) {
                    // The workspace tile: arrows, menus, double click folds the Clip.
                    .next => if (left) {
                        wm.pending_ui = .workspace_next;
                    },
                    .prev => if (left) {
                        wm.pending_ui = .workspace_prev;
                    },
                    .none => switch (button) {
                        BTN_LEFT => if (dbl) {
                            ui.clip_collapsed = !ui.clip_collapsed;
                            ui.clip.dirty = true;
                            ui.saveState();
                        } else {
                            var pr = base;
                            pr.kind = .main_clip;
                            ui.press = pr;
                        },
                        BTN_RIGHT => ui.request = .{ .open_bar_menu = .{ .kind = .clip, .output = out, .x = mx, .y = my, .slot = null } },
                        BTN_MIDDLE => ui.request = .{ .open_bar_menu = .{ .kind = .workspaces, .output = out, .x = mx, .y = my, .slot = null } },
                        else => {},
                    },
                },
                .dock => switch (button) {
                    // The logo tile: drag moves the Dock, double click shows the
                    // info panel (Window Maker), right click the Dock menu.
                    BTN_LEFT => if (dbl) {
                        ui.request = .{ .open_bar_menu = .{ .kind = .info, .output = out, .x = mx, .y = my, .slot = null } };
                    } else {
                        var pr = base;
                        pr.kind = .main_dock;
                        ui.press = pr;
                    },
                    BTN_RIGHT => ui.request = .{ .open_bar_menu = .{ .kind = .dock, .output = out, .x = mx, .y = my, .slot = null } },
                    else => {},
                },
                .drawer => {
                    const di = if (b.wd) |d| (model.drawerIndex(d) orelse return) else return;
                    switch (button) {
                        // A click opens/closes the Drawer, a drag moves it.
                        BTN_LEFT => {
                            var pr = base;
                            pr.kind = .main_drawer;
                            pr.activate_on_release = true;
                            ui.press = pr;
                        },
                        BTN_RIGHT => ui.request = .{ .open_bar_menu = .{ .kind = .drawer, .output = out, .x = mx, .y = my, .slot = .{ .index = di } } },
                        else => {},
                    }
                },
            }
        } else if (slot) |ref| {
            // The tile of a minimized window restores it with ONE click (a
            // double click is only for starting programs) and has no menu.
            const mini_tile = if (ui.slotApp(ref)) |sa| sa.mini_window != 0 else false;
            switch (button) {
                BTN_LEFT => {
                    const single = wm.cfg.dock_single_click or mini_tile;
                    if (!single and dbl) {
                        ui.activateSlot(ref, false);
                    } else {
                        // Not yet a click: it may become a drag. With
                        // single-click launching it launches on release.
                        var pr = base;
                        pr.activate_on_release = single;
                        ui.press = pr;
                    }
                },
                BTN_MIDDLE => ui.activateSlot(ref, true),
                BTN_RIGHT => if (!mini_tile) {
                    ui.request = .{ .open_bar_menu = .{
                        .kind = switch (b.kind) {
                            .dock => .dock,
                            .clip => .clip,
                            .drawer => .dock,
                        },
                        .output = out,
                        .x = mx,
                        .y = my,
                        .slot = ref,
                    } };
                },
                else => {},
            }
        }
        wm.obj.manageDirty();
    }

    /// The pointer moved with a button held on a bar: start a drag once it
    /// has gone far enough, then follow it.
    fn dragMotion(ui: *Ui, b: *Bar) void {
        if (ui.dragUpdate(b)) ui.wm.obj.manageDirty();
    }

    /// Where a tile dragged to output-local top-left (rx, ry) would land:
    /// first in its own dock (redocking), then in the others, as
    /// Window Maker's handleDockMove tries them.
    fn findDrop(ui: *Ui, m: *dock_mod.Model, gi: *wdock.Icon, rx: i32, ry: i32) ?DropTarget {
        const src = gi.dock orelse return null;
        if (wdock.snapIcon(&m.scr, src, gi, rx, ry, true)) |xy| return .{ .dock = src, .xy = xy };
        if (ui.wm.cfg.dock_enabled) {
            const dock = m.scr.dock.?;
            if (dock != src) {
                if (wdock.snapIcon(&m.scr, dock, gi, rx, ry, false)) |xy| return .{ .dock = dock, .xy = xy };
            }
            for (m.scr.drawers.items) |d| {
                if (d == src or d.collapsed) continue;
                if (wdock.snapIcon(&m.scr, d, gi, rx, ry, false)) |xy| return .{ .dock = d, .xy = xy };
            }
        }
        if (ui.wm.cfg.clip_enabled and !ui.clip_collapsed) {
            const clip = m.currentClip();
            if (clip != src) {
                if (wdock.snapIcon(&m.scr, clip, gi, rx, ry, false)) |xy| return .{ .dock = clip, .xy = xy };
            }
        }
        return null;
    }

    /// The pointer moved with a button held on a bar: start a drag once it
    /// has gone far enough, then follow it. True if a bar (or the place it
    /// sits at) changed and needs a new frame.
    fn dragUpdate(ui: *Ui, b: *Bar) bool {
        const p = if (ui.press) |*pp| pp else return false;
        const wm = ui.wm;
        const out = b.output orelse return false;
        const m = if (ui.model) |*mm| mm else return false;
        if (!p.dragging) {
            const thr: i32 = @max(4, wm.cfg.drag_threshold);
            if (@abs(ui.px - p.x) <= thr and @abs(ui.py - p.y) <= thr) return false;
            // A locked tile stays where it is (Window Maker's Lock), and a
            // temporary DockApp tile is not something to rearrange.
            if (p.slot) |ref| if (ui.slotApp(ref)) |app| if (app.locked or app.attached) {
                ui.press = null;
                return false;
            };
            p.dragging = true;
        }
        const pb = p.bar;
        // The pointer, and the dragged tile's top-left, output-local.
        const lx = b.rect.x - out.rect.x + ui.px;
        const ly = b.rect.y - out.rect.y + ui.py;
        switch (p.kind) {
            .tile => {
                const target = ui.findDrop(m, p.icon, lx - p.off_x, ly - p.off_y);
                ui.drop_target = target;
                pb.drag = .{ .icon = p.icon, .detached = target == null, .x = ui.px, .y = ui.py };
            },
            .main_dock => {
                // The Dock follows the pointer: its first tile is the pointer
                // minus the point that was grabbed.
                const pl = dock_mod.dockPlacementFor(out.rect, b.rect.x + ui.px - p.off_x, b.rect.y + ui.py - p.off_y);
                wm.cfg.dock_edge = pl.edge;
                wm.cfg.dock_offset = pl.offset;
                pb.drag = null;
            },
            .main_clip => {
                wm.cfg.clip_corner = dock_mod.clipCornerFor(out.rect, b.rect.x + ui.px, b.rect.y + ui.py);
                pb.drag = null;
            },
            .main_drawer => {
                if (b.wd) |d| _ = m.moveDrawerToward(d, ly - p.off_y);
                pb.drag = null;
            },
        }
        ui.markBarsDirty();
        return true;
    }

    /// A button was let go: finish a drag, or (single-click mode) launch.
    fn onRelease(ui: *Ui, button: u32) void {
        if (ui.finishPress(button)) ui.wm.obj.manageDirty();
    }

    fn finishPress(ui: *Ui, button: u32) bool {
        if (button != BTN_LEFT) return false;
        const p = ui.press orelse return false;
        ui.press = null;
        const target = ui.drop_target;
        ui.drop_target = null;
        p.bar.drag = null;
        ui.markBarsDirty();

        if (!p.dragging) {
            if (p.activate_on_release) {
                if (p.slot) |ref| {
                    ui.activateSlot(ref, false);
                } else if (p.kind == .main_drawer) {
                    // A click on a Drawer's tile opens or closes it.
                    if (p.bar.wd) |d| d.collapsed = !d.collapsed;
                    ui.saveState();
                }
            }
            return true;
        }
        const m = if (ui.model) |*mm| mm else return true;
        if (p.kind == .tile) {
            const ref = p.slot orelse return true;
            const src = p.icon.dock;
            if (target) |t| {
                _ = m.dropSlot(ref.index, t.dock, t.xy);
                if (t.dock.kind == .drawer) wdock.drawerConsolidateIcons(t.dock);
            } else {
                // Let go of it anywhere else: the tile is taken away.
                _ = m.removeSlot(ref.index);
            }
            if (src) |sd| if (sd.kind == .drawer) wdock.drawerConsolidateIcons(sd);
            ui.clearPointers();
        }
        // Dragging over a Drawer slides its tiles aside; if the tile went
        // somewhere else (or nowhere) they have to come back, in EVERY
        // Drawer, not just the one it was dropped on.
        wdock.consolidateAllDrawers(&m.scr);
        ui.saveState();
        return true;
    }

    /// Pointers into the model (hover, press) must not outlive a change to
    /// the tiles.
    fn clearPointers(ui: *Ui) void {
        ui.press = null;
        ui.drop_target = null;
        var buf: [2 + dock_mod.max_drawers]*Bar = undefined;
        for (ui.allBars(&buf)) |b| {
            b.hover = null;
            b.hover_arrow = .none;
            b.drag = null;
            b.dirty = true;
        }
    }

    fn slotApp(ui: *Ui, ref: SlotRef) ?*const dockapp.DockApp {
        const m = if (ui.model) |*mm| mm else return null;
        const sl = m.slot(ref.index) orelse return null;
        return &sl.app;
    }

    /// A click on a tile: focus the application if a window of it is open,
    /// else start it. `force_new` always starts it (middle click, menu).
    fn activateSlot(ui: *Ui, ref: SlotRef, force_new: bool) void {
        const app = ui.slotApp(ref) orelse return;
        // The tile of a minimized window: bring exactly that window back.
        if (app.mini_window != 0) {
            var wit = ui.wm.windows.first();
            while (wit) |w| : (wit = types.nextWindow(w, ui.wm)) {
                if (w.closed or !w.minimized or w.min_order != app.mini_window) continue;
                ui.wm.pending_ui = .{ .focus = w };
                return;
            }
            return;
        }
        if (!force_new) {
            var it = ui.wm.windows.first();
            while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
                if (w.closed or (w.workspace == null and !w.minimized)) continue;
                const id = w.app_id orelse continue;
                if (!app.matches(id)) continue;
                ui.wm.pending_ui = .{ .focus = w };
                return;
            }
            // A running DockApp takes its own clicks: nothing to focus, and
            // not a second instance either.
            if (dockhost.hostFor(ui.wm, app) != null) return;
        }
        // A temporary DockApp tile has no command to start.
        if (app.command.len == 0) return;
        const now = ui.nowMs();
        if (!force_new) if (ui.model) |*m| if (m.slot(ref.index)) |sl| {
            if (sl.launching and now -% sl.launch_stamp < relaunch_guard_ms) return;
        };
        // A command that could not even be started does not make the tile
        // look as if it were starting.
        if (!proc.spawnChecked(ui.wm, app.command)) return;
        if (ui.model) |*m| {
            m.markLaunching(ref.index, now);
            ui.markBarsDirty();
        }
    }

    fn runUiCmd(ui: *Ui, cmd: UiCmd) void {
        switch (cmd) {
            .set_dock_level => |l| ui.dock_level = l,
            .toggle_clip_level => ui.clip_on_top = !ui.clip_on_top,
            .toggle_clip_collapse => ui.clip_collapsed = !ui.clip_collapsed,
            .toggle_clip_auto_collapse => ui.clip_auto_collapse = !ui.clip_auto_collapse,
            .toggle_clip_auto_raise => ui.clip_auto_raise = !ui.clip_auto_raise,
            .launch => |ref| {
                ui.activateSlot(ref, true);
                return;
            },
            .app_op => |r| {
                ui.app_request = r;
                return;
            },
            .toggle_lock => |ref| {
                const m = if (ui.model) |*mm| mm else return;
                const sl = m.slot(ref.index) orelse return;
                sl.app.locked = !sl.app.locked;
                sl.gi.lock = sl.app.locked;
            },
            .keep_attached => |ref| {
                const m = if (ui.model) |*mm| mm else return;
                if (!m.keepAttached(ref.index)) return;
            },
            .remove => |ref| {
                const m = if (ui.model) |*mm| mm else return;
                if (!m.removeSlot(ref.index)) return;
            },
            .set_workspace => |r| {
                const m = if (ui.model) |*mm| mm else return;
                if (!m.setSlotWorkspace(r.ref.index, r.ws)) return;
            },
            .keep => |k| ui.keepApplication(k.app_id, k.clip),
            .add_drawer => {
                const m = if (ui.model) |*mm| mm else return;
                const made = m.addDrawer("Drawer") catch return;
                if (made == null) return;
            },
            .remove_drawer => |i| {
                const m = if (ui.model) |*mm| mm else return;
                if (i >= m.scr.drawers.items.len) return;
                m.removeDrawer(m.scr.drawers.items[i]);
            },
            .toggle_drawer_collapse => |i| {
                const m = if (ui.model) |*mm| mm else return;
                if (i >= m.scr.drawers.items.len) return;
                const d = m.scr.drawers.items[i];
                d.collapsed = !d.collapsed;
            },
            .toggle_drawer_auto_collapse => |i| {
                const m = if (ui.model) |*mm| mm else return;
                if (i >= m.scr.drawers.items.len) return;
                const d = m.scr.drawers.items[i];
                d.auto_collapse = !d.auto_collapse;
            },
        }
        ui.clearPointers();
        ui.saveState();
    }

    /// How many windows (open, and of those minimized) belong to `app`.
    fn appState(ui: *Ui, app: *const dockapp.DockApp) struct { open: usize, hidden: usize } {
        var open: usize = 0;
        var hidden: usize = 0;
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            if (w.closed) continue;
            const id = w.app_id orelse continue;
            if (!app.matches(id)) continue;
            open += 1;
            if (w.minimized) hidden += 1;
        }
        return .{ .open = open, .hidden = hidden };
    }

    fn keepApplication(ui: *Ui, app_id: []const u8, clip: bool) void {
        const m = if (ui.model) |*mm| mm else return;
        if (!validAppId(app_id) or m.hasApp(app_id)) return;
        var buf: [128]u8 = undefined;
        const cmd = guessCommand(&buf, app_id) orelse return;
        const app: dockapp.DockApp = .{
            .name = app_id,
            .command = &.{cmd},
            .app_id = app_id,
            .place = if (clip) .clip else .dock,
            // (the current workspace's Clip, see Model.addApp)
            .workspace = if (clip) @as(?u32, 0) else null,
        };
        _ = m.addApp(app) catch |err| {
            log.warn("dock: cannot keep {s}: {t}", .{ app_id, err });
            return;
        };
    }

    /// Run what a menu row asked for on an application's windows. Called
    /// from sync(), i.e. inside the manage sequence, where window state may
    /// change.
    fn runAppRequest(ui: *Ui) void {
        const req = ui.app_request orelse return;
        ui.app_request = null;
        const wm = ui.wm;
        const app = ui.slotApp(req.ref) orelse return;
        const dest = types.workingOutput(wm);

        var last: ?*types.Window = null;
        var it = wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, wm)) {
            if (w.closed) continue;
            const id = w.app_id orelse continue;
            if (!app.matches(id)) continue;
            switch (req.op) {
                .kill => w.obj.close(),
                .hide => workspace.minimize(wm, w),
                .unhide => if (w.minimized) {
                    const out = dest orelse continue;
                    workspace.restore(wm, w, out.ws()) catch continue;
                    last = w;
                },
                .bring_here => {
                    const out = dest orelse continue;
                    if (w.minimized) {
                        workspace.restore(wm, w, out.ws()) catch continue;
                    } else if (w.workspace) |src| {
                        if (src != out.ws()) workspace.moveToWorkspace(wm, w, out.ws()) catch continue;
                    }
                    last = w;
                },
            }
        }
        if (last) |w| {
            wm.focus_request = w;
            wm.follow_request = true;
        }
        // A DockApp is not in the window list above; "Kill" reaches it here.
        if (req.op == .kill) dockhost.closeFor(wm, app);
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
        const left_first = ui.wm.cfg.menu_submenu_align == .left;
        const right_x = pl.x + pl.w - 2;
        const left_x = pl.x - cl.w + 2;
        cl.x = if (left_first) left_x else right_x;
        cl.y = pl.y + title_h + @as(i32, @intCast(row -| pl.scroll)) * item_h - title_h;
        if (cl.output) |out| {
            fitToOutput(cl, out);
            // `menu_submenu_align` is the side tried first; flip to the other
            // one when the submenu would leave the output on that side.
            if (left_first) {
                cl.x = left_x;
                if (cl.x < out.rect.x) cl.x = right_x;
            } else {
                cl.x = right_x;
                if (cl.x + cl.w > out.rect.right()) cl.x = left_x;
            }
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

    /// Runs an `EXEC` entry. The line is split exactly like a key binding's
    /// command (`config.parseCommand`: blanks separate words, "double quotes"
    /// group one). Use `SHEXEC` for anything that needs a real shell.
    fn spawnWords(ui: *Ui, cmd: []const u8) void {
        var tmp: std.heap.ArenaAllocator = .init(ui.gpa());
        defer tmp.deinit();
        const argv = config_mod.parseCommand(tmp.allocator(), cmd) catch |err| {
            switch (err) {
                error.OutOfMemory => log.err("out of memory while starting `{s}`", .{cmd}),
                else => log.warn("EXEC `{s}` has no command to run", .{cmd}),
            }
            return;
        };
        proc.spawn(ui.wm, argv);
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
                log.warn("menu `{s}`: more than {d} entries, the rest is not shown", .{ m.title, max_rows });
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
                "licensed under the GNU GPL,",
                "version 3.",
                "It comes with no warranty.",
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
        ui.runAppRequest();
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

    /// Restack, bottom to top: the Dock, the Clip and the Drawers. Runs after
    /// the windows (the focused one was raised); the DockApps (dockhost.apply)
    /// and then the menus (`onRenderMenus`) go on top of this.
    pub fn onRenderBars(ui: *Ui) void {
        // A real fullscreen window covers the Dock and the Clip: it goes
        // above them (they are not raised below, see `raised`).
        if (ui.fullscreenWindow()) |fs| {
            if (fs.visible == true) fs.node.placeTop();
        }
        if (ui.raised(.dock)) if (ui.dock.panel) |p| p.node.placeTop();
        if (ui.raised(.clip)) if (ui.clip.panel) |p| p.node.placeTop();
        for (ui.drawer_bars.items) |b| {
            if (ui.raisedBar(b)) if (b.panel) |p| p.node.placeTop();
        }
        // The flying frames are above the Dock (they end on its tile) and
        // below the menus.
        if (ui.anim_panel) |p| p.node.placeTop();
    }

    /// Menus are above everything else.
    pub fn onRenderMenus(ui: *Ui) void {
        for (ui.panels.items) |op| op.panel.node.placeTop();
    }

    /// What dockhost needs to know about the Dock this pass.
    pub fn dockHost(ui: *Ui) dockhost.Host {
        const m: *dock_mod.Model = if (ui.model) |*mm| mm else return .{};
        const p = ui.dock.panel orelse return .{};
        return .{
            .model = m,
            .out = ui.dock.output,
            .panel = p.node,
            .raised = ui.raised(.dock),
        };
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

    fn rebuildModel(ui: *Ui) void {
        const wm = ui.wm;
        ui.clearDrawerBars();
        if (ui.model) |*m| m.deinit();
        ui.model = null;
        ui.model_gen = wm.dock_gen;
        ui.model = dock_mod.Model.init(ui.gpa(), wm.dockapps, wm.cfg.workspace_names, config_mod.max_workspaces) catch |err| blk: {
            log.err("dock: cannot build the model: {t}", .{err});
            break :blk null;
        };
        ui.dock_level = dock_mod.levelFor(wm.cfg.dock_on_top, wm.cfg.dock_auto_raise);
        ui.clip_on_top = wm.cfg.clip_on_top;
        ui.clip_collapsed = wm.cfg.clip_collapsed;
        ui.clip_auto_collapse = wm.cfg.clip_auto_collapse;
        ui.clip_auto_raise = wm.cfg.clip_auto_raise;
        ui.dock_clicked = false;
        ui.clip_clicked = false;
        // Pointers into the old model mean nothing now.
        ui.app_request = null;
        ui.dock.wd = null;
        ui.clip.wd = null;
        ui.clearPointers();
    }

    fn clearDrawerBars(ui: *Ui) void {
        for (ui.drawer_bars.items) |b| {
            ui.dropBar(b);
            ui.gpa().destroy(b);
        }
        ui.drawer_bars.clearRetainingCapacity();
    }

    fn dropBar(ui: *Ui, b: *Bar) void {
        if (b.panel) |p| ui.graveyard.append(ui.gpa(), p) catch p.destroy();
        b.panel = null;
        b.output = null;
        b.wd = null;
        b.hover = null;
        b.hover_arrow = .none;
        b.drag = null;
        b.fold_at = null;
        b.unfold_at = null;
        b.dirty = true;
    }

    /// The fullscreen window of the workspace shown on the Dock's output.
    fn fullscreenWindow(ui: *const Ui) ?*types.Window {
        const out = ui.dock.output orelse ui.clip.output orelse return null;
        if (out.workspace_count == 0) return null;
        return out.ws().fullscreen;
    }

    fn raised(ui: *const Ui, kind: BarKind) bool {
        if (ui.dock.drag != null or ui.clip.drag != null) return true;
        // Fullscreen: the Dock and the Clip go behind the window. Their
        // space stays reserved (syncBars), so nothing moves around.
        if (ui.fullscreenWindow() != null) return false;
        return switch (kind) {
            .dock, .drawer => switch (ui.dock_level) {
                .top => true,
                .auto => ui.dock.hover != null,
                .normal => ui.dock_clicked,
            },
            .clip => ui.clip_on_top or ui.clip_clicked or (ui.clip_auto_raise and ui.clip.hover != null),
        };
    }

    fn raisedBar(ui: *const Ui, b: *const Bar) bool {
        if (b.kind == .drawer) {
            return ui.raised(.dock) or (ui.dock_level == .auto and b.hover != null);
        }
        return ui.raised(b.kind);
    }

    /// Milliseconds on a clock that only goes forward, wrapping at 2^32 (all
    /// comparisons use wrapping subtraction).
    fn nowMs(ui: *const Ui) u32 {
        const ts = std.Io.Clock.awake.now(ui.wm.io);
        return @truncate(@as(u64, @intCast(@max(0, ts.toMilliseconds()))));
    }

    /// What `saveState` writes next to the entries.
    fn savedState(ui: *const Ui) dockapp.State {
        const cfg = &ui.wm.cfg;
        return .{
            .edge = cfg.dock_edge,
            .offset = cfg.dock_offset,
            .dock_on_top = ui.dock_level == .top,
            .dock_auto_raise = ui.dock_level == .auto,
            .clip_corner = cfg.clip_corner,
            .clip_on_top = ui.clip_on_top,
            // With Autocollapse the fold state changes all the time and is
            // not worth remembering.
            .clip_collapsed = if (ui.clip_auto_collapse) null else ui.clip_collapsed,
            .clip_auto_collapse = ui.clip_auto_collapse,
            .clip_auto_raise = ui.clip_auto_raise,
        };
    }

    /// Write the Dock and Clip contents and switches to the state file
    /// (`dock_save_state`, see wm_files.saveDockState). Never fatal.
    fn saveState(ui: *Ui) void {
        const wm = ui.wm;
        if (!wm.cfg.dock_save_state) return;
        const path = wm.dock_state_path orelse return;
        const m = if (ui.model) |*mm| mm else return;
        var arena: std.heap.ArenaAllocator = .init(ui.gpa());
        defer arena.deinit();
        const list = m.exportList(arena.allocator()) catch return;
        wm_files.saveDockState(wm.io, ui.gpa(), path, list, ui.savedState()) catch |err| {
            log.warn("dock: cannot save the state to {s}: {t}", .{ path, err });
            return;
        };
        log.debug("dock: state saved to {s}", .{path});
    }

    fn prepareBar(ui: *Ui, b: *Bar, out: *types.Output, wd: *wdock.Dock, only_main: bool) void {
        if (b.output != out) ui.dropBar(b);
        b.output = out;
        const cells = dock_mod.cellsOf(wd, only_main, true);
        const rect: types.Rect = .{
            .x = out.rect.x + wd.x_pos + cells.minx * dock_mod.tile,
            .y = out.rect.y + wd.y_pos + cells.miny * dock_mod.tile,
            .w = cells.cols() * dock_mod.tile,
            .h = cells.rows() * dock_mod.tile,
        };
        if (b.panel) |p| {
            if (p.w != rect.w or p.h != rect.h) {
                ui.graveyard.append(ui.gpa(), p) catch p.destroy();
                b.panel = null;
                b.dirty = true;
            }
        }
        if (b.wd != wd or b.only_main != only_main or !std.meta.eql(b.cells, cells)) b.dirty = true;
        b.wd = wd;
        b.only_main = only_main;
        b.cells = cells;
        b.visible = dock_mod.cellsOf(wd, only_main, false);
        b.rect = rect;
        if (b.panel == null) {
            b.panel = Panel.create(ui, rect.w, rect.h) catch |err| {
                log.err("dock surface: {t}", .{err});
                return;
            };
            b.dirty = true;
        }
    }

    /// Only the tiles take pointer input; the margin around them (room for
    /// a dragged tile) and the gaps between them let it through.
    fn setInputRegion(ui: *Ui, panel: *Panel, b: *const Bar, wd: *const wdock.Dock) void {
        const region = ui.compositor.createRegion() catch return;
        defer region.destroy();
        for (wd.icons) |maybe| {
            const gi = maybe orelse continue;
            if (b.only_main and !gi.main) continue;
            const c = dock_mod.cellPx(b.cells, gi.xindex, gi.yindex);
            region.add(c[0], c[1], dock_mod.tile, dock_mod.tile);
        }
        panel.surface.setInputRegion(region);
    }

    fn presentBar(ui: *Ui, b: *Bar, m: *const dock_mod.Model) void {
        const panel = b.panel orelse return;
        const out = b.output orelse return;
        const wd = b.wd orelse return;
        if (b.dirty or !panel.committed) {
            const slot = panel.freeSlot() catch {
                // river has not released a buffer yet; retry next sequence.
                ui.wm.obj.manageDirty();
                return;
            };
            dock_mod.drawBar(&slot.canvas, m, .{
                .dock = wd,
                .cells = b.cells,
                .only_main = b.only_main,
                .hover = b.hover,
                .hover_arrow = b.hover_arrow,
                .drag = b.drag,
                .workspace = out.active,
                .name = m.workspaceName(out.active),
                .target = if (ui.drop_target) |t| (if (t.dock == wd) t.xy else null) else null,
            });
            ui.setInputRegion(panel, b, wd);
            panel.present(slot);
            b.dirty = false;
        }
        place(panel, b.rect.x, b.rect.y);
        if (!ui.raisedBar(b)) panel.node.placeBottom();
    }

    fn dropAllBars(ui: *Ui) void {
        ui.dropBar(&ui.dock);
        ui.dropBar(&ui.clip);
        ui.clearDrawerBars();
    }

    /// main.onManage() runs this a second time after the actions, so the Dock
    /// tile of a window minimized by a key binding (or the loss of one that
    /// was restored) shows up in the same sequence. The surface that a
    /// changed Dock replaced is destroyed right away, like sync() does at
    /// its end: left in the graveyard it would stay on the screen with its
    /// old tiles until the next input event.
    pub fn syncDock(ui: *Ui) void {
        ui.syncBars();
        ui.reapGraveyard();
    }

    pub fn syncBars(ui: *Ui) void {
        const wm = ui.wm;
        if (ui.model_gen != wm.dock_gen) ui.rebuildModel();

        const out = ui.primaryOutput();
        // What the Dock reserves only ever applies to the output it is on.
        var oit = wm.outputs.first();
        while (oit) |other| : (oit = types.nextOutput(other, wm)) {
            if (other != out) other.reserved = .{};
        }
        const primary = out orelse {
            ui.dropAllBars();
            return;
        };
        const m: *dock_mod.Model = if (ui.model) |*mm| mm else {
            ui.dropAllBars();
            primary.reserved = .{};
            return;
        };

        // The tiles follow the programs: every DockApp has one (a temporary
        // one if it has no entry), `running` is up to date, a temporary tile
        // goes with its program. (dockhost.zig owns all of that.)
        // The rows of the screen must be known before tiles are added to the
        // Dock (a new tile has to lie on the screen); layout() sets them.
        m.layout(primary.rect.w, primary.rect.h, wm.cfg.dock_edge == .right, wm.cfg.dock_offset, wm.cfg.clip_corner);
        const synced = dockhost.syncModel(wm, m);
        const expired = m.expireLaunching(ui.nowMs(), launch_timeout_ms);
        if (synced) ui.clearPointers();
        if (synced or expired) ui.markBarsDirty();

        // A Dock/Clip raised by a click goes back down once the keyboard
        // focus has moved to another window.
        const focus_now: ?*types.Window = if (wm.seats.first()) |sd| sd.focused else null;
        if (focus_now != ui.raise_focus) {
            ui.raise_focus = focus_now;
            ui.dock_clicked = false;
            ui.clip_clicked = false;
        }

        const cfg = &wm.cfg;
        primary.reserved = .{};

        // Where everything is on this output; the Clip follows the workspace.
        m.layout(primary.rect.w, primary.rect.h, cfg.dock_edge == .right, cfg.dock_offset, cfg.clip_corner);
        const clip_before = m.currentClip();
        m.setWorkspace(primary.active);
        if (m.currentClip() != clip_before) ui.clip.dirty = true;

        if (cfg.dock_enabled) {
            ui.prepareBar(&ui.dock, primary, m.scr.dock.?, false);
            // The Dock's column is taken out of the work area whatever its
            // level (top / auto / lowered): tiled windows are laid out and
            // clipped next to it (layout.compute, window.applyClip).
            // A fullscreen window does not change this: it covers the
            // whole output on its own, and the other windows keep their
            // places for when it ends.
            if (cfg.dock_reserve_space) switch (cfg.dock_edge) {
                .left => primary.reserved.left = dock_mod.tile,
                .right => primary.reserved.right = dock_mod.tile,
            };
        } else ui.dropBar(&ui.dock);

        if (!std.meta.eql(primary.reserved, ui.last_reserved)) {
            ui.last_reserved = primary.reserved;
            log.debug("dock: reserved space left={d} right={d} (dock_enabled={}, dock_reserve_space={}, edge={t}, level={t})", .{
                primary.reserved.left, primary.reserved.right,
                cfg.dock_enabled,      cfg.dock_reserve_space,
                cfg.dock_edge,         ui.dock_level,
            });
        }

        if (cfg.clip_enabled) {
            ui.prepareBar(&ui.clip, primary, m.currentClip(), ui.clip_collapsed);
        } else ui.dropBar(&ui.clip);

        // One bar per Drawer.
        const want = if (cfg.dock_enabled) m.scr.drawers.items.len else 0;
        while (ui.drawer_bars.items.len > want) {
            const b = ui.drawer_bars.pop().?;
            ui.dropBar(b);
            ui.gpa().destroy(b);
        }
        while (ui.drawer_bars.items.len < want) {
            const b = ui.gpa().create(Bar) catch break;
            b.* = .{ .kind = .drawer };
            ui.drawer_bars.append(ui.gpa(), b) catch {
                ui.gpa().destroy(b);
                break;
            };
        }
        for (ui.drawer_bars.items, 0..) |b, i| {
            const d = m.scr.drawers.items[i];
            ui.prepareBar(b, primary, d, d.collapsed);
        }

        ui.presentBar(&ui.dock, m);
        ui.presentBar(&ui.clip, m);
        for (ui.drawer_bars.items) |b| ui.presentBar(b, m);
    }

    // ---- minimize / restore animation ---------------------------------------------
    //
    // Window Maker's miniaturize animation (anim.zig): the window's frame
    // flies to its Dock tile when it is minimized, and from the tile back to
    // the window when it is restored. How the three steps fit together:
    //
    //   * animRemember() ends every manage sequence by writing down which
    //     windows are minimized and where the others are on the screen;
    //   * animCollect() starts the next one by comparing: a window that is
    //     minimized now but was not is a minimize, the other way round a
    //     restore. This finds every way there is (key, menu, Dock click,
    //     hide_others, ...) without any of them knowing about animations;
    //   * animLaunch() runs after the layout, when the final rectangle of a
    //     restored window is known, and animStep() draws the pictures.

    /// The Dock tile at grid cell (cx, cy) as a global box; null if the Dock
    /// has no surface.
    fn dockCellBox(ui: *const Ui, cx: i32, cy: i32) ?anim.Box {
        const b = &ui.dock;
        if (b.rect.w <= 0 or b.rect.h <= 0) return null;
        const p = dock_mod.cellPx(b.cells, cx, cy);
        return .{ .x = b.rect.x + p[0], .y = b.rect.y + p[1], .w = dock_mod.tile, .h = dock_mod.tile };
    }

    /// Where the tile of the minimized window `order` is, if it has one.
    fn miniTileBox(ui: *Ui, order: u64) ?anim.Box {
        const m = if (ui.model) |*mm| mm else return null;
        const idx = m.miniSlotFor(order) orelse return null;
        const s = m.slot(idx) orelse return null;
        return ui.dockCellBox(s.gi.xindex, s.gi.yindex);
    }

    /// The end of a manage sequence: what animCollect compares with.
    pub fn animRemember(ui: *Ui) void {
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            w.anim_min = w.minimized;
            const on_screen = w.visible == true and !w.minimized and !w.closed and
                w.workspace != null and w.target.w > 0 and w.target.h > 0;
            const b = frameBox(ui.wm, w);
            w.anim_rect = if (on_screen) .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h } else .{};
        }
    }

    /// Which windows were minimized or restored since the last sequence.
    /// Must run BEFORE the Dock is synced: the tile of a restored window is
    /// where the animation starts, and the sync takes it away.
    pub fn animCollect(ui: *Ui) void {
        ui.anim_req_n = 0;
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            if (w.closed or w.anim_min == w.minimized) continue;
            if (ui.anim_req_n >= anim_max) break;
            var from: anim.Box = undefined;
            if (w.minimized) {
                // It was on the screen where it was last seen; a window on
                // another workspace flies nowhere.
                const r = w.anim_rect;
                if (r.w <= 0 or r.h <= 0) continue;
                from = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
            } else {
                from = ui.miniTileBox(w.min_order) orelse ui.dockCellBox(0, 0) orelse continue;
            }
            ui.anim_req[ui.anim_req_n] = .{ .win = w, .restore = !w.minimized, .from = from };
            ui.anim_req_n += 1;
        }
    }

    /// Start what animCollect found. Runs after the layout.
    pub fn animLaunch(ui: *Ui) void {
        ui.animLaunchAt(ui.nowMs());
    }

    fn animLaunchAt(ui: *Ui, now: u32) void {
        defer ui.anim_req_n = 0;
        const style = animStyle(ui.wm.cfg.iconify_style, now) orelse return;
        for (ui.anim_req[0..ui.anim_req_n]) |r| {
            if (ui.anim_n >= anim_max) break;
            const w = r.win;
            if (w.closed) continue;
            var to: anim.Box = undefined;
            if (r.restore) {
                // To where the window is now (after the layout), if that is
                // on the screen.
                const ws = w.workspace orelse continue;
                if (ws.output.active != ws.index or w.target.w <= 0 or w.target.h <= 0) continue;
                to = frameBox(ui.wm, w);
            } else {
                // To its tile; if it has none (the Dock is full or off) to
                // the Dock's first tile; if there is no Dock, nowhere.
                to = ui.miniTileBox(w.min_order) orelse ui.dockCellBox(0, 0) orelse continue;
            }
            ui.anims[ui.anim_n] = .{
                .plan = anim.plan(style, r.from, to),
                .start_ms = now,
                .hold = if (r.restore) w else null,
            };
            ui.anim_n += 1;
            ui.anim_redraw = true;
        }
    }

    /// Is the window on its way back from the Dock? Then it stays hidden
    /// until the animation is over (window.applyRender asks).
    pub fn animHolding(ui: *const Ui, w: *const types.Window) bool {
        for (ui.anims[0..ui.anim_n]) |*an| {
            if (an.hold == w) return true;
        }
        return false;
    }

    /// Milliseconds until an animation needs a new picture (0: now), null
    /// if nothing flies.
    fn animWaitMs(ui: *const Ui, now: u32) ?u32 {
        if (ui.anim_n == 0) return null;
        var best: u32 = std.math.maxInt(u32);
        for (ui.anims[0..ui.anim_n]) |*an| {
            const idx = animIndex(an, now);
            if (idx >= an.plan.n or idx != an.drawn) return 0;
            const left = an.plan.delay_ms - (now -% an.start_ms) % an.plan.delay_ms;
            best = @min(best, left);
        }
        return best;
    }

    /// Stop everything that flies and let go of the windows it holds.
    fn animCancel(ui: *Ui) void {
        ui.anim_n = 0;
        ui.animEnd();
    }

    /// Nothing flies any more: the surface goes.
    fn animEnd(ui: *Ui) void {
        if (ui.anim_panel) |p| {
            ui.graveyard.append(ui.gpa(), p) catch p.destroy();
            ui.anim_panel = null;
            ui.reapGraveyard();
        }
    }

    /// A surface that covers every running animation. null: it cannot be
    /// made (too big, out of memory), and nothing is shown.
    fn animEnsurePanel(ui: *Ui) bool {
        var u = ui.anims[0].plan.bounds;
        for (ui.anims[1..ui.anim_n]) |an| {
            const b = an.plan.bounds;
            const x0 = @min(u.x, b.x);
            const y0 = @min(u.y, b.y);
            const x1 = @max(u.x + u.w, b.x + b.w);
            const y1 = @max(u.y + u.h, b.y + b.h);
            u = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        }
        if (ui.anim_panel != null) {
            const o = ui.anim_box;
            if (u.x >= o.x and u.y >= o.y and u.x + u.w <= o.x + o.w and u.y + u.h <= o.y + o.h) return true;
            ui.animEnd();
        }
        if (u.w <= 0 or u.h <= 0 or u.w > anim_max_px or u.h > anim_max_px) return false;
        const p = Panel.create(ui, u.w, u.h) catch return false;
        // Frames in the air never catch the pointer.
        if (ui.compositor.createRegion()) |region| {
            defer region.destroy();
            p.surface.setInputRegion(region);
        } else |_| {}
        ui.anim_panel = p;
        ui.anim_box = u;
        ui.anim_redraw = true;
        return true;
    }

    /// Draw what is due. Runs in every manage sequence (the event loop
    /// starts one whenever a picture is due, see onTimer).
    pub fn animStep(ui: *Ui) void {
        if (ui.anim_n == 0) {
            if (ui.anim_panel != null) ui.animEnd();
            return;
        }
        const now = ui.nowMs();

        // The finished ones go; a window they held is shown again by the
        // applyRender that follows in this sequence.
        var i: usize = 0;
        while (i < ui.anim_n) {
            if (animIndex(&ui.anims[i], now) >= ui.anims[i].plan.n) {
                ui.anims[i] = ui.anims[ui.anim_n - 1];
                ui.anim_n -= 1;
            } else i += 1;
        }
        if (ui.anim_n == 0) {
            ui.animEnd();
            return;
        }

        if (!ui.animEnsurePanel()) {
            log.warn("animation: no surface for it; skipped", .{});
            ui.animCancel();
            return;
        }
        const panel = ui.anim_panel.?;
        var changed = ui.anim_redraw;
        for (ui.anims[0..ui.anim_n]) |*an| {
            if (animIndex(an, now) != an.drawn) changed = true;
        }
        if (changed) {
            // Both buffers still with river: the next tick tries again.
            const slot = panel.freeSlot() catch return;
            slot.canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
            for (ui.anims[0..ui.anim_n]) |*an| {
                const idx = animIndex(an, now);
                an.drawn = idx;
                anim.draw(&slot.canvas, an.plan.frame(idx), ui.anim_box.x, ui.anim_box.y);
            }
            panel.present(slot);
            ui.anim_redraw = false;
        }
        place(panel, ui.anim_box.x, ui.anim_box.y);
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

    /// "• label" for the choice that is on, "  label" otherwise (the menus
    /// have no check marks).
    fn marked(ui: *Ui, on: bool, label: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(ui.a(), "{s} {s}", .{ if (on) "\u{2022}" else " ", label }, 0);
    }

    fn buildDockPositionLevel(ui: *Ui) !usize {
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        for ([_]dock_mod.Level{ .normal, .auto, .top }) |l| {
            try rows.append(ui.a(), .{
                .label = try ui.marked(ui.dock_level == l, l.label()),
                .kind = .{ .ui_cmd = .{ .set_dock_level = l } },
            });
        }
        return ui.finishLevel(me, "Dock position", &rows);
    }

    fn buildClipOptionsLevel(ui: *Ui) !usize {
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        try rows.append(ui.a(), .{ .label = try ui.marked(ui.clip_on_top, "Keep on Top"), .kind = .{ .ui_cmd = .toggle_clip_level } });
        try rows.append(ui.a(), .{ .label = try ui.marked(ui.clip_collapsed, "Collapsed"), .kind = .{ .ui_cmd = .toggle_clip_collapse } });
        try rows.append(ui.a(), .{ .label = try ui.marked(ui.clip_auto_collapse, "Autocollapse"), .kind = .{ .ui_cmd = .toggle_clip_auto_collapse } });
        try rows.append(ui.a(), .{ .label = try ui.marked(ui.clip_auto_raise, "Autoraise"), .kind = .{ .ui_cmd = .toggle_clip_auto_raise } });
        return ui.finishLevel(me, "Clip Options", &rows);
    }

    /// Programs with a window that have no Dock/Clip entry yet, one row each
    /// (at most `max_keep_rows`). Window Maker's "Keep Icon".
    fn buildKeepLevel(ui: *Ui, clip: bool) !?usize {
        const m = if (ui.model) |*mm| mm else return null;
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        var it = ui.wm.windows.first();
        while (it) |w| : (it = types.nextWindow(w, ui.wm)) {
            if (rows.items.len >= max_keep_rows) break;
            if (w.closed) continue;
            const id = w.app_id orelse continue;
            if (!validAppId(id) or m.hasApp(id)) continue;
            var dup = false;
            for (rows.items) |r| {
                if (std.mem.eql(u8, r.label, clipUtf8(id, max_label_bytes))) dup = true;
            }
            if (dup) continue;
            const stored = try ui.a().dupe(u8, id);
            try rows.append(ui.a(), .{
                .label = try ui.zdup(clipUtf8(id, 64)),
                .kind = .{ .ui_cmd = .{ .keep = .{ .app_id = stored, .clip = clip } } },
            });
        }
        if (rows.items.len == 0) {
            _ = ui.levels.pop();
            return null;
        }
        return try ui.finishLevel(me, "Keep Application", &rows);
    }

    /// Clip only: where an entry is shown (Window Maker's "Move Icon To").
    fn buildMoveLevel(ui: *Ui, ref: SlotRef) !usize {
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        const m = if (ui.model) |*mm| mm else return error.NoModel;
        const cur: ?u32 = if (ui.slotApp(ref)) |app| app.workspace else null;
        try rows.append(ui.a(), .{
            .label = try ui.marked(cur == null, "All workspaces"),
            .kind = .{ .ui_cmd = .{ .set_workspace = .{ .ref = ref, .ws = null } } },
        });
        const live: u32 = if (types.workingOutput(ui.wm)) |o| o.workspace_count else ui.wm.cfg.workspace_count;
        const n = @min(live, max_move_rows);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const label = if (m.workspaceName(i)) |name|
                try std.fmt.allocPrint(ui.a(), "{d}  {s}", .{ i + 1, clipUtf8(name, 40) })
            else
                try std.fmt.allocPrint(ui.a(), "{d}", .{i + 1});
            const marked_label = try ui.marked(cur != null and cur.? == i, label);
            try rows.append(ui.a(), .{
                .label = marked_label,
                .kind = .{ .ui_cmd = .{ .set_workspace = .{ .ref = ref, .ws = i } } },
            });
        }
        return ui.finishLevel(me, "Move Icon To", &rows);
    }

    fn buildBarMenu(ui: *Ui, kind: BarMenuKind, slot: ?SlotRef) !usize {
        if (kind == .workspaces) return ui.buildWorkspaceLevel();
        if (kind == .info) return ui.buildTextLevel(.info_panel);

        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;

        if (kind == .drawer) {
            _ = ui.levels.pop();
            return ui.buildDrawerMenu(if (slot) |r| r.index else 0);
        }
        var title: []const u8 = if (kind == .dock) "Dock" else "Clip";
        var on_tile = false;
        if (slot) |ref| if (ui.slotApp(ref)) |app| {
            on_tile = true;
            title = app.name;
            const st = ui.appState(app);
            // A DockApp is no window: it can be killed, not hidden or brought.
            const hosted = dockhost.hostFor(ui.wm, app) != null;
            const running = st.open > 0 or hosted;
            const all_hidden = st.open > 0 and st.hidden == st.open;

            // Window Maker's per-icon entries, in its order.
            try rows.append(ui.a(), .{
                .label = "Launch",
                .enabled = app.command.len > 0,
                .kind = .{ .ui_cmd = .{ .launch = ref } },
            });
            try rows.append(ui.a(), .{
                .label = if (all_hidden) "Unhide Here" else "Bring Here",
                .enabled = st.open > 0,
                .kind = .{ .ui_cmd = .{ .app_op = .{ .op = .bring_here, .ref = ref } } },
            });
            try rows.append(ui.a(), .{
                .label = if (all_hidden) "Unhide" else "Hide",
                .enabled = st.open > 0,
                .kind = .{ .ui_cmd = .{ .app_op = .{ .op = if (all_hidden) .unhide else .hide, .ref = ref } } },
            });
            if (app.place == .clip) {
                const child = try ui.buildMoveLevel(ref);
                try rows.append(ui.a(), .{ .label = "Move Icon To", .kind = .{ .submenu = child } });
            }
            if (app.attached) {
                try rows.append(ui.a(), .{ .label = "Keep Icon", .kind = .{ .ui_cmd = .{ .keep_attached = ref } } });
            } else {
                try rows.append(ui.a(), .{
                    .label = if (app.locked) "Unlock" else "Lock",
                    .kind = .{ .ui_cmd = .{ .toggle_lock = ref } },
                });
            }
            try rows.append(ui.a(), .{
                .label = "Remove Icon",
                .enabled = !app.locked and !app.attached,
                .kind = .{ .ui_cmd = .{ .remove = ref } },
            });
            try rows.append(ui.a(), .{
                .label = "Kill",
                .enabled = running,
                .kind = .{ .ui_cmd = .{ .app_op = .{ .op = .kill, .ref = ref } } },
            });
        };

        if (!on_tile) switch (kind) {
            .dock => {
                const pos = try ui.buildDockPositionLevel();
                try rows.append(ui.a(), .{ .label = "Dock position", .kind = .{ .submenu = pos } });
                if (try ui.buildKeepLevel(false)) |keep| {
                    try rows.append(ui.a(), .{ .label = "Keep Application", .kind = .{ .submenu = keep } });
                } else {
                    try rows.append(ui.a(), .{ .label = "Keep Application", .enabled = false, .kind = .none });
                }
                try rows.append(ui.a(), .{ .label = "Add a drawer", .kind = .{ .ui_cmd = .add_drawer } });
                const info = try ui.buildTextLevel(.info_panel);
                try rows.append(ui.a(), .{ .label = "Info Panel", .kind = .{ .submenu = info } });
            },
            .clip => {
                const opts = try ui.buildClipOptionsLevel();
                try rows.append(ui.a(), .{ .label = "Clip Options", .kind = .{ .submenu = opts } });
                if (try ui.buildKeepLevel(true)) |keep| {
                    try rows.append(ui.a(), .{ .label = "Keep Application", .kind = .{ .submenu = keep } });
                } else {
                    try rows.append(ui.a(), .{ .label = "Keep Application", .enabled = false, .kind = .none });
                }
                try rows.append(ui.a(), .{ .label = "Next Workspace", .kind = .{ .builtin = .workspace_next } });
                try rows.append(ui.a(), .{ .label = "Previous Workspace", .kind = .{ .builtin = .workspace_prev } });
                const child = try ui.buildWorkspaceLevel();
                try rows.append(ui.a(), .{ .label = "Workspaces", .kind = .{ .submenu = child } });
            },
            .drawer, .workspaces, .info => unreachable,
        };
        return ui.finishLevel(me, title, &rows);
    }

    /// The menu of a Drawer's own tile (`index` is the Drawer's).
    fn buildDrawerMenu(ui: *Ui, index: usize) !usize {
        const m = if (ui.model) |*mm| mm else return error.NoModel;
        if (index >= m.scr.drawers.items.len) return error.NoModel;
        const d = m.scr.drawers.items[index];
        const me = ui.levels.items.len;
        try ui.levels.append(ui.gpa(), undefined);
        var rows: std.ArrayList(Row) = .empty;
        try rows.append(ui.a(), .{ .label = try ui.marked(d.collapsed, "Collapsed"), .kind = .{ .ui_cmd = .{ .toggle_drawer_collapse = index } } });
        try rows.append(ui.a(), .{ .label = try ui.marked(d.auto_collapse, "Autocollapse"), .kind = .{ .ui_cmd = .{ .toggle_drawer_auto_collapse = index } } });
        try rows.append(ui.a(), .{ .label = "Remove drawer", .kind = .{ .ui_cmd = .{ .remove_drawer = index } } });
        return ui.finishLevel(me, m.drawer_names.items[index], &rows);
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
            log.err("desktop surface: {t}", .{err});
            return;
        };
        // A fully transparent surface still takes pointer input, and the
        // wallpaper (if any) stays visible.
        const slot = panel.freeSlot() catch |err| {
            log.err("desktop buffer: {t}", .{err});
            panel.destroy();
            return;
        };
        slot.canvas.clear(col_clear);
        panel.present(slot);
        ui.desktops.append(ui.gpa(), .{ .output = out, .panel = panel }) catch {
            panel.destroy();
            return;
        };
        log.debug("desktop surface {d}x{d} at {d},{d}", .{ out.rect.w, out.rect.h, out.rect.x, out.rect.y });
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
            log.warn("root menu: none loaded", .{});
            return;
        };
        const top = built catch |err| {
            log.err("root menu build failed: {t}", .{err});
            ui.resetMenu();
            return;
        };
        ui.showTop(out, top, x, y);
    }

    fn openBarMenu(ui: *Ui, kind: BarMenuKind, out: *types.Output, x: i32, y: i32, slot: ?SlotRef) void {
        ui.resetMenu();
        const top = ui.buildBarMenu(kind, slot) catch |err| {
            log.err("dock menu build failed: {t}", .{err});
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
        log.debug("menu `{s}` at {d},{d} ({d} rows)", .{ lvl.title, lvl.x, lvl.y, lvl.rows.len });
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
                    log.err("menu surface: {t}", .{err});
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
        for (ui.anims[0..ui.anim_n]) |*an| {
            if (an.hold == w) an.hold = null;
        }
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
        const tw = gfx.measureText(lvl.title, gfx.fonts.menuTitle()).w;
        cv.drawText(lvl.title, @divTrunc(lvl.w - tw, 2), 3, gfx.fonts.menuTitle(), col_hi_text);

        const first = lvl.scroll;
        const last = @min(lvl.rows.len, first + shown(lvl));
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

test "barHit: Dock rows, gaps and the logo" {
    var wm: types.WindowManager = undefined;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer ui.arena.deinit();
    const apps = dockTestApps();
    var m = try dock_mod.Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();

    const dock = m.scr.dock.?;
    const bar: Bar = .{ .kind = .dock, .wd = dock, .cells = dock_mod.cellsOf(dock, false, false) };
    ui.px = 30;
    ui.py = 5;
    try std.testing.expect(ui.barHit(&bar).icon.?.main); // the logo
    ui.py = 64 + 63; // row 1: term
    try std.testing.expectEqual(@as(usize, 0), ui.barHit(&bar).icon.?.tag);
    ui.py = 64 * 2; // below the last tile
    try std.testing.expect(ui.barHit(&bar).icon == null);
    ui.px = -1;
    ui.py = 5;
    try std.testing.expect(ui.barHit(&bar).icon == null);
}

test "barHit: Clip tile, arrows and an application tile next to it" {
    var wm: types.WindowManager = undefined;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer ui.arena.deinit();
    const apps = [_]dockapp.DockApp{.{ .name = "n", .command = &.{"n"}, .place = .clip, .workspace = 0, .x = 1 }};
    var m = try dock_mod.Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();

    const clip = m.scr.clips.items[0];
    const bar: Bar = .{ .kind = .clip, .wd = clip, .cells = dock_mod.cellsOf(clip, false, false) };
    ui.px = 60;
    ui.py = 3;
    var hit = ui.barHit(&bar);
    try std.testing.expect(hit.icon.?.main);
    try std.testing.expectEqual(dock_mod.Arrow.next, hit.arrow);
    ui.px = 3;
    ui.py = 60;
    try std.testing.expectEqual(dock_mod.Arrow.prev, ui.barHit(&bar).arrow);
    ui.px = 64 + 20;
    ui.py = 3; // an application tile: its corner is not an arrow
    hit = ui.barHit(&bar);
    try std.testing.expect(!hit.icon.?.main);
    try std.testing.expectEqual(dock_mod.Arrow.none, hit.arrow);

    // Collapsed, only the workspace tile answers.
    var folded = bar;
    folded.only_main = true;
    try std.testing.expect(ui.barHit(&folded).icon == null);
}

var test_dummy: u8 = 0;

/// A WindowManager + Ui + Output with a Dock model, enough for the menus,
/// run-time switches and the drag logic (nothing here talks to river).
const Fx = struct {
    wm: types.WindowManager,
    ui: Ui,
    out: types.Output,
    wins: [8]*types.Window = undefined,
    nwins: usize = 0,

    fn create(apps: []const dockapp.DockApp) !*Fx {
        const a = std.testing.allocator;
        const f = try a.create(Fx);
        f.* = .{
            .wm = .{
                .gpa = a,
                .io = undefined,
                .cfg = .{ .arena = .init(a) },
                .obj = @ptrCast(&test_dummy),
                .obj_version = 6,
                .outputs = undefined,
                .windows = undefined,
                .dock_windows = undefined,
                .seats = undefined,
            },
            .ui = undefined,
            .out = .{ .obj = @ptrCast(&test_dummy) },
        };
        f.out.rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
        f.wm.windows.init();
        f.wm.dock_windows.init();
        f.wm.outputs.init();
        f.wm.seats.init();
        f.wm.cfg.dock_save_state = false;
        f.ui = testUi(a, &f.wm);
        f.ui.model = try dock_mod.Model.init(a, .{ .apps = apps }, &.{}, 4);
        return f;
    }

    fn destroy(f: *Fx) void {
        const a = std.testing.allocator;
        f.ui.levels.deinit(a);
        f.ui.arena.deinit();
        if (f.ui.model) |*m| m.deinit();
        for (f.wins[0..f.nwins]) |w| {
            types.unlink(&w.link);
            if (w.app_id) |id| a.free(id);
            a.destroy(w);
        }
        f.wm.cfg.deinit();
        a.destroy(f);
    }

    fn addWindow(f: *Fx, app_id: []const u8) !*types.Window {
        const w = try std.testing.allocator.create(types.Window);
        w.* = .{ .obj = @ptrCast(&test_dummy), .node = @ptrCast(&test_dummy) };
        w.app_id = try std.testing.allocator.dupe(u8, app_id);
        f.wm.windows.append(w);
        f.wins[f.nwins] = w;
        f.nwins += 1;
        return w;
    }

    /// The Dock's bar as a sync would have made it (no surface), the model
    /// laid out on the output.
    fn dockBar(f: *Fx) *Bar {
        const m = &f.ui.model.?;
        m.layout(f.out.rect.w, f.out.rect.h, true, 0, .top_left);
        return f.bar(&f.ui.dock, m.scr.dock.?, false);
    }

    fn clipBar(f: *Fx) *Bar {
        const m = &f.ui.model.?;
        m.layout(f.out.rect.w, f.out.rect.h, true, 0, .top_left);
        return f.bar(&f.ui.clip, m.currentClip(), false);
    }

    fn bar(f: *Fx, b: *Bar, wd: *wdock.Dock, only_main: bool) *Bar {
        b.output = &f.out;
        b.wd = wd;
        b.only_main = only_main;
        b.cells = dock_mod.cellsOf(wd, only_main, true);
        b.visible = dock_mod.cellsOf(wd, only_main, false);
        b.rect = .{
            .x = f.out.rect.x + wd.x_pos + b.cells.minx * dock_mod.tile,
            .y = f.out.rect.y + wd.y_pos + b.cells.miny * dock_mod.tile,
            .w = b.cells.cols() * dock_mod.tile,
            .h = b.cells.rows() * dock_mod.tile,
        };
        return b;
    }
};

fn rowLabels(lvl: Level, out: *[16][]const u8) []const []const u8 {
    for (lvl.rows, 0..) |r, i| out[i] = r.label;
    return out[0..lvl.rows.len];
}

test "isDoubleClick: same button, bar and tile within the delay, wrapping time" {
    const last: LastClick = .{ .time = 1000, .button = BTN_LEFT, .kind = .dock, .tile = 2, .valid = true };
    try std.testing.expect(isDoubleClick(last, 1300, BTN_LEFT, .dock, 2));
    try std.testing.expect(isDoubleClick(last, 1000 + double_click_ms, BTN_LEFT, .dock, 2));
    try std.testing.expect(!isDoubleClick(last, 1000 + double_click_ms + 1, BTN_LEFT, .dock, 2));
    try std.testing.expect(!isDoubleClick(last, 1100, BTN_RIGHT, .dock, 2));
    try std.testing.expect(!isDoubleClick(last, 1100, BTN_LEFT, .clip, 2));
    try std.testing.expect(!isDoubleClick(last, 1100, BTN_LEFT, .dock, 3));
    try std.testing.expect(!isDoubleClick(.{}, 1, BTN_LEFT, .dock, 0)); // nothing before
    // The millisecond counter wraps around 2^32.
    const wrapped: LastClick = .{ .time = 0xffffff00, .button = BTN_LEFT, .kind = .dock, .tile = 1, .valid = true };
    try std.testing.expect(isDoubleClick(wrapped, 0x50, BTN_LEFT, .dock, 1));
    try std.testing.expect(!isDoubleClick(wrapped, 0x100, BTN_LEFT, .dock, 1));
}

test "validAppId and guessCommand: only plain program names become entries" {
    try std.testing.expect(validAppId("firefox"));
    try std.testing.expect(validAppId("org.mozilla.firefox"));
    try std.testing.expect(validAppId("my-app_2+"));
    try std.testing.expect(!validAppId(""));
    try std.testing.expect(!validAppId("has space"));
    try std.testing.expect(!validAppId("a\"b"));
    try std.testing.expect(!validAppId("../evil"));
    try std.testing.expect(!validAppId("-rf"));
    try std.testing.expect(!validAppId(".hidden"));
    try std.testing.expect(!validAppId("x" ** 101));

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("firefox", guessCommand(&buf, "org.mozilla.firefox").?);
    try std.testing.expectEqualStrings("alacritty", guessCommand(&buf, "Alacritty").?);
    try std.testing.expectEqualStrings("foot", guessCommand(&buf, "foot").?);
    try std.testing.expectEqualStrings("trailing.", guessCommand(&buf, "trailing.").?);
}

test "buildBarMenu: the logo's menu has Dock position (current one marked), Keep Application, Info" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    f.ui.dock_level = .auto;

    const top = try f.ui.buildBarMenu(.dock, null);
    const lvl = f.ui.levels.items[top];
    try std.testing.expectEqualStrings("Dock", lvl.title);
    try std.testing.expectEqual(@as(usize, 4), lvl.rows.len);
    try std.testing.expectEqualStrings("Dock position", lvl.rows[0].label);
    // No window of an unknown program: Keep Application is shown, greyed out.
    try std.testing.expectEqualStrings("Keep Application", lvl.rows[1].label);
    try std.testing.expect(!lvl.rows[1].enabled);
    try std.testing.expectEqualStrings("Add a drawer", lvl.rows[2].label);
    try std.testing.expectEqualStrings("Info Panel", lvl.rows[3].label);

    const pos = f.ui.levels.items[lvl.rows[0].kind.submenu];
    try std.testing.expectEqual(@as(usize, 3), pos.rows.len);
    try std.testing.expect(std.mem.endsWith(u8, pos.rows[0].label, "Normal"));
    try std.testing.expect(std.mem.endsWith(u8, pos.rows[1].label, "Auto raise & lower"));
    try std.testing.expect(std.mem.endsWith(u8, pos.rows[2].label, "Keep on Top"));
    try std.testing.expect(std.mem.startsWith(u8, pos.rows[1].label, "\u{2022}"));
    try std.testing.expect(!std.mem.startsWith(u8, pos.rows[0].label, "\u{2022}"));
    try std.testing.expectEqual(dock_mod.Level.top, pos.rows[2].kind.ui_cmd.set_dock_level);
}

test "buildBarMenu: Keep Application lists programs that have a window but no tile" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    _ = try f.addWindow("foot"); // "term" starts foot: already has a tile
    _ = try f.addWindow("org.gnome.Nautilus");
    _ = try f.addWindow("org.gnome.Nautilus"); // twice: listed once
    _ = try f.addWindow("dockapp:clock"); // a DockApp is never offered
    _ = try f.addWindow("bad id"); // not a plain name

    const top = try f.ui.buildBarMenu(.dock, null);
    const keep = f.ui.levels.items[f.ui.levels.items[top].rows[1].kind.submenu];
    try std.testing.expectEqual(@as(usize, 1), keep.rows.len);
    try std.testing.expectEqualStrings("org.gnome.Nautilus", keep.rows[0].label);
    const k = keep.rows[0].kind.ui_cmd.keep;
    try std.testing.expectEqualStrings("org.gnome.Nautilus", k.app_id);
    try std.testing.expect(!k.clip);
}

test "buildBarMenu: an application tile gets Window Maker's entries, enabled by what runs" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();

    // Not running: only Launch, Lock and Remove Icon do anything.
    const top = try f.ui.buildBarMenu(.dock, .{ .index = 0 });
    const lvl = f.ui.levels.items[top];
    try std.testing.expectEqualStrings("term", lvl.title);
    var buf: [16][]const u8 = undefined;
    const labels = rowLabels(lvl, &buf);
    const want = [_][]const u8{ "Launch", "Bring Here", "Hide", "Lock", "Remove Icon", "Kill" };
    try std.testing.expectEqual(want.len, labels.len);
    for (want, labels) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expect(lvl.rows[0].enabled);
    try std.testing.expect(!lvl.rows[1].enabled);
    try std.testing.expect(!lvl.rows[2].enabled);
    try std.testing.expect(lvl.rows[4].enabled);
    try std.testing.expect(!lvl.rows[5].enabled);
    try std.testing.expect(lvl.rows[0].kind.ui_cmd.launch.index == 0);

    // Running: Bring Here / Hide / Kill come alive.
    f.ui.resetMenu();
    const w = try f.addWindow("foot");
    const t2 = f.ui.levels.items[try f.ui.buildBarMenu(.dock, .{ .index = 0 })];
    try std.testing.expect(t2.rows[1].enabled and t2.rows[2].enabled and t2.rows[5].enabled);
    try std.testing.expectEqualStrings("Hide", t2.rows[2].label);
    try std.testing.expectEqual(AppOp.hide, t2.rows[2].kind.ui_cmd.app_op.op);

    // All of its windows minimized: the labels turn around.
    f.ui.resetMenu();
    w.minimized = true;
    const t3 = f.ui.levels.items[try f.ui.buildBarMenu(.dock, .{ .index = 0 })];
    try std.testing.expectEqualStrings("Unhide Here", t3.rows[1].label);
    try std.testing.expectEqualStrings("Unhide", t3.rows[2].label);
    try std.testing.expectEqual(AppOp.unhide, t3.rows[2].kind.ui_cmd.app_op.op);

    // A locked tile cannot be removed.
    f.ui.resetMenu();
    f.ui.model.?.slots.items[0].app.locked = true;
    const t4 = f.ui.levels.items[try f.ui.buildBarMenu(.dock, .{ .index = 0 })];
    try std.testing.expectEqualStrings("Unlock", t4.rows[3].label);
    try std.testing.expect(!t4.rows[4].enabled);

    // A stale slot (the list was rebuilt while the menu was being asked for)
    // is just not offered: the logo menu comes instead.
    f.ui.resetMenu();
    const t5 = try f.ui.buildBarMenu(.dock, .{ .index = 99 });
    try std.testing.expectEqualStrings("Dock", f.ui.levels.items[t5].title);
}

test "buildBarMenu: Clip menus, Clip Options with marks and Move Icon To" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    f.ui.clip_collapsed = true;
    f.ui.clip_on_top = false;

    const top = f.ui.levels.items[try f.ui.buildBarMenu(.clip, null)];
    try std.testing.expectEqualStrings("Clip", top.title);
    try std.testing.expectEqualStrings("Clip Options", top.rows[0].label);
    const opts = f.ui.levels.items[top.rows[0].kind.submenu];
    try std.testing.expectEqual(@as(usize, 4), opts.rows.len);
    try std.testing.expect(std.mem.endsWith(u8, opts.rows[0].label, "Keep on Top"));
    try std.testing.expect(!std.mem.startsWith(u8, opts.rows[0].label, "\u{2022}"));
    try std.testing.expect(std.mem.endsWith(u8, opts.rows[1].label, "Collapsed"));
    try std.testing.expect(std.mem.startsWith(u8, opts.rows[1].label, "\u{2022}"));
    try std.testing.expect(std.mem.endsWith(u8, opts.rows[2].label, "Autocollapse"));
    try std.testing.expect(std.mem.endsWith(u8, opts.rows[3].label, "Autoraise"));

    // A Clip tile: Move Icon To lists "All workspaces" and the workspaces.
    f.ui.resetMenu();
    const tile_menu = f.ui.levels.items[try f.ui.buildBarMenu(.clip, .{ .index = 1 })];
    try std.testing.expectEqualStrings("notes", tile_menu.title);
    try std.testing.expectEqualStrings("Move Icon To", tile_menu.rows[3].label);
    const mv = f.ui.levels.items[tile_menu.rows[3].kind.submenu];
    try std.testing.expectEqual(@as(usize, 1 + 4), mv.rows.len);
    try std.testing.expect(std.mem.endsWith(u8, mv.rows[0].label, "All workspaces"));
    try std.testing.expect(std.mem.startsWith(u8, mv.rows[1].label, "\u{2022}")); // "notes" is on workspace 1
    try std.testing.expectEqual(@as(?u32, 2), mv.rows[3].kind.ui_cmd.set_workspace.ws);
}

test "runUiCmd flips the run-time switches and edits the model" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    const ui = &f.ui;

    try std.testing.expectEqual(dock_mod.Level.top, ui.dock_level);
    ui.runUiCmd(.{ .set_dock_level = .auto });
    try std.testing.expectEqual(dock_mod.Level.auto, ui.dock_level);
    ui.runUiCmd(.{ .set_dock_level = .normal });
    try std.testing.expectEqual(dock_mod.Level.normal, ui.dock_level);

    ui.runUiCmd(.toggle_clip_level);
    try std.testing.expect(!ui.clip_on_top);
    ui.runUiCmd(.toggle_clip_collapse);
    try std.testing.expect(ui.clip_collapsed);
    ui.runUiCmd(.toggle_clip_auto_collapse);
    ui.runUiCmd(.toggle_clip_auto_raise);
    try std.testing.expect(ui.clip_auto_collapse and ui.clip_auto_raise);

    // Lock and unlock a tile; a locked one is not removed.
    ui.runUiCmd(.{ .toggle_lock = .{ .index = 0 } });
    try std.testing.expect(ui.model.?.slots.items[0].app.locked);
    ui.runUiCmd(.{ .remove = .{ .index = 0 } });
    try std.testing.expect(ui.model.?.slot(0) != null);
    ui.runUiCmd(.{ .toggle_lock = .{ .index = 0 } });
    ui.runUiCmd(.{ .remove = .{ .index = 0 } });
    try std.testing.expect(ui.model.?.slot(0) == null);

    // Move a Clip entry to another workspace and to "all".
    ui.runUiCmd(.{ .set_workspace = .{ .ref = .{ .index = 1 }, .ws = 3 } });
    try std.testing.expectEqual(@as(?u32, 3), ui.model.?.slots.items[1].app.workspace);
    try std.testing.expect(ui.model.?.slots.items[1].gi.dock.? == ui.model.?.scr.clips.items[3]);
    ui.runUiCmd(.{ .set_workspace = .{ .ref = .{ .index = 1 }, .ws = null } });
    try std.testing.expectEqual(@as(?u32, null), ui.model.?.slots.items[1].app.workspace);
    try std.testing.expect(ui.model.?.slots.items[1].gi.omnipresent);

    // Keep Application makes an entry that matches its windows; twice and
    // odd names do nothing.
    ui.runUiCmd(.{ .keep = .{ .app_id = "org.gnome.Nautilus", .clip = false } });
    try std.testing.expectEqual(@as(usize, 4), ui.model.?.slots.items.len);
    const kept = ui.model.?.slots.items[3].app;
    try std.testing.expectEqualStrings("nautilus", kept.command[0]);
    try std.testing.expect(kept.matches("org.gnome.Nautilus"));
    ui.runUiCmd(.{ .keep = .{ .app_id = "org.gnome.Nautilus", .clip = false } });
    ui.runUiCmd(.{ .keep = .{ .app_id = "bad id", .clip = true } });
    try std.testing.expectEqual(@as(usize, 4), ui.model.?.slots.items.len);
    // On the Clip it lands on the workspace shown.
    ui.runUiCmd(.{ .keep = .{ .app_id = "foot2", .clip = true } });
    try std.testing.expectEqual(@as(usize, 5), ui.model.?.slots.items.len);
    const on_clip = ui.model.?.slots.items[4].app;
    try std.testing.expect(on_clip.place == .clip);
    try std.testing.expectEqual(@as(?u32, 0), on_clip.workspace);
}

test "runUiCmd: drawers are added, switched and removed" {
    const f = try Fx.create(&.{});
    defer f.destroy();
    const ui = &f.ui;
    const m = &ui.model.?;
    m.layout(1920, 1080, true, 0, .top_left);

    ui.runUiCmd(.add_drawer);
    try std.testing.expectEqual(@as(usize, 1), m.scr.drawers.items.len);
    const d = m.scr.drawers.items[0];
    try std.testing.expect(d.collapsed and d.auto_collapse);
    ui.runUiCmd(.{ .toggle_drawer_collapse = 0 });
    try std.testing.expect(!d.collapsed);
    ui.runUiCmd(.{ .toggle_drawer_auto_collapse = 0 });
    try std.testing.expect(!d.auto_collapse);
    // The menu of its tile.
    const lvl = f.ui.levels.items[try f.ui.buildBarMenu(.drawer, .{ .index = 0 })];
    try std.testing.expectEqualStrings("Drawer", lvl.title);
    try std.testing.expectEqual(@as(usize, 3), lvl.rows.len);
    ui.runUiCmd(.{ .remove_drawer = 0 });
    try std.testing.expectEqual(@as(usize, 0), m.scr.drawers.items.len);
    // A stale index does nothing.
    ui.runUiCmd(.{ .remove_drawer = 7 });
}

test "runUiCmd app_op only records a request for sync() to run" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    f.ui.runUiCmd(.{ .app_op = .{ .op = .kill, .ref = .{ .index = 0 } } });
    try std.testing.expectEqual(AppOp.kill, f.ui.app_request.?.op);
}

test "raised(): top always, auto while hovered, normal after a click, a drag lifts any" {
    const f = try Fx.create(&.{});
    defer f.destroy();
    const ui = &f.ui;
    var gi: wdock.Icon = .{};

    ui.dock_level = .top;
    try std.testing.expect(ui.raised(.dock));
    ui.dock_level = .normal;
    try std.testing.expect(!ui.raised(.dock));
    ui.dock_clicked = true;
    try std.testing.expect(ui.raised(.dock));
    ui.dock_clicked = false;
    ui.dock_level = .auto;
    try std.testing.expect(!ui.raised(.dock));
    ui.dock.hover = &gi;
    try std.testing.expect(ui.raised(.dock));
    ui.dock.hover = null;
    ui.dock_level = .normal;
    ui.dock.drag = .{ .icon = &gi, .x = 0, .y = 0 };
    try std.testing.expect(ui.raised(.dock));
    ui.dock.drag = null;

    ui.clip_on_top = false;
    try std.testing.expect(!ui.raised(.clip));
    ui.clip_auto_raise = true;
    ui.clip.hover = &gi;
    try std.testing.expect(ui.raised(.clip));
    ui.clip.hover = null;
    ui.clip_clicked = true;
    try std.testing.expect(ui.raised(.clip));

    // A Drawer follows the Dock.
    var db: Bar = .{ .kind = .drawer };
    ui.dock_level = .top;
    try std.testing.expect(ui.raisedBar(&db));
    ui.dock_level = .normal;
    try std.testing.expect(!ui.raisedBar(&db));
}

/// A press on the tile `gi` of `bar`, `dx`/`dy` into the tile.
fn pressOn(bar: *Bar, kind: PressKind, gi: *wdock.Icon, slot: ?SlotRef, dx: i32, dy: i32) Press {
    const c = dock_mod.cellPx(bar.cells, gi.xindex, gi.yindex);
    return .{ .kind = kind, .bar = bar, .icon = gi, .slot = slot, .x = c[0] + dx, .y = c[1] + dy, .off_x = dx, .off_y = dy };
}

/// Move the pointer so that the dragged tile's top-left is at output-local
/// (tx, ty) (the pointer being `off_*` into it).
fn pointerFor(ui: *Ui, bar: *const Bar, p: Press, tx: i32, ty: i32) void {
    ui.px = tx + p.off_x - (bar.rect.x - 0);
    ui.py = ty + p.off_y - (bar.rect.y - 0);
}

test "dragging a Dock tile: it snaps to a free row, dropped nowhere it is taken away, a locked tile stays" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "a", .command = &.{"a"}, .y = 1 },
        .{ .name = "b", .command = &.{"b"}, .y = 2 },
        .{ .name = "c", .command = &.{"c"}, .y = 3, .locked = true },
    };
    const f = try Fx.create(&apps);
    defer f.destroy();
    const ui = &f.ui;
    const bar = f.dockBar();
    const m = &ui.model.?;
    const dock_x = m.scr.dock.?.x_pos;

    // Press "a", move a few pixels: below the threshold, no drag.
    const a = m.slots.items[0].gi;
    ui.press = pressOn(bar, .tile, a, .{ .index = 0 }, 30, 10);
    ui.px = ui.press.?.x + 2;
    ui.py = ui.press.?.y + 2;
    try std.testing.expect(!ui.dragUpdate(bar));
    try std.testing.expect(bar.drag == null);

    // To row 5, a free row (the gap rows 3-4 stay what they are): the drag
    // shows where it would land.
    pointerFor(ui, bar, ui.press.?, dock_x, 5 * 64 + 2);
    try std.testing.expect(ui.dragUpdate(bar));
    try std.testing.expect(!bar.drag.?.detached);
    try std.testing.expectEqual(@as(i32, 5), ui.drop_target.?.xy[1]);
    try std.testing.expect(ui.finishPress(BTN_LEFT));
    try std.testing.expect(ui.press == null and bar.drag == null and ui.drop_target == null);
    try std.testing.expectEqual(@as(i32, 5), a.yindex);

    // Take "b" far away from the Dock: it is removed.
    const b = m.slots.items[1].gi;
    ui.press = pressOn(bar, .tile, b, .{ .index = 1 }, 30, 10);
    pointerFor(ui, bar, ui.press.?, 300, 400);
    try std.testing.expect(ui.dragUpdate(bar));
    try std.testing.expect(bar.drag.?.detached);
    try std.testing.expect(ui.finishPress(BTN_LEFT));
    try std.testing.expect(m.slot(1) == null);

    // "c" is locked: pulling at it does nothing at all.
    const c = m.slots.items[2].gi;
    ui.press = pressOn(bar, .tile, c, .{ .index = 2 }, 30, 10);
    pointerFor(ui, bar, ui.press.?, 300, 400);
    try std.testing.expect(!ui.dragUpdate(bar));
    try std.testing.expect(ui.press == null);
    try std.testing.expect(m.slot(2) != null);

    // A release with nothing pressed (or another button) is not an event.
    try std.testing.expect(!ui.finishPress(BTN_LEFT));
    ui.press = pressOn(bar, .tile, c, null, 0, 0);
    try std.testing.expect(!ui.finishPress(BTN_RIGHT));
}

test "dragging the logo moves the Dock to the other edge and along it" {
    const f = try Fx.create(&.{});
    defer f.destroy();
    const ui = &f.ui;
    const bar = f.dockBar();
    try std.testing.expectEqual(config_mod.DockEdge.right, f.wm.cfg.dock_edge);

    // Press the logo 30 px into it, drag to global (100, 400).
    const logo = f.ui.model.?.scr.dock.?.icons[0].?;
    ui.press = pressOn(bar, .main_dock, logo, null, 30, 30);
    ui.px = 100 - bar.rect.x;
    ui.py = 400 - bar.rect.y;
    try std.testing.expect(ui.dragUpdate(bar));
    try std.testing.expectEqual(config_mod.DockEdge.left, f.wm.cfg.dock_edge);
    try std.testing.expectEqual(@as(i32, 370), f.wm.cfg.dock_offset);
    try std.testing.expect(bar.drag == null);
    try std.testing.expect(ui.finishPress(BTN_LEFT));
}

test "dragging the Clip's workspace tile picks the nearest corner" {
    const f = try Fx.create(&.{});
    defer f.destroy();
    const ui = &f.ui;
    const bar = f.clipBar();
    const tile0 = f.ui.model.?.currentClip().icons[0].?;
    ui.press = pressOn(bar, .main_clip, tile0, null, 30, 30);
    ui.px = 1800 - bar.rect.x;
    ui.py = 1000 - bar.rect.y;
    try std.testing.expect(ui.dragUpdate(bar));
    try std.testing.expectEqual(config_mod.ClipCorner.bottom_right, f.wm.cfg.clip_corner);
}

test "findDrop and dropping: Dock -> Clip -> Drawer, as handleDockMove tries the docks" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "a", .command = &.{"a"}, .y = 1 },
        .{ .name = "n", .command = &.{"n"}, .place = .clip, .workspace = 0, .x = 1 },
    };
    const f = try Fx.create(&apps);
    defer f.destroy();
    const ui = &f.ui;
    const m = &ui.model.?;
    m.layout(1920, 1080, true, 0, .top_left);
    const a = m.slots.items[0].gi;

    // Next to the Clip's neighbour: the tile snaps into the Clip.
    const t = ui.findDrop(m, a, 64, 64).?;
    try std.testing.expect(t.dock == m.currentClip());
    try std.testing.expectEqual([2]i32{ 1, 1 }, t.xy);
    try std.testing.expect(m.dropSlot(0, t.dock, t.xy));
    try std.testing.expect(m.slots.items[0].app.place == .clip);

    // Nowhere near anything: no target.
    try std.testing.expect(ui.findDrop(m, a, 900, 700) == null);

    // A Drawer on row 2 (row 1 is free again, but the first free row wins
    // from 1 upwards: the Dock has nothing on it now).
    const d = (try m.addDrawer("D")).?;
    d.collapsed = false;
    try std.testing.expectEqual(@as(i32, 64), d.y_pos);
    const into = ui.findDrop(m, a, m.scr.dock.?.x_pos - 64, d.y_pos + 2).?;
    try std.testing.expect(into.dock == d);
    try std.testing.expect(m.dropSlot(0, into.dock, into.xy));
    try std.testing.expect(m.slots.items[0].app.place == .drawer);
    try std.testing.expectEqual(@as(i32, -1), a.xindex);

    // Taking it from the Drawer into the Dock closes the Drawer's gap.
    const back = ui.findDrop(m, a, m.scr.dock.?.x_pos, 4 * 64).?;
    try std.testing.expect(back.dock == m.scr.dock.?);
    try std.testing.expect(m.dropSlot(0, back.dock, back.xy));
    try std.testing.expectEqual(@as(usize, 1), d.icon_count);
}

test "a click on a Drawer's tile opens and closes it; dragging it moves it to another row" {
    const f = try Fx.create(&.{});
    defer f.destroy();
    const ui = &f.ui;
    const m = &ui.model.?;
    m.layout(1920, 1080, true, 0, .top_left);
    const d = (try m.addDrawer("D")).?;
    try std.testing.expect(d.collapsed);
    const bar = f.bar(try ui.gpa().create(Bar), d, true);
    defer ui.gpa().destroy(bar);
    bar.kind = .drawer;

    const tile0 = d.icons[0].?;
    var pr = pressOn(bar, .main_drawer, tile0, null, 10, 10);
    pr.activate_on_release = true;
    ui.press = pr;
    try std.testing.expect(ui.finishPress(BTN_LEFT));
    try std.testing.expect(!d.collapsed);

    // Drag it two rows down.
    ui.press = pressOn(bar, .main_drawer, tile0, null, 10, 10);
    pointerFor(ui, bar, ui.press.?, d.x_pos, 3 * 64);
    try std.testing.expect(ui.dragUpdate(bar));
    try std.testing.expectEqual(@as(i32, 3 * 64), d.y_pos);
    // Not onto the logo's row.
    pointerFor(ui, bar, ui.press.?, d.x_pos, 4);
    _ = ui.dragUpdate(bar);
    try std.testing.expectEqual(@as(i32, 3 * 64), d.y_pos);
    try std.testing.expect(ui.finishPress(BTN_LEFT));
}

test "saveState writes the model and the switches, loadable again" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    const io = std.testing.io;
    const a = std.testing.allocator;

    const path = try std.fmt.allocPrint(a, "/tmp/wmaker-wl-ui-state-{d}/WMState", .{std.c.getpid()});
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, std.fs.path.dirname(path).?) catch {};

    f.wm.io = io;
    f.wm.dock_state_path = path;
    f.wm.cfg.dock_save_state = true;
    f.wm.cfg.dock_edge = .left;
    f.wm.cfg.dock_offset = 77;
    f.ui.dock_level = .auto;
    f.ui.clip_collapsed = true;
    f.ui.saveState();

    const text = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .limited(1 << 20));
    defer a.free(text);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const list = try dockapp.parseWMStateAll(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), list.apps.len);
    const st = list.state.?;
    try std.testing.expectEqual(config_mod.DockEdge.left, st.edge.?);
    try std.testing.expectEqual(@as(i32, 77), st.offset.?);
    try std.testing.expectEqual(false, st.dock_on_top.?);
    try std.testing.expectEqual(true, st.dock_auto_raise.?);
    try std.testing.expectEqual(true, st.clip_collapsed.?);

    // With Autocollapse the fold state is not remembered.
    f.ui.clip_auto_collapse = true;
    try std.testing.expect(f.ui.savedState().clip_collapsed == null);

    // Switched off: nothing is written.
    f.wm.cfg.dock_save_state = false;
    try std.Io.Dir.cwd().deleteFile(io, path);
    f.ui.saveState();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .limited(10)));
}

test "slotApp refuses indices past the end" {
    var wm: types.WindowManager = undefined;
    wm.cfg = .{ .arena = .init(std.testing.allocator) };
    defer wm.cfg.deinit();
    var ui = testUi(std.testing.allocator, &wm);
    defer ui.arena.deinit();

    try std.testing.expect(ui.slotApp(.{ .index = 0 }) == null);
    const apps = dockTestApps();
    ui.model = try dock_mod.Model.init(std.testing.allocator, .{ .apps = &apps }, &.{}, 4);
    defer ui.model.?.deinit();
    try std.testing.expectEqualStrings("term", ui.slotApp(.{ .index = 0 }).?.name);
    try std.testing.expect(ui.slotApp(.{ .index = 2 }) != null);
    try std.testing.expect(ui.slotApp(.{ .index = 3 }) == null);
}

test "the Dock tile of a minimized window asks for exactly that window" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    const first = try f.addWindow("foot");
    const second = try f.addWindow("foot"); // same program, minimized later
    first.minimized = true;
    first.min_order = 3;
    second.minimized = true;
    second.min_order = 4;
    const m = &f.ui.model.?;
    const t1 = try m.attachWindow("foot", "foot", 3);
    const t2 = try m.attachWindow("foot", "foot", 4);

    f.ui.activateSlot(.{ .index = t2 }, false);
    switch (f.wm.pending_ui.?) {
        .focus => |w| try std.testing.expect(w == second),
        else => return error.TestUnexpectedResult,
    }
    f.wm.pending_ui = null;
    f.ui.activateSlot(.{ .index = t1 }, true); // the middle button does the same
    switch (f.wm.pending_ui.?) {
        .focus => |w| try std.testing.expect(w == first),
        else => return error.TestUnexpectedResult,
    }
    f.wm.pending_ui = null;

    // The window came back by another way (key, menu): its tile does nothing
    // (and is removed by the next sync).
    first.minimized = false;
    f.ui.activateSlot(.{ .index = t1 }, false);
    try std.testing.expect(f.wm.pending_ui == null);
}

test "animation: a minimized window is noticed and flies to its Dock tile" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    f.wm.cfg.iconify_style = .zoom; // ends exactly on the tile (twist stops 3/16 short, like Window Maker)
    const w = try f.addWindow("foot");
    const other = try f.addWindow("other"); // minimized, but it was not on the screen
    w.anim_rect = .{ .x = 100, .y = 50, .w = 800, .h = 600 };
    w.minimized = true;
    w.min_order = 7;
    other.minimized = true;
    other.min_order = 8;
    _ = f.dockBar();
    _ = try f.ui.model.?.attachWindow("foot", "foot", 7);
    _ = f.dockBar();

    f.ui.animCollect();
    try std.testing.expectEqual(@as(usize, 1), f.ui.anim_req_n);
    try std.testing.expect(f.ui.anim_req[0].win == w and !f.ui.anim_req[0].restore);
    try std.testing.expectEqual(@as(i32, 100), f.ui.anim_req[0].from.x);

    f.ui.animLaunchAt(1000);
    try std.testing.expectEqual(@as(usize, 1), f.ui.anim_n);
    try std.testing.expectEqual(@as(usize, 0), f.ui.anim_req_n);
    try std.testing.expect(f.ui.anims[0].hold == null); // a minimized window is hidden anyway
    try std.testing.expectEqual(@as(u32, 1000), f.ui.anims[0].start_ms);

    // The last picture of the zoom is on the tile.
    const tile_box = f.ui.miniTileBox(7).?;
    const last = f.ui.anims[0].plan.frame(1000).boxes[6];
    try std.testing.expect(@abs(last[0] - tile_box.x) <= 1 and @abs(last[1] - tile_box.y) <= 1);
    try std.testing.expect(@abs(last[2] - tile_box.w) <= 1 and @abs(last[3] - tile_box.h) <= 1);

    // `none` starts nothing.
    f.ui.anim_n = 0;
    f.wm.cfg.iconify_style = .none;
    f.ui.animCollect();
    f.ui.animLaunchAt(2000);
    try std.testing.expectEqual(@as(usize, 0), f.ui.anim_n);
}

test "animation: a restored window starts on its Dock tile" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    const w = try f.addWindow("foot");
    w.anim_min = true; // it was minimized at the end of the last sequence
    w.minimized = false; // and is not now
    w.min_order = 7;
    _ = f.dockBar();
    _ = try f.ui.model.?.attachWindow("foot", "foot", 7);
    _ = f.dockBar();

    f.ui.animCollect();
    try std.testing.expectEqual(@as(usize, 1), f.ui.anim_req_n);
    try std.testing.expect(f.ui.anim_req[0].win == w and f.ui.anim_req[0].restore);
    const tile_box = f.ui.miniTileBox(7).?;
    try std.testing.expectEqual(tile_box, f.ui.anim_req[0].from);

    // It has no workspace on the screen here: nothing flies, nothing is held.
    f.ui.animLaunchAt(1000);
    try std.testing.expectEqual(@as(usize, 0), f.ui.anim_n);
    try std.testing.expect(!f.ui.animHolding(w));
}

test "animation: the tile of a restored window is gone after the Dock sync, so collecting must come first" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    const w = try f.addWindow("foot");
    w.anim_min = true; // minimized at the end of the last sequence
    w.minimized = false; // restored since
    w.min_order = 7;
    _ = f.dockBar();
    _ = try f.ui.model.?.attachWindow("foot", "foot", 7);
    _ = f.dockBar();

    // The order main.onManage keeps: collect, then sync the Dock.
    const tile_box = f.ui.miniTileBox(7).?;
    f.ui.animCollect();
    try std.testing.expectEqual(@as(usize, 1), f.ui.anim_req_n);
    try std.testing.expectEqual(tile_box, f.ui.anim_req[0].from);
    f.ui.anim_req_n = 0;

    // The sync removes the tile of a window that is not minimized any more...
    _ = dockhost.syncModel(f.ui.wm, &f.ui.model.?);
    try std.testing.expect(f.ui.miniTileBox(7) == null);
    // ...so collecting afterwards could no longer start the animation on it.
    f.ui.animCollect();
    try std.testing.expect(f.ui.anim_req_n == 0 or !std.meta.eql(f.ui.anim_req[0].from, tile_box));
}

test "animation: a window coming back is held until it is forgotten or the animation ends" {
    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    const w = try f.addWindow("foot");
    const from: anim.Box = .{ .x = 1856, .y = 64, .w = 64, .h = 64 };
    const to: anim.Box = .{ .x = 100, .y = 50, .w = 800, .h = 600 };
    f.ui.anims[0] = .{ .plan = anim.plan(.twist, from, to), .start_ms = 1000, .hold = w };
    f.ui.anim_n = 1;
    try std.testing.expect(f.ui.animHolding(w));

    // The event loop sleeps until the next picture is due.
    try std.testing.expectEqual(@as(?u32, 0), f.ui.animWaitMs(1000)); // picture 0 is not drawn yet
    f.ui.anims[0].drawn = 0;
    try std.testing.expectEqual(@as(?u32, 20), f.ui.animWaitMs(1000));
    try std.testing.expectEqual(@as(?u32, 15), f.ui.animWaitMs(1005));
    try std.testing.expectEqual(@as(?u32, 0), f.ui.animWaitMs(1020)); // picture 1 is due
    const over = 1000 + f.ui.anims[0].plan.durationMs() + 1;
    try std.testing.expectEqual(@as(?u32, 0), f.ui.animWaitMs(over)); // over: step() ends it

    // A window that dies while it flies is not held (nor pointed at) any more.
    f.ui.forgetWindow(w);
    try std.testing.expect(!f.ui.animHolding(w));
    f.ui.anim_n = 0;
    try std.testing.expectEqual(@as(?u32, null), f.ui.animWaitMs(1000));
}

test "animation: styles, window frame and what a sequence remembers" {
    try std.testing.expectEqual(@as(?anim.Style, .zoom), animStyle(.zoom, 5));
    try std.testing.expectEqual(@as(?anim.Style, .twist), animStyle(.twist, 5));
    try std.testing.expectEqual(@as(?anim.Style, .flip), animStyle(.flip, 5));
    try std.testing.expectEqual(@as(?anim.Style, null), animStyle(.none, 5));
    // random: all three turn up
    var seen = [_]bool{ false, false, false };
    for (0..3) |t| seen[@intFromEnum(animStyle(.random, @intCast(t)).?)] = true;
    try std.testing.expect(seen[0] and seen[1] and seen[2]);

    const apps = dockTestApps();
    const f = try Fx.create(&apps);
    defer f.destroy();
    const w = try f.addWindow("foot");
    w.target = .{ .x = 10, .y = 20, .w = 100, .h = 50 };
    const bw = w.borderWidth(&f.wm.cfg);
    const fb = frameBox(&f.wm, w);
    try std.testing.expectEqual(anim.Box{ .x = 10 - bw, .y = 20 - bw, .w = 100 + 2 * bw, .h = 50 + 2 * bw }, fb);

    // A window that is not shown (visible unknown) leaves no rectangle; a
    // minimized one is remembered as minimized.
    w.minimized = true;
    w.anim_rect = .{ .x = 1, .y = 1, .w = 5, .h = 5 };
    f.ui.animRemember();
    try std.testing.expect(w.anim_min);
    try std.testing.expectEqual(@as(i32, 0), w.anim_rect.w);
}

test "sync() builds the Dock before the desktops and the bars are restacked after the windows" {
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
    try std.testing.expect(std.mem.indexOf(u8, r_body, "applyRender").? < std.mem.indexOf(u8, r_body, "u.onRenderBars()").?);
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
    wm.cfg = .{ .arena = .init(gpa), .config_file = "/home/x/.config/wmaker-wl/config.lua" };
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
        if (std.mem.indexOf(u8, r.label, "config.lua") != null) has_config = true;
    }
    try std.testing.expect(has_version and has_config);

    const legal = ui.levels.items[try ui.buildTextLevel(.legal_panel)];
    try std.testing.expectEqualStrings("Legal", legal.title);
    var mentions_licence = false;
    for (legal.rows) |r| {
        if (std.mem.indexOf(u8, r.label, "GPL") != null) mentions_licence = true;
    }
    try std.testing.expect(mentions_licence);
}

test "timeDue and sooner: the wrapping millisecond clock" {
    try std.testing.expect(timeDue(100, 100));
    try std.testing.expect(timeDue(101, 100));
    try std.testing.expect(!timeDue(99, 100));
    // Across the wrap of the 32-bit clock.
    try std.testing.expect(timeDue(5, 0xffff_fff0));
    try std.testing.expect(!timeDue(0xffff_fff0, 5));

    var best: ?u32 = null;
    sooner(&best, 1000, null);
    try std.testing.expectEqual(@as(?u32, null), best);
    sooner(&best, 1000, 1700);
    try std.testing.expectEqual(@as(?u32, 700), best);
    sooner(&best, 1000, 1250);
    try std.testing.expectEqual(@as(?u32, 250), best);
    sooner(&best, 1000, 1900);
    try std.testing.expectEqual(@as(?u32, 250), best);
    sooner(&best, 1000, 900); // already due
    try std.testing.expectEqual(@as(?u32, 0), best);
}
