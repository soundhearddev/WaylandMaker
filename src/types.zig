// SPDX-License-Identifier: MIT
//
// Central data model and configuration for the Wayland window manager.
// Defines: Window lifecycle, WindowList (doubly-linked), WindowManager state,
// and global configuration.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration: adjust these to change layout behavior
// ============================================================================

pub const Config = struct {
    /// Output dimensions in pixels. Hardcoded for now; should eventually
    /// read from wl_output if you want multi-monitor support.
    pub const output_width: i32 = 1920;
    pub const output_height: i32 = 1080;

    /// Horizontal gap between tiled windows (pixels). Set to 0 for no gap.
    pub const gap: i32 = 0;

    /// Vertical gap between tiled windows (pixels). Set to 0 for no gap.
    pub const gap_vertical: i32 = 0;
};

// ============================================================================
// Window: represents a single managed Wayland window
// ============================================================================

pub const Window = struct {
    /// river_window_v1 object from the compositor
    obj: *river.WindowV1,

    /// river_node_v1 object from the compositor (may be null if getNode fails)
    node: ?*river.NodeV1,

    /// Doubly-linked list pointers for WindowList
    next: ?*Window = null,
    prev: ?*Window = null,

    /// Set to true when window receives .closed event.
    /// Actual removal happens in layout.removeClosedWindows().
    closed: bool = false,

    /// Last known dimensions. Updated when we proposeDimensions().
    width: i32 = 0,
    height: i32 = 0,

    /// Last known position on output. Updated when we setPosition().
    x: i32 = 0,
    y: i32 = 0,
};

// ============================================================================
// WindowList: doubly-linked list of Windows
// ============================================================================

pub const WindowList = struct {
    first: ?*Window = null,
    last: ?*Window = null,

    /// Append a window to the end of the list.
    /// O(1) operation.
    pub fn append(self: *WindowList, window: *Window) void {
        std.debug.assert(window.next == null and window.prev == null);

        window.prev = self.last;
        window.next = null;

        if (self.last) |last| {
            last.next = window;
        } else {
            self.first = window;
        }

        self.last = window;
    }

    /// Remove a window from the list.
    /// O(1) operation. Clears the window's next/prev pointers.
    pub fn remove(self: *WindowList, window: *Window) void {
        if (window.prev) |prev| {
            prev.next = window.next;
        } else {
            self.first = window.next;
        }

        if (window.next) |next| {
            next.prev = window.prev;
        } else {
            self.last = window.prev;
        }

        window.next = null;
        window.prev = null;
    }

    /// Count total windows in the list.
    /// O(n) operation. Call sparingly (cache the result if you need it multiple times).
    pub fn count(self: *WindowList) usize {
        var result: usize = 0;
        var current = self.first;

        while (current) |window| {
            result += 1;
            current = window.next;
        }

        return result;
    }

    /// Check if list is empty.
    /// O(1) operation.
    pub fn isEmpty(self: *WindowList) bool {
        return self.first == null;
    }

    /// Find a window by its river_window_v1 object pointer.
    /// Returns null if not found. O(n) operation.
    pub fn findByObj(self: *WindowList, obj: *river.WindowV1) ?*Window {
        var current = self.first;
        while (current) |window| {
            if (window.obj == obj) {
                return window;
            }
            current = window.next;
        }
        return null;
    }
};

// ============================================================================
// WindowManager: root state object
// ============================================================================

pub const WindowManager = struct {
    /// General-purpose allocator for creating/destroying Window objects.
    /// Used in main() to allocate the WindowManager itself, so must outlive it.
    allocator: Allocator,

    /// river_window_manager_v1 object from the compositor.
    /// Obtained via registry.bind() in main.zig.
    obj: *river.WindowManagerV1,

    /// All currently managed windows. Linked list for efficient insertion/removal.
    windows: WindowList = .{},

    /// Add a new window to the manager.
    /// Window is appended to the end of the windows list.
    /// Caller is responsible for creating the Window object itself.
    pub fn addWindow(self: *WindowManager, window: *Window) void {
        std.log.info("[WINDOW] Adding window to manager (total before: {d})", .{self.windows.count()});
        self.windows.append(window);
    }

    /// Attempt to find a window by its river_window_v1 pointer.
    /// Returns null if not found.
    pub fn findWindow(self: *WindowManager, obj: *river.WindowV1) ?*Window {
        return self.windows.findByObj(obj);
    }

    /// Count total managed windows.
    pub fn windowCount(self: *WindowManager) usize {
        return self.windows.count();
    }

    /// Check if we're managing any windows.
    pub fn hasWindows(self: *WindowManager) bool {
        return !self.windows.isEmpty();
    }
};
