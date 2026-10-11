// SPDX-License-Identifier: 0BSD
//
// wdock: the logic of Window Maker's dock.c (WDock / WAppIcon), ported 1:1
// and with everything that touches X11 or a widget removed: slot arithmetic,
// snapping, attaching and detaching, drawers, the Clip's workspace switching
// and the omnipresent ("global") icons. Names follow the C original
// (wDockFindFreeSlot -> findFreeSlot, wDockSnapIcon -> snapIcon, ...) so the
// two can be read side by side.
//
// The model is Window Maker's grid, not a list: every icon has an
// (xindex, yindex) in tile units relative to its dock's first icon
// (icons[0], the Dock's logo tile / the Clip's tile / the Drawer's tile).
//   * Dock: one column, xindex == 0, yindex may be negative or positive.
//   * Clip: free 2D placement, an icon must touch a neighbour (vicinity 1).
//   * Drawer: a row to the left/right of the Dock, xindex 1, 2, 3 ... (or
//     -1, -2, ... when the Dock is on the right), always gap-free.
// Pixel positions are derived: x_pos = dock.x_pos + xindex * icon_size.
//
// Not here (UI side): drawing, timers (auto-collapse / auto-raise), the
// "type the command" dialog, process tracking, WMState. Where the original
// calls into those, this code only updates the flags they read.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const icon_size: i32 = 64;
/// DOCK_DETTACH_THRESHOLD, CLIP_ATTACH_VICINITY, DOCK_MAX_ICONS (wconfig.h).
pub const dock_detach_threshold: i32 = 3;
pub const clip_attach_vicinity: i32 = 1;
pub const dock_max_icons: usize = 32;

pub const Kind = enum { dock, clip, drawer };

pub const Icon = struct {
    xindex: i32 = 0,
    yindex: i32 = 0,
    /// Absolute position, kept in step with the indices by this module.
    x_pos: i32 = 0,
    y_pos: i32 = 0,
    dock: ?*Dock = null,
    /// What the UI hangs on it (index into its own tables, a window id...).
    tag: usize = 0,

    docked: bool = false,
    omnipresent: bool = false,
    /// Pulled into the Clip by autoattract; goes away with its program.
    attracted: bool = false,
    launching: bool = false,
    running: bool = false,
    forced_dock: bool = false,
    auto_launch: bool = false,
    /// "Lock": cannot be removed.
    lock: bool = false,
    /// A launch command is known (the C code tests `icon->command`).
    has_command: bool = false,
    /// The Clip's / Drawer's / Dock's own tile (icons[0]).
    main: bool = false,
};

pub const Dock = struct {
    kind: Kind,
    x_pos: i32 = 0,
    y_pos: i32 = 0,
    /// icons[0] is the main tile; null = free slot.
    icons: []?*Icon,
    icon_count: usize = 1,
    on_right_side: bool = true,
    collapsed: bool = false,
    auto_collapse: bool = false,
    auto_raise_lower: bool = false,
    mapped: bool = true,
    lowered: bool = true,
    attract_icons: bool = false,

    pub fn maxIcons(d: *const Dock) usize {
        return d.icons.len;
    }
};

pub const Omnipresence = enum { failed, not_applicable, success };

pub const Screen = struct {
    gpa: Allocator,
    width: i32,
    height: i32,
    current_workspace: usize = 0,
    no_dock: bool = false,
    dock: ?*Dock = null,
    /// One Clip per workspace (workspaces[i]->clip).
    clips: std.ArrayList(*Dock) = .empty,
    /// scr->drawers, in creation order.
    drawers: std.ArrayList(*Dock) = .empty,
    /// scr->global_icons: omnipresent Clip icons.
    global_icons: std.ArrayList(*Icon) = .empty,

    pub fn deinit(s: *Screen) void {
        if (s.dock) |d| destroy(s.gpa, d);
        for (s.clips.items) |c| destroy(s.gpa, c);
        for (s.drawers.items) |d| destroy(s.gpa, d);
        s.clips.deinit(s.gpa);
        s.drawers.deinit(s.gpa);
        s.global_icons.deinit(s.gpa);
    }

    pub fn globalIconCount(s: *const Screen) usize {
        return s.global_icons.items.len;
    }

    /// onScreen(): the tile at (x, y) lies fully inside the screen.
    pub fn onScreen(s: *const Screen, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x + icon_size <= s.width and y + icon_size <= s.height;
    }
};

// ----------------------------------------------------------------------------
// Creation (wDockCreate, wDockDestroy)
// ----------------------------------------------------------------------------

