// SPDX-License-Identifier: 0BSD
//
// Central data model: Output -> Workspace -> Strip -> Column -> Window,
// plus Seat, bindings, and the global WindowManager root.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

// ============================================================================
// Tunables
// ============================================================================

pub const Config = struct {
    /// Default width of a newly created column, as a fraction of the
    /// output's usable width (0.0-1.0). FACT (verified by grep): the
    /// previous fixed-pixel `default_column_width: i32 = 700` was never
    /// adjusted anywhere in the codebase after a Column was created --
    /// `col.width` had exactly one write site (Column's own field
    /// initializer) in the entire project, so every column on every
    /// monitor at every window count ended up exactly 700px wide. That's
    /// the actual bug behind "it never tiles, always the default size".
    /// A fraction of the *current* output's usable width, recomputed each
    /// time a column is created (see window.assignToStrip), fixes that at
    /// the source instead of letting layout.zig or main.zig patch over a
    /// stale absolute pixel value later.
    pub const default_column_width_fraction: f64 = 0.5;
    /// Absolute floor so a column is never created unusably narrow (e.g.
    /// output not ready yet, or a very small/rotated output).
    pub const min_column_width: i32 = 200;
    pub const gap: i32 = 8;
    pub const mod: river.SeatV1.Modifiers = .{ .mod4 = true };
    pub const workspace_count: u32 = 4;
    pub const terminal_cmd = [_][]const u8{"foot"};
    pub const scroll_step: i32 = 200;
};

// ============================================================================
// Column: a vertical stack of windows inside the scrollable strip
// ============================================================================

pub const Column = struct {
    strip: *Strip,
    link: wl.list.Link,

    /// Set by window.assignToStrip() from the output's *current* usable
    /// width -- never left at a type-level default, see Config's doc
    /// comment above for why that mattered.
    width: i32,
    strip_x: i32 = 0,

    windows: wl.list.Head(Window, .column_link),

    pub fn isEmpty(column: *Column) bool {
        return column.windows.empty();
    }

    pub fn focusedWindow(column: *Column) ?*Window {
        return column.windows.last();
    }
};

// ============================================================================
// Strip: the horizontally-scrollable sequence of columns for one workspace
// ============================================================================

pub const Strip = struct {
    workspace: *Workspace,

    columns: wl.list.Head(Column, .link),
    /// Currently focused column, if any.
    active_column: ?*Column = null,

    /// Horizontal scroll offset in logical pixels.
    scroll_x: i32 = 0,

    pub fn init(strip: *Strip, workspace: *Workspace) void {
        strip.* = .{
            .workspace = workspace,
            .columns = undefined,
        };
        strip.columns.init();
    }

    /// The window that should carry keyboard focus for this strip.
    pub fn focusedWindow(strip: *const Strip) ?*Window {
        const column = strip.active_column orelse return null;
        return column.focusedWindow();
    }

    pub fn columnCount(strip: *const Strip) u32 {
        var count: u32 = 0;
        var it = strip.columns.first();
        while (it) |col| : (it = nextColumn(col)) count += 1;
        return count;
    }
};

pub fn nextColumn(column: *Column) ?*Column {
    const n = column.link.next orelse return null;
    if (n == &column.strip.columns.link) return null;
    return @fieldParentPtr("link", n);
}

pub fn prevColumn(column: *Column) ?*Column {
    const p = column.link.prev orelse return null;
    if (p == &column.strip.columns.link) return null;
    return @fieldParentPtr("link", p);
}

pub fn nextWindowInColumn(win: *Window) ?*Window {
    const column = win.column orelse return null;
    const n = win.column_link.next orelse return null;
    if (n == &column.windows.link) return null;
    return @fieldParentPtr("column_link", n);
}

// ============================================================================
// Workspace: Window-Maker-style numbered workspace, one Strip each
// ============================================================================

pub const Workspace = struct {
    output: *Output,
    index: u32,
    strip: Strip,

    pub fn init(workspace: *Workspace, output: *Output, index: u32) void {
        workspace.* = .{
            .output = output,
            .index = index,
            .strip = undefined,
        };
        workspace.strip.init(workspace);
    }
};

// ============================================================================
// Output
// ============================================================================

pub const Output = struct {
    obj: *river.OutputV1,
    removed: bool = false,
    link: wl.list.Link,

    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    workspaces: [Config.workspace_count]Workspace = undefined,
    active_workspace: u32 = 0,

    pub fn activeWorkspace(output: *Output) *Workspace {
        return &output.workspaces[output.active_workspace];
    }

    pub fn usableRect(output: *Output) Rectangle {
        return .{ .x = output.x, .y = output.y, .width = output.width, .height = output.height };
    }

    pub fn isReady(output: *const Output) bool {
        return output.width > 0 and output.height > 0;
    }

    pub fn switchWorkspace(output: *Output, index: u32) void {
        if (index >= Config.workspace_count) return;
        output.active_workspace = index;
    }
};

