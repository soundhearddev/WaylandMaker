// SPDX-License-Identifier: GPL-3.0
//
// What every tile of a dock looks like, and what changed since the last time.
// Pure data in, pure data out: no Wayland, no cairo, no allocation.
//
//   dock_model.zig   what is in the Dock (tiles, rows, running, launching)
//   dock_view.zig    what each tile LOOKS like: `Look`, and where it is: `Tile`
//   compositor       one scene node per tile; pixels rendered per `Look.key()`
//
// Why this layer exists: the compositor must not redraw a dock because the
// pointer moved over it. A tile's pixels are a function of its `Look` only
// (never of its position), so
//
//   * a rendered tile is cached by `Look.key()`: the same look is drawn once,
//     however many tiles share it and however often it comes back (hover
//     in, hover out);
//   * `diff` says which tiles appeared, vanished, moved or changed their
//     look, so a pointer move touches two nodes (the tile that lost the hover
//     and the one that got it), a workspace switch one, and a pass in which
//     nothing happened none.
//
// Everything that changes pixels is in `Look`. Anything that is not in it
// (a position, the time) cannot change a tile's pixels, which is the
// contract the compositor's cache relies on.

const std = @import("std");

const dock_model = @import("dock_model.zig");
const wdock = @import("wm_dock.zig");

const Model = dock_model.Model;
const Cells = dock_model.Cells;

pub const Arrow = dock_model.Arrow;

pub const TileKind = enum {
    /// The Dock's own tile (the logo).
    logo,
    /// The Clip's workspace tile: number, name, the two arrows.
    clip,
    /// A Drawer's own tile: a chevron.
    drawer,
    /// An application: its icon, and the marks for not running / launching /
    /// omnipresent.
    app,
    /// The recessed cell a dragged tile would land in.
    gap,
};

/// Everything that decides the pixels of one tile. Value type: two tiles with
/// an equal `Look` are drawn identically.
pub const Look = struct {
    kind: TileKind,
    /// Tile edge in pixels (the config's `dock_size`).
    size: i32,
    /// The pointer is on it (and no drag is going on).
    hot: bool = false,
    /// App tiles: a hash of what names the icon (its `icon`, else its app_id,
    /// else its command, else its name). 0: nothing to look up.
    icon_key: u64 = 0,
    /// A minimized window's tile: its program's system icon, no marks.
    mini: bool = false,
    /// Window Maker's three dots: docked, can be started, is not running.
    not_running: bool = false,
    /// The raster over the icon while the program starts.
    launching: bool = false,
    /// The folded corner of a Clip tile that follows the workspace.
    omnipresent: bool = false,
    /// Clip: the 0-based workspace shown, and a hash of its name (0: none).
    workspace: u32 = 0,
    name_key: u64 = 0,
    /// Clip: the arrow under the pointer (only when `hot`).
    arrow: Arrow = .none,
    /// Drawer: the chevron points left.
    chevron_left: bool = false,
    /// The tile is being dragged away and would be removed: drawn faded.
    faded: bool = false,

    /// Cache key. Distinct looks give distinct keys except for hash
    /// collisions (2^-64); a collision shows one tile with another's pixels
    /// until the next change, which is harmless.
    pub fn key(l: Look) u64 {
        var h = std.hash.Wyhash.init(0x646f636b); // "dock"
        std.hash.autoHash(&h, l);
        return h.final();
    }

    pub fn eql(a: Look, b: Look) bool {
        return std.meta.eql(a, b);
    }
};

/// One tile of the plan: which tile, where on the dock's surface, how it looks.
pub const Tile = struct {
    /// Identity that survives from plan to plan: the grid icon's address
    /// (the model owns it for as long as the tile exists), or `gap_id` /
    /// `floating_id` for the two tiles that belong to a drag.
    id: u64,
    /// Surface-local position of the top-left corner.
    x: i32,
    y: i32,
    look: Look,
    /// A tile in the air under the pointer: above everything else.
    floating: bool = false,
};

pub const gap_id: u64 = 1;
pub const floating_id: u64 = 2;

