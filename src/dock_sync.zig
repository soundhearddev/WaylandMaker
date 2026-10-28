// SPDX-License-Identifier: GPL-3.0
//
// From the Dock model to what is on the screen, and nothing else: which
// surfaces (the Dock, the current Clip, the Drawers) exist, where each one is,
// above or below the windows, and which tiles are on it. It runs after every
// change of the model or of the pointer state, plans each surface
// (dock_view.plan), compares the plan with the previous one (dock_view.diff)
// and tells a backend only what changed.
//
// The backend is a type parameter, so that this logic is tested without a
// compositor (see the tests) and the wlroots code (dock_scene.zig) is only
// what has to be wlroots: making scene nodes and drawing into them. A backend
// provides
//
//     Group, Node                       its handles (pointer sized or smaller)
//     createGroup(*B) !Group            one per surface (scene tree)
//     destroyGroup(*B, Group)           with every tile in it
//     placeGroup(*B, Group, x, y)       global position of the surface
//     raiseGroup(*B, Group, bool)       above (true) or below the windows
//     createTile(*B, Group, Tile, Content) !Node
//     updateTile(*B, Node, Tile, Content)   position and / or look changed
//     destroyTile(*B, Node)
//
// A tile's coordinates are relative to its group. The tile in the air of a
// drag (`Tile.floating`) is above the rest of its group and may lie outside
// it: groups are not clipped.

const std = @import("std");
const log = std.log.scoped(.dock);

const dock_input = @import("dock_input.zig");
const dock_model = @import("dock_model.zig");
const dock_view = @import("dock_view.zig");
const wdock = @import("wm_dock.zig");

const Model = dock_model.Model;
const Tile = dock_view.Tile;

/// What a look names by a hash and the backend needs to draw it.
pub const Content = struct {
    /// App tiles: the slot (icon, name, command ...). null for the others.
    slot: ?*const dock_model.Slot = null,
    /// The Clip's workspace name.
    name: ?[]const u8 = null,
};

pub const Options = struct {
    /// Global position of the output the model lives on.
    origin: [2]i32 = .{ 0, 0 },
    dock_visible: bool = true,
    clip_visible: bool = true,
    dock_level: dock_model.Level = .top,
    clip_level: dock_model.Level = .top,
};

