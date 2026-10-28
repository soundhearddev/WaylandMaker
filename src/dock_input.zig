// SPDX-License-Identifier: GPL-3.0
//
// What the pointer does to the Dock, the Clip and the Drawers: hover, click,
// double click, dragging a tile to another place (or away), moving the Dock,
// the Clip or a Drawer, the Clip's workspace arrows, and the Clip's and the
// Drawers' auto fold. It is a state machine over the `Model` and knows nothing
// of Wayland: the compositor feeds it pointer events in OUTPUT-LOCAL pixels
// (the model's coordinates) and carries out what it returns.
//
//   * The model is changed here only where the change is the Dock's own
//     business (a tile moved or removed, a Clip folded). Everything the rest of
//     the compositor must do (start a program, show a window, change the
//     workspace, move the Dock to another edge) comes back as an `Effect`.
//   * `viewState` hands dock_view.plan what it needs, so what is drawn always
//     follows from this state.
//
// The rules are Window Maker's (dock.c, wdock*): a tile is started by a double
// click (or one click, if `single_click`); a click on a running program's tile
// shows its window; the middle button starts another instance; a tile pulled
// out of every dock and let go is removed; the Dock's, the Clip's and a
// Drawer's own tile drag the whole thing.

const std = @import("std");

const config = @import("config.zig");
const dock_model = @import("dock_model.zig");
const dock_view = @import("dock_view.zig");
const wdock = @import("wm_dock.zig");

const Model = dock_model.Model;

pub const Button = enum { left, middle, right };

pub const Settings = struct {
    /// One click starts a program (Window Maker's default is two).
    single_click: bool = false,
    double_click_ms: u32 = 400,
    /// How far the pointer has to move, with the button down, before it is a drag.
    drag_px: i32 = 5,
    /// Delay before an auto-collapse Clip / Drawer opens under the pointer ...
    expand_delay_ms: u32 = 600,
    /// ... and before it folds after the pointer left it.
    collapse_delay_ms: u32 = 1000,
};

/// What the compositor has to do. Slots are `Model` slot indices.
pub const Effect = union(enum) {
    /// Start the program of the tile; `new_instance`: even if one is running.
    launch: struct { slot: usize, new_instance: bool },
    /// Show the window of the tile (restore it if minimized, change the
    /// workspace, focus it).
    activate: usize,
    /// Change the workspace by this much (the Clip's arrows, the wheel).
    workspace: i32,
    /// The Dock was dragged to this side / distance from the top.
    place_dock: struct { edge: config.DockEdge, offset: i32 },
    /// The Clip was dragged to this corner.
    place_clip: config.ClipCorner,
    /// The context menu of a tile or an empty main tile was asked for.
    menu: struct { dock: *wdock.Dock, icon: *wdock.Icon, x: i32, y: i32 },
    /// Something that WMState remembers changed: write it.
    save,
};

pub const Effects = struct {
    buf: [4]Effect = undefined,
    len: usize = 0,

    pub fn push(e: *Effects, fx: Effect) void {
        if (e.len < e.buf.len) {
            e.buf[e.len] = fx;
            e.len += 1;
        }
    }
    pub fn slice(e: *const Effects) []const Effect {
        return e.buf[0..e.len];
    }
};

pub const Outcome = struct {
    /// The event belongs to the dock: do not hand it to a window.
    consumed: bool = false,
    /// Something the plan depends on changed: plan and `diff` again.
    redraw: bool = false,
    effects: Effects = .{},
};

pub const Hit = struct {
    dock: *wdock.Dock,
    icon: *wdock.Icon,
};

const Mode = enum { pending, tile, dock, clip, drawer };

const Press = struct {
    hit: Hit,
    button: Button,
    x: i32,
    y: i32,
    /// Where in the tile the button went down.
    off_x: i32,
    off_y: i32,
    time: u32,
    mode: Mode = .pending,
};

const Timer = struct { dock: *wdock.Dock, at: u32, collapse: bool };

