// SPDX-License-Identifier: 0BSD
//
// river_window_v1 lifecycle: creating Window objects, assigning them to a
// column in the active strip, proposing their tiled size, and cleaning up
// once they're closed.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");
const seat = @import("seat.zig");

const WindowManager = types.WindowManager;
const Window = types.Window;
const Column = types.Column;
const Strip = types.Strip;
const Rectangle = types.Rectangle;

/// WindowManager instance the currently-being-created windowListener
/// belongs to. Needed because river_window_v1's `closed` event handler
/// must reach the WindowManager to fix up strip.active_column /
/// wm.pending_focus, but windowListener's only context parameter is the
/// Window itself. Since this project only ever has one WindowManager
/// instance (see main.zig), a module-level pointer set once in main() is
/// simplest.
pub var global_wm: ?*WindowManager = null;

pub fn create(
    wm: *WindowManager,
    river_win: *river.WindowV1,
    river_node: ?*river.NodeV1,
) !*Window {
    std.log.info("[WINDOW] Creating new window object", .{});

    const win = try wm.gpa.create(Window);

    win.* = .{
        .obj = river_win,
        .node = river_node,
        .link = undefined,
        .height = 0,
        .x = 0,
        .y = 0,
        .new = true,
        .ready = false,
        .column = null,
    };

    wm.windows.append(win);
    river_win.setListener(*Window, windowListener, win);

    return win;
}

/// Assign a newly-managed window to a column, size the column against the
/// output it's actually going on, run layout, and propose the result to
/// river. Called once from handleManageStart (main.zig) for every window
/// still flagged `new`.
///
/// FACT (verified with `grep -n "\.width" src/*.zig` before this rewrite):
/// in the previous version, types.Column.width was a struct field with a
/// single write site in the whole codebase -- its own default-value
/// initializer, `width: i32 = Config.default_column_width`. Nothing else
/// ever assigned to it: layout.recomputeGeometry only *reads* col.width
/// (`win.width = col.width`), it never computes or updates it. So every
/// column, on every output, with any number of windows, was always
/// exactly the same fixed 700px -- windows were being "tiled" into
/// same-sized slots regardless of how much screen space was actually
/// available, which is indistinguishable from "it doesn't tile" when
/// there's only one window (the reported symptom).
///
/// The fix: a column's width is now computed once, when the column is
/// created (assignToStrip below), from the *current* output's usable
/// width -- not left at a type-level constant.
pub fn manage(win: *Window, wm: *WindowManager) void {
    std.log.info("[WINDOW] Managing window...", .{});

    win.new = false;
    win.obj.useSsd();

    if (win.node == null) {
        win.node = win.obj.getNode() catch |err| {
            std.log.err("[WINDOW] Failed to get river node: {}", .{err});
            return;
        };
        std.log.info("[WINDOW] Successfully obtained river node for window", .{});
    }

    if (wm.outputs.first()) |out| {
        const workspace = out.activeWorkspace();
        const rect = out.usableRect();

        assignToStrip(&workspace.strip, win, wm.gpa, rect);
        layout.recomputeGeometry(&workspace.strip, rect);

        // recomputeGeometry has now set win.x/y/width/height from the
        // column's actual (output-relative) width -- propose exactly
        // that, nothing else touches these fields afterward.

        if (win.node) |node| {
            node.setPosition(win.x, win.y);
            std.log.info("[WINDOW] Set node position to ({d}, {d})", .{ win.x, win.y });
        }
    } else {
        // No output bound yet. Shouldn't normally happen -- per protocol
        // and main.zig's riverWmListener, `output` events arrive before
        // `window` events -- but keep a sane fallback instead of
        // proposing 0x0 if it ever does.
        win.width = types.Config.min_column_width;
        win.height = 800;
        std.log.warn("[WINDOW] No bound output available. Using fallback layout dimensions ({d}x{d}).", .{ win.width, win.height });
    }

    std.log.info("[WINDOW] Proposing {d}x{d}", .{ win.width, win.height });
    win.obj.proposeDimensions(win.width, win.height);

    win.obj.setBorders(
        .{ .top = true, .bottom = true, .left = true, .right = true },
        20,
        0xffffffff, // r = 100%
        0x00000000, // g = 0%
        0x00000000, // b = 0%
        0xffffffff, // a = 100% (opaque; values are premultiplied-alpha)
    );

    if (wm.seats.first()) |s| {
        seat.focus(s, win);
    }
}