pub fn Sync(comptime B: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        backend: *B,
        surfaces: std.ArrayList(Surface) = .empty,

        const Surface = struct {
            dock: *wdock.Dock,
            group: B.Group,
            tiles: std.AutoHashMap(u64, B.Node),
            prev: std.ArrayList(Tile) = .empty,
            pos: [2]i32,
            raised: bool,
        };

        pub fn init(gpa: std.mem.Allocator, backend: *B) Self {
            return .{ .gpa = gpa, .backend = backend };
        }

        pub fn deinit(s: *Self) void {
            s.dropAll();
            s.surfaces.deinit(s.gpa);
        }

        /// Drop every surface (the model they were made from is gone).
        pub fn dropAll(s: *Self) void {
            while (s.surfaces.items.len > 0) s.dropSurface(s.surfaces.items.len - 1);
        }

        /// Forget the tiles, not the surfaces: the next `update` draws every
        /// tile again (the look of the world changed: another scale, a new
        /// font).
        pub fn invalidate(s: *Self) void {
            for (s.surfaces.items) |*surf| surf.prev.clearRetainingCapacity();
        }

        /// How many tiles are on show (for the dump and the tests).
        pub fn tileCount(s: *const Self) usize {
            var n: usize = 0;
            for (s.surfaces.items) |*surf| n += surf.tiles.count();
            return n;
        }

        pub fn surfaceCount(s: *const Self) usize {
            return s.surfaces.items.len;
        }

        // ---- the update ---------------------------------------------------------

        /// Make the screen show `m` as `in` says. False: nothing is shown (no
        /// Dock, no Clip), so the Dock takes no room.
        pub fn update(s: *Self, m: *Model, in: *const dock_input.Input, opt: Options) bool {
            var wanted: [2 + dock_model.max_drawers]*wdock.Dock = undefined;
            var levels: [wanted.len]dock_model.Level = undefined;
            var n: usize = 0;
            if (opt.dock_visible) if (m.scr.dock) |d| {
                wanted[n] = d;
                levels[n] = opt.dock_level;
                n += 1;
            };
            if (opt.clip_visible) {
                wanted[n] = m.currentClip();
                levels[n] = opt.clip_level;
                n += 1;
            }
            if (opt.dock_visible) for (m.scr.drawers.items) |d| {
                if (n >= wanted.len) break;
                wanted[n] = d;
                levels[n] = opt.dock_level;
                n += 1;
            };

            // Surfaces that are not wanted any more: another workspace's
            // Clip, a Drawer that was removed, a Dock that was switched off.
            var i = s.surfaces.items.len;
            while (i > 0) {
                i -= 1;
                const dock = s.surfaces.items[i].dock;
                const keep = for (wanted[0..n]) |w| {
                    if (w == dock) break true;
                } else false;
                if (!keep) s.dropSurface(i);
            }

            for (wanted[0..n], levels[0..n]) |d, level| s.syncSurface(m, in, opt, d, level);
            return n > 0;
        }

        fn find(s: *Self, d: *const wdock.Dock) ?*Surface {
            for (s.surfaces.items) |*surf| if (surf.dock == d) return surf;
            return null;
        }

        fn dropSurface(s: *Self, index: usize) void {
            var surf = s.surfaces.orderedRemove(index);
            // The group takes its tiles with it.
            s.backend.destroyGroup(surf.group);
            surf.tiles.deinit();
            surf.prev.deinit(s.gpa);
        }

        fn raisedFor(in: *const dock_input.Input, d: *const wdock.Dock, level: dock_model.Level) bool {
            return switch (level) {
                .top => true,
                .normal => false,
                // up while the pointer is on it or a tile of it is being dragged
                .auto => in.inside == d or (if (in.press) |p| p.hit.dock == d else false),
            };
        }

        fn syncSurface(s: *Self, m: *Model, in: *const dock_input.Input, opt: Options, d: *wdock.Dock, level: dock_model.Level) void {
            const only_main = d.kind != .dock and d.collapsed;
            const cells = dock_model.cellsOf(d, only_main, false);
            const main = d.icons[0] orelse return;
            // The surface's top left corner, output-local: where the cell
            // (minx, miny) is.
            const local: [2]i32 = .{
                main.x_pos + (cells.minx - main.xindex) * dock_model.tile,
                main.y_pos + (cells.miny - main.yindex) * dock_model.tile,
            };
            const pos: [2]i32 = .{ opt.origin[0] + local[0], opt.origin[1] + local[1] };
            const raised = raisedFor(in, d, level);

            const surf = s.find(d) orelse blk: {
                const group = s.backend.createGroup() catch |err| {
                    log.warn("no scene tree for a dock surface: {t}", .{err});
                    return;
                };
                s.surfaces.append(s.gpa, .{
                    .dock = d,
                    .group = group,
                    .tiles = .init(s.gpa),
                    .pos = .{ std.math.minInt(i32), 0 },
                    .raised = !raised,
                }) catch {
                    s.backend.destroyGroup(group);
                    return;
                };
                break :blk &s.surfaces.items[s.surfaces.items.len - 1];
            };

            if (!std.meta.eql(surf.pos, pos)) {
                s.backend.placeGroup(surf.group, pos[0], pos[1]);
                surf.pos = pos;
            }
            if (surf.raised != raised) {
                s.backend.raiseGroup(surf.group, raised);
                surf.raised = raised;
            }

            const st = in.viewState(m, d, local);
            var buf: [dock_view.maxTiles]Tile = undefined;
            const next = dock_view.plan(m, d, cells, st, &buf);

            var ad: Adapter = .{ .s = s, .surf = surf, .m = m, .st = st };
            dock_view.diff(surf.prev.items, next, &ad);

            surf.prev.clearRetainingCapacity();
            if (ad.failed) return; // next time everything is tried again
            surf.prev.appendSlice(s.gpa, next) catch {};
        }

        /// What `dock_view.diff` calls; turns each change into a backend call.
        const Adapter = struct {
            s: *Self,
            surf: *Surface,
            m: *const Model,
            st: dock_view.State,
            failed: bool = false,

            fn content(a: *const Adapter, t: Tile) Content {
                var c: Content = .{};
                switch (t.id) {
                    dock_view.gap_id => {},
                    dock_view.floating_id => if (a.st.drag) |d| {
                        c.slot = a.m.slotOf(d.icon);
                    },
                    else => {
                        const gi: *const wdock.Icon = @ptrFromInt(@as(usize, @intCast(t.id)));
                        c.slot = a.m.slotOf(gi);
                    },
                }
                if (t.look.kind == .clip) c.name = a.st.name;
                return c;
            }

            fn put(a: *Adapter, t: Tile) void {
                const c = a.content(t);
                if (a.surf.tiles.get(t.id)) |node| {
                    a.s.backend.updateTile(node, t, c);
                    return;
                }
                const node = a.s.backend.createTile(a.surf.group, t, c) catch |err| {
                    log.warn("no tile: {t}", .{err});
                    a.failed = true;
                    return;
                };
                a.surf.tiles.put(t.id, node) catch {
                    a.s.backend.destroyTile(node);
                    a.failed = true;
                };
            }

            pub fn add(a: *Adapter, t: Tile) void {
                a.put(t);
            }
            pub fn move(a: *Adapter, t: Tile) void {
                a.put(t);
            }
            pub fn restyle(a: *Adapter, t: Tile) void {
                a.put(t);
            }
            pub fn remove(a: *Adapter, id: u64) void {
                if (a.surf.tiles.fetchRemove(id)) |kv| a.s.backend.destroyTile(kv.value);
            }
        };
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const dockapp = @import("dockapp.zig");

/// A backend that only counts and remembers.
const Mock = struct {
    groups_made: usize = 0,
    groups_gone: usize = 0,
    tiles_made: usize = 0,
    tiles_gone: usize = 0,
    updates: usize = 0,
    raise_calls: usize = 0,
    last_place: [2]i32 = .{ 0, 0 },
    raised: bool = false,
    last_content_slot: ?*const dock_model.Slot = null,
    last_name: ?[]const u8 = null,
    fail_tiles: bool = false,
    next_id: usize = 1,

    pub const Group = usize;
    pub const Node = usize;

    pub fn createGroup(b: *Mock) !Group {
        b.groups_made += 1;
        return b.groups_made;
    }
    pub fn destroyGroup(b: *Mock, _: Group) void {
        b.groups_gone += 1;
    }
    pub fn placeGroup(b: *Mock, _: Group, x: i32, y: i32) void {
        b.last_place = .{ x, y };
    }
    pub fn raiseGroup(b: *Mock, _: Group, up: bool) void {
        b.raise_calls += 1;
        b.raised = up;
    }
    pub fn createTile(b: *Mock, _: Group, _: Tile, c: Content) !Node {
        if (b.fail_tiles) return error.OutOfMemory;
        b.tiles_made += 1;
        b.last_content_slot = c.slot;
        b.last_name = c.name;
        b.next_id += 1;
        return b.next_id;
    }
    pub fn updateTile(b: *Mock, _: Node, _: Tile, c: Content) void {
        b.updates += 1;
        b.last_content_slot = c.slot;
    }
    pub fn destroyTile(b: *Mock, _: Node) void {
        b.tiles_gone += 1;
    }
};

fn mk(comptime name: []const u8, y: i32) dockapp.DockApp {
    return .{ .name = name, .command = &.{name}, .y = y };
}

fn fixture(apps: []const dockapp.DockApp) !Model {
    var m = try Model.init(testing.allocator, .{ .apps = apps }, &.{}, 3);
    m.layout(1920, 1080, true, 0, .top_left);
    return m;
}

test "first update: Dock, Clip and their tiles appear, placed at the output's origin plus their spot" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};

    try testing.expect(sync.update(&m, &in, .{ .origin = .{ 100, 50 } }));
    try testing.expectEqual(@as(usize, 2), sync.surfaceCount()); // Dock and Clip
    // logo + 2 apps, and the Clip's tile (+ its apps: none here)
    try testing.expect(mock.tiles_made >= 4);
    try testing.expectEqual(mock.tiles_made, sync.tileCount());
    try testing.expect(mock.raised);
}

