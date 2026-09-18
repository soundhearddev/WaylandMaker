// SPDX-License-Identifier: MIT
//
// Event loop and Wayland protocol handlers.
// Responsibilities:
// - Connect to Wayland display
// - Bind river_window_manager_v1 protocol
// - Listen for window/manager events
// - Call layout engine to compute and apply layouts
// - Main dispatch loop

const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const types = @import("types.zig");
const layout = @import("layout.zig");

const WindowManager = types.WindowManager;
const Window = types.Window;

// ============================================================================
// Wayland event listeners
// ============================================================================

/// Listener for individual river_window_v1 events.
/// A Window is created when river sends .window event from river_window_manager_v1.
/// It is marked closed when it emits .closed, and actually removed during
/// the next manage() call.
fn windowListener(
    _: *river.WindowV1,
    event: river.WindowV1.Event,
    window: *Window,
) void {
    switch (event) {
        .closed => {
            std.log.info("[WINDOW] window closed event received", .{});
            window.closed = true;
        },
        else => {
            // Ignore other window events (.configure_request, etc.)
        },
    }
}

/// Listener for river_window_manager_v1 events.
/// Called when:
/// - .window: a new window is being managed (create Window, add to manager)
/// - .manage_start: layout pass for new windows (call layout.manage)
/// - .render_start: position windows (call layout.render)
fn windowManagerListener(
    _: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    manager: *WindowManager,
) void {
    switch (event) {
        .window => |args| {
            // A new window is being managed by river.
            // args.id is the river_window_v1 object.
            const river_window = args.id;

            std.log.info("[WINDOW] new window event", .{});

            // Try to get the river_node_v1 for this window.
            // This may fail if the window isn't ready yet, but we still
            // proceed (we just won't be able to setPosition() until we have it).
            const node = river_window.getNode() catch |err| {
                std.log.warn(
                    "[WINDOW] failed to get node for window: {any}",
                    .{err},
                );
                return;
            };

            // Allocate a Window struct
            const window = manager.allocator.create(Window) catch |err| {
                std.log.err(
                    "[WINDOW] failed to allocate Window struct: {any}",
                    .{err},
                );
                return;
            };

            // Initialize the Window
            window.* = .{
                .obj = river_window,
                .node = node,
            };

            // Attach our listener to the window so we get .closed events
            river_window.setListener(
                *Window,
                windowListener,
                window,
            );

            // Add it to the manager's window list
            manager.addWindow(window);
        },

        .manage_start => {
            // River is starting a manage pass. This means one or more new
            // windows have been created and are ready to be tiled.
            // Call the layout engine to assign dimensions.
            std.log.info("[MANAGER] manage_start event", .{});
            layout.manage(manager);
        },

        .render_start => {
            // River is starting a render pass. Windows should now have
            // accepted their proposed dimensions and are ready to be
            // positioned on screen.
            // Call the layout engine to assign positions.
            std.log.info("[MANAGER] render_start event", .{});
            layout.render(manager);
        },

        else => {
            // Ignore other manager events
        },
    }
}

/// Listener for wl_registry events.
/// When the registry advertises "river_window_manager_v1", we bind it
/// and store the pointer so main() can use it.
fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    window_manager_ptr: *?*river.WindowManagerV1,
) void {
    switch (event) {
        .global => |args| {
            const interface_name = std.mem.span(args.interface);

            if (std.mem.eql(u8, interface_name, "river_window_manager_v1")) {
                std.log.info(
                    "[REGISTRY] found river_window_manager_v1 (version {d})",
                    .{args.version},
                );

                // Bind to river_window_manager_v1
                window_manager_ptr.* = registry.bind(
                    args.name,
                    river.WindowManagerV1,
                    args.version,
                ) catch |err| {
                    std.log.err(
                        "[REGISTRY] failed to bind river_window_manager_v1: {any}",
                        .{err},
                    );
                    return;
                };

                std.log.info("[REGISTRY] successfully bound river_window_manager_v1", .{});
            }
        },

        else => {
            // Ignore other registry events
        },
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    std.log.info("[INIT] starting Wayland window manager", .{});

    // Connect to Wayland display (via WAYLAND_DISPLAY env var or default)
    const display = wl.Display.connect(null) catch |err| {
        std.log.err("[INIT] failed to connect to Wayland display: {any}", .{err});
        return err;
    };
    defer display.disconnect();

    std.log.info("[INIT] connected to Wayland display", .{});

    // Get the global registry to discover available protocols
    const registry = try display.getRegistry();

    // Allocate and initialize the WindowManager state
    const manager = try allocator.create(WindowManager);
    defer allocator.destroy(manager);

    manager.* = .{
        .allocator = allocator,
        .obj = undefined, // Will be set by registryListener
    };

    // Set up registry listener to find river_window_manager_v1
    var wm_obj: ?*river.WindowManagerV1 = null;

    registry.setListener(
        *?*river.WindowManagerV1,
        registryListener,
        &wm_obj,
    );

    // First roundtrip: let the registry listener process all .global events
    std.log.info("[INIT] first roundtrip (discover protocols)", .{});
    if (display.roundtrip() != .SUCCESS) {
        std.log.err("[INIT] first roundtrip failed", .{});
        return error.RoundtripFailed;
    }

    // Check that we found river_window_manager_v1
    const river_manager = wm_obj orelse {
        std.log.err(
            "[INIT] river_window_manager_v1 not found. Is river running?",
            .{},
        );
        return error.MissingRiverWindowManagement;
    };

    manager.obj = river_manager;

    std.log.info("[INIT] river_window_manager_v1 available, attaching listener", .{});

    // Attach our listener to the window manager
    river_manager.setListener(
        *WindowManager,
        windowManagerListener,
        manager,
    );

    // Second roundtrip: let the window manager listener receive initial
    // events (e.g., if there are already windows, or if the compositor
    // sends synchronous responses to our listener attachment).
    std.log.info("[INIT] second roundtrip (initial window manager events)", .{});
    if (display.roundtrip() != .SUCCESS) {
        std.log.err("[INIT] second roundtrip failed", .{});
        return error.RoundtripFailed;
    }

    std.log.info("[INIT] initialization complete, entering dispatch loop", .{});

    // Main event loop: dispatch all pending Wayland events.
    // dispatch() blocks until at least one event is available, then processes
    // all events, then returns. We loop forever, only exiting if dispatch()
    // fails (which means the display connection is broken).
    while (true) {
        const result = display.dispatch();

        switch (result) {
            .SUCCESS => {
                // Events were dispatched; loop and wait for more.
            },
            else => {
                std.log.err("[DISPATCH] display.dispatch() failed: {any}", .{result});
                break;
            },
        }
    }

    std.log.info("[SHUTDOWN] exiting", .{});
}