/// A tile being dragged.
pub const Drag = struct {
    /// The tile in the air.
    icon: *const wdock.Icon,
    /// The grid cell it would land in, if that is in this dock.
    target: ?[2]i32 = null,
    /// It snaps nowhere: letting go removes it. The tile stays where it was,
    /// faded.
    detached: bool = false,
    /// The pointer, surface-local.
    x: i32,
    y: i32,
};

/// What the plan needs besides the model.
pub const State = struct {
    /// Collapsed Clip / Drawer: only its own tile.
    only_main: bool = false,
    hover: ?*const wdock.Icon = null,
    hover_arrow: Arrow = .none,
    drag: ?Drag = null,
    /// The Clip's tile shows this (0-based) workspace and its name.
    workspace: u32 = 0,
    name: ?[]const u8 = null,
};

fn hashStr(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6b6579, s);
}

/// What names `app`'s icon: its icon key, else its app_id, else the program,
/// else the entry's name. (The compositor's icon cache resolves it.)
fn iconKeyOf(app: anytype) u64 {
    if (app.icon) |i| return hashStr(i);
    if (app.app_id) |a| return hashStr(a);
    if (app.command.len > 0) return hashStr(app.command[0]);
    return hashStr(app.name);
}

/// The look of the tile `gi`, or null for an icon the model has no slot for.
pub fn lookOf(m: *const Model, dock: *const wdock.Dock, gi: *const wdock.Icon, st: State) ?Look {
    const hot = st.hover == gi and st.drag == null;
    const size = dock_model.tile;
    if (gi.main) return switch (dock.kind) {
        .dock => .{ .kind = .logo, .size = size, .hot = hot },
        .clip => .{
            .kind = .clip,
            .size = size,
            // The tile is lit only when the pointer is on it and not on an arrow.
            .hot = hot and st.hover_arrow == .none,
            .workspace = st.workspace,
            .name_key = if (st.name) |n| hashStr(n) else 0,
            .arrow = if (hot) st.hover_arrow else .none,
        },
        .drawer => blk: {
            // The chevron points where the Drawer opens (away from it when
            // it is open).
            const left_open = dock.on_right_side;
            break :blk .{
                .kind = .drawer,
                .size = size,
                .hot = hot,
                .chevron_left = if (st.only_main) left_open else !left_open,
            };
        },
    };
    const s = m.slotOf(gi) orelse return null;
    const mini = s.app.mini_window != 0;
    return .{
        .kind = .app,
        .size = size,
        .hot = hot,
        .icon_key = iconKeyOf(s.app),
        .mini = mini,
        // Only an entry that can be started says "not running".
        .not_running = !mini and !s.running and s.app.command.len > 0,
        .launching = s.launching,
        .omnipresent = gi.omnipresent,
    };
}

/// The tiles of `dock` in drawing order (the gap first, the tile in the air
/// last), written to `buf`. `cells` is the dock's surface in grid cells
/// (`dock_model.cellsOf`). Returns the used part of `buf`; a dock with more
/// tiles than `buf` holds is cut (see `maxTiles`, `needed`).
pub fn plan(m: *const Model, dock: *const wdock.Dock, cells: Cells, st: State, buf: []Tile) []Tile {
    var n: usize = 0;
    const size = dock_model.tile;

    if (st.drag) |d| if (d.target) |t| {
        if (n < buf.len) {
            const p = dock_model.cellPx(cells, t[0], t[1]);
            buf[n] = .{ .id = gap_id, .x = p[0], .y = p[1], .look = .{ .kind = .gap, .size = size } };
            n += 1;
        }
    };

    for (dock.icons) |maybe| {
        const gi = maybe orelse continue;
        if (st.only_main and !gi.main) continue;
        const lifted = if (st.drag) |d| d.icon == gi and !d.detached else false;
        if (lifted) continue;
        var look = lookOf(m, dock, gi, st) orelse continue;
        if (st.drag) |d| if (d.icon == gi and d.detached) {
            look.faded = true;
        };
        if (n == buf.len) break;
        const p = dock_model.cellPx(cells, gi.xindex, gi.yindex);
        buf[n] = .{ .id = @intFromPtr(gi), .x = p[0], .y = p[1], .look = look };
        n += 1;
    }

    // The tile in the air: lit, under the pointer, kept on the surface.
    if (st.drag) |d| if (!d.detached and n < buf.len) {
        const w = cells.cols() * size;
        const h = cells.rows() * size;
        const fx = std.math.clamp(d.x - @divTrunc(size, 2), 0, @max(0, w - size));
        const fy = std.math.clamp(d.y - @divTrunc(size, 2), 0, @max(0, h - size));
        var air: State = st;
        air.hover = d.icon; // lit
        air.drag = null;
        if (lookOf(m, dock, d.icon, air)) |look| {
            buf[n] = .{ .id = floating_id, .x = fx, .y = fy, .look = look, .floating = true };
            n += 1;
        }
    };
    return buf[0..n];
}

