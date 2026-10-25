// SPDX-License-Identifier: GPL-3.0
//
// Data model.
//
//   WindowManager
//    ├─ outputs ─ Output
//    │            └─ workspaces[N] ─ Workspace
//    │                                ├─ strip    ─ Column ─ Window   (tiled)
//    │                                ├─ floating ─ Window ...        (z-ordered, top = last)
//    │                                └─ fullscreen: ?*Window
//    ├─ windows       (every normal window exactly once, regardless of state)
//    ├─ dock_windows  (every DockApp exactly once; see dockhost.zig)
//    └─ seats
//
// Invariants (enforced by the functions in workspace.zig, relied on
// everywhere else):
//
//   I1. Every live Window is in exactly one of `wm.windows` (role .normal)
//       and `wm.dock_windows` (role .dockapp). A DockApp is in no workspace,
//       no strip and no focus: nothing that loops over `wm.windows` can see it.
//   I2. A Window is a member of exactly one container:
//         .tiled      -> exactly one Column.windows of `win.workspace`
//         .floating   -> `win.workspace.floating`
//         .fullscreen -> the SAME container it had before (see `restore`);
//                        fullscreen is a display state layered on top, so
//                        the strip keeps its shape and leaving fullscreen
//                        needs no re-insertion. `workspace.fullscreen`
//                        points at it.
//   I3. `win.workspace == null`  <=>  the window is not placed anywhere.
//   I4. A Column is never empty (it is destroyed with its last window).
//   I5. A wl.list.Link that is not in a list has both pointers `null`
//       (the default below; `Link.remove()` also leaves this state).
//       `Link.remove()` DEREFERENCES prev/next, so calling it on an unlinked
//       link crashes. Always go through `unlink()`, which checks first. The
//       old code left links `undefined`, which was undefined behaviour.

const std = @import("std");
// `wayland` is only used for the intrusive list types (wl.list). Everything
// that belongs to the compositor comes from `backend`, see backend.zig.
const wayland = @import("wayland");
const config = @import("config.zig");
const animation = @import("animation.zig");
const wm_attr = @import("wm_attr.zig");
const wm_menu = @import("wm_menu.zig");
const dockapp = @import("dockapp.zig");
const monitors = @import("monitors.zig");
const backend = @import("backend.zig");
const wl = wayland.client.wl;

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }
    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.right() and py >= r.y and py < r.bottom();
    }
    /// Shrink on every side by `n` (never below 1x1).
    pub fn inset(r: Rect, n: i32) Rect {
        return .{
            .x = r.x + n,
            .y = r.y + n,
            .w = @max(1, r.w - 2 * n),
            .h = @max(1, r.h - 2 * n),
        };
    }
};

// ============================================================================
// Window
// ============================================================================

pub const Mode = enum { tiled, floating, fullscreen };

/// Where a fullscreen window returns to when it leaves fullscreen.
pub const Restore = enum { tiled, floating };

/// What a window is to the compositor. A DockApp (app_id `dockapp:<name>`) is
/// an icon, not a window: see dockhost.zig. Decided once by `dockhost.adopt`.
pub const Role = enum { normal, dockapp };

