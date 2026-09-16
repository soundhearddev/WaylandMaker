// SPDX-License-Identifier: 0BSD
//
// Central data model: Output -> Workspace -> Strip -> Column -> Window,
// plus Seat and the global WindowManager root.
//
// This mirrors rill's src/types.zig in spirit (one file, all shared
// structs, no Wayland calls except the object pointers themselves) but
// keeps our Window-Maker-flavored Strip/Column model instead of rill's
// flat per-workspace window list. Layout math lives in layout.zig, not
// here; this file only defines the shapes.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

// ============================================================================
// Tunables
// ============================================================================

pub const Config = struct {
    /// Default width of a new column, in logical pixels. Real Window Maker /
    /// niri configs make this adjustable per-column later; fixed for now.
    pub const default_column_width: i32 = 700;
    /// Gap between columns, between stacked windows, and between the strip
    /// and the output edges.
    pub const gap: i32 = 8;
    /// Modifier used for all bindings below. Mod4 == the "Windows/Super" key,
    /// which is what Window Maker traditionally called "Mod1" in its own
    /// numbering but corresponds to Super on modern layouts.
    pub const mod: river.SeatV1.Modifiers = .{ .mod4 = true };
    /// Number of Window-Maker-style numbered workspaces per output.
    pub const workspace_count: u32 = 4;
};

// ============================================================================
// Column: a vertical stack of windows inside the scrollable strip
// ============================================================================

pub const Column = struct {
    strip: *Strip,
    link: wl.list.Link,

    /// Logical width of this column.
    width: i32 = Config.default_column_width,
    /// Left edge of this column within the strip's own coordinate space
    /// (i.e. before the strip's scroll offset is applied). Recomputed
    /// whenever columns are added/removed/resized (layout.recomputeGeometry).
    strip_x: i32 = 0,

    windows: wl.list.Head(Window, .column_link),

    pub fn isEmpty(column: *Column) bool {
        return column.windows.empty();
    }
};

// ============================================================================
// Strip: the horizontally-scrollable sequence of columns for one workspace
// ============================================================================

pub const Strip = struct {
    workspace: *Workspace,

    columns: wl.list.Head(Column, .link),
    /// Currently focused column, if any window exists.
    active_column: ?*Column = null,

    /// Horizontal scroll offset, in logical pixels. 0 = first column's left
    /// edge is flush with the output's left edge.
    scroll_x: i32 = 0,

    pub fn init(strip: *Strip, workspace: *Workspace) void {
        strip.* = .{
            .workspace = workspace,
            .columns = undefined,
        };
        strip.columns.init();
    }

    /// The window that should carry keyboard focus for this strip: the
    /// topmost (most recently focused) window in the active column.
    pub fn focusedWindow(strip: *Strip) ?*Window {
        const column = strip.active_column orelse return null;
        return column.windows.last();
    }
};

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
    river_layer_shell_output: ?*river.LayerShellOutputV1 = null,
    removed: bool = false,
    link: wl.list.Link,

    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// Usable area after layer-shell surfaces (bars, docks) reserve space.
    /// Falls back to the full output rect until the compositor reports one.
    non_exclusive: ?Rectangle = null,

    workspaces: [Config.workspace_count]Workspace = undefined,
    active_workspace: u32 = 0,

    pub fn activeWorkspace(output: *Output) *Workspace {
        return &output.workspaces[output.active_workspace];
    }

    pub fn usableRect(output: *Output) Rectangle {
        return output.non_exclusive orelse .{
            .x = output.x,
            .y = output.y,
            .width = output.width,
            .height = output.height,
        };
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

pub const PointerRequest = union(enum) {
    move: struct { seat: *Seat },
    resize: struct { seat: *Seat, edges: river.WindowV1.Edges },
    none,
};

pub const Window = struct {
    obj: *river.WindowV1,
    node: *river.NodeV1,
    link: wl.list.Link,

    new: bool = true,
    closed: bool = false,

    /// Which column (if any) this window currently lives in. Null for
    /// windows not yet assigned (shouldn't persist past manage()).
    column: ?*Column = null,
    column_link: wl.list.Link = undefined,

    x: i32 = 0,
    y: i32 = 0,
    width: i32,
    height: i32,

    /// Window-Maker-style per-window attributes. Cheap to add, high
    /// "feels like Window Maker" payoff. See docs/WMAKER_COMPAT.md.
    is_omnipresent: bool = false,

    app_id: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,

    pointer_request: PointerRequest = .none,
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
        edges: river.WindowV1.Edges = .{},
    },
};

pub const Seat = struct {
    obj: *river.SeatV1,
    new: bool = true,
    removed: bool = false,
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
// Window manager root
// ============================================================================

pub const WindowManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    obj: *river.WindowManagerV1,
    xkb_bindings: *river.XkbBindingsV1,
    river_layer_shell: ?*river.LayerShellV1 = null,

    outputs: wl.list.Head(Output, .link),
    windows: wl.list.Head(Window, .link),
    seats: wl.list.Head(Seat, .link),
};