/// A `buf` for `plan` that is enough for any dock: a dock has one cell per
/// row of its output (`Dock.icons.len`), so this covers outputs up to
/// 510 rows high (32640 px at 64 px tiles). For an unusual size use
/// `needed`.
pub const maxTiles = 512;

/// Room `plan` may need for `dock`: every cell, the gap, the tile in the air.
pub fn needed(dock: *const wdock.Dock) usize {
    return dock.icons.len + 2;
}

/// What changed between two plans of the same dock. `sink` has:
///   add(tile)       a tile that was not there
///   remove(id)      a tile that is gone
///   move(tile)      the same tile, somewhere else (or in the air / back)
///   restyle(tile)   the same tile, another look: needs its pixels
/// A tile that moved and changed gets both. Unchanged tiles get nothing.
pub fn diff(prev: []const Tile, next: []const Tile, sink: anytype) void {
    for (next) |t| {
        const old = find(prev, t.id) orelse {
            sink.add(t);
            continue;
        };
        if (old.x != t.x or old.y != t.y or old.floating != t.floating) sink.move(t);
        if (!old.look.eql(t.look)) sink.restyle(t);
    }
    for (prev) |t| {
        if (find(next, t.id) == null) sink.remove(t.id);
    }
}

fn find(tiles: []const Tile, id: u64) ?Tile {
    for (tiles) |t| if (t.id == id) return t;
    return null;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const dockapp = @import("dockapp.zig");

fn mk(comptime name: []const u8, y: i32) dockapp.DockApp {
    return .{ .name = name, .command = &.{name}, .y = y };
}

/// Records what `diff` reports.
const Rec = struct {
    added: usize = 0,
    removed: usize = 0,
    moved: usize = 0,
    restyled: usize = 0,
    last_restyled: u64 = 0,

    pub fn add(r: *Rec, _: Tile) void {
        r.added += 1;
    }
    pub fn remove(r: *Rec, _: u64) void {
        r.removed += 1;
    }
    pub fn move(r: *Rec, _: Tile) void {
        r.moved += 1;
    }
    pub fn restyle(r: *Rec, t: Tile) void {
        r.restyled += 1;
        r.last_restyled = t.id;
    }
    fn quiet(r: Rec) bool {
        return r.added + r.removed + r.moved + r.restyled == 0;
    }
};

fn changes(prev: []const Tile, next: []const Tile) Rec {
    var r: Rec = .{};
    diff(prev, next, &r);
    return r;
}

fn dockCells(m: *const Model) Cells {
    return dock_model.cellsOf(m.scr.dock.?, false, false);
}

test "plan: the logo and the tiles, at their cells, looking like what they are" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 2);
    defer m.deinit();
    m.slots.items[0].running = true;

    var buf: [maxTiles]Tile = undefined;
    const d = m.scr.dock.?;
    const tiles = plan(&m, d, dockCells(&m), .{}, &buf);
    try testing.expectEqual(@as(usize, 3), tiles.len);
    try testing.expectEqual(TileKind.logo, tiles[0].look.kind);
    try testing.expectEqual(@as(i32, 0), tiles[0].y);
    try testing.expectEqual(dock_model.tile, tiles[1].y);
    try testing.expectEqual(TileKind.app, tiles[1].look.kind);
    // a runs, b does not: only b shows the dots.
    try testing.expect(!tiles[1].look.not_running);
    try testing.expect(tiles[2].look.not_running);
    // Different programs: different icons.
    try testing.expect(tiles[1].look.icon_key != tiles[2].look.icon_key);
    try testing.expect(tiles[1].look.key() != tiles[2].look.key());
}

