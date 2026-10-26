// SPDX-License-Identifier: GPL-3.0
//
// Where a window is DRAWN, as opposed to where it belongs (`win.target`):
// the movement spring of tiled windows, the opening animation, and the clip
// box that cuts what scrolled under the Dock. Pure model code, shared by
// backends; the wlroots backend calls `visualState` once per window and pass.
//

const std = @import("std");
const anim_log = std.log.scoped(.anim);

const types = @import("types.zig");
const animation = @import("animation.zig");

const Window = types.Window;
const WindowManager = types.WindowManager;

/// Forget everything about how the window moved (it is hidden, or its
/// geometry is owned by the compositor): the next time it is shown it appears
/// where it belongs.
pub fn stopAnimations(win: *Window) void {
    win.anim_x = null;
    win.anim_y = null;
    win.open_anim = null;
    win.has_shown = false;
}

/// A pointer drag is going on that must not be smoothed: the window being
/// dragged follows the pointer, and while a column is resized by hand its
/// neighbours follow the edge.
fn dragBlocks(wm: *WindowManager, win: *const Window) bool {
    var it = wm.seats.first();
    while (it) |s| : (it = types.nextSeat(s, wm)) {
        if (s.op_state == .idle) continue;
        if (s.op_window == win or s.op == .resize) return true;
    }
    return false;
}

/// One axis: restart towards `want` when the destination changed (from where
/// the window is now), and give the position for this moment.
fn axis(spec: animation.Spec, anim: *?animation.Animation, shown: i32, goal: *i32, want: i32, now: f64) i32 {
    if (want != goal.*) {
        goal.* = want;
        anim.* = animation.Animation.init(spec, @floatFromInt(shown), @floatFromInt(want), 0, now);
        anim_log.debug("movement {d} -> {d} (clock {d:.1})", .{ shown, want, now });
    }
    if (anim.*) |a| {
        if (!a.isDone(now)) return @intFromFloat(@round(a.valueAt(now)));
        anim.* = null;
        anim_log.debug("movement arrived at {d}", .{want});
    }
    return want;
}

/// Where `win` is drawn at this moment, and how much of it is uncovered.
/// Also keeps `wm.anim_active` up to date.
pub const Visual = struct { x: i32, y: i32, reveal: f64 };

pub fn visualState(wm: *WindowManager, win: *Window) Visual {
    const cfg = &wm.cfg;
    const now = wm.clock.now();
    var vis: Visual = .{ .x = win.target.x, .y = win.target.y, .reveal = 1.0 };

    // ---- movement
    const travels = cfg.animations and !cfg.anim_window_movement.isOff() and
        win.mode == .tiled and win.has_shown and win.anim_ws == win.workspace and !dragBlocks(wm, win);
    if (travels) {
        vis.x = axis(cfg.anim_window_movement, &win.anim_x, win.shown_x, &win.goal_x, win.target.x, now);
        vis.y = axis(cfg.anim_window_movement, &win.anim_y, win.shown_y, &win.goal_y, win.target.y, now);
    } else {
        win.anim_x = null;
        win.anim_y = null;
        win.goal_x = win.target.x;
        win.goal_y = win.target.y;
    }
    win.shown_x = vis.x;
    win.shown_y = vis.y;
    win.has_shown = true;
    win.anim_ws = win.workspace;

    // ---- open: wait for the first content, so the animation is not spent
    // on a window that has nothing to show yet.
    if (!win.opened and win.ready) {
        win.opened = true;
        if (cfg.animations) {
            win.open_anim = animation.Animation.init(cfg.anim_window_open, 0.0, 1.0, 0.0, now);
            if (win.open_anim != null) {
                anim_log.debug("window `{s}` opens ({d}x{d}) clock={d:.1}", .{ win.app_id orelse "?", win.target.w, win.target.h, now });
            }
        }
    }
    if (win.open_anim) |a| {
        if (a.isDone(now) or !cfg.animations) {
            win.open_anim = null;
            anim_log.debug("open animation finished clock={d:.1}", .{now});
        } else {
            vis.reveal = std.math.clamp(a.valueAt(now), 0.0, 1.0);
        }
    }

    if (win.anim_x != null or win.anim_y != null or win.open_anim != null) wm.anim_active = true;
    return vis;
}

/// The part of the window to show, relative to its top left corner: the
/// work area cuts what scrolled under the Dock (null: nothing to cut), and
/// while a window opens only the middle `reveal` (0..1) of its frame is
/// uncovered (content plus `bw` of border). Never a 0 size: that would turn
/// clipping off.
pub fn visibleBox(vis: types.Rect, bw: i32, work: ?types.Rect, reveal: f64) ?types.Rect {
    const cut: ?types.Rect = if (work) |w| clipBox(vis, bw, w) else null;
    if (reveal >= 1.0) return cut;

    const p = std.math.clamp(reveal, 0.0, 1.0);
    const fw = vis.w + 2 * bw;
    const fh = vis.h + 2 * bw;
    const rw: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(fw)) * p))));
    const rh: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(fh)) * p))));
    var box: types.Rect = .{
        .x = -bw + @divTrunc(fw - rw, 2),
        .y = -bw + @divTrunc(fh - rh, 2),
        .w = rw,
        .h = rh,
    };

    if (cut) |c| {
        const x0 = @max(box.x, c.x);
        const y0 = @max(box.y, c.y);
        const x1 = @min(box.x + box.w, c.x + c.w);
        const y1 = @min(box.y + box.h, c.y + c.h);
        if (x1 <= x0 or y1 <= y0) return .{ .x = vis.w + bw + 16, .y = vis.h + bw + 16, .w = 1, .h = 1 };
        box = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    return box;
}