/// Create a new column sized against `usable_rect` (the output's current
/// usable area) and insert it into the strip right after the currently
/// active column (or at the end, if there is none yet), then make it the
/// new active column.
pub fn assignToStrip(
    strip: *Strip,
    win: *Window,
    gpa: std.mem.Allocator,
    usable_rect: Rectangle,
) void {
    std.log.info("[STRIP] Inserting new column for window", .{});

    const col = gpa.create(Column) catch return;
    col.* = .{
        .strip = strip,
        .link = undefined,
        .width = columnWidthFor(usable_rect),
        .windows = undefined,
    };
    col.windows.init();
    col.windows.append(win);
    win.column = col;

    if (strip.active_column) |active| {
        if (active.link.next) |next_link| {
            col.link.next = next_link;
            col.link.prev = &active.link;
            active.link.next = &col.link;
            next_link.prev = &col.link;
        } else {
            strip.columns.append(col);
        }
    } else {
        strip.columns.append(col);
    }

    strip.active_column = col;
}

/// A new column's width: a fixed fraction of the output's current usable
/// width (see types.Config.default_column_width_fraction), floored at
/// min_column_width so it's never created unusably narrow. Using a
/// fraction of the *live* usable_rect (rather than a fixed pixel count)
/// is what makes this scale correctly across different monitor sizes and
/// is what was missing before -- see manage()'s doc comment above.
fn columnWidthFor(usable_rect: Rectangle) i32 {
    const usable: f64 = @floatFromInt(@max(0, usable_rect.width - types.Config.gap * 2));
    const computed: i32 = @intFromFloat(usable * types.Config.default_column_width_fraction);
    return @max(types.Config.min_column_width, computed);
}

fn windowListener(
    river_win: *river.WindowV1,
    event: river.WindowV1.Event,
    win: *Window,
) void {
    switch (event) {
        .dimensions => |dim| {
            win.width = dim.width;
            win.height = dim.height;
            win.ready = true;
            std.log.info("[WINDOW] Received dimensions: {d}x{d}", .{ dim.width, dim.height });
            if (global_wm) |wm| wm.needs_layout = true;
        },
        .closed => {
            std.log.info("[WINDOW] Window closed", .{});
            handleClosed(river_win, win);
        },
        else => {
            std.log.debug("[EVENT] Received river_window_v1 event", .{});
        },
    }
}

/// Remove a closed window from whatever column it was in, drop the column
/// too if it's now empty, and pick a new focus target so the strip never
/// points active_column at something already destroyed. Per protocol,
/// river_window_v1.destroy() should be called after `closed` is received.
fn handleClosed(river_win: *river.WindowV1, win: *Window) void {
    const wm = global_wm orelse {
        river_win.destroy();
        return;
    };

    if (win.column) |col| {
        const strip = col.strip;
        const was_active_column = strip.active_column == col;

        win.column_link.remove();
        win.column = null;

        if (col.isEmpty()) {
            // Grab neighbors *before* unlinking col -- col.link.next/prev
            // are only valid to read up until the remove() call below.
            const fallback = types.nextColumn(col) orelse types.prevColumn(col);

            col.link.remove();
            if (was_active_column) strip.active_column = fallback;

            wm.gpa.destroy(col);
        }
        // If the column survives (other stacked windows remain), it keeps
        // its position in the strip and focusedWindow() below already
        // returns whichever window is now last in it -- nothing else to
        // do here.

        // Only re-request focus if the closed window could plausibly have
        // held it (its column was the active one) -- otherwise leave
        // pending_focus alone so we don't clobber an unrelated in-flight
        // focus change from some other action this same manage cycle.
        if (was_active_column) {
            if (strip.active_column) |active| {
                wm.pending_focus = active.focusedWindow();
            } else {
                wm.pending_focus = null;
            }
        }
    }

    win.link.remove();
    win.closed = true;
    wm.needs_layout = true;

    river_win.destroy();
    wm.gpa.destroy(win);
}
