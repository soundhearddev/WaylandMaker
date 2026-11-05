// SPDX-License-Identifier: GPL-3.0
//
// One monitor on the compositor side: the wlroots output, its place in the
// scene and in the output layout, and its model `Output`.
//
// Not to be confused with outputs.zig (what the model does when a monitor
// comes or goes) and monitors.zig (identity, rules, profiles): those have no
// wlroots. This file reports the real output to them (`manage.createOutput`,
// `setOutputRect`, ...) and carries out what they decide on the real output
// (`Monitor.applyRule`: on/off, mode, scale, place on the desk).

const std = @import("std");
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const model = @import("model.zig");
const types = model.types;
const backend = @import("backend.zig");
const manage = @import("manage.zig");
const perf = @import("perf.zig");
const monitors = model.monitors;

const layer = @import("layer.zig");
const Server = @import("server.zig").Server;

/// The part of a monitor's rule the compositor carries out.
const Applied = struct {
    enabled: bool,
    mode: ?monitors.Mode,
    scale: ?f32,
    position: ?monitors.Position,
};

pub const Monitor = struct {
    server: *Server,
    wlr_output: *wlr.Output,
    scene_output: *wlr.SceneOutput,
    out: *types.Output,
    link: wl.list.Link = undefined,
    /// The output is being destroyed: nothing may be arranged on it any more.
    gone: bool = false,
    /// What `applyRule` last put on the real output; equal to what the rule
    /// wants now means nothing to do.
    applied: ?Applied = null,
    /// `wm.config_gen` when `applied` was worked out: the rules are matched
    /// again only after a reload, not on every pass (during an animation: every frame).
    applied_gen: u32 = 0,
    /// Part of the desk (`output_layout`). A switched-off output is not: the
    /// pointer cannot run onto a screen that is dark.
    in_layout: bool = true,

    frame: wl.Listener(*wlr.Output) = .init(onFrame),
    request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(onRequestState),
    destroy: wl.Listener(*wlr.Output) = .init(onDestroy),

    pub fn create(server: *Server, wlr_output: *wlr.Output) !void {
        // VR headsets and the like: not part of the desktop.
        if (wlr_output.non_desktop) {
            log.info("output {s} is not a desktop output, ignored", .{wlr_output.name});
            return;
        }
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
        // The cursor theme at this monitor's scale (a HiDPI screen would get
        // a tiny cursor from the 1x images only).
        if (wlr_output.scale > 1) server.cursor.xcursor.load(wlr_output.scale) catch {};
        m.syncRect();
        log.info("output {s}: {d}x{d}", .{ name, out.rect.w, out.rect.h });
        server.scheduleManage();
    }

    /// Carry out the `monitor()` rule on the real output: on/off, video mode,
    /// scale and place on the desk. The model decides (outputs.zig), this
    /// only commits, and only when something differs from the last time.
    /// Runs after every manage pass; does nothing until the rule has been
    /// settled (the monitors have been quiet), and never switches off the
    /// last output.
    pub fn applyRule(m: *Monitor) void {
        if (m.gone or !m.out.settled) return;
        if (m.applied) |a| {
            if (m.applied_gen == m.server.wm.config_gen and a.enabled == !m.out.disabled) return;
        }
        m.applied_gen = m.server.wm.config_gen;
        const rule = monitors.findRule(m.server.wm.monitors.rules, &m.out.mon);
        const want: Applied = .{
            .enabled = !m.out.disabled,
            .mode = if (rule) |r| r.mode else null,
            .scale = if (rule) |r| r.scale else null,
            .position = if (rule) |r| r.position else null,
        };
        if (m.applied) |a| if (std.meta.eql(a, want)) return;
        const first = m.applied == null;
        m.applied = want;
        // Nothing asked and nothing applied before: the output is as create() left it.
        if (first and want.enabled and want.mode == null and want.scale == null and want.position == null) return;

        const out = m.wlr_output;
        var state = wlr.Output.State.init();
        defer state.finish();
        state.setEnabled(want.enabled);
        if (want.enabled) {
            if (want.mode) |wm| {
                if (m.findMode(wm)) |mode| {
                    state.setMode(mode);
                } else {
                    // Not a listed mode (a custom timing, or a typo): the
                    // backend decides whether it can do it.
                    log.warn("output {s}: no listed mode {d}x{d}, trying it as a custom mode", .{ out.name, wm.w, wm.h });
                    state.setCustomMode(wm.w, wm.h, wm.refresh_mhz);
                }
            } else if (out.preferredMode()) |pm| {
                state.setMode(pm);
            }
            state.setScale(want.scale orelse 1);
        }
        if (!out.commitState(&state)) {
            log.warn("output {s}: the rule could not be applied (mode, scale or on/off refused)", .{out.name});
        } else if (want.enabled) {
            // The cursor theme at the new scale.
            if (out.scale > 1) m.server.cursor.xcursor.load(out.scale) catch {};
            manage.setOutputScale(m.server.wm, m.out, @intFromFloat(@round(out.scale)));
        }

        if (!want.enabled) {
            if (m.in_layout) {
                m.server.output_layout.remove(out);
                m.in_layout = false;
            }
        } else if (!m.in_layout) {
            if (m.server.output_layout.addAuto(out)) |lo| {
                m.server.scene_output_layout.addOutput(lo, m.scene_output);
                m.in_layout = true;
            } else |err| log.warn("output {s}: cannot put it back on the desk: {t}", .{ out.name, err });
        }

        if (want.enabled and m.in_layout) if (want.position) |pos| {
            _ = m.server.output_layout.add(out, pos.x, pos.y) catch |err| {
                log.warn("output {s}: cannot place it at {d},{d}: {t}", .{ out.name, pos.x, pos.y, err });
            };
        };
        if (m.in_layout) m.syncRect();
        m.server.scheduleManage();
    }

    /// The listed mode of this output for `want`: the size, and the refresh
    /// closest to the one asked for (the highest when none was).
    fn findMode(m: *Monitor, want: monitors.Mode) ?*wlr.Output.Mode {
        var best: ?*wlr.Output.Mode = null;
        var best_diff: i32 = std.math.maxInt(i32);
        var it = m.wlr_output.modes.iterator(.forward);
        while (it.next()) |mode| {
            if (mode.width != want.w or mode.height != want.h) continue;
            const diff: i32 = if (want.refresh_mhz == 0) -mode.refresh else @intCast(@abs(mode.refresh - want.refresh_mhz));
            if (diff < best_diff) {
                best = mode;
                best_diff = diff;
            }
        }
        return best;
    }

    /// Copy the monitor's box on the desk into the model.
    pub fn syncRect(m: *Monitor) void {
        var box: wlr.Box = undefined;
        m.server.output_layout.getBox(m.wlr_output, &box);
        manage.setOutputRect(m.server.wm, m.out, .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height }, m.server.nowMs());
    }

    fn onFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const m: *Monitor = @fieldParentPtr("frame", listener);
        m.server.runPendingManage();
        const span = perf.start(m.server.wm.io, .render);
        _ = m.scene_output.commit(null);
        _ = perf.stop(m.server.wm.io, span);
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

        // Its panels and launchers close with it; nothing is arranged on it
        // from here on.
        m.gone = true;
        layer.closeOn(server, m);

        manage.removeOutput(server.wm, m.out, server.nowMs());
        m.frame.link.remove();
        m.request_state.link.remove();
        m.destroy.link.remove();
        m.link.remove();
        server.gpa.destroy(m);
        server.scheduleManage();
    }
};