pub const Window = struct {
    obj: *backend.Window,
    node: *backend.Node,

    role: Role = .normal,

    /// Link in `wm.windows` (role .normal) or `wm.dock_windows` (.dockapp).
    link: wl.list.Link = .{ .prev = null, .next = null },

    // ---- identity ---------------------------------------------------------
    app_id: ?[]u8 = null,
    title: ?[]u8 = null,
    /// Set when the client declared a parent (dialog, file picker...).
    parent: ?*backend.Window = null,

    // ---- lifecycle --------------------------------------------------------
    /// Not yet placed on a workspace (the next manage pass places it).
    new: bool = true,
    /// The client has reported a size, i.e. has content. Informational only:
    /// a new window is configured BEFORE this is true, so nothing may wait on it.
    ready: bool = false,
    closed: bool = false,

    // ---- placement --------------------------------------------------------
    mode: Mode = .tiled,
    workspace: ?*Workspace = null,

    /// Link in Column.windows while tiled.
    column: ?*Column = null,
    column_link: wl.list.Link = .{ .prev = null, .next = null },

    /// Link in Workspace.floating while floating.
    floating_link: wl.list.Link = .{ .prev = null, .next = null },

    /// Fullscreen bookkeeping.
    restore: Restore = .tiled,

    /// Window Maker "Omnipresent": follows the user to every workspace.
    /// Only meaningful while floating (see isOmnipresent).
    sticky: bool = false,

    /// Window Maker attributes for this window's app_id (WMWindowAttributes).
    /// Refreshed whenever app_id/dimensions_hint/parent arrive. StartWorkspace
    /// is decided once, when the window is first placed. Floating/Omnipresent
    /// are re-checked on every such refresh too (window.zig's
    /// recheckFloating), so a DockApp whose app_id or fixed-size hint shows
    /// up only after that first placement still ends up floating instead of
    /// stuck tiled with a full border.
    attrs: wm_attr.Attributes = .{},

    // ---- geometry ---------------------------------------------------------
    /// Floating geometry, in output-local coordinates (relative to the
    /// output's top-left). Remembered across tiled<->floating toggles.
    float_rect: Rect = .{},
    has_float_rect: bool = false,
    /// Minimized (Window Maker "miniaturized" / "hidden"): taken out of the
    /// layout entirely -- so `workspace == null` like any unplaced window --
    /// and hidden. It is brought back to the CURRENT workspace by `restore`
    /// (workspace.zig), or from the Windows menu / a Dock tile.
    minimized: bool = false,
    /// Where it came from, for putting it back the same way.
    min_floating: bool = false,
    /// Counts up: the highest is the one `restore` brings back first.
    min_order: u64 = 0,
    /// What the last manage sequence ended with, so the next one can see
    /// that the window was minimized or restored (ui.zig `animCollect`):
    /// `minimized` as it was, and the window's frame on screen (w == 0:
    /// it was not shown).
    anim_min: bool = false,
    anim_rect: Rect = .{},

    /// Content rect (borders excluded) currently *wanted* on screen in
    /// global coordinates. Computed by layout every pass.
    target: Rect = .{},
    /// Content size the client last reported.
    actual_w: i32 = 0,
    actual_h: i32 = 0,
    /// Client's size hints (0 = no preference).
    min_w: i32 = 0,
    min_h: i32 = 0,
    max_w: i32 = 0,
    max_h: i32 = 0,

    // ---- what we last told the client (so we only send changes) ------------------
    sent_w: i32 = -1,
    sent_h: i32 = -1,
    sent_tiled: ?bool = null,
    sent_border: ?BorderKind = null,
    sent_x: i32 = std.math.minInt(i32),
    sent_y: i32 = std.math.minInt(i32),
    visible: ?bool = null,
    sent_fullscreen: ?*Output = null,
    /// Last clip box sent (window-relative; null = never sent / none).
    sent_clip: ?Rect = null,

    // ---- animation (window.zig: `visualState`) --------------------------------
    /// Where the window was drawn last. While it travels this is not `target`.
    shown_x: i32 = 0,
    shown_y: i32 = 0,
    /// `shown_*` hold a real position (false after being hidden, so a window
    /// that comes back does not fly in from where it was).
    has_shown: bool = false,
    /// The workspace `shown_*` belongs to; another one means a jump, not a move.
    anim_ws: ?*Workspace = null,
    /// Where the running movement is going (a different `target` restarts it).
    goal_x: i32 = 0,
    goal_y: i32 = 0,
    anim_x: ?animation.Animation = null,
    anim_y: ?animation.Animation = null,
    /// The window has been uncovered once (or the opening animation was off).
    opened: bool = false,
    /// 0 -> 1 while a new window is uncovered.
    open_anim: ?animation.Animation = null,

    /// Column the window was in before it was "consumed"/detached, used
    /// only to restore floating -> tiled placement (see workspace.zig).
    saved_column_index: usize = 0,
    saved_column_width: i32 = 0,

    /// The monitor this window was taken off when that monitor went away, and
    /// the workspace it was on there. It goes back when the monitor returns
    /// (output.restoreHomes). A hash and an index, not a pointer: the
    /// monitor is gone. Cleared when the window is moved on purpose.
    home: monitors.Home = .{},

    pub fn isTiled(w: *const Window) bool {
        return w.mode == .tiled;
    }

    /// Shown on every workspace. A tiled window cannot be: it has a slot in
    /// exactly one strip.
    pub fn isOmnipresent(w: *const Window) bool {
        return w.sticky and w.mode == .floating;
    }

    /// Border width for this window (`NoBorder` removes it).
    pub fn borderWidth(w: *const Window, cfg: *const config.Config) i32 {
        return if (w.attrs.is("no_border")) 0 else cfg.border_width;
    }

    /// Height/width bounds honouring the client's hints.
    pub fn clampSize(w: *const Window, width: i32, height: i32, min_size: i32) struct { w: i32, h: i32 } {
        var cw = @max(width, @max(min_size, w.min_w));
        var ch = @max(height, @max(min_size, w.min_h));
        if (w.max_w > 0) cw = @min(cw, @max(w.max_w, w.min_w));
        if (w.max_h > 0) ch = @min(ch, @max(w.max_h, w.min_h));
        return .{ .w = @max(1, cw), .h = @max(1, ch) };
    }
};