/// wDockCreate: a dock of `kind` whose main tile is at (x, y). A Drawer
/// copies the Dock's side and joins scr.drawers (drawerAppendToChain) with
/// auto_collapse on. The Dock and every Clip are owned by the Screen only if
/// the caller stores them in scr.dock / scr.clips.
pub fn create(scr: *Screen, kind: Kind, x: i32, y: i32) Allocator.Error!*Dock {
    const gpa = scr.gpa;
    const max: usize = switch (kind) {
        .clip => dock_max_icons,
        .drawer => @intCast(@max(1, @divTrunc(scr.width, icon_size))),
        .dock => @intCast(@max(1, @divTrunc(scr.height, icon_size))),
    };
    const dock = try gpa.create(Dock);
    errdefer gpa.destroy(dock);
    const icons = try gpa.alloc(?*Icon, max);
    errdefer gpa.free(icons);
    @memset(icons, null);
    const btn = try gpa.create(Icon);
    errdefer gpa.destroy(btn);
    btn.* = .{ .x_pos = x, .y_pos = y, .main = true, .docked = true, .running = true };
    dock.* = .{ .kind = kind, .x_pos = x, .y_pos = y, .icons = icons };
    btn.dock = dock;
    icons[0] = btn;
    if (kind == .drawer) {
        dock.on_right_side = if (scr.dock) |d| d.on_right_side else true;
        dock.auto_collapse = true;
        try scr.drawers.append(gpa, dock);
    }
    return dock;
}

/// wDockDestroy: frees the dock and all its icons (the caller owns the
/// meaning of `tag`). Does not unlink a drawer from scr.drawers.
pub fn destroy(gpa: Allocator, dock: *Dock) void {
    for (dock.icons) |maybe| if (maybe) |i| gpa.destroy(i);
    gpa.free(dock.icons);
    gpa.destroy(dock);
}

/// drawerRemoveFromChain + destroy (removeDrawerCallback).
pub fn removeDrawer(scr: *Screen, drawer: *Dock) void {
    for (scr.drawers.items, 0..) |d, i| {
        if (d == drawer) {
            _ = scr.drawers.orderedRemove(i);
            break;
        }
    }
    destroy(scr.gpa, drawer);
}

/// getDrawer: the Drawer that hangs at row `y_index` of the Dock, if any.
pub fn getDrawer(scr: *const Screen, y_index: i32) ?*Dock {
    const dock = scr.dock orelse return null;
    for (scr.drawers.items) |d| {
        if (d.y_pos - dock.y_pos == y_index * icon_size) return d;
    }
    return null;
}

fn firstFree(dock: *const Dock) ?usize {
    var i: usize = 1;
    while (i < dock.icons.len) : (i += 1) if (dock.icons[i] == null) return i;
    return null;
}

fn indexOf(dock: *const Dock, icon: *const Icon) ?usize {
    var i: usize = 1;
    while (i < dock.icons.len) : (i += 1) if (dock.icons[i] == icon) return i;
    return null;
}

fn place(dock: *const Dock, icon: *Icon, x: i32, y: i32) void {
    icon.xindex = x;
    icon.yindex = y;
    icon.x_pos = dock.x_pos + x * icon_size;
    icon.y_pos = dock.y_pos + y * icon_size;
}

// ----------------------------------------------------------------------------
// Attach, detach, move (wDockAttachIcon, wDockReattachIcon, wDockDetach,
// wDockMoveIconBetweenDocks)
// ----------------------------------------------------------------------------

/// wDockAttachIcon without the command dialog: the caller has made sure the
/// icon's command is known (or decided it may go without, Clip + attracted).
pub fn attachIcon(dock: *Dock, icon: *Icon, x: i32, y: i32) bool {
    const index = firstFree(dock) orelse return false;
    dock.icons[index] = icon;
    place(dock, icon, x, y);
    icon.omnipresent = false;
    dock.icon_count += 1;
    icon.running = true;
    icon.launching = false;
    icon.docked = true;
    icon.dock = dock;
    return true;
}

/// wDockReattachIcon: the icon stays in the dock, only its slot changes.
pub fn reattachIcon(dock: *Dock, icon: *Icon, x: i32, y: i32) void {
    std.debug.assert(indexOf(dock, icon) != null);
    place(dock, icon, x, y);
}