pub const Input = struct {
    settings: Settings = .{},

    hover: ?Hit = null,
    arrow: dock_model.Arrow = .none,
    press: ?Press = null,
    /// The tile in the air, and where it would land.
    drag_x: i32 = 0,
    drag_y: i32 = 0,
    drop: ?struct { dock: *wdock.Dock, xy: [2]i32 } = null,
    detached: bool = false,

    last_click: ?struct { icon: *const wdock.Icon, time: u32 } = null,
    inside: ?*wdock.Dock = null,
    timer: ?Timer = null,

    // ---- hit testing --------------------------------------------------------

    /// The tile under (x, y), or null. A folded Clip / Drawer has only its own
    /// tile.
    pub fn hitTest(m: *const Model, x: i32, y: i32) ?Hit {
        if (m.scr.dock) |d| if (hitDock(d, x, y)) |i| return .{ .dock = d, .icon = i };
        const clip = m.currentClip();
        if (hitDock(clip, x, y)) |i| return .{ .dock = clip, .icon = i };
        for (m.scr.drawers.items) |d| if (hitDock(d, x, y)) |i| return .{ .dock = d, .icon = i };
        return null;
    }

    fn hitDock(d: *wdock.Dock, x: i32, y: i32) ?*wdock.Icon {
        if (!d.mapped) return null;
        for (d.icons) |maybe| {
            const i = maybe orelse continue;
            if (d.kind != .dock and d.collapsed and !i.main) continue;
            if (x >= i.x_pos and x < i.x_pos + dock_model.tile and y >= i.y_pos and y < i.y_pos + dock_model.tile) return i;
        }
        return null;
    }

    pub fn pressing(in: *const Input) bool {
        return in.press != null;
    }

    pub fn dragging(in: *const Input) bool {
        const p = in.press orelse return false;
        return p.mode != .pending;
    }

    // ---- what to draw -------------------------------------------------------

    /// The `State` for planning `dock`. `origin` is the model-local position
    /// of the top left corner of its surface (the compositor's scene node).
    pub fn viewState(in: *const Input, m: *const Model, dock: *const wdock.Dock, origin: [2]i32) dock_view.State {
        var st: dock_view.State = .{ .only_main = dock.kind != .dock and dock.collapsed };
        if (dock.kind == .clip) {
            st.workspace = @intCast(m.scr.current_workspace);
            st.name = m.workspaceName(st.workspace);
        }
        const tile_drag = if (in.press) |p| p.mode == .tile else false;
        if (!tile_drag) {
            if (in.hover) |h| if (h.dock == dock) {
                st.hover = h.icon;
                st.hover_arrow = in.arrow;
            };
        } else if (in.press) |p| {
            // The tile in the air belongs to the dock it came from; the gap
            // to the dock it would land in.
            const source = p.hit.dock == dock;
            const target = if (in.drop) |d| d.dock == dock else false;
            if (source or target) {
                st.drag = .{
                    .icon = p.hit.icon,
                    .target = if (target) in.drop.?.xy else null,
                    .detached = in.detached,
                    .x = in.drag_x - origin[0] - p.off_x,
                    .y = in.drag_y - origin[1] - p.off_y,
                };
                if (!source) st.drag.?.target = in.drop.?.xy;
            }
        }
        return st;
    }

    // ---- motion -------------------------------------------------------------

    pub fn motion(in: *Input, m: *Model, x: i32, y: i32, time: u32) Outcome {
        var out: Outcome = .{};
        if (in.press) |*p| {
            out.consumed = true;
            in.drag(m, p, x, y, &out);
            return out;
        }

        const hit = hitTest(m, x, y);
        out.consumed = hit != null;

        var arrow: dock_model.Arrow = .none;
        if (hit) |h| if (h.dock.kind == .clip and h.icon.main) {
            arrow = dock_model.clipArrowAt(x - h.icon.x_pos, y - h.icon.y_pos);
        };
        const same = if (hit) |h| if (in.hover) |o| o.icon == h.icon else false else in.hover == null;
        if (!same or arrow != in.arrow) out.redraw = true;
        in.hover = hit;
        in.arrow = arrow;

        in.setInside(if (hit) |h| h.dock else null, time);
        return out;
    }

    /// The pointer left the output the dock is on.
    pub fn leave(in: *Input, time: u32) bool {
        const had = in.hover != null;
        in.hover = null;
        in.arrow = .none;
        in.setInside(null, time);
        return had;
    }

    fn setInside(in: *Input, now: ?*wdock.Dock, time: u32) void {
        if (now == in.inside) return;
        const old = in.inside;
        in.inside = now;
        in.timer = null;
        if (old) |o| if (o.kind != .dock and o.auto_collapse and !o.collapsed) {
            in.timer = .{ .dock = o, .at = time +% in.settings.collapse_delay_ms, .collapse = true };
        };
        if (now) |n| if (n.kind != .dock and n.auto_collapse and n.collapsed) {
            in.timer = .{ .dock = n, .at = time +% in.settings.expand_delay_ms, .collapse = false };
        };
    }

    /// When `tick` next has something to do (event-loop time, ms), or null.
    pub fn deadline(in: *const Input) ?u32 {
        const t = in.timer orelse return null;
        return t.at;
    }

    /// Fold or unfold what is due. True: the plan changed.
    pub fn tick(in: *Input, now: u32) bool {
        const t = in.timer orelse return false;
        if (in.press != null) return false;
        if (@as(i32, @bitCast(now -% t.at)) < 0) return false;
        in.timer = null;
        if (t.dock.collapsed == t.collapse) return false;
        t.dock.collapsed = t.collapse;
        return true;
    }

    // ---- dragging -----------------------------------------------------------

    fn drag(in: *Input, m: *Model, p: *Press, x: i32, y: i32, out: *Outcome) void {
        in.drag_x = x;
        in.drag_y = y;
        if (p.button != .left) return;

        if (p.mode == .pending) {
            const dx = x - p.x;
            const dy = y - p.y;
            const lim = in.settings.drag_px;
            if (dx * dx + dy * dy < lim * lim) return;
            p.mode = modeFor(p.hit);
            if (p.mode == .tile) in.last_click = null;
            out.redraw = true;
        }

        const gx = x - p.off_x;
        const gy = y - p.off_y;
        const bounds: types_Rect = .{ .x = 0, .y = 0, .w = m.scr.width, .h = m.scr.height };
        switch (p.mode) {
            .pending => {},
            .tile => {
                in.findDrop(m, p, gx, gy);
                out.redraw = true;
            },
            .dock => {
                const at = dock_model.dockPlacementFor(bounds, gx, gy);
                out.effects.push(.{ .place_dock = .{ .edge = at.edge, .offset = at.offset } });
                out.redraw = true;
            },
            .clip => {
                out.effects.push(.{ .place_clip = dock_model.clipCornerFor(bounds, x, y) });
                out.redraw = true;
            },
            .drawer => {
                if (m.moveDrawerToward(p.hit.dock, gy)) out.redraw = true;
            },
        }
    }

    const types_Rect = @import("types.zig").Rect;

    fn modeFor(h: Hit) Mode {
        if (!h.icon.main) return .tile;
        return switch (h.dock.kind) {
            .dock => .dock,
            .clip => .clip,
            .drawer => .drawer,
        };
    }

    /// Where would the tile land if let go at the pointer (x, y)?
    fn findDrop(in: *Input, m: *Model, p: *const Press, gx: i32, gy: i32) void {
        in.drop = null;
        const gi = p.hit.icon;
        const docks = [_]?*wdock.Dock{ m.scr.dock, m.currentClip() };
        for (docks) |maybe| {
            const d = maybe orelse continue;
            if (wdock.snapIcon(&m.scr, d, gi, gx, gy, gi.dock == d)) |xy| {
                in.drop = .{ .dock = d, .xy = xy };
                break;
            }
        } else for (m.scr.drawers.items) |d| {
            if (wdock.snapIcon(&m.scr, d, gi, gx, gy, gi.dock == d)) |xy| {
                in.drop = .{ .dock = d, .xy = xy };
                break;
            }
        }
        in.detached = in.drop == null;
    }

    // ---- buttons ------------------------------------------------------------

    pub fn button(in: *Input, m: *Model, x: i32, y: i32, btn: Button, pressed: bool, time: u32) Outcome {
        var out: Outcome = .{};
        if (pressed) {
            const hit = hitTest(m, x, y) orelse return out;
            out.consumed = true;
            if (in.press != null) return out;
            if (btn == .right) {
                out.effects.push(.{ .menu = .{ .dock = hit.dock, .icon = hit.icon, .x = x, .y = y } });
                return out;
            }
            in.press = .{
                .hit = hit,
                .button = btn,
                .x = x,
                .y = y,
                .off_x = x - hit.icon.x_pos,
                .off_y = y - hit.icon.y_pos,
                .time = time,
            };
            in.drag_x = x;
            in.drag_y = y;
            return out;
        }

        const p = in.press orelse return out;
        if (p.button != btn) return out;
        in.press = null;
        out.consumed = true;
        out.redraw = true;
        if (p.mode == .pending) {
            in.click(m, p, x, y, time, &out);
        } else if (p.mode == .tile) {
            in.dropTile(m, p, &out);
        } else {
            out.effects.push(.save);
        }
        in.drop = null;
        in.detached = false;
        wdock.consolidateAllDrawers(&m.scr);

        // The pointer may be somewhere else now: the hover follows.
        const again = in.motion(m, x, y, time);
        out.redraw = out.redraw or again.redraw;
        return out;
    }

    fn dropTile(in: *Input, m: *Model, p: Press, out: *Outcome) void {
        const index = slotIndex(m, p.hit.icon) orelse return;
        if (in.drop) |d| {
            if (m.dropSlot(index, d.dock, d.xy)) out.effects.push(.save);
        } else if (m.slot(index)) |s| {
            // Pulled out of every dock: gone (a minimized window's tile and
            // a locked one stay).
            if (s.app.mini_window == 0 and m.removeSlot(index)) out.effects.push(.save);
        }
    }

    fn slotIndex(m: *const Model, gi: *const wdock.Icon) ?usize {
        for (m.slots.items, 0..) |*s, i| {
            if (s.alive and s.gi == gi) return i;
        }
        return null;
    }

    fn click(in: *Input, m: *Model, p: Press, x: i32, y: i32, time: u32, out: *Outcome) void {
        const hit = p.hit;
        if (hit.icon.main) {
            switch (hit.dock.kind) {
                .dock => {},
                .clip => switch (dock_model.clipArrowAt(x - hit.icon.x_pos, y - hit.icon.y_pos)) {
                    .next => out.effects.push(.{ .workspace = 1 }),
                    .prev => out.effects.push(.{ .workspace = -1 }),
                    .none => {
                        hit.dock.collapsed = !hit.dock.collapsed;
                        out.effects.push(.save);
                    },
                },
                .drawer => hit.dock.collapsed = !hit.dock.collapsed,
            }
            return;
        }

        const index = slotIndex(m, hit.icon) orelse return;
        const s = m.slot(index) orelse return;

        if (p.button == .middle) {
            if (s.app.command.len > 0) out.effects.push(.{ .launch = .{ .slot = index, .new_instance = true } });
            return;
        }

        const double = if (in.last_click) |lc|
            lc.icon == hit.icon and time -% lc.time <= in.settings.double_click_ms
        else
            false;
        in.last_click = if (double) null else .{ .icon = hit.icon, .time = time };

        if (s.app.mini_window != 0 or s.running) {
            out.effects.push(.{ .activate = index });
        } else if ((double or in.settings.single_click) and s.app.command.len > 0 and !s.launching) {
            out.effects.push(.{ .launch = .{ .slot = index, .new_instance = false } });
        }
    }

    // ---- the wheel ----------------------------------------------------------

    /// The wheel over the Clip changes the workspace. `dy` > 0: down / next.
    pub fn scroll(in: *Input, m: *Model, x: i32, y: i32, dy: f64) Outcome {
        _ = in;
        var out: Outcome = .{};
        const hit = hitTest(m, x, y) orelse return out;
        out.consumed = true;
        if (hit.dock.kind == .clip and dy != 0) {
            out.effects.push(.{ .workspace = if (dy > 0) 1 else -1 });
        }
        return out;
    }

    /// The model was rebuilt or changed under us (a tile removed, the
    /// workspace changed): drop what pointed into it.
    pub fn reset(in: *Input) void {
        in.hover = null;
        in.arrow = .none;
        in.press = null;
        in.drop = null;
        in.detached = false;
        in.last_click = null;
        in.inside = null;
        in.timer = null;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const dockapp = @import("dockapp.zig");

fn mk(comptime name: []const u8, y: i32) dockapp.DockApp {
    return .{ .name = name, .command = &.{name}, .y = y };
}

fn fixture(apps: []const dockapp.DockApp) !Model {
    var m = try Model.init(testing.allocator, .{ .apps = apps }, &.{}, 3);
    m.layout(1920, 1080, true, 0, .top_left);
    return m;
}

/// Centre of the tile of slot `i`.
fn centreOf(m: *const Model, i: usize) [2]i32 {
    const gi = m.slots.items[i].gi;
    return .{ gi.x_pos + @divTrunc(dock_model.tile, 2), gi.y_pos + @divTrunc(dock_model.tile, 2) };
}

fn clickAt(in: *Input, m: *Model, at: [2]i32, btn: Button, time: u32) Outcome {
    _ = in.button(m, at[0], at[1], btn, true, time);
    return in.button(m, at[0], at[1], btn, false, time + 20);
}

test "hit testing: a tile is hit, empty screen is not, a folded Clip has only its tile" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try fixture(&apps);
    defer m.deinit();
    const c = centreOf(&m, 0);
    const h = Input.hitTest(&m, c[0], c[1]).?;
    try testing.expect(h.icon == m.slots.items[0].gi);
    try testing.expect(Input.hitTest(&m, 5, 700) == null);

    const clip = m.currentClip();
    const main = clip.icons[0].?;
    try testing.expect(Input.hitTest(&m, main.x_pos + 5, main.y_pos + 30).?.icon == main);
}

test "hover: lights the tile under the pointer, and only then asks for a redraw" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};
    const c = centreOf(&m, 0);
    const first = in.motion(&m, c[0], c[1], 0);
    try testing.expect(first.consumed and first.redraw);
    try testing.expect(in.hover.?.icon == m.slots.items[0].gi);
    const same = in.motion(&m, c[0] + 1, c[1], 10);
    try testing.expect(same.consumed and !same.redraw);
    const away = in.motion(&m, 5, 700, 20);
    try testing.expect(!away.consumed and away.redraw and in.hover == null);

    const st = in.viewState(&m, m.scr.dock.?, .{ 0, 0 });
    try testing.expect(st.hover == null);
    _ = in.motion(&m, c[0], c[1], 30);
    try testing.expect(in.viewState(&m, m.scr.dock.?, .{ 0, 0 }).hover == m.slots.items[0].gi);
}

