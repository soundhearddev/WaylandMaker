// SPDX-License-Identifier: MIT
//
// Layout engine: computes window dimensions and positions, then applies them
// to the river compositor. Handles cleanup of closed windows and performs
// the actual tiling calculations.

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

const WindowManager = types.WindowManager;
const Window = types.Window;
const Config = types.Config;

// ============================================================================
// Layout computation: called by windowManagerListener when manage_start fires
// ============================================================================

/// Called when river_window_manager_v1 sends .manage_start event.
/// This is the hook point where we:
/// 1. Remove any windows that have closed since the last manage_start
/// 2. Compute layout for all remaining windows
/// 3. Tell the compositor about dimensions and tiling state
/// 4. Finish the manage operation
///
/// Does not modify the windows list, only window.width/height and their
/// obj.proposeDimensions()/setTiled() properties.
pub fn manage(manager: *WindowManager) void {
    // First pass: clean up any closed windows to get accurate count
    removeClosedWindows(manager);

    const window_count = manager.windowCount();

    std.log.info("[LAYOUT] manage_start: {d} windows to layout", .{window_count});

    if (window_count == 0) {
        // No windows to manage. Still need to call manageFinish() to close
        // the manage_start transaction.
        manager.obj.manageFinish();
        return;
    }

    // Compute layout: evenly divide output width by window count.
    // Each window gets output_height as its full height.
    const window_width = @divTrunc(
        Config.output_width,
        @as(i32, @intCast(window_count)),
    );
    const window_height = Config.output_height;

    std.log.info(
        "[LAYOUT] proposing dimensions: {d}x{d} per window",
        .{ window_width, window_height },
    );

    // Walk the window list and tell each window its proposed size.
    // Also mark them as tiled (not floating).
    var current = manager.windows.first;
    while (current) |window| {
        // Save the computed dimensions so we can use them in render()
        window.width = window_width;
        window.height = window_height;

        // Tell river what size this window should be
        window.obj.proposeDimensions(window_width, window_height);

        // Mark this window as tiled (all edges), so river knows it's part
        // of the tiling layout and not floating/fullscreen/etc.
        window.obj.setTiled(.{
            .top = true,
            .bottom = true,
            .left = true,
            .right = true,
        });

        current = window.next;
    }

    // Signal to river that we're done proposing changes for this manage_start
    manager.obj.manageFinish();
}

// ============================================================================
// Position assignment: called by windowManagerListener when render_start fires
// ============================================================================

/// Called when river_window_manager_v1 sends .render_start event.
/// This is the hook point where we:
/// 1. Compute the X position for each window (left-to-right tiling)
/// 2. Tell the compositor where to position each window on the output
/// 3. Finish the render operation (tells river the layout is complete)
///
/// Window dimensions should already be set by manage(). This only assigns
/// X,Y positions.
pub fn render(manager: *WindowManager) void {
    const window_count = manager.windowCount();

    std.log.info("[LAYOUT] render_start: positioning {d} windows", .{window_count});

    if (window_count == 0) {
        manager.obj.renderFinish();
        return;
    }

    // Use the first window's width (all should be equal from manage())
    // as the stride. If somehow it's zero, compute it fresh.
    const window_width = blk: {
        if (manager.windows.first) |first| {
            if (first.width > 0) {
                break :blk first.width;
            }
        }
        break :blk @divTrunc(
            Config.output_width,
            @as(i32, @intCast(window_count)),
        );
    };

    var index: i32 = 0;
    var current = manager.windows.first;

    while (current) |window| {
        // Compute x position: index * window_width (left-to-right)
        const x = index * window_width;
        const y: i32 = 0; // Always at top of output

        // Update our cached position
        window.x = x;
        window.y = y;

        // Tell river where to render this window
        if (window.node) |node| {
            node.setPosition(x, y);
        } else {
            std.log.warn(
                "[LAYOUT] window {d} has no node, skipping setPosition",
                .{index},
            );
        }

        index += 1;
        current = window.next;
    }

    std.log.debug("[LAYOUT] positioned {d} windows", .{index});

    // Signal to river that we're done positioning windows
    manager.obj.renderFinish();
}

// ============================================================================
// Internal: cleanup of closed windows
// ============================================================================

/// Scan the windows list for any marked .closed and remove them.
/// This is called at the start of manage() to ensure layout operates on
/// the actual current window set.
///
/// A window is marked .closed when it emits a .closed event from river.
/// We defer actual removal (destroy + free) to here so we don't mutate
/// the windows list while iterating event handlers.
fn removeClosedWindows(manager: *WindowManager) void {
    var current = manager.windows.first;

    var removed_count: usize = 0;

    while (current) |window| {
        // Grab next before we potentially remove current
        const next = window.next;

        if (window.closed) {
            std.log.info("[LAYOUT] removing closed window", .{});

            // Remove from list
            manager.windows.remove(window);

            // Clean up river resources
            window.obj.destroy();

            // Free the Window struct itself
            manager.allocator.destroy(window);

            removed_count += 1;
        }

        current = next;
    }

    if (removed_count > 0) {
        std.log.info("[LAYOUT] cleaned up {d} closed windows", .{removed_count});
    }
}