test "an update that changes nothing does nothing" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{});
    const made = mock.tiles_made;
    const raises = mock.raise_calls;
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(made, mock.tiles_made);
    try testing.expectEqual(@as(usize, 0), mock.updates);
    try testing.expectEqual(raises, mock.raise_calls);
}

test "hover restyles exactly one tile" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{});

    const gi = m.slots.items[0].gi;
    _ = in.motion(&m, gi.x_pos + 30, gi.y_pos + 30, 0);
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(@as(usize, 1), mock.updates);
    // the backend was told which slot the tile shows
    try testing.expect(mock.last_content_slot == &m.slots.items[0]);
}

test "a removed tile is destroyed; a tile in the air is a tile of its own, the gap too" {
    const apps = [_]dockapp.DockApp{ mk("a", 1), mk("b", 2) };
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{});
    const before = sync.tileCount();

    // drag "a" to a free row
    const gi = m.slots.items[0].gi;
    const c = [2]i32{ gi.x_pos + 30, gi.y_pos + 30 };
    _ = in.button(&m, c[0], c[1], .left, true, 0);
    _ = in.motion(&m, c[0], c[1] + 4 * dock_model.tile, 20);
    _ = sync.update(&m, &in, .{});
    // the dragged tile is replaced by the floating one, and a gap appears
    try testing.expectEqual(before + 1, sync.tileCount());

    _ = in.button(&m, c[0], c[1] + 4 * dock_model.tile, .left, false, 40);
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(before, sync.tileCount());

    // taking a tile away from the model removes its node
    try testing.expect(m.removeSlot(1));
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(before - 1, sync.tileCount());
    try testing.expect(mock.tiles_gone >= 2);
}