test "a double click starts a program, a single click does not; single_click does" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};
    const c = centreOf(&m, 0);

    var o = clickAt(&in, &m, c, .left, 1000);
    try testing.expectEqual(@as(usize, 0), o.effects.len);
    o = clickAt(&in, &m, c, .left, 1100);
    try testing.expectEqual(@as(usize, 1), o.effects.len);
    try testing.expectEqual(@as(usize, 0), o.effects.slice()[0].launch.slot);
    try testing.expect(!o.effects.slice()[0].launch.new_instance);

    // too slow: two single clicks
    o = clickAt(&in, &m, c, .left, 5000);
    o = clickAt(&in, &m, c, .left, 6000);
    try testing.expectEqual(@as(usize, 0), o.effects.len);

    in.settings.single_click = true;
    o = clickAt(&in, &m, c, .left, 9000);
    try testing.expectEqual(@as(usize, 1), o.effects.len);
}

test "a running program's tile shows its window; the middle button starts another" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    m.slots.items[0].running = true;
    var in: Input = .{};
    const c = centreOf(&m, 0);
    var o = clickAt(&in, &m, c, .left, 1000);
    try testing.expectEqual(@as(usize, 0), o.effects.slice()[0].activate);
    o = clickAt(&in, &m, c, .middle, 2000);
    try testing.expect(o.effects.slice()[0].launch.new_instance);
}