/// wDockDetach. The caller frees/keeps the command strings; `icon` stays
/// valid (an app icon of a still running program becomes a free icon).
pub fn detach(scr: *Screen, dock: *Dock, icon: *Icon) void {
    _ = makeIconOmnipresent(scr, icon, false);
    icon.docked = false;
    icon.dock = null;
    icon.attracted = false;
    icon.auto_launch = false;
    icon.has_command = false;
    const index = indexOf(dock, icon) orelse return;
    dock.icons[index] = null;
    icon.yindex = -1;
    icon.xindex = -1;
    dock.icon_count -= 1;
}

/// wDockMoveIconBetweenDocks (without the command dialog).
pub fn moveIconBetweenDocks(scr: *Screen, src: *Dock, dest: *Dock, icon: *Icon, x: i32, y: i32) bool {
    if (src == dest) return true;
    if (dest.kind == .dock and !icon.has_command) return false;
    if (dest.kind == .dock or dest.kind == .drawer) _ = makeIconOmnipresent(scr, icon, false);
    const si = indexOf(src, icon) orelse return false;
    const di = firstFree(dest) orelse return false;
    src.icons[si] = null;
    src.icon_count -= 1;
    dest.icons[di] = icon;
    icon.dock = dest;
    if (icon.has_command and (dest.kind == .dock or dest.kind == .drawer)) icon.attracted = false;
    place(dest, icon, x, y);
    dest.icon_count += 1;
    return true;
}

// ----------------------------------------------------------------------------
// Omnipresent icons (wClipMakeIconOmnipresent)
// ----------------------------------------------------------------------------

fn iconCanBeOmnipresent(scr: *const Screen, icon: *const Icon) bool {
    for (scr.clips.items) |clip| {
        if (icon.dock) |d| if (clip == d) continue;
        if (clip.icon_count + scr.globalIconCount() >= clip.icons.len) return false;
        for (clip.icons) |maybe| {
            const btn = maybe orelse continue;
            if (btn.xindex == icon.xindex and btn.yindex == icon.yindex) return false;
        }
    }
    return true;
}

pub fn makeIconOmnipresent(scr: *Screen, icon: *Icon, omnipresent: bool) Omnipresence {
    if (icon.main) return .not_applicable;
    if (icon.dock) |d| if (d.kind == .dock) return .not_applicable;
    if (icon.omnipresent == omnipresent) return .success;
    if (omnipresent) {
        if (!iconCanBeOmnipresent(scr, icon)) {
            icon.omnipresent = false;
            return .failed;
        }
        scr.global_icons.append(scr.gpa, icon) catch return .failed;
        icon.omnipresent = true;
    } else {
        icon.omnipresent = false;
        for (scr.global_icons.items, 0..) |g, i| {
            if (g == icon) {
                _ = scr.global_icons.orderedRemove(i);
                break;
            }
        }
    }
    return .success;
}

/// wClipUpdateForWorkspaceChange: every omnipresent icon moves to the new
/// workspace's Clip; the old Clip collapses if it autocollapses. The caller
/// then repaints. (Timers: the UI cancels them for `old`.)
pub fn clipUpdateForWorkspaceChange(scr: *Screen, workspace: usize) void {
    if (workspace >= scr.clips.items.len) return;
    const new_clip = scr.clips.items[workspace];
    if (scr.current_workspace != workspace and scr.current_workspace < scr.clips.items.len) {
        const old_clip = scr.clips.items[scr.current_workspace];
        for (scr.global_icons.items) |g| {
            const from = g.dock orelse continue;
            _ = moveIconBetweenDocks(scr, from, new_clip, g, g.xindex, g.yindex);
        }
        if (old_clip.auto_collapse) old_clip.collapsed = true;
    }
    scr.current_workspace = workspace;
}

// ----------------------------------------------------------------------------
// Free slot (wDockFindFreeSlot)
// ----------------------------------------------------------------------------

const Corner = enum { none, nw, ne, sw, se };

fn cornerOf(dock: *const Dock, ex: i32, ey: i32) Corner {
    if (dock.kind != .clip) return .none;
    if (dock.x_pos < 1 and dock.y_pos < 1) return .ne;
    if (dock.x_pos < 1 and dock.y_pos >= ey - icon_size) return .se;
    if (dock.x_pos >= ex - icon_size and dock.y_pos >= ey - icon_size) return .sw;
    if (dock.x_pos >= ex - icon_size and dock.y_pos < 1) return .nw;
    return .none;
}