pub const BorderKind = enum { focused, unfocused, floating, none };

// ============================================================================
// Column / Strip
// ============================================================================

pub const Column = struct {
    strip: *Strip,
    link: wl.list.Link = .{ .prev = null, .next = null },
    windows: wl.list.Head(Window, .column_link),

    /// Width in pixels of the *outer* box (borders included).
    width: i32,
    /// Left edge in strip coordinates; assigned by layout.
    x: i32 = 0,
    /// Window that has (or last had) focus within this column.
    focused: ?*Window = null,
    /// Remembered width before "maximize_column", 0 if not maximised.
    unmaximized_width: i32 = 0,

    pub fn first(c: *Column) ?*Window {
        return c.windows.first();
    }

    pub fn count(c: *Column) usize {
        var n: usize = 0;
        var it = c.windows.first();
        while (it) |w| : (it = nextWin(w)) n += 1;
        return n;
    }

    pub fn active(c: *Column) ?*Window {
        return c.focused orelse c.windows.first();
    }

    /// `maximize_column` is on: the column fills the work area and remembers
    /// the width it had before.
    pub fn isMaximized(c: *const Column) bool {
        return c.unmaximized_width != 0;
    }
};

pub const Strip = struct {
    workspace: *Workspace,
    columns: wl.list.Head(Column, .link),
    active: ?*Column = null,
    /// Strip coordinate of the viewport's left edge.
    scroll_x: i32 = 0,
    /// Extra shift to the right, set by layout when `center_single_column`
    /// centres a lone column. 0 otherwise.
    offset_x: i32 = 0,
    /// Work area width the column widths were last fitted to (0 = never);
    /// layout rescales the columns when it changes (Dock appears, a bar
    /// reserves space, ...).
    work_w: i32 = 0,

    pub fn columnCount(s: *Strip) usize {
        var n: usize = 0;
        var it = s.columns.first();
        while (it) |c| : (it = nextCol(c)) n += 1;
        return n;
    }

    pub fn activeWindow(s: *Strip) ?*Window {
        const c = s.active orelse return null;
        return c.active();
    }
};

// ============================================================================
// Workspace / Output
// ============================================================================

pub const Workspace = struct {
    output: *Output,
    index: u32,
    strip: Strip,
    /// Bottom -> top. New/raised floating windows are appended.
    floating: wl.list.Head(Window, .floating_link),
    fullscreen: ?*Window = null,

    /// Which layer has keyboard focus intent: tiled strip or floating.
    /// `focus_toggle_floating` flips this.
    last_focused: ?*Window = null,

    pub fn init(ws: *Workspace, output: *Output, index: u32) void {
        ws.* = .{
            .output = output,
            .index = index,
            .strip = .{ .workspace = ws, .columns = undefined },
            .floating = undefined,
        };
        ws.strip.columns.init();
        ws.floating.init();
    }

    pub fn isEmpty(ws: *Workspace) bool {
        return ws.strip.columns.empty() and ws.floating.empty() and ws.fullscreen == null;
    }
};

