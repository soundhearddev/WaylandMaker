// SPDX-License-Identifier: 0BSD
//
// Central data model: Output -> Workspace -> Strip -> Column -> Window,
// plus Seat, keybinding actions and the global WindowManager root.

const std = @import("std");
const wayland = @import("wayland");
const config = @import("config.zig");
const wmaker = @import("compatibility.zig");
const river = wayland.client.river;
const wl = wayland.client.wl;

// ============================================================================
// Tunables
// ============================================================================

pub const Config = struct {
    /// Width of a new column as a fraction of the output width. Columns
    /// keep this width; opening more windows scrolls instead of shrinking.
    pub const default_column_width_fraction: f64 = 0.5;

    /// Width presets cycled by Mod+R (fractions of the output width).
    pub const width_presets = [_]f64{ 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0 };

    /// Step for Mod+Minus / Mod+Equal (fraction of the output width).
    pub const width_step: f64 = 0.1;

    pub const min_column_width: i32 = 200;

    /// Gap between columns / windows and to the screen edge (pixels).
    pub const gap: i32 = 8;

    /// Border around every window (pixels).
    pub const border_width: i32 = 2;

    /// Border colours as 0xRRGGBB (converted to river's 32-bit channels).
    pub const border_focused: u32 = 0xd8a657;
    pub const border_unfocused: u32 = 0x3c3836;

    pub const mod: river.SeatV1.Modifiers = .{ .mod4 = true };
    pub const mod_shift: river.SeatV1.Modifiers = .{ .mod4 = true, .shift = true };

    pub const workspace_count: u32 = 4;

    // Default Parameter
    pub const terminal_cmd = [_][]const u8{"alacritty"};
    pub const launcher_cmd = [_][]const u8{"fuzzel"};
    pub const browser_cmd = [_][]const u8{"librewolf"};
};

pub const Rectangle = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

// ============================================================================
// Column
// ============================================================================

pub const Column = struct {
    strip: *Strip,
    link: wl.list.Link,

    /// Fixed width in pixels, set when the column is created and changed
    /// only by explicit resize actions.
    width: i32,
    /// Left edge of the column in strip coordinates (set by layout).
    strip_x: i32 = 0,

    windows: wl.list.Head(Window, .column_link),
    /// Window inside this column that has (or last had) focus.
    focused: ?*Window = null,

    pub fn isEmpty(column: *Column) bool {
        return column.windows.empty();
    }

    pub fn focusedWindow(column: *Column) ?*Window {
        if (column.focused) |w| return w;
        return column.windows.first();
    }

    pub fn windowCount(column: *Column) i32 {
        var n: i32 = 0;
        var it = column.windows.first();
        while (it) |w| : (it = nextWindowInColumn(w)) n += 1;
        return n;
    }
};

// ============================================================================
// Strip
// ============================================================================