/// Where a new icon goes: the next slot along the edge, away from the
/// corner (Clip in a corner), otherwise the first free slot on a spiral
/// around the main tile. Returns {x, y} indices, or null if full.
pub fn findFreeSlot(scr: *const Screen, dock: *const Dock) Allocator.Error!?[2]i32 {
    const gpa = scr.gpa;
    if (dock.kind == .drawer) {
        if (dock.icon_count >= dock.icons.len) return null;
        const n: i32 = @intCast(dock.icon_count);
        return .{ n * (if (dock.on_right_side) @as(i32, -1) else 1), 0 };
    }

    var extra: usize = 0;
    if (dock.kind == .clip) {
        const cur = if (scr.current_workspace < scr.clips.items.len) scr.clips.items[scr.current_workspace] else null;
        if (cur != dock) extra = scr.globalIconCount();
    }
    if (dock.icon_count + extra >= dock.icons.len) return null;

    var ex = scr.width;
    const ey = scr.height;
    if (!scr.no_dock) if (scr.dock) |d| {
        if (d.on_right_side) ex -= icon_size;
    };
    if (ex < dock.x_pos) ex = dock.x_pos;

    const corner = cornerOf(dock, ex, ey);
    if (corner != .none) {
        const hcount: usize = @intCast(@min(@as(i32, @intCast(dock.icons.len)), @divTrunc(scr.width, icon_size)));
        const vcount: usize = @intCast(@min(@as(i32, @intCast(dock.icons.len)), @divTrunc(scr.height, icon_size)));
        const hmap = try gpa.alloc(bool, hcount + 1);
        defer gpa.free(hmap);
        const vmap = try gpa.alloc(bool, vcount + 1);
        defer gpa.free(vmap);
        @memset(hmap, false);
        @memset(vmap, false);
        const sx: i32 = if (corner == .ne or corner == .se) 1 else -1;
        const sy: i32 = if (corner == .ne or corner == .nw) 1 else -1;

        const Mark = struct {
            fn one(b: *const Icon, sx_: i32, sy_: i32, hm: []bool, vm: []bool) void {
                const vy = sy_ * b.yindex;
                const hx = sx_ * b.xindex;
                if (b.xindex == 0 and vy > 0 and vy < @as(i32, @intCast(vm.len)) - 1) {
                    vm[@intCast(vy)] = true;
                } else if (b.yindex == 0 and hx > 0 and hx < @as(i32, @intCast(hm.len)) - 1) {
                    hm[@intCast(hx)] = true;
                }
            }
        };
        for (dock.icons) |maybe| if (maybe) |b| Mark.one(b, sx, sy, hmap, vmap);
        for (scr.global_icons.items) |b| Mark.one(b, sx, sy, hmap, vmap);

        const top = @max(vcount, hcount);
        var i: usize = 1;
        while (i < top) : (i += 1) {
            var x: i32 = 0;
            var y: i32 = 0;
            if (i < vcount and !vmap[i]) {
                y = @intCast(i);
            } else if (i < hcount and !hmap[i]) {
                x = @intCast(i);
            } else continue;
            return .{ sx * x, sy * y };
        }
    }

    // Spiral around the main tile. (XY2OFS maps everything outside the map
    // to offset 0; kept as is.)
    const max_f: f64 = @floatFromInt(dock.icons.len);
    var mwidth: i32 = @intFromFloat(@ceil(@sqrt(max_f)));
    mwidth += mwidth;
    const r = @divTrunc(mwidth - 1, 2);
    const slot_map = try gpa.alloc(bool, @intCast(mwidth * mwidth));
    defer gpa.free(slot_map);
    @memset(slot_map, false);

    const Ofs = struct {
        fn at(x: i32, y: i32, rr: i32, mw: i32) usize {
            if (@max(@abs(x), @abs(y)) > rr) return 0;
            return @intCast((y + rr) * mw + x + rr);
        }
    };
    for (dock.icons) |maybe| if (maybe) |b| {
        slot_map[Ofs.at(b.xindex, b.yindex, r, mwidth)] = true;
    };
    for (scr.global_icons.items) |b| slot_map[Ofs.at(b.xindex, b.yindex, r, mwidth)] = true;

    var i: i32 = 1;
    while (i <= r) : (i += 1) {
        var x: i32 = -i;
        while (x <= i) : (x += 1) {
            const tx = dock.x_pos + x * icon_size;
            var y: i32 = -i;
            var ty = dock.y_pos + y * icon_size;
            if (!slot_map[Ofs.at(x, y, r, mwidth)] and scr.onScreen(tx, ty)) return .{ x, y };
            y = i;
            ty = dock.y_pos + y * icon_size;
            if (!slot_map[Ofs.at(x, y, r, mwidth)] and scr.onScreen(tx, ty)) return .{ x, y };
        }
        var y: i32 = -i + 1;
        while (y <= i - 1) : (y += 1) {
            const ty = dock.y_pos + y * icon_size;
            var x2: i32 = -i;
            var tx = dock.x_pos + x2 * icon_size;
            if (!slot_map[Ofs.at(x2, y, r, mwidth)] and scr.onScreen(tx, ty)) return .{ x2, y };
            x2 = i;
            tx = dock.x_pos + x2 * icon_size;
            if (!slot_map[Ofs.at(x2, y, r, mwidth)] and scr.onScreen(tx, ty)) return .{ x2, y };
        }
    }
    return null;
}

