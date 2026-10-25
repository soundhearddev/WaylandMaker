// SPDX-License-Identifier: GPL-3.0
//
// wlr-probe: can wlroots be used from Zig on this machine at all?
//
// Creates what a compositor needs (backend, renderer, allocator), says what
// it got, and exits. No clients, no event loop. Use it to check an install
// before blaming the compositor:
//
//   zig build wlr-probe
//   WLR_BACKENDS=headless ./zig-out/bin/wlr-probe     (no display needed)
//   WLR_BACKENDS=wayland  ./zig-out/bin/wlr-probe     (nested)
//
// Exit status 0: everything came up. Anything else: the message says what not.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

pub fn main() !void {
    wlr.log.init(.info, null);

    std.debug.print("wlroots {s} built against, {d}.{d}.{d} loaded\n", .{
        wlr.version.str,
        wlr.version.runtimeMajor(),
        wlr.version.runtimeMinor(),
        wlr.version.runtimeMicro(),
    });
    if (wlr.version.runtimeMajor() != wlr.version.major or wlr.version.runtimeMinor() != wlr.version.minor) {
        std.debug.print("the bindings and the library are different wlroots versions: expect crashes\n", .{});
        return error.VersionMismatch;
    }
    std.debug.print("backends: drm={} libinput={} x11={} session={} | renderers: gles2={} vulkan={}\n", .{
        wlr.config.has_drm_backend,
        wlr.config.has_libinput_backend,
        wlr.config.has_x11_backend,
        wlr.config.has_session,
        wlr.config.has_gles2_renderer,
        wlr.config.has_vulkan_renderer,
    });

    const server = try wl.Server.create();
    defer server.destroy();

    var session: ?*wlr.Session = null;
    const backend = try wlr.Backend.autocreate(server.getEventLoop(), &session);
    defer backend.destroy();
    std.debug.print("backend: ok (session: {s})\n", .{if (session != null) "yes" else "none"});

    const renderer = try wlr.Renderer.autocreate(backend);
    try renderer.initServer(server);
    std.debug.print("renderer: ok\n", .{});

    _ = try wlr.Allocator.autocreate(backend, renderer);
    std.debug.print("allocator: ok\n", .{});

    std.debug.print("probe passed\n", .{});
}