pub const Output = struct {
    obj: *backend.Output,
    link: wl.list.Link = .{ .prev = null, .next = null },
    removed: bool = false,

    // ---- which monitor this is (monitors.zig) ------------------------------
    /// Name, make and model, from the `wl_output` (output.zig). Empty until it
    /// has been seen; `mon.key()` is the identity used to find its rule and
    /// to give windows back after a reconnect.
    mon: monitors.Info = .{},
    /// A `monitor()` rule switched it off: it is ignored like a screen that is
    /// not there (see `liveOutput`), but stays known.
    disabled: bool = false,
    /// A `monitor()` rule made it the primary one (see `primaryOutput`).
    primary: bool = false,
    /// Its rule has been applied for this connection (output.settleOutput).
    settled: bool = false,

    /// Full output rectangle in global coordinates.
    rect: Rect = .{},
    /// Area not covered by layer-shell exclusive zones (bars, docks).
    usable: ?Rect = null,
    /// Space taken by wmaker-wl's own Dock (ui.zig keeps this current).
    /// Subtracted from the area windows may occupy, see `workArea`.
    reserved: Insets = .{},
    /// The user's `strut_*` options (main.layoutAll keeps them current).
    struts: Insets = .{},

    workspaces: [config.max_workspaces]Workspace = undefined,
    workspace_count: u32 = 0,
    active: u32 = 0,
    /// The workspace that was shown before `active` (`workspace_last`,
    /// `workspace_back_and_forth`); null until the first switch.
    prev_active: ?u32 = null,

    pub fn ws(o: *Output) *Workspace {
        return &o.workspaces[o.active];
    }

    pub fn ready(o: *const Output) bool {
        return o.rect.w > 0 and o.rect.h > 0;
    }

    /// Rectangle windows may occupy: the area left by layer-shell bars,
    /// minus whatever our own Dock reserves.
    pub fn workArea(o: *const Output) Rect {
        const base = o.usable orelse o.rect;
        const r = o.reserved;
        const st = o.struts;
        return .{
            .x = base.x + r.left + st.left,
            .y = base.y + r.top + st.top,
            .w = @max(1, base.w - r.left - r.right - st.left - st.right),
            .h = @max(1, base.h - r.top - r.bottom - st.top - st.bottom),
        };
    }

    pub const Insets = struct {
        left: i32 = 0,
        right: i32 = 0,
        top: i32 = 0,
        bottom: i32 = 0,
    };
};

// ============================================================================
// Seat & pointer operations
// ============================================================================

pub const PointerOp = enum { none, move, resize };

/// Where the interactive pointer operation is (pointer_op.zig).
///
///   idle ──begin──▶ requested ──startPending──▶ running
///     ▲                │                            │
///     │                │ button up before start     │ button up (or the window died)
///     │                ▼                            ▼
///     └──────── (cancelled)                      ending ──finish──▶ idle
///
/// `requested`: the binding press was seen; the next manage pass starts it.
/// `running`: motion only changes `op_dx`/`op_dy`. Pointer input is NOT
///   delivered to clients.
/// `ending`: the button went up (or the window died); the pass that sees it
///   applies the last delta and finishes the operation.
pub const OpState = enum { idle, requested, running, ending };

pub const Seat = struct {
    obj: *backend.Seat,
    link: wl.list.Link = .{ .prev = null, .next = null },
    removed: bool = false,

    /// Keyboard focus as we last set it.
    focused: ?*Window = null,
    /// Focus before `focused` (for focus_previous).
    previous: ?*Window = null,
    /// Window under the pointer.
    hovered: ?*Window = null,

    // ---- interactive pointer operation (see OpState) -------------------------
    op: PointerOp = .none,
    op_state: OpState = .idle,
    op_window: ?*Window = null,
    /// A binding's button is currently held; used to cancel a `requested`
    /// operation whose button was released before the manage sequence.
    op_button_down: bool = false,
    /// Cumulative pointer delta since the op started.
    op_dx: i32 = 0,
    op_dy: i32 = 0,
    /// Window geometry captured at op start (output-local floating rect).
    op_start_rect: Rect = .{},
    /// A tiled window being dragged has not detached yet.
    op_detached: bool = false,
    /// Which edges a resize moves (from the pointer position at start).
    op_resize_left: bool = false,
    op_resize_top: bool = false,
    /// Latest known pointer position (global), for edge selection.
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
};

// ============================================================================
// Window manager root
// ============================================================================