/// The part of a window (content `target` plus `bw` of border on each side)
/// that lies inside `work`, relative to the window's top left corner.
/// null = it lies completely inside, nothing to clip. A window completely
/// outside gets a 1x1 box that does not touch it (a 0 size would turn
/// clipping off).
pub fn clipBox(target: types.Rect, bw: i32, work: types.Rect) ?types.Rect {
    const x0 = @max(target.x - bw, work.x);
    const y0 = @max(target.y - bw, work.y);
    const x1 = @min(target.right() + bw, work.right());
    const y1 = @min(target.bottom() + bw, work.bottom());
    if (x1 <= x0 or y1 <= y0) {
        return .{ .x = target.w + bw + 16, .y = target.h + bw + 16, .w = 1, .h = 1 };
    }
    if (x0 == target.x - bw and y0 == target.y - bw and x1 == target.right() + bw and y1 == target.bottom() + bw) {
        return null;
    }
    return .{ .x = x0 - target.x, .y = y0 - target.y, .w = x1 - x0, .h = y1 - y0 };
}

test "clipBox: inside = no clip, scrolled under the Dock = cut at the edge, outside = nothing" {
    const work: types.Rect = .{ .x = 64, .y = 0, .w = 936, .h = 800 };
    try std.testing.expectEqual(@as(?types.Rect, null), clipBox(.{ .x = 100, .y = 10, .w = 400, .h = 300 }, 2, work));
    // Starts 36px left of the work area (x = 28): the left 36px are cut.
    const c = clipBox(.{ .x = 28, .y = 10, .w = 400, .h = 300 }, 0, work).?;
    try std.testing.expectEqual(@as(i32, 36), c.x);
    try std.testing.expectEqual(@as(i32, 364), c.w);
    try std.testing.expectEqual(@as(i32, 300), c.h);
    // Completely under the Dock strip.
    const o = clipBox(.{ .x = -400, .y = 10, .w = 400, .h = 300 }, 0, work).?;
    try std.testing.expectEqual(@as(i32, 1), o.w);
    try std.testing.expect(o.x >= 400);
}

test "axis: a new destination starts from where the window is, arrives exactly" {
    const spec = animation.Spec.default_movement;
    var anim: ?animation.Animation = null;
    var goal: i32 = 0;

    // Same destination as before: no animation.
    try std.testing.expectEqual(@as(i32, 0), axis(spec, &anim, 0, &goal, 0, 0));
    try std.testing.expect(anim == null);

    // A column makes room: the window is to go to x = 400.
    try std.testing.expectEqual(@as(i32, 0), axis(spec, &anim, 0, &goal, 400, 1000));
    try std.testing.expect(anim != null);
    const mid = axis(spec, &anim, 0, &goal, 400, 1100);
    try std.testing.expect(mid > 0 and mid < 400);

    // The destination changes in mid-flight: it goes on from `mid`, no jump.
    const turned = axis(spec, &anim, mid, &goal, 100, 1100);
    try std.testing.expectEqual(mid, turned);
    try std.testing.expectEqual(@as(i32, 100), goal);

    // Long after: there, and nothing is running any more.
    try std.testing.expectEqual(@as(i32, 100), axis(spec, &anim, turned, &goal, 100, 5000));
    try std.testing.expect(anim == null);

    // "off": the destination is taken at once.
    var none: ?animation.Animation = null;
    var g2: i32 = 0;
    try std.testing.expectEqual(@as(i32, 300), axis(.off, &none, 0, &g2, 300, 0));
    try std.testing.expect(none == null);
}

test "visibleBox: fully open = the work area cut only; opening = a growing middle" {
    const work: types.Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const win: types.Rect = .{ .x = 100, .y = 100, .w = 400, .h = 200 };

    // Fully open and inside the work area: nothing to clip.
    try std.testing.expectEqual(@as(?types.Rect, null), visibleBox(win, 2, work, 1.0));
    // No work area (a floating window): same.
    try std.testing.expectEqual(@as(?types.Rect, null), visibleBox(win, 2, null, 1.0));

    // Half open: half the frame (404 x 204 with the border), in the middle.
    const half = visibleBox(win, 2, null, 0.5).?;
    try std.testing.expectEqual(@as(i32, 202), half.w);
    try std.testing.expectEqual(@as(i32, 102), half.h);
    try std.testing.expectEqual(@as(i32, -2 + 101), half.x);
    try std.testing.expectEqual(@as(i32, -2 + 51), half.y);

    // Never 0 x 0 (that would switch clipping off).
    const first = visibleBox(win, 2, null, 0.0).?;
    try std.testing.expect(first.w >= 1 and first.h >= 1);

    // Opening AND scrolled under the Dock: the intersection of both.
    const dock_work: types.Rect = .{ .x = 150, .y = 0, .w = 850, .h = 800 };
    const both = visibleBox(win, 2, dock_work, 0.5).?;
    try std.testing.expect(both.x >= 150 - win.x);
    try std.testing.expect(both.w >= 1 and both.h >= 1);

    // Opening completely outside the work area: the harmless 1 x 1 box.
    const out = visibleBox(.{ .x = 2000, .y = 0, .w = 100, .h = 100 }, 0, work, 0.5).?;
    try std.testing.expectEqual(@as(i32, 1), out.w);
}