test "a program that is just starting is not started twice" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    m.slots.items[0].launching = true;
    var in: Input = .{ .settings = .{ .single_click = true } };
    const o = clickAt(&in, &m, centreOf(&m, 0), .left, 1000);
    try testing.expectEqual(@as(usize, 0), o.effects.len);
}

test "the right button asks for the menu on press and starts nothing" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};
    const c = centreOf(&m, 0);
    const o = in.button(&m, c[0], c[1], .right, true, 0);
    try testing.expect(o.consumed);
    try testing.expect(o.effects.slice()[0].menu.icon == m.slots.items[0].gi);
    try testing.expect(!in.pressing());
}

test "a press on nothing is not ours" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};
    const o = in.button(&m, 5, 700, .left, true, 0);
    try testing.expect(!o.consumed and !in.pressing());
}

test "the Clip: its arrows change the workspace, the rest folds it, the wheel scrolls it" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};
    const main = m.currentClip().icons[0].?;

    var o = clickAt(&in, &m, .{ main.x_pos + dock_model.tile - 4, main.y_pos + 4 }, .left, 100);
    try testing.expectEqual(@as(i32, 1), o.effects.slice()[0].workspace);
    o = clickAt(&in, &m, .{ main.x_pos + 4, main.y_pos + dock_model.tile - 4 }, .left, 300);
    try testing.expectEqual(@as(i32, -1), o.effects.slice()[0].workspace);

    const was = m.currentClip().collapsed;
    o = clickAt(&in, &m, .{ main.x_pos + @divTrunc(dock_model.tile, 2), main.y_pos + @divTrunc(dock_model.tile, 2) }, .left, 500);
    try testing.expect(m.currentClip().collapsed != was);
    try testing.expect(o.effects.slice()[0] == .save);

    o = in.scroll(&m, main.x_pos + 20, main.y_pos + 20, -1);
    try testing.expect(o.consumed);
    try testing.expectEqual(@as(i32, -1), o.effects.slice()[0].workspace);
}

