// SPDX-License-Identifier: GPL-3.0
//
// Draws the miniaturize / deminiaturize animation (miniaturize.zig): the
// outline that flies between a window and its Dock tile.
//
// The manage pass decides what flies where and when (`wm.mini_runs`); this
// file shows the frame the clock is at. Window Maker draws its frames with an
// XOR line straight onto the root window. There is no XOR in a scene, so a
// frame is a transparent ARGB buffer holding the outline (a light line
// under a dark one: visible on any background), shown in a scene buffer
// above everything but the menus. One buffer per running animation, redrawn
// only when the frame changes, destroyed when the animation ends.
//
// Called after every manage pass (`Server.runManage`); an animation keeps
// `wm.anim_active` up, so there is one pass per displayed frame and nothing
// when it is over.

const std = @import("std");
const log = std.log.scoped(.anim);

const wlr = @import("wlroots");

const miniaturize = @import("miniaturize.zig");
const gfx = @import("gfx.zig");
const dock_scene = @import("dock_scene.zig");
const Server = @import("server.zig").Server;

const wm_pixbuf_create = dock_scene.wm_pixbuf_create;

// Window Maker's `frame_gc` is an XOR/invert line that shows on any
// background: a dark line inside a light one is visible on every background too.
const col_halo: gfx.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.85 };
const col_line: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0.95 };

pub const MiniUi = struct {
    server: *Server,
    tree: *wlr.SceneTree,
    /// One node per slot of `wm.mini_runs`.
    nodes: [miniaturize.max_runs]?*wlr.SceneBuffer = @splat(null),
    /// What each node shows: the run (by its start) and the frame.
    shown: [miniaturize.max_runs]?struct { start: f64, frame: usize } = @splat(null),

    pub fn create(server: *Server) !*MiniUi {
        const ui = try server.gpa.create(MiniUi);
        errdefer server.gpa.destroy(ui);
        ui.* = .{
            .server = server,
            .tree = try server.scene.tree.createSceneTree(),
        };
        return ui;
    }

    pub fn destroy(ui: *MiniUi) void {
        // The nodes go with the scene tree.
        ui.server.gpa.destroy(ui);
    }

    /// Show the frame each running animation is at now.
    pub fn update(ui: *MiniUi) void {
        const wm = ui.server.wm;
        const now = wm.clock.now();
        for (&wm.mini_runs, 0..) |*slot, i| {
            const run = slot.* orelse {
                ui.drop(i);
                continue;
            };
            const k = run.frameAt(now) orelse {
                ui.drop(i);
                continue;
            };
            if (ui.shown[i]) |s| if (s.start == run.start and s.frame == k) continue;
            ui.show(i, &run, k);
        }
    }

    fn drop(ui: *MiniUi, i: usize) void {
        if (ui.nodes[i]) |node| node.node.destroy();
        ui.nodes[i] = null;
        ui.shown[i] = null;
    }

    fn show(ui: *MiniUi, i: usize, run: *const miniaturize.Run, k: usize) void {
        const frame = run.plan.frames[k];
        const box = miniaturize.frameBox(frame);
        if (box.w <= 0 or box.h <= 0) return;

        const node = ui.nodes[i] orelse blk: {
            const n = ui.tree.createSceneBuffer(null) catch {
                log.err("out of memory: the miniaturize animation is not shown", .{});
                return;
            };
            ui.nodes[i] = n;
            break :blk n;
        };

        const w: usize = @intCast(box.w);
        const h: usize = @intCast(box.h);
        const stride = w * 4;
        const gpa = ui.server.gpa;
        const bytes = gpa.alloc(u8, stride * h) catch return;
        defer gpa.free(bytes);
        @memset(bytes, 0);
        var cv = gfx.Canvas.initForData(bytes.ptr, box.w, box.h, @intCast(stride)) catch return;
        defer cv.deinit();
        draw(&cv, frame, box.x, box.y);
        cv.flush();

        const buf = wm_pixbuf_create(box.w, box.h, bytes.ptr, stride) orelse return;
        node.setBuffer(buf);
        buf.drop();
        node.setDestSize(box.w, box.h);
        node.node.setPosition(box.x, box.y);
        ui.shown[i] = .{ .start = run.start, .frame = k };
    }
};

fn outline(cv: *gfx.Canvas, pts: []const [2]f64) void {
    cv.strokePath(pts, true, 3, col_halo);
    cv.strokePath(pts, true, 1, col_line);
}

/// Draw one frame on `cv`, whose top left is the global point (ox, oy).
pub fn draw(cv: *gfx.Canvas, f: miniaturize.Frame, ox: i32, oy: i32) void {
    const fox: f64 = @floatFromInt(ox);
    const foy: f64 = @floatFromInt(oy);
    switch (f) {
        .poly => |pts| {
            // The fifth point is the first one again: the path is closed.
            var q: [4][2]f64 = undefined;
            for (0..4) |i| q[i] = .{ @as(f64, @floatFromInt(pts[i][0])) - fox + 0.5, @as(f64, @floatFromInt(pts[i][1])) - foy + 0.5 };
            outline(cv, &q);
        },
        .boxes => |bs| for (bs) |b| {
            // XDrawRectangle(x, y, w, h) covers x .. x + w inclusive.
            const x0: f64 = @as(f64, @floatFromInt(b[0])) - fox + 0.5;
            const y0: f64 = @as(f64, @floatFromInt(b[1])) - foy + 0.5;
            const x1: f64 = x0 + @as(f64, @floatFromInt(b[2]));
            const y1: f64 = y0 + @as(f64, @floatFromInt(b[3]));
            outline(cv, &.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } });
        },
    }
}