// ----------------------------------------------------------------------------
// Drawers: sliding, holes, consolidation
// ----------------------------------------------------------------------------

/// wSlideAppicons: shift icons one slot (the animation is the UI's job).
pub fn slideAppicons(icons: []const *Icon, to_the_left: bool) void {
    for (icons) |a| {
        a.xindex += if (to_the_left) @as(i32, -1) else 1;
        a.x_pos += if (to_the_left) -icon_size else icon_size;
    }
}

/// indexOfHole: the one xindex missing from the drawer's gap-free run.
pub fn indexOfHole(drawer: *const Dock, moving: ?*const Icon, redocking: bool) i32 {
    const n: i32 = @intCast(drawer.icon_count);
    var hole: i32 = if (redocking) @divTrunc((n - 1) * n, 2) else @divTrunc(n * (n + 1), 2);
    hole *= if (drawer.on_right_side) @as(i32, -1) else 1;
    var i: usize = 1;
    while (i < drawer.icons.len) : (i += 1) {
        if (drawer.icons[i]) |a| {
            if (moving == null or a != moving.?) hole -= a.xindex;
        }
    }
    return hole;
}

/// wDrawerFillTheGap: after an icon left (or is about to), close the hole.
pub fn drawerFillTheGap(drawer: *Dock, aicon: ?*const Icon, redocking: bool) void {
    const hole = indexOfHole(drawer, aicon, redocking);
    var buf: [256]*Icon = undefined;
    var n: usize = 0;
    for (drawer.icons) |maybe| {
        const ai = maybe orelse continue;
        if (aicon != null and ai == aicon.?) continue;
        if (@abs(ai.xindex) > @abs(hole) and n < buf.len) {
            buf[n] = ai;
            n += 1;
        }
    }
    slideAppicons(buf[0..n], !drawer.on_right_side);
}