test "dragging a tile to a free row of the Dock moves it" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};
    const gi = m.slots.items[0].gi;
    const from_y = gi.y_pos;
    const c = centreOf(&m, 0);

    _ = in.button(&m, c[0], c[1], .left, true, 0);
    // below the threshold nothing is dragged yet
    _ = in.motion(&m, c[0], c[1] + 2, 10);
    try testing.expect(!in.dragging());
    const o = in.motion(&m, c[0], c[1] + 3 * dock_model.tile, 20);
    try testing.expect(in.dragging() and o.consumed and o.redraw);
    try testing.expect(in.drop != null and !in.detached);

    // while it is in the air the plan has a gap and a floating tile
    const st = in.viewState(&m, m.scr.dock.?, .{ m.scr.dock.?.x_pos, 0 });
    try testing.expect(st.drag != null and st.drag.?.target != null);

    const up = in.button(&m, c[0], c[1] + 3 * dock_model.tile, .left, false, 30);
    try testing.expect(up.effects.slice()[0] == .save);
    try testing.expect(gi.y_pos != from_y);
    try testing.expect(!in.pressing() and in.drop == null);
}

test "pulling a tile out of every dock removes it; a locked tile stays" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), .{ .name = "b", .command = &.{"b"}, .y = 2, .locked = true } };
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};

    const c = centreOf(&m, 0);
    _ = in.button(&m, c[0], c[1], .left, true, 0);
    _ = in.motion(&m, 300, 700, 20);
    try testing.expect(in.detached);
    const st = in.viewState(&m, m.scr.dock.?, .{ m.scr.dock.?.x_pos, 0 });
    try testing.expect(st.drag.?.detached);
    const up = in.button(&m, 300, 700, .left, false, 30);
    try testing.expect(up.effects.slice()[0] == .save);
    try testing.expect(!m.slots.items[0].alive);

    const c2 = centreOf(&m, 1);
    _ = in.button(&m, c2[0], c2[1], .left, true, 100);
    _ = in.motion(&m, 300, 700, 120);
    const up2 = in.button(&m, 300, 700, .left, false, 130);
    try testing.expectEqual(@as(usize, 0), up2.effects.len);
    try testing.expect(m.slots.items[1].alive);
}