test "moving the Dock moves its group, not its tiles" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{});
    const made = mock.tiles_made;

    m.layout(1920, 1080, false, 200, .top_left); // Dock to the left, lower down
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(made, mock.tiles_made);
    try testing.expectEqual(@as(usize, 0), mock.updates);
}

test "switching workspace swaps the Clip's surface; dock_visible = false removes the Dock and its Drawers" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(@as(usize, 2), sync.surfaceCount());

    m.setWorkspace(1);
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(@as(usize, 2), sync.surfaceCount());
    try testing.expectEqual(@as(usize, 1), mock.groups_gone);

    try testing.expect(sync.update(&m, &in, .{ .dock_visible = false }));
    try testing.expectEqual(@as(usize, 1), sync.surfaceCount());
    try testing.expect(!sync.update(&m, &in, .{ .dock_visible = false, .clip_visible = false }));
    try testing.expectEqual(@as(usize, 0), sync.surfaceCount());
    try testing.expectEqual(@as(usize, 0), sync.tileCount());
}

test "the Clip's tile gets the workspace's name" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try Model.init(testing.allocator, .{ .apps = &apps }, &.{ "Mail", "Web" }, 2);
    defer m.deinit();
    m.layout(1920, 1080, true, 0, .top_left);
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{ .dock_visible = false });
    try testing.expectEqualStrings("Mail", mock.last_name.?);
}

test "the level: normal stays below, top above, auto only while the pointer is on it" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};

    _ = sync.update(&m, &in, .{ .dock_level = .normal, .clip_level = .normal });
    try testing.expect(!mock.raised);

    _ = sync.update(&m, &in, .{ .dock_level = .auto, .clip_level = .normal });
    try testing.expect(!mock.raised);
    const gi = m.slots.items[0].gi;
    _ = in.motion(&m, gi.x_pos + 30, gi.y_pos + 30, 0);
    _ = sync.update(&m, &in, .{ .dock_level = .auto, .clip_level = .normal });
    try testing.expect(mock.raised);
    _ = in.leave(10);
    _ = sync.update(&m, &in, .{ .dock_level = .auto, .clip_level = .normal });
    try testing.expect(!mock.raised);
}

test "a tile that could not be made is tried again at the next update" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{ .fail_tiles = true };
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(@as(usize, 0), sync.tileCount());
    mock.fail_tiles = false;
    _ = sync.update(&m, &in, .{});
    try testing.expect(sync.tileCount() >= 3);
}

test "invalidate draws everything again, without making a second node for a tile" {
    const apps = [_]dockapp.DockApp{mk("a", 1)};
    var m = try fixture(&apps);
    defer m.deinit();
    var mock: Mock = .{};
    var sync = Sync(Mock).init(testing.allocator, &mock);
    defer sync.deinit();
    var in: dock_input.Input = .{};
    _ = sync.update(&m, &in, .{});
    const made = mock.tiles_made;
    sync.invalidate();
    _ = sync.update(&m, &in, .{});
    try testing.expectEqual(made, mock.tiles_made);
    try testing.expectEqual(made, mock.updates);
}