/// drawerConsolidateIcons: after loading, squeeze out gaps.
pub fn drawerConsolidateIcons(drawer: *Dock) void {
    var max_remaining: u32 = 0;
    var sum: u32 = 0;
    for (drawer.icons) |maybe| {
        const ai = maybe orelse continue;
        sum += @abs(ai.xindex);
        max_remaining = @max(max_remaining, @abs(ai.xindex));
    }
    var guard: u32 = 0;
    while (sum != max_remaining * (max_remaining + 1) / 2 and guard < 1024) : (guard += 1) {
        var max_deleted: u32 = if (max_remaining > 0) max_remaining - 1 else 0;
        while (max_deleted > 0) : (max_deleted -= 1) {
            var found = false;
            for (drawer.icons) |maybe| {
                const ai = maybe orelse continue;
                if (@abs(ai.xindex) == max_deleted) {
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }
        if (max_deleted == 0) return;
        var buf: [256]*Icon = undefined;
        var n: usize = 0;
        for (drawer.icons) |maybe| {
            const ai = maybe orelse continue;
            if (@abs(ai.xindex) > max_deleted and n < buf.len) {
                buf[n] = ai;
                n += 1;
            }
        }
        slideAppicons(buf[0..n], !drawer.on_right_side);
        max_remaining -= 1;
        sum -= @intCast(n);
    }
}

// ----------------------------------------------------------------------------
// Snapping (wDockSnapIcon): where does a dragged icon land?
// ----------------------------------------------------------------------------

/// The slot {x, y} the icon at pixel (req_x, req_y) snaps to in `dock`, or
/// null if it does not snap there. For a Drawer the icons in the way are
/// slid aside (as the C code does while dragging).
pub fn snapIcon(scr: *Screen, dock: *Dock, icon: *Icon, req_x: i32, req_y: i32, redocking: bool) ?[2]i32 {
    const dx = dock.x_pos;
    const dy = dock.y_pos;
    const offset = @divTrunc(icon_size, 2);

    if (!redocking and dock.icon_count >= dock.icons.len) return null;

    var ex_y: i32 = if (req_y < dy)
        @divTrunc(req_y - offset - dy, icon_size)
    else
        @divTrunc(req_y + offset - dy, icon_size);
    var ex_x: i32 = if (req_x < dx)
        @divTrunc(req_x - offset - dx, icon_size)
    else
        @divTrunc(req_x + offset - dx, icon_size);

    if (!scr.onScreen(dx + ex_x * icon_size, dy + ex_y * icon_size)) return null;

    switch (dock.kind) {
        .dock => {
            if (icon.dock != dock and ex_x != 0) {
                const from_drawer_tile = if (icon.dock) |d| d.kind == .drawer and icon == d.icons[0] else false;
                if (!from_drawer_tile) return null;
            }
            if (!redocking and ex_x != 0) return null;
            if (getDrawer(scr, ex_y) != null) return null;

            var aicon: ?*Icon = null;
            for (dock.icons) |maybe| {
                if (maybe) |n| if (n.yindex == ex_y) {
                    aicon = n;
                    break;
                };
            }

            if (redocking) {
                if (@abs(ex_x) > dock_detach_threshold) return null;
                if (aicon == null or aicon.? == icon) return .{ 0, ex_y };

                var sig: i32 = if (ex_y * icon_size < req_y + offset - dy) 1 else -1;
                var done = false;
                var closest: i32 = ex_y;
                var i: i32 = 0;
                while (i < (dock_detach_threshold + 1) * 2 and !done) : (i += 1) {
                    done = true;
                    closest = sig * @divTrunc(i, 2) + ex_y;
                    if (scr.onScreen(dx, dy + closest * icon_size)) {
                        for (dock.icons) |maybe| {
                            if (maybe) |n| if (n.yindex == closest) {
                                if (n != icon) done = false;
                                break;
                            };
                        }
                        done = done and getDrawer(scr, closest) == null;
                    } else {
                        done = false;
                    }
                    sig = -sig;
                }
                if (done and
                    ((ex_y >= closest and ex_y - closest < dock_detach_threshold + 1) or
                        (ex_y < closest and closest - ex_y <= dock_detach_threshold + 1)))
                {
                    return .{ 0, closest };
                }
            } else {
                if (aicon == null and ex_x == 0) return .{ 0, ex_y };
            }
            return null;
        },
        .clip => {
            const start: usize = if (icon.omnipresent) 0 else scr.current_workspace;
            const stop: usize = if (icon.omnipresent) scr.clips.items.len else start + 1;
            var aicon: ?*Icon = null;
            var k = start;
            while (k < stop and aicon == null) : (k += 1) {
                if (k >= scr.clips.items.len) continue;
                for (scr.clips.items[k].icons) |maybe| {
                    if (maybe) |n| if (n.xindex == ex_x and n.yindex == ex_y) {
                        aicon = n;
                        break;
                    };
                }
            }
            var neighbours = false;
            k = start;
            while (k < stop and !neighbours) : (k += 1) {
                if (k >= scr.clips.items.len) continue;
                for (scr.clips.items[k].icons) |maybe| {
                    if (maybe) |n| {
                        if (n != icon and @abs(n.xindex - ex_x) <= clip_attach_vicinity and
                            @abs(n.yindex - ex_y) <= clip_attach_vicinity)
                        {
                            neighbours = true;
                            break;
                        }
                    }
                }
            }
            if (neighbours and (aicon == null or (redocking and aicon.? == icon))) return .{ ex_x, ex_y };
            return null;
        },
        .drawer => {
            const count: i32 = @intCast(dock.icon_count);
            if (ex_y != 0 or @as(i32, @intCast(@abs(ex_x))) - count > dock_detach_threshold or
                (ex_x < 0 and !dock.on_right_side) or (ex_x > 0 and dock.on_right_side))
                return null;
            if (ex_x == 0) ex_x = if (dock.on_right_side) -1 else 1;
            const ax: i32 = @intCast(@abs(ex_x));
            if (redocking) {
                if (ax > count - 1) ex_x = @divTrunc(ex_x * (count - 1), ax);
            } else {
                if (ax > count) ex_x = @divTrunc(ex_x * count, ax);
            }
            const hole = indexOfHole(dock, icon, redocking);
            var buf: [256]*Icon = undefined;
            var n: usize = 0;
            var i: usize = 1;
            while (i < dock.icons.len) : (i += 1) {
                const a = dock.icons[i] orelse continue;
                if (a == icon) continue;
                if ((ex_x <= a.xindex and a.xindex < hole) or (hole < a.xindex and a.xindex <= ex_x)) {
                    if (n < buf.len) {
                        buf[n] = a;
                        n += 1;
                    }
                }
            }
            slideAppicons(buf[0..n], hole < ex_x);
            ex_y = 0;
            return .{ ex_x, ex_y };
        },
    }
}

// ----------------------------------------------------------------------------
// Moving and swapping the whole dock (moveDock, wDockSwap)
// ----------------------------------------------------------------------------

pub fn moveDock(scr: *Screen, dock: *Dock, new_x: i32, new_y: i32) void {
    if (dock.kind == .dock) {
        for (scr.drawers.items) |d| moveDock(scr, d, new_x, d.y_pos - dock.y_pos + new_y);
    }
    dock.x_pos = new_x;
    dock.y_pos = new_y;
    for (dock.icons) |maybe| {
        const b = maybe orelse continue;
        b.x_pos = new_x + b.xindex * icon_size;
        b.y_pos = new_y + b.yindex * icon_size;
    }
}

/// wDockSwap: the Dock jumps to the other screen edge; Drawers mirror
/// (swapDrawer: xindex flips sign).
pub fn swap(scr: *Screen, dock: *Dock) void {
    dock.on_right_side = !dock.on_right_side;
    const x: i32 = if (dock.on_right_side) scr.width - icon_size else 0;
    for (scr.drawers.items) |d| {
        d.on_right_side = dock.on_right_side;
        d.x_pos = x;
        for (d.icons) |maybe| {
            const b = maybe orelse continue;
            b.xindex = -b.xindex;
            b.x_pos = d.x_pos + b.xindex * icon_size;
        }
    }
    dock.x_pos = x;
    for (dock.icons) |maybe| {
        const b = maybe orelse continue;
        b.x_pos = x;
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn testScreen(gpa: Allocator) !Screen {
    var s: Screen = .{ .gpa = gpa, .width = 1920, .height = 1080 };
    s.dock = try create(&s, .dock, 1920 - icon_size, 0);
    return s;
}

fn newIcon(gpa: Allocator) !*Icon {
    const i = try gpa.create(Icon);
    i.* = .{ .has_command = true };
    return i;
}

test "dock: free slot is the first row below the logo, snapping follows the grid" {
    var s = try testScreen(std.testing.allocator);
    defer s.deinit();
    const dock = s.dock.?;

    const a = try newIcon(s.gpa);
    const slot = (try findFreeSlot(&s, dock)).?;
    // The spiral starts at the ring around the main tile: top row first.
    try std.testing.expectEqual(@as(i32, 0), slot[0] * 0);
    try std.testing.expect(attachIcon(dock, a, 0, 1));
    try std.testing.expectEqual(@as(i32, 1 * icon_size), a.y_pos);
    try std.testing.expectEqual(dock.x_pos, a.x_pos);
    try std.testing.expectEqual(@as(usize, 2), dock.icon_count);

    // Dragging a new icon next to the dock snaps to its column; onto an
    // occupied row it does not.
    const b = try newIcon(s.gpa);
    defer s.gpa.destroy(b);
    const snap = snapIcon(&s, dock, b, dock.x_pos + 5, 2 * icon_size + 10, false);
    try std.testing.expectEqual(@as(?[2]i32, .{ 0, 2 }), snap);
    try std.testing.expectEqual(@as(?[2]i32, null), snapIcon(&s, dock, b, dock.x_pos, icon_size + 5, false));
    // Far from the column: no snap.
    try std.testing.expectEqual(@as(?[2]i32, null), snapIcon(&s, dock, b, dock.x_pos - 3 * icon_size, 2 * icon_size, false));

    detach(&s, dock, a);
    try std.testing.expectEqual(@as(usize, 1), dock.icon_count);
    try std.testing.expect(!a.docked);
    s.gpa.destroy(a);
}

test "clip: needs a neighbour, corner placement runs along the edge" {
    var s: Screen = .{ .gpa = std.testing.allocator, .width = 1920, .height = 1080 };
    defer s.deinit();
    const clip = try create(&s, .clip, 0, 0);
    try s.clips.append(s.gpa, clip);

    // Clip in the top-left corner (NE rule in the C code): first free slot
    // runs down the column.
    const s1 = (try findFreeSlot(&s, clip)).?;
    try std.testing.expectEqual(@as(i32, 0), s1[0]);
    try std.testing.expectEqual(@as(i32, 1), s1[1]);
    const a = try newIcon(s.gpa);
    try std.testing.expect(attachIcon(clip, a, s1[0], s1[1]));
    // Like the C code: the first free index in EITHER direction wins, so with
    // (0, 1) taken the next slot is (1, 0), then (0, 2), (2, 0), ...
    const s2 = (try findFreeSlot(&s, clip)).?;
    try std.testing.expectEqual(@as(i32, 1), s2[0]);
    try std.testing.expectEqual(@as(i32, 0), s2[1]);

    // Snapping: next to the Clip's tile ok, far away not.
    const b = try newIcon(s.gpa);
    defer s.gpa.destroy(b);
    try std.testing.expectEqual(@as(?[2]i32, .{ 1, 0 }), snapIcon(&s, clip, b, icon_size + 3, 4, false));
    try std.testing.expectEqual(@as(?[2]i32, null), snapIcon(&s, clip, b, 6 * icon_size, 6 * icon_size, false));
}

test "omnipresent icons follow the workspace" {
    var s: Screen = .{ .gpa = std.testing.allocator, .width = 1920, .height = 1080 };
    defer s.deinit();
    const c0 = try create(&s, .clip, 0, 0);
    const c1 = try create(&s, .clip, 0, 0);
    try s.clips.append(s.gpa, c0);
    try s.clips.append(s.gpa, c1);

    const a = try newIcon(s.gpa);
    try std.testing.expect(attachIcon(c0, a, 0, 1));
    try std.testing.expectEqual(Omnipresence.success, makeIconOmnipresent(&s, a, true));
    try std.testing.expectEqual(@as(usize, 1), s.globalIconCount());

    clipUpdateForWorkspaceChange(&s, 1);
    try std.testing.expect(a.dock.? == c1);
    try std.testing.expectEqual(@as(usize, 1), c1.icon_count - 1);
    try std.testing.expectEqual(@as(usize, 0), c0.icon_count - 1);

    detach(&s, c1, a);
    try std.testing.expectEqual(@as(usize, 0), s.globalIconCount());
    s.gpa.destroy(a);
}

test "drawer: icons line up gap-free, a hole is closed" {
    var s = try testScreen(std.testing.allocator);
    defer s.deinit();
    const dock = s.dock.?;
    const dr = try create(&s, .drawer, dock.x_pos, 2 * icon_size);
    try std.testing.expect(dr.on_right_side);
    try std.testing.expect(dr.auto_collapse);
    try std.testing.expect(getDrawer(&s, 2) == dr);

    var icons: [3]*Icon = undefined;
    for (&icons) |*p| {
        p.* = try newIcon(s.gpa);
        const slot = (try findFreeSlot(&s, dr)).?;
        try std.testing.expectEqual(@as(i32, 0), slot[1]);
        try std.testing.expect(attachIcon(dr, p.*, slot[0], slot[1]));
    }
    // Right-side Dock: the drawer grows to the left.
    try std.testing.expectEqual(@as(i32, -1), icons[0].xindex);
    try std.testing.expectEqual(@as(i32, -3), icons[2].xindex);

    // Remove the middle one: detach it, then close the hole (the C code's
    // order in handleDockMove).
    detach(&s, dr, icons[1]);
    drawerFillTheGap(dr, icons[1], false);
    try std.testing.expectEqual(@as(i32, -1), icons[0].xindex);
    try std.testing.expectEqual(@as(i32, -2), icons[2].xindex);
    s.gpa.destroy(icons[1]);

    // A drawer row is not available as a Dock slot.
    const b = try newIcon(s.gpa);
    defer s.gpa.destroy(b);
    try std.testing.expectEqual(@as(?[2]i32, null), snapIcon(&s, dock, b, dock.x_pos, 2 * icon_size, false));
}

test "swap mirrors the dock and its drawers" {
    var s = try testScreen(std.testing.allocator);
    defer s.deinit();
    const dock = s.dock.?;
    const dr = try create(&s, .drawer, dock.x_pos, icon_size);
    const a = try newIcon(s.gpa);
    try std.testing.expect(attachIcon(dr, a, -1, 0));
    swap(&s, dock);
    try std.testing.expect(!dock.on_right_side);
    try std.testing.expectEqual(@as(i32, 0), dock.x_pos);
    try std.testing.expectEqual(@as(i32, 1), a.xindex);
    try std.testing.expectEqual(@as(i32, icon_size), a.x_pos);
}
