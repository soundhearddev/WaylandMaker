// SPDX-License-Identifier: 0BSD
//
// Data model.
//
//   WindowManager
//    ├─ outputs ─ Output
//    │            └─ workspaces[N] ─ Workspace
//    │                                ├─ strip    ─ Column ─ Window   (tiled)
//    │                                ├─ floating ─ Window ...        (z-ordered, top = last)
//    │                                └─ fullscreen: ?*Window
//    ├─ windows  (every window exactly once, regardless of state)
//    └─ seats
//
// Invariants (enforced by the functions in workspace.zig, relied on
// everywhere else):
//
//   I1. Every live Window is in `wm.windows`.
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
const wayland = @import("wayland");
const config = @import("config.zig");
const wm_attr = @import("wm_attr.zig");
const wm_menu = @import("wm_menu.zig");
const river = wayland.client.river;
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

pub const Window = struct {
    obj: *river.WindowV1,
    node: *river.NodeV1,

    /// Link in `wm.windows`.
    link: wl.list.Link = .{ .prev = null, .next = null },

    // ---- identity ---------------------------------------------------------
    app_id: ?[]u8 = null,
    title: ?[]u8 = null,
    /// Set when the client declared a parent (dialog, file picker...).
    parent: ?*river.WindowV1 = null,

    // ---- lifecycle --------------------------------------------------------
    /// Not yet placed on a workspace (first manage_start places it).
    new: bool = true,
    /// Has received a `dimensions` event, i.e. has content. Informational
    /// only: a new window gets its first proposal BEFORE this is true (river
    /// sends `dimensions` in reply to it), so nothing may wait on this.
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
    /// Refreshed when the app_id arrives; placement decisions (workspace,
    /// floating, omnipresent) are taken once, when the window is first placed.
    attrs: wm_attr.Attributes = .{},

    // ---- geometry ---------------------------------------------------------
    /// Floating geometry, in output-local coordinates (relative to the
    /// output's top-left). Remembered across tiled<->floating toggles.
    float_rect: Rect = .{},
    has_float_rect: bool = false,

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

    // ---- what we last told river (so we only send changes) ------------------
    sent_w: i32 = -1,
    sent_h: i32 = -1,
    sent_tiled: ?bool = null,
    sent_border: ?BorderKind = null,
    sent_x: i32 = std.math.minInt(i32),
    sent_y: i32 = std.math.minInt(i32),
    visible: ?bool = null,
    sent_fullscreen: ?*Output = null,

    /// Column the window was in before it was "consumed"/detached, used
    /// only to restore floating -> tiled placement (see workspace.zig).
    saved_column_index: usize = 0,
    saved_column_width: i32 = 0,

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
};

pub const Strip = struct {
    workspace: *Workspace,
    columns: wl.list.Head(Column, .link),
    active: ?*Column = null,
    /// Strip coordinate of the viewport's left edge.
    scroll_x: i32 = 0,

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
    obj: *river.OutputV1,
    layer_shell: ?*river.LayerShellOutputV1 = null,
    link: wl.list.Link = .{ .prev = null, .next = null },
    removed: bool = false,

    /// Full output rectangle in global coordinates.
    rect: Rect = .{},
    /// Area not covered by layer-shell exclusive zones (bars, docks).
    usable: ?Rect = null,

    workspaces: [config.max_workspaces]Workspace = undefined,
    workspace_count: u32 = 0,
    active: u32 = 0,

    pub fn ws(o: *Output) *Workspace {
        return &o.workspaces[o.active];
    }

    pub fn ready(o: *const Output) bool {
        return o.rect.w > 0 and o.rect.h > 0;
    }

    /// Rectangle windows may occupy.
    pub fn workArea(o: *const Output) Rect {
        return o.usable orelse o.rect;
    }
};

// ============================================================================
// Seat & pointer operations
// ============================================================================

pub const PointerOp = enum { none, move, resize };

/// Where the interactive pointer operation is in river's protocol.
///
///   idle ──beginOp──▶ requested ──op_start_pointer──▶ running
///     ▲                  │                               │
///     │                  │ button up before start        │ op_release
///     │                  ▼                               ▼
///     └─────────── (cancelled, no op_end needed)      ending ──op_end──▶ idle
///
/// `requested`: we saw the binding press but have not sent op_start_pointer
///   yet (that request is only legal inside a manage sequence). river knows
///   nothing about the operation, so it will never send op_release.
/// `running`: river is in cursor mode `op` and sends op_delta on every
///   motion. Pointer input is NOT delivered to clients until we op_end().
/// `ending`: op_release arrived (or the window died); op_end() goes out in
///   the next manage sequence.
pub const OpState = enum { idle, requested, running, ending };

pub const XkbBinding = struct {
    obj: *river.XkbBindingV1,
    link: wl.list.Link = .{ .prev = null, .next = null },
    /// Index into wm.commands.
    command: usize,
};

pub const PointerBinding = struct {
    obj: *river.PointerBindingV1,
    link: wl.list.Link = .{ .prev = null, .next = null },
    seat: *Seat,
    op: PointerOp,
};

pub const Seat = struct {
    obj: *river.SeatV1,
    link: wl.list.Link = .{ .prev = null, .next = null },
    removed: bool = false,
    bindings_ready: bool = false,

    xkb_bindings: wl.list.Head(XkbBinding, .link),
    pointer_bindings: wl.list.Head(PointerBinding, .link),

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

    obj: *river.WindowManagerV1,
    obj_version: u32,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,

    outputs: wl.list.Head(Output, .link),
    windows: wl.list.Head(Window, .link),
    seats: wl.list.Head(Seat, .link),

    /// Parsed key binding commands; XkbBinding.command indexes this.
    commands: []const Command = &.{},

    /// Window Maker per-application rules (WMWindowAttributes).
    attrs: wm_attr.Table = .{},
    /// The root menu (Window Maker WMRootMenu / wlmaker RootMenu.plist).
    root_menu: ?*const wm_menu.Menu = null,

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
};

// ============================================================================
// Commands (what a key binding does)
// ============================================================================

pub const Command = union(enum) {
    none,
    spawn: []const []const u8,
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

    float_move: struct { dx: i32, dy: i32 },
    float_resize: struct { dw: i32, dh: i32 },

    workspace: u32,
    workspace_next,
    workspace_prev,
    move_to_workspace: u32,
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