pub const WindowManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,

    obj: *backend.WindowManager,
    obj_version: u32,

    pending_ui: ?UiAction = null,

    /// Source of `Window.min_order`.
    min_counter: u64 = 0,

    /// The output the user is working on. Set whenever focus lands on a
    /// window (that window's output) and by focus_output_next/prev, which
    /// is what lets an EMPTY output be chosen. null until the first focus.
    active_output: ?*Output = null,

    outputs: wl.list.Head(Output, .link),
    /// External-monitor handling: rules, profiles, hot-plug settling.
    monitors: monitors.Manager = .{},
    windows: wl.list.Head(Window, .link),
    /// The DockApps (role .dockapp), owned by dockhost.zig.
    dock_windows: wl.list.Head(Window, .link),
    seats: wl.list.Head(Seat, .link),

    /// Parsed key binding commands; XkbBinding.command indexes this.
    commands: []const Command = &.{},

    /// Window Maker per-application rules (WMWindowAttributes).
    attrs: wm_attr.Table = .{},
    /// The root menu (Window Maker WMRootMenu / wlmaker RootMenu.plist).
    root_menu: ?*const wm_menu.Menu = null,
    /// Dock and Clip contents (WMState), owned by cfg's
    /// arena exactly like `root_menu`. ui.zig deep-copies what it needs,
    /// and rebuilds when `dock_gen` changes (every (re)load bumps it).
    dockapps: dockapp.List = .{},
    dock_gen: u32 = 0,
    /// Where the Dock saves what the user changed (null: not saved). Owned
    /// by cfg's arena like `dockapps`.
    dock_state_path: ?[]const u8 = null,

    /// Actions queued by key presses. `pressed` fires *outside* a manage
    /// sequence, but almost every request an action needs is only legal
    /// *inside* one, so `pressed` only queues and manage_start executes.
    pending: std.ArrayList(Command) = .empty,

    /// Window that should get keyboard focus at the end of this manage pass.
    focus_request: ?*Window = null,
    /// The active column changed; scroll it into view during layout.
    follow_request: bool = false,
    /// Client asked to enter/leave fullscreen (executed in manage).
    pending_fullscreen: ?struct { win: *Window, on: bool } = null,

    quit: bool = false,

    /// Time of the animations (animation.zig), read once per manage / render
    /// sequence by `window.tickClock`.
    clock: animation.Clock = .{},
    /// Something is still moving: the event loop asks for a new manage
    /// sequence every frame until nothing is.
    anim_active: bool = false,
    /// Real time (ms) at which the next frame may be requested.
    anim_frame_at: u64 = 0,

    /// The `reload_config` command asked for a config reload. Executed in the
    /// same manage sequence, after the queued actions (main.onManage): a
    /// reload destroys and re-creates the key bindings, which is only legal
    /// there, and must not run while the action queue is being worked off.
    reload_pending: bool = false,
    /// The focus request of this pass came from the pointer (click, hover),
    /// not from the keyboard: `warp_mouse_to_focus` must not move the pointer
    /// then. Cleared at the end of every manage pass.
    focus_by_pointer: bool = false,
};

// ============================================================================
// Commands (what a key binding does)
// ============================================================================