pub const Rectangle = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

// ============================================================================
// Window
// ============================================================================

pub const Window = struct {
    obj: *river.WindowV1,
    node: ?*river.NodeV1 = null,
    link: wl.list.Link,

    new: bool = true,
    closed: bool = false,
    ready: bool = false,

    column: ?*Column = null,
    column_link: wl.list.Link = undefined,

    x: i32 = 0,
    y: i32 = 0,
    /// Initial guess only -- overwritten by layout.recomputeGeometry as
    /// soon as this window is assigned to a column (window.assignToStrip
    /// + manage() do this before the first propose_dimensions is sent).
    width: i32 = Config.min_column_width,
    height: i32 = 0,

    is_omnipresent: bool = false,

    app_id: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,
};

// ============================================================================
// Bindings
// ============================================================================

pub const Action = enum {
    none,
    spawn_terminal,
    close,
    focus_next_window,
    focus_prev_column,
    focus_next_column,
    workspace_1,
    workspace_2,
    workspace_3,
    workspace_4,
    toggle_omnipresent,
    move,
    resize,
    exit,
};

pub const XkbBinding = struct {
    obj: *river.XkbBindingV1,
    seat: *Seat,
    action: Action = .none,
    link: wl.list.Link,
};

pub const PointerBinding = struct {
    obj: *river.PointerBindingV1,
    seat: *Seat,
    action: Action = .none,
    link: wl.list.Link,
};

// ============================================================================
// Seat
// ============================================================================

pub const SeatOp = union(enum) {
    none,
    move: struct { window: *Window, start_x: i32, start_y: i32 },
    resize: struct {
        window: *Window,
        start_x: i32,
        start_y: i32,
        start_width: i32,
        start_height: i32,
    },
};

pub const Seat = struct {
    obj: *river.SeatV1,
    new: bool = true,
    removed: bool = false,
    /// True until setupBindings() has run for this seat inside a manage
    /// sequence. See seat.create()/seat.setupBindings() for why this
    /// can't happen immediately when the seat is created.
    needs_binding_setup: bool = false,
    link: wl.list.Link,

    focused: ?*Window = null,
    hovered: ?*Window = null,
    interacted: ?*Window = null,

    xkb_bindings: wl.list.Head(XkbBinding, .link),
    pointer_bindings: wl.list.Head(PointerBinding, .link),
    pending_action: Action = .none,

    op: SeatOp = .none,
    op_dx: i32 = 0,
    op_dy: i32 = 0,
    op_release: bool = false,
};

// ============================================================================
// Window Manager Root
// ============================================================================

pub const WindowManager = struct {
    gpa: std.mem.Allocator,
    /// Io backend for this process, from std.process.Init (see main.zig).
    /// Needed for std.process.Child.spawn(io) in main.zig's spawn() --
    /// Zig 0.16 made process spawning go through std.Io like the rest of
    /// I/O, rather than being implicit/global.
    io: std.Io,

    obj: ?*river.WindowManagerV1 = null,
    xkb_bindings: ?*river.XkbBindingsV1 = null,

    outputs: wl.list.Head(Output, .link),
    windows: wl.list.Head(Window, .link),
    seats: wl.list.Head(Seat, .link),

    pending_windows: std.ArrayList(*Window) = .empty,
    needs_layout: bool = true,

    /// Window that a keybinding wants focused, applied on the next
    /// manage_start via river_seat_v1.focus_window. That request "may only
    /// be made as part of a manage sequence" per the protocol, but
    /// keybinding actions (action.zig's handleAction) run directly from
    /// the xkb_binding `pressed` event callback, which happens *before*
    /// the manage_start that always follows it -- so we can't call
    /// focus_window right there. Deferring through this field is the fix.
    pending_focus: ?*Window = null,

    /// Argv of a command a keybinding wants spawned, applied on the next
    /// manage_start. Spawning (std.process.Child) isn't a Wayland request
    /// and has no ordering requirement of its own, but we defer it anyway
    /// so all side effects of an action happen in one predictable place
    /// (manage_start) instead of half in the input callback, half later.
    pending_spawn: ?[]const []const u8 = null,

    /// Window a keybinding wants closed, applied on the next manage_start
    /// via river_window_v1.close. Same manage-sequence-only reasoning as
    /// pending_focus.
    pending_close: ?*Window = null,
};

pub fn nextWindow(win: *Window, wm: *WindowManager) ?*Window {
    const n = win.link.next orelse return null;
    if (n == &wm.windows.link) return null; // Prevents infinite loops
    return @fieldParentPtr("link", n);
}

pub fn nextOutput(out: *Output) ?*Output {
    const n = out.link.next orelse return null;
    return @fieldParentPtr("link", n);
}
