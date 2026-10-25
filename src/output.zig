// SPDX-License-Identifier: GPL-3.0
//
// One monitor: wlroots output, its place in the scene, its model `Output`.

const std = @import("std");
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const types = model.types;
const backend = @import("backend.zig");
const manage = @import("manage.zig");

const Server = @import("server.zig").Server;

pub const Monitor = struct {
    server: *Server,
    wlr_output: *wlr.Output,
    scene_output: *wlr.SceneOutput,
    out: *types.Output,
    link: wl.list.Link = undefined,

    frame: wl.Listener(*wlr.Output) = .init(onFrame),
    request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(onRequestState),
    destroy: wl.Listener(*wlr.Output) = .init(onDestroy),

    pub fn create(server: *Server, wlr_output: *wlr.Output) !void {
        if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRender;

        // Enable it at its preferred mode. (A saved `monitor()` rule can
        // change that later, once the manage pass knows the rules.)
        var state = wlr.Output.State.init();
        defer state.finish();
        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| state.setMode(mode);
        if (!wlr_output.commitState(&state)) return error.Commit;

        const m = try server.gpa.create(Monitor);
        errdefer server.gpa.destroy(m);

        const now = server.nowMs();
        const out = try manage.createOutput(server.wm, backend.handle(backend.Output, m), now);
        errdefer manage.removeOutput(server.wm, out, now);

        const layout_output = try server.output_layout.addAuto(wlr_output);
        const scene_output = try server.scene.createSceneOutput(wlr_output);
        server.scene_output_layout.addOutput(layout_output, scene_output);

        m.* = .{ .server = server, .wlr_output = wlr_output, .scene_output = scene_output, .out = out };
        server.monitors.append(m);
        wlr_output.events.frame.add(&m.frame);
        wlr_output.events.request_state.add(&m.request_state);
        wlr_output.events.destroy.add(&m.destroy);

        const name = std.mem.span(wlr_output.name);
        manage.setOutputInfo(
            server.wm,
            out,
            name,
            if (wlr_output.make) |s| std.mem.span(s) else null,
            if (wlr_output.model) |s| std.mem.span(s) else null,
            if (wlr_output.description) |s| std.mem.span(s) else null,
            @intFromFloat(@round(wlr_output.scale)),
            now,
        );
        m.syncRect();
        log.info("output {s}: {d}x{d}", .{ name, out.rect.w, out.rect.h });
        server.scheduleManage();
    }

    /// Copy the monitor's box on the desk into the model.
    pub fn syncRect(m: *Monitor) void {
        var box: wlr.Box = undefined;
        m.server.output_layout.getBox(m.wlr_output, &box);
        manage.setOutputRect(m.server.wm, m.out, .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height }, m.server.nowMs());
    }

    fn onFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const m: *Monitor = @fieldParentPtr("frame", listener);
        _ = m.scene_output.commit(null);
        var now: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &now);
        m.scene_output.sendFrameDone(&now);
        // An animation advances once per displayed frame.
        if (m.server.wm.anim_active) m.server.scheduleManage();
    }

    fn onRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
        const m: *Monitor = @fieldParentPtr("request_state", listener);
        // The nested backend asks for a new size when its window is resized.
        _ = m.wlr_output.commitState(event.state);
        m.syncRect();
    }

    fn onDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const m: *Monitor = @fieldParentPtr("destroy", listener);
        const server = m.server;
        log.info("output {s} removed", .{m.wlr_output.name});

        manage.removeOutput(server.wm, m.out, server.nowMs());
        m.frame.link.remove();
        m.request_state.link.remove();
        m.destroy.link.remove();
        m.link.remove();
        server.gpa.destroy(m);
        server.scheduleManage();
    }
};