test "a tile's look does not depend on where it is, and equal looks share a key" {
    const apps = [_]dockapp.DockApp{
        .{ .name = "x", .command = &.{"term"}, .y = 1 },
        .{ .name = "y", .command = &.{"term"}, .y = 5 },
    };
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 2);
    defer m.deinit();
    var buf: [maxTiles]Tile = undefined;
    const tiles = plan(&m, m.scr.dock.?, dockCells(&m), .{}, &buf);
    // Same program, same state: one set of pixels for both.
    try testing.expect(tiles[1].look.eql(tiles[2].look));
    try testing.expectEqual(tiles[1].look.key(), tiles[2].look.key());
    try testing.expect(tiles[1].y != tiles[2].y);
}

test "the pointer moving from one tile to the next changes exactly two tiles" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 2);
    defer m.deinit();
    const d = m.scr.dock.?;
    const a = m.slots.items[0].gi;
    const b = m.slots.items[1].gi;

    var b0: [maxTiles]Tile = undefined;
    var b1: [maxTiles]Tile = undefined;
    var b2: [maxTiles]Tile = undefined;
    const idle = plan(&m, d, dockCells(&m), .{}, &b0);
    try testing.expect(changes(idle, plan(&m, d, dockCells(&m), .{}, &b1)).quiet());

    const on_a = plan(&m, d, dockCells(&m), .{ .hover = a }, &b1);
    var r = changes(idle, on_a);
    try testing.expectEqual(@as(usize, 1), r.restyled);
    try testing.expectEqual(@as(usize, 0), r.moved + r.added + r.removed);

    const on_b = plan(&m, d, dockCells(&m), .{ .hover = b }, &b2);
    r = changes(on_a, on_b);
    try testing.expectEqual(@as(usize, 2), r.restyled);

    // Back to idle: the look of the first frame returns, so does its key
    // (the compositor finds it in its cache).
    var b3: [maxTiles]Tile = undefined;
    const idle2 = plan(&m, d, dockCells(&m), .{}, &b3);
    for (idle, idle2) |x, y| try testing.expectEqual(x.look.key(), y.look.key());
}

test "a program starting or ending restyles its tile only" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 2);
    defer m.deinit();
    const d = m.scr.dock.?;
    var b0: [maxTiles]Tile = undefined;
    var b1: [maxTiles]Tile = undefined;
    const before = plan(&m, d, dockCells(&m), .{}, &b0);

    m.slots.items[1].launching = true;
    const during = plan(&m, d, dockCells(&m), .{}, &b1);
    var r = changes(before, during);
    try testing.expectEqual(@as(usize, 1), r.restyled);
    try testing.expectEqual(@as(u64, @intFromPtr(m.slots.items[1].gi)), r.last_restyled);

    m.slots.items[1].launching = false;
    m.slots.items[1].running = true;
    var b2: [maxTiles]Tile = undefined;
    r = changes(during, plan(&m, d, dockCells(&m), .{}, &b2));
    try testing.expectEqual(@as(usize, 1), r.restyled); // the raster goes, the dots stay off
    try testing.expect(!b2[2].look.not_running and !b2[2].look.launching);
}

test "the Clip tile follows the workspace and its name; the arrow lights only the arrow" {
    var m = try Model.init(testing.allocator, .{}, &.{ "one", "two" }, 2);
    defer m.deinit();
    const clip = m.currentClip();
    const cells = dock_model.cellsOf(clip, false, false);
    const main = clip.icons[0].?;

    var b0: [maxTiles]Tile = undefined;
    var b1: [maxTiles]Tile = undefined;
    const ws0 = plan(&m, clip, cells, .{ .workspace = 0, .name = "one" }, &b0);
    const ws1 = plan(&m, clip, cells, .{ .workspace = 1, .name = "two" }, &b1);
    try testing.expectEqual(TileKind.clip, ws0[0].look.kind);
    try testing.expect(!ws0[0].look.eql(ws1[0].look));
    try testing.expectEqual(@as(usize, 1), changes(ws0, ws1).restyled);

    // On the tile: lit. On an arrow: the arrow is lit, the tile is not.
    var b2: [maxTiles]Tile = undefined;
    const on_tile = plan(&m, clip, cells, .{ .hover = main, .workspace = 0, .name = "one" }, &b2);
    try testing.expect(on_tile[0].look.hot and on_tile[0].look.arrow == .none);
    var b3: [maxTiles]Tile = undefined;
    const on_arrow = plan(&m, clip, cells, .{ .hover = main, .hover_arrow = .next, .workspace = 0, .name = "one" }, &b3);
    try testing.expect(!on_arrow[0].look.hot and on_arrow[0].look.arrow == .next);
    // The arrow of a tile the pointer is not on does not light.
    var b4: [maxTiles]Tile = undefined;
    const stray = plan(&m, clip, cells, .{ .hover_arrow = .next, .workspace = 0, .name = "one" }, &b4);
    try testing.expect(stray[0].look.arrow == .none);
}