test "dragging the Dock's own tile asks to place the Dock; the Clip's, to move the Clip" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};

    const logo = m.scr.dock.?.icons[0].?;
    _ = in.button(&m, logo.x_pos + 10, logo.y_pos + 10, .left, true, 0);
    const o = in.motion(&m, 100, 400, 20);
    const pd = o.effects.slice()[0].place_dock;
    try testing.expectEqual(config.DockEdge.left, pd.edge);
    try testing.expectEqual(@as(i32, 390), pd.offset);
    const up = in.button(&m, 100, 400, .left, false, 30);
    try testing.expect(up.effects.slice()[0] == .save);

    const main = m.currentClip().icons[0].?;
    _ = in.button(&m, main.x_pos + 30, main.y_pos + 30, .left, true, 100);
    const o2 = in.motion(&m, 1800, 1000, 120);
    try testing.expectEqual(config.ClipCorner.bottom_right, o2.effects.slice()[0].place_clip);
}

test "auto fold: an auto-collapse Clip opens after the delay and folds after the pointer left" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    const clip = m.currentClip();
    clip.auto_collapse = true;
    clip.collapsed = true;
    var in: Input = .{};
    const main = clip.icons[0].?;

    _ = in.motion(&m, main.x_pos + 30, main.y_pos + 30, 1000);
    try testing.expectEqual(@as(?u32, 1600), in.deadline());
    try testing.expect(!in.tick(1599));
    try testing.expect(in.tick(1600));
    try testing.expect(!clip.collapsed);

    // leaving it folds it, coming back in time cancels that
    _ = in.motion(&m, 900, 900, 2000);
    try testing.expectEqual(@as(?u32, 3000), in.deadline());
    _ = in.motion(&m, main.x_pos + 30, main.y_pos + 30, 2500);
    try testing.expectEqual(@as(?u32, null), in.deadline());
    _ = in.leave(5000);
    try testing.expect(in.tick(6000));
    try testing.expect(clip.collapsed);
}

test "the timer does not fire in the middle of a drag, and survives the clock wrapping" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    const clip = m.currentClip();
    clip.auto_collapse = true;
    var in: Input = .{};
    const main = clip.icons[0].?;
    _ = in.motion(&m, main.x_pos + 30, main.y_pos + 30, 0xffff_fff0);
    _ = in.motion(&m, 900, 900, 0xffff_fff8);
    var expect: u32 = 0xffff_fff8;
    expect +%= 1000;
    try testing.expectEqual(@as(?u32, expect), in.deadline());
    try testing.expect(!in.tick(0x0000_0100));
    try testing.expect(in.tick(0x0000_0500));
}

test "reset forgets everything that points into the model" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var in: Input = .{};
    const c = centreOf(&m, 0);
    _ = in.button(&m, c[0], c[1], .left, true, 0);
    in.reset();
    try testing.expect(!in.pressing() and in.hover == null);
}