pub const Strip = struct {
    workspace: *Workspace,
    columns: wl.list.Head(Column, .link),
    active_column: ?*Column = null,

    /// Strip coordinate of the viewport's left edge.
    scroll_x: i32 = 0,

    pub fn init(strip: *Strip, workspace: *Workspace) void {
        strip.* = .{
            .workspace = workspace,
            .columns = undefined,
        };
        strip.columns.init();
    }

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

pub fn prevWindowInColumn(win: *Window) ?*Window {
    const column = win.column orelse return null;
    const p = win.column_link.prev orelse return null;
    if (p == &column.windows.link) return null;
    return @fieldParentPtr("column_link", p);
}

// ============================================================================
// Workspace
// ============================================================================

pub const Workspace = struct {
    output: *Output,
    index: u32,
    strip: Strip,

    /// Windows that are temporarily floating above the tiled strip.
    floating: wl.list.Head(Window, .floating_link),

    pub fn init(workspace: *Workspace, output: *Output, index: u32) void {
        workspace.* = .{
            .output = output,
            .index = index,
            .strip = undefined,
            .floating = undefined,
        };
        workspace.strip.init(workspace);
        workspace.floating.init();
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

    pub fn rect(output: *const Output) Rectangle {
        return .{ .x = output.x, .y = output.y, .width = output.width, .height = output.height };
    }

    pub fn isReady(output: *const Output) bool {
        return output.width > 0 and output.height > 0;
    }
};

// ============================================================================
// Window
// ============================================================================

pub const Window = struct {
    obj: *river.WindowV1,
    node: ?*river.NodeV1 = null,
    link: wl.list.Link,

    /// Not yet placed into a column.
    new: bool = true,
    closed: bool = false,
    /// Received its first `dimensions` event.
    ready: bool = false,

    column: ?*Column = null,
    column_link: wl.list.Link = undefined,

    /// Workspace this window currently belongs to.
    workspace: ?*Workspace = null,

    /// Link used while the window is in Workspace.floating.
    floating_link: wl.list.Link = undefined,

    // Saved tiled placement while floating.
    saved_column_index: usize = 0,
    saved_window_index: usize = 0,
    saved_column_width: i32 = 0,

    /// WindowMaker "Omnipresent" state.
    sticky: bool = false,

    /// Target geometry computed by layout (output coordinates).
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = Config.min_column_width,
    height: i32 = 0,

    /// Last size we actually sent with propose_dimensions, so we only
    /// re-propose when something changed.
    proposed_w: i32 = -1,
    proposed_h: i32 = -1,

    /// Last border colour state we sent (avoids spamming set_borders).
    border_focused: ?bool = null,

    /// Whether the window is currently hidden (other workspace).
    hidden: bool = false,

    /// Set while the window is being dragged/resized interactively.
    floating: bool = false,
};

// ============================================================================
// Bindings
// ============================================================================

pub const Action = enum {
    none,
    // spawning
    spawn_terminal,
    spawn_launcher,
    spawn_browser,
    // window / column focus
    close,
    toggle_floating,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    focus_first_column,
    focus_last_column,
    // moving things around
    move_column_left,
    move_column_right,
    move_window_up,
    move_window_down,
    consume_left, // pull window into the left column (stack it)
    expel_right, // push window out into its own new column
    // sizing
    cycle_column_width,
    widen_column,
    narrow_column,
    // workspaces
    workspace_1,
    workspace_2,
    workspace_3,
    workspace_4,
    move_to_workspace_1,
    move_to_workspace_2,
    move_to_workspace_3,
    move_to_workspace_4,
    // misc
    exit,
};

pub const XkbBinding = struct {
    obj: *river.XkbBindingV1,
    seat: *Seat,
    action: Action = .none,
    link: wl.list.Link,
};

pub const PointerOperation = enum {
    none,
    move,
    resize,
};

pub const PointerBinding = struct {
    obj: *river.PointerBindingV1,
    seat: *Seat,
    button: u32,
    operation: PointerOperation,
    link: wl.list.Link,
};

// ============================================================================
// Seat
// ============================================================================

pub const Seat = struct {
    obj: *river.SeatV1,
    removed: bool = false,
    needs_binding_setup: bool = false,
    link: wl.list.Link,

    xkb_bindings: wl.list.Head(XkbBinding, .link),
    pointer_bindings: wl.list.Head(PointerBinding, .link),

    focused: ?*Window = null,

    pointer_window: ?*Window = null,
    pointer_operation: PointerOperation = .none,
    pointer_operation_window: ?*Window = null,

    pointer_initial_x: i32 = 0,
    pointer_initial_y: i32 = 0,
    pointer_initial_width: i32 = 0,
    pointer_initial_height: i32 = 0,

    pointer_drag_dx: i32 = 0,
    pointer_drag_dy: i32 = 0,
    pointer_last_reorder_x: i32 = 0,
    pointer_last_reorder_y: i32 = 0,

    pointer_start_pending: bool = false,
    pointer_end_pending: bool = false,
};

// ============================================================================
// Window Manager root
// ============================================================================

pub const WindowManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: config.Config,
    wmaker_ctx: wmaker.WMakerContext,

    obj: ?*river.WindowManagerV1 = null,
    /// Version we bound river_window_manager_v1 with (see main.zig).
    obj_version: u32 = 1,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,

    outputs: wl.list.Head(Output, .link),
    windows: wl.list.Head(Window, .link),
    seats: wl.list.Head(Seat, .link),

    /// Actions queued by key presses. The `pressed` event arrives outside
    /// a manage sequence, but nearly every request an action needs
    /// (focus_window, close, propose_dimensions, ...) is only legal
    /// *inside* one. So `pressed` only queues the action here and the next
    /// manage_start (which the protocol guarantees follows) executes it.
    pending_actions: std.ArrayList(Action) = .empty,

    /// Window to focus on the next manage_start.
    pending_focus: ?*Window = null,

    /// Argv the next manage_start should spawn.
    pending_spawn: ?[]const []const u8 = null,

    /// Window to close on the next manage_start.
    pending_close: ?*Window = null,

    needs_layout: bool = true,
    quit: bool = false,
};

pub fn nextWindow(win: *Window, wm: *WindowManager) ?*Window {
    const n = win.link.next orelse return null;
    if (n == &wm.windows.link) return null;
    return @fieldParentPtr("link", n);
}

/// Outputs live in `wm.outputs`; the list head is the sentinel, so we need
/// the WindowManager to know where the list ends.
pub fn nextOutput(out: *Output, wm: *WindowManager) ?*Output {
    const n = out.link.next orelse return null;
    if (n == &wm.outputs.link) return null;
    return @fieldParentPtr("link", n);
}

pub fn nextSeat(s: *Seat, wm: *WindowManager) ?*Seat {
    const n = s.link.next orelse return null;
    if (n == &wm.seats.link) return null;
    return @fieldParentPtr("link", n);
}