test "a collapsed Clip is only its own tile" {
    const apps = [_]dockapp.DockApp{.{ .name = "w", .command = &.{"w"}, .place = .clip, .workspace = 0, .x = 1 }};
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 1);
    defer m.deinit();
    const clip = m.currentClip();
    var buf: [maxTiles]Tile = undefined;
    const open = plan(&m, clip, dock_model.cellsOf(clip, false, false), .{}, &buf);
    try testing.expectEqual(@as(usize, 2), open.len);
    var buf2: [maxTiles]Tile = undefined;
    const shut = plan(&m, clip, dock_model.cellsOf(clip, true, false), .{ .only_main = true }, &buf2);
    try testing.expectEqual(@as(usize, 1), shut.len);
    try testing.expectEqual(TileKind.clip, shut[0].look.kind);
}

test "a drag: the tile leaves its cell, floats under the pointer, and its target shows a gap" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 2);
    defer m.deinit();
    const d = m.scr.dock.?;
    const cells = dock_model.cellsOf(d, false, true);
    const a = m.slots.items[0].gi;

    var b0: [maxTiles]Tile = undefined;
    const idle = plan(&m, d, cells, .{}, &b0);
    var b1: [maxTiles]Tile = undefined;
    const dragging = plan(&m, d, cells, .{ .hover = a, .drag = .{ .icon = a, .target = .{ 0, 4 }, .x = 20, .y = 90 } }, &b1);

    try testing.expectEqual(gap_id, dragging[0].id);
    try testing.expectEqual(TileKind.gap, dragging[0].look.kind);
    try testing.expect(dragging[dragging.len - 1].floating);
    try testing.expect(dragging[dragging.len - 1].look.hot);
    // a is not at its cell any more; the others are not lit during a drag.
    for (dragging) |t| if (t.id == @as(u64, @intFromPtr(a)) and !t.floating) return error.TestUnexpectedResult;
    for (dragging) |t| if (!t.floating and t.look.kind != .gap) try testing.expect(!t.look.hot);

    // The same drag again, the pointer a bit further: only the floating
    // tile moved.
    var b2: [maxTiles]Tile = undefined;
    const moved = plan(&m, d, cells, .{ .hover = a, .drag = .{ .icon = a, .target = .{ 0, 4 }, .x = 24, .y = 96 } }, &b2);
    const r = changes(dragging, moved);
    try testing.expectEqual(@as(usize, 1), r.moved);
    try testing.expectEqual(@as(usize, 0), r.restyled + r.added + r.removed);

    // Letting go without a target: back to the first plan.
    var b3: [maxTiles]Tile = undefined;
    const done = plan(&m, d, cells, .{}, &b3);
    for (idle, done) |x, y| {
        try testing.expectEqual(x.id, y.id);
        try testing.expect(x.look.eql(y.look));
    }
}

test "a drag that snaps nowhere fades the tile in place and floats nothing" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 2);
    defer m.deinit();
    const d = m.scr.dock.?;
    const a = m.slots.items[0].gi;
    var buf: [maxTiles]Tile = undefined;
    const tiles = plan(&m, d, dock_model.cellsOf(d, false, true), .{ .drag = .{ .icon = a, .detached = true, .x = 500, .y = 500 } }, &buf);
    try testing.expectEqual(@as(usize, 2), tiles.len);
    try testing.expect(tiles[1].look.faded);
    for (tiles) |t| try testing.expect(!t.floating);
}