pub const Command = union(enum) {
    none,
    spawn: []const []const u8,
    /// Run through `/bin/sh -c`, exactly like the root menu's `SHEXEC` and
    /// the autostart script. Lets a bind use pipes, `&&`, `~`/`$HOME`
    /// expansion, backgrounding with `&`, or any other shell syntax --
    /// effectively "run any program" from a key combo.
    shell: []const u8,
    /// A Lua function of config.lua, bound with `bind("Super+x", function() ... end)`.
    /// The number is its reference in the config's Lua state, see config.callLua.
    lua: i32,
    close,
    exit,
    toggle_floating,
    toggle_fullscreen,
    maximize_column,

    focus_left,
    focus_right,
    focus_up,
    focus_down,
    focus_first_column,
    focus_last_column,
    focus_previous,
    focus_toggle_floating,

    move_column_left,
    move_column_right,
    move_column_first,
    move_column_last,
    move_window_up,
    move_window_down,
    consume_left,
    expel_right,

    scroll_left,
    scroll_right,
    center_column,

    cycle_column_width,
    widen_column,
    narrow_column,
    /// The active column takes this fraction of the
    /// work area (`set_column_width 0.5` or `set_column_width 50%`).
    set_column_width: f64,

    float_move: struct { dx: i32, dy: i32 },
    float_resize: struct { dw: i32, dh: i32 },

    workspace: u32,
    workspace_next,
    workspace_prev,
    /// Back to the workspace that was shown before this one.
    workspace_last,
    /// Modular workspaces: append a new workspace / delete the last one (its
    /// windows move to the one before it), like Window Maker's "New" and
    /// "Destroy Last" in the workspace menu.
    workspace_add,
    workspace_remove_last,
    move_to_workspace: u32,
    move_to_workspace_next,
    move_to_workspace_prev,
    /// The neighbouring window in the
    /// column, or at its end the previous / next workspace.
    focus_window_or_workspace_up,
    focus_window_or_workspace_down,
    /// The neighbouring column, or
    /// at the edge of the strip the previous / next output.
    focus_column_or_output_left,
    focus_column_or_output_right,

    /// Re-read config.lua now (what `pkill -HUP wmaker-wl` does).
    reload_config,

    /// Window Maker's miniaturize / hide. See workspace.minimize.
    minimize,
    /// Bring back the window minimized last (onto the current workspace).
    restore,
    /// Window Maker's SHOW_ALL: bring back every minimized window.
    show_all,
    /// Window Maker's HIDE_OTHERS: minimize every other application.
    hide_others,
    /// Window Maker's HIDE: minimize every window of the focused application.
    hide_app,
    /// Turn the Dock tiles of minimized windows on / off (`mini_dock`).
    toggle_mini_dock,

    /// Make the next / previous output the one the user works on (focus goes
    /// to the window that was active there; an empty output is fine).
    focus_output_next,
    focus_output_prev,
    /// Move the focused window to the next / previous output.
    move_to_output_next,
    move_to_output_prev,
};

/// What a root-menu click asks for. Executed in manage (focus and
/// workspace changes are management state).
pub const UiAction = union(enum) {
    /// Focus `win`; a minimized one is brought back first.
    focus: *Window,
    show_all,
    hide_others,
    /// Window Maker's SHUTDOWN: ask every window to close, then leave.
    shutdown,
    workspace: u32,
    workspace_next,
    workspace_prev,
};
// ============================================================================
// Safe intrusive-list helpers
// ============================================================================

pub fn isLinked(link: *const wl.list.Link) bool {
    return link.next != null;
}

/// Remove `link` from whatever list it is in; a no-op if it is in none.
pub fn unlink(link: *wl.list.Link) void {
    if (isLinked(link)) link.remove();
}

// ============================================================================
// List navigation. wl.list is intrusive and circular with the head as
// sentinel, so "next" must stop when it hits the head.
// ============================================================================

pub fn nextCol(c: *Column) ?*Column {
    const n = c.link.next orelse return null;
    if (n == &c.strip.columns.link) return null;
    return @fieldParentPtr("link", n);
}

pub fn prevCol(c: *Column) ?*Column {
    const p = c.link.prev orelse return null;
    if (p == &c.strip.columns.link) return null;
    return @fieldParentPtr("link", p);
}

pub fn nextWin(w: *Window) ?*Window {
    const col = w.column orelse return null;
    const n = w.column_link.next orelse return null;
    if (n == &col.windows.link) return null;
    return @fieldParentPtr("column_link", n);
}

pub fn prevWin(w: *Window) ?*Window {
    const col = w.column orelse return null;
    const p = w.column_link.prev orelse return null;
    if (p == &col.windows.link) return null;
    return @fieldParentPtr("column_link", p);
}

pub fn nextFloating(w: *Window) ?*Window {
    const ws = w.workspace orelse return null;
    const n = w.floating_link.next orelse return null;
    if (n == &ws.floating.link) return null;
    return @fieldParentPtr("floating_link", n);
}

pub fn prevFloating(w: *Window) ?*Window {
    const ws = w.workspace orelse return null;
    const p = w.floating_link.prev orelse return null;
    if (p == &ws.floating.link) return null;
    return @fieldParentPtr("floating_link", p);
}

pub fn nextWindow(w: *Window, wm: *WindowManager) ?*Window {
    const n = w.link.next orelse return null;
    if (n == &wm.windows.link) return null;
    return @fieldParentPtr("link", n);
}

pub fn nextDockWindow(w: *Window, wm: *WindowManager) ?*Window {
    const n = w.link.next orelse return null;
    if (n == &wm.dock_windows.link) return null;
    return @fieldParentPtr("link", n);
}

