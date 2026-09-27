// SPDX-License-Identifier: 0BSD
//
// wlprefs entry point: connect, bind globals, create the window, pump the
// Wayland event loop until the window is closed.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;

const wlprefs = @import("wlprefs");
const Window = wlprefs.window.Window;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const display = wl.Display.connect(null) catch |err| {
        std.log.err("could not connect to Wayland display: {t}", .{err});
        return err;
    };
    defer display.disconnect();

    var win = Window.init(gpa);
    defer win.deinit();

    const registry = try display.getRegistry();
    registry.setListener(*Window, Window.registryListener, &win);

    // First roundtrip: collect every global the compositor advertises.
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    if (win.wm_base) |wm_base| {
        wm_base.setListener(*Window, Window.wmBaseListener, &win);
    } else {
        std.log.err("compositor does not support xdg_wm_base", .{});
        return error.MissingGlobal;
    }
    if (win.compositor == null) {
        std.log.err("compositor does not support wl_compositor", .{});
        return error.MissingGlobal;
    }
    if (win.shm == null) {
        std.log.err("compositor does not support wl_shm", .{});
        return error.MissingGlobal;
    }

    try win.create();

    // Second roundtrip: let the compositor send the initial
    // xdg_surface.configure, which unblocks the first draw().
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (!win.closed) {
        if (display.dispatch() != .SUCCESS) break;
    }
}