test "the floating tile stays on the surface" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{}, 2);
    defer m.deinit();
    const d = m.scr.dock.?;
    const cells = dock_model.cellsOf(d, false, true);
    const a = m.slots.items[0].gi;
    var buf: [maxTiles]Tile = undefined;
    const t = plan(&m, d, cells, .{ .drag = .{ .icon = a, .x = -500, .y = 9999 } }, &buf);
    const air = t[t.len - 1];
    try testing.expect(air.floating);
    try testing.expectEqual(@as(i32, 0), air.x);
    try testing.expect(air.y + dock_model.tile <= cells.rows() * dock_model.tile);
}

test "diff: tiles that appear, vanish or move are reported once, unchanged ones not at all" {
    const look: Look = .{ .kind = .app, .size = 64 };
    const a: Tile = .{ .id = 10, .x = 0, .y = 0, .look = look };
    const b: Tile = .{ .id = 11, .x = 0, .y = 64, .look = look };
    var b_moved = b;
    b_moved.y = 128;
    var a_new = a;
    a_new.look.launching = true;

    var r = changes(&.{ a, b }, &.{ a, b });
    try testing.expect(r.quiet());
    r = changes(&.{a}, &.{ a, b });
    try testing.expectEqual(@as(usize, 1), r.added);
    r = changes(&.{ a, b }, &.{a});
    try testing.expectEqual(@as(usize, 1), r.removed);
    r = changes(&.{ a, b }, &.{ a, b_moved });
    try testing.expectEqual(@as(usize, 1), r.moved);
    try testing.expectEqual(@as(usize, 0), r.restyled);
    r = changes(&.{ a, b }, &.{ a_new, b_moved });
    try testing.expectEqual(@as(usize, 1), r.moved);
    try testing.expectEqual(@as(usize, 1), r.restyled);
    r = changes(&.{}, &.{});
    try testing.expect(r.quiet());
}

test "every field of a Look changes its key" {
    const base: Look = .{ .kind = .app, .size = 64 };
    const variants = [_]Look{
        .{ .kind = .clip, .size = 64 },
        .{ .kind = .app, .size = 48 },
        .{ .kind = .app, .size = 64, .hot = true },
        .{ .kind = .app, .size = 64, .icon_key = 7 },
        .{ .kind = .app, .size = 64, .mini = true },
        .{ .kind = .app, .size = 64, .not_running = true },
        .{ .kind = .app, .size = 64, .launching = true },
        .{ .kind = .app, .size = 64, .omnipresent = true },
        .{ .kind = .app, .size = 64, .workspace = 1 },
        .{ .kind = .app, .size = 64, .name_key = 9 },
        .{ .kind = .app, .size = 64, .arrow = .next },
        .{ .kind = .app, .size = 64, .chevron_left = true },
        .{ .kind = .app, .size = 64, .faded = true },
    };
    for (variants, 0..) |v, i| {
        try testing.expect(v.key() != base.key());
        for (variants[i + 1 ..]) |w| try testing.expect(v.key() != w.key());
    }
}

test "a Drawer's chevron points where it opens, and the other way when it is open" {
    const drawers = [_]dockapp.DrawerInfo{.{ .row = 2 }};
    var m = try Model.init(testing.allocator, .{ .drawers = &drawers }, &.{}, 2);
    defer m.deinit();
    m.layout(1000, 800, true, 0, .top_left);
    const dr = m.scr.drawers.items[0];
    const main = dr.icons[0].?;

    var b0: [maxTiles]Tile = undefined;
    var b1: [maxTiles]Tile = undefined;
    const collapsed = plan(&m, dr, dock_model.cellsOf(dr, true, false), .{ .only_main = true }, &b0);
    const open = plan(&m, dr, dock_model.cellsOf(dr, false, false), .{}, &b1);
    _ = main;
    try testing.expectEqual(TileKind.drawer, collapsed[0].look.kind);
    try testing.expect(collapsed[0].look.chevron_left != open[0].look.chevron_left);
}

test "maxTiles covers the docks of real outputs" {
    var m = try Model.init(testing.allocator, .{}, &.{}, 2);
    defer m.deinit();
    m.layout(1920, 8640, true, 0, .top_left); // an 8K-high output
    try testing.expect(needed(m.scr.dock.?) <= maxTiles);
}