/// An output windows can be put on: there, sized, and not switched off by a
/// `monitor()` rule.
pub fn liveOutput(o: *const Output) bool {
    return !o.removed and !o.disabled and o.ready();
}

/// The output the user is working on: `wm.active_output` while it exists,
/// else the focused window's output, else the primary one. Everything
/// that says "the current output" (actions, where new windows open) asks
/// this one place.
pub fn workingOutput(wm: *WindowManager) ?*Output {
    if (wm.active_output) |o| if (liveOutput(o)) return o;
    if (wm.seats.first()) |s| {
        if (s.focused) |w| if (w.workspace) |ws| if (liveOutput(ws.output)) return ws.output;
    }
    return primaryOutput(wm);
}

/// The monitor that gets new windows when nothing else decides, and the Dock
/// and the Clip: the one a `monitor()` rule made `primary`, else the first
/// live one in the order `output_order` says.
pub fn primaryOutput(wm: *WindowManager) ?*Output {
    var live: [monitors.max_monitors]*Output = undefined;
    const n = liveOutputs(wm, &live);
    for (live[0..n]) |o| if (o.primary) return o;
    return if (n > 0) live[0] else null;
}

/// The live outputs, in the order `output_order` asks for (left to right by
/// default, or the order the monitors were announced). Fills `buf`, returns how many.
pub fn liveOutputs(wm: *WindowManager, buf: *[monitors.max_monitors]*Output) usize {
    var n: usize = 0;
    var it = wm.outputs.first();
    while (it) |o| : (it = nextOutput(o, wm)) {
        if (!liveOutput(o) or n == buf.len) continue;
        buf[n] = o;
        n += 1;
    }
    if (wm.monitors.order == .position and n > 1) {
        // Insertion sort by position: n is tiny and it must keep ties stable.
        var boxes: [monitors.max_monitors]monitors.Box = undefined;
        for (buf[0..n], 0..) |o, i| boxes[i] = .{ .x = o.rect.x, .y = o.rect.y, .w = o.rect.w, .h = o.rect.h };
        var idx: [monitors.max_monitors]usize = undefined;
        const sorted = monitors.order(boxes[0..n], &idx);
        var copy: [monitors.max_monitors]*Output = undefined;
        @memcpy(copy[0..n], buf[0..n]);
        for (sorted, 0..) |from, to| buf[to] = copy[from];
    }
    return n;
}

/// The live output after (`forward`) or before `from` in output order,
/// wrapping around. `from` itself if it is the only live one.
pub fn cycleOutput(wm: *WindowManager, from: *Output, forward: bool) ?*Output {
    var live: [monitors.max_monitors]*Output = undefined;
    const n = liveOutputs(wm, &live);
    if (n == 0) return null;
    var from_idx: ?usize = null;
    for (live[0..n], 0..) |o, i| {
        if (o == from) from_idx = i;
    }
    const i = from_idx orelse return live[0];
    return live[if (forward) (i + 1) % n else (i + n - 1) % n];
}

/// The live output next to `from` in `dir` on the desk (by position), or null.
pub fn outputToward(wm: *WindowManager, from: *Output, dir: monitors.Direction) ?*Output {
    var live: [monitors.max_monitors]*Output = undefined;
    const n = liveOutputs(wm, &live);
    var boxes: [monitors.max_monitors]monitors.Box = undefined;
    var from_idx: ?usize = null;
    for (live[0..n], 0..) |o, i| {
        boxes[i] = .{ .x = o.rect.x, .y = o.rect.y, .w = o.rect.w, .h = o.rect.h };
        if (o == from) from_idx = i;
    }
    const fi = from_idx orelse return null;
    const ni = monitors.neighbor(boxes[0..n], fi, dir) orelse return null;
    return live[ni];
}

pub fn nextOutput(o: *Output, wm: *WindowManager) ?*Output {
    const n = o.link.next orelse return null;
    if (n == &wm.outputs.link) return null;
    return @fieldParentPtr("link", n);
}

pub fn nextSeat(s: *Seat, wm: *WindowManager) ?*Seat {
    const n = s.link.next orelse return null;
    if (n == &wm.seats.link) return null;
    return @fieldParentPtr("link", n);
}
