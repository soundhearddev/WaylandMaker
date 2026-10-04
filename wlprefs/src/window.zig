// SPDX-License-Identifier: 0BSD
//
// The wlprefs main window.
//
// This is a close geometric port of Window Maker's own WPrefs.app (see
// wmaker.git WPrefs.app/WPrefs.c, function createMainWindow /
// changeSection), not a generic "settings app" layout:
//
//   * fixed-size window, 520x390, not resizable (WPrefs pins min==max
//     size the same way);
//   * a sunken, horizontally-scrolling strip of 64x64 icon-only buttons
//     at (10,10), sized 500x87 -- WPrefs' WMScrollView + 64x64
//     WMCustomButtons in WIPImageOnly mode, no per-icon caption, plus
//     its own 20px-tall horizontal WMScroller along the bottom of the
//     strip (16 icons * 64px don't fit in 500px);
//   * a single content frame at (-2,105), sized 524x235, flat until the
//     first click and then WRGroove (WPrefs.c: changeSection() flips
//     WPrefs.banner's relief from WRFlat to WRGroove on first use);
//     it shows a centered banner (title/version/status) until a
//     section is picked, then that section's panel;
//   * a row of raised command buttons along the bottom (y=350): status
//     text on the left, Revert Page / Revert All / Save / Close on the right;
//   * the window title becomes the selected section's name, exactly as
//     WMSetWindowTitle(WPrefs.win, rec->sectionName) does.
//
// What is not WPrefs: the state lives in prefs.zig (the config file is read
// at start-up, a save re-reads it and changes only the keys that were
// changed, see there), and the window keeps ONE shm buffer for its whole life
// instead of creating a pool per redraw.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const xkb = @import("xkbcommon");

const gfx = @import("gfx.zig");
const root = @import("root.zig");
const panel_menu = @import("panel_menu.zig");
const panels = @import("panels.zig");
const settings = @import("settings.zig");
const prefs_mod = @import("prefs.zig");
const icons = @import("icons.zig");
const Category = root.Category;

// ---- NeXTSTEP palette -------------------------------------------------------

const widget_face = gfx.Color.rgb(0xaeaeae);
const text_black = gfx.Color.rgb(0x000000);
const text_dim = gfx.Color.rgb(0x505050);

const font = "Sans 10";
const font_bold_title = "Sans Bold 18";
const font_small = "Sans 8";

// ---- geometry, ported 1:1 from WPrefs.app/WPrefs.c's createMainWindow -----

const win_width: i32 = 520;
const win_height: i32 = 390;

const strip_x: i32 = 10;
const strip_y: i32 = 10;
const strip_w: i32 = 500;
const strip_h: i32 = 87;

const icon_size: i32 = 64;

const scroller_h: i32 = 20;
const icon_viewport_h: i32 = strip_h - scroller_h;

const frame_left: i32 = -2; // FRAME_LEFT
const frame_top: i32 = 105; // FRAME_TOP
const frame_width: i32 = 524; // FRAME_WIDTH
const frame_height: i32 = 235; // FRAME_HEIGHT

const button_y: i32 = 350;
const button_h: i32 = 28;
const balloon_x: i32 = 15;
const revert_page_x: i32 = 135;
const revert_all_x: i32 = 235;
const save_x: i32 = 335;
const close_x: i32 = 425;
const cmd_button_w: i32 = 90;
const save_close_w: i32 = 80;

fn contentWidth() i32 {
    return @as(i32, @intCast(Category.all.len)) * icon_size;
}

fn maxScroll() i32 {
    return @max(0, contentWidth() + 4 - strip_w);
}

const Thumb = struct {
    w: i32,
    fn x(th: Thumb, scroll_x: i32) i32 {
        const track = strip_w - 4 - th.w;
        const ms = maxScroll();
        if (ms <= 0) return strip_x + 2;
        return strip_x + 2 + @divTrunc(scroll_x * track, ms);
    }
};

fn thumb() Thumb {
    const w = @divTrunc(strip_w * strip_w, contentWidth());
    return .{ .w = std.math.clamp(w, 20, strip_w - 4) };
}

pub const Window = struct {
    gpa: std.mem.Allocator,

    // ---- globals ------------------------------------------------------------
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,

    // ---- input --------------------------------------------------------------
    pointer: ?*wl.Pointer = null,
    px: i32 = 0,
    py: i32 = 0,
    dragging: bool = false,
    drag_off: i32 = 0,

    keyboard: ?*wl.Keyboard = null,
    xkb_ctx: ?*xkb.Context = null,
    xkb_keymap: ?*xkb.Keymap = null,
    xkb_state: ?*xkb.State = null,
    focused_text: ?*settings.Text = null,

    // ---- window state -------------------------------------------------------
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,

    configured: bool = false,
    closed: bool = false,

    selected: ?Category = null,
    scroll_x: i32 = 0,
    /// First visible row of the key binding list.
    bind_scroll: i32 = 0,

    icons: [Category.all.len]gfx.Image = undefined,
    icons_loaded: bool = false,
    /// Dock/Clip picker icons (or their fallbacks).
    icon_set: icons.Set = .{},

    menu_imgs: panel_menu.Images = undefined,
    menu_state: panel_menu.State = .{},

    // ---- the one shm buffer -----------------------------------------------
    shm_data: []align(std.heap.page_size_min) u8 = &.{},
    buffer: ?*wl.Buffer = null,
    /// The compositor still holds the buffer (no `release` yet).
    buf_busy: bool = false,
    redraw_pending: bool = false,

    // ---- settings -----------------------------------------------------------
    prefs: prefs_mod.Prefs,
    status: [160:0]u8 = [_:0]u8{0} ** 160,
    /// Close was clicked with unsaved changes: the next Close discards them.
    close_armed: bool = false,

    /// `config_path`: edit this file instead of the compositor's own
    /// (`wlprefs --config FILE`, for trying it out).
    pub fn init(gpa: std.mem.Allocator, config_path: ?[]const u8) !Window {
        var win: Window = .{
            .gpa = gpa,
            .prefs = try prefs_mod.Prefs.init(gpa, config_path),
        };
        win.setStatus(win.prefs.openingMessage());
        return win;
    }

    fn setStatus(win: *Window, msg: []const u8) void {
        const n = @min(msg.len, win.status.len - 1);
        @memcpy(win.status[0..n], msg[0..n]);
        win.status[n] = 0;
    }

    fn cur(win: *Window) *settings.Settings {
        return &win.prefs.cur;
    }

    fn save(win: *Window) void {
        const r = win.prefs.save();
        win.setStatus(r.message);
        win.close_armed = false;
    }

    // ---- wl_registry --------------------------------------------------------
    pub fn registryListener(reg: *wl.Registry, ev: wl.Registry.Event, win: *Window) void {
        switch (ev) {
            .global => |g| {
                if (std.mem.orderZ(u8, g.interface, wl.Compositor.interface.name) == .eq) {
                    win.compositor = reg.bind(g.name, wl.Compositor, @min(g.version, 6)) catch return;
                } else if (std.mem.orderZ(u8, g.interface, wl.Shm.interface.name) == .eq) {
                    win.shm = reg.bind(g.name, wl.Shm, 1) catch return;
                } else if (std.mem.orderZ(u8, g.interface, xdg.WmBase.interface.name) == .eq) {
                    win.wm_base = reg.bind(g.name, xdg.WmBase, @min(g.version, 3)) catch return;
                } else if (std.mem.orderZ(u8, g.interface, wl.Seat.interface.name) == .eq) {
                    // Only the first seat.
                    if (win.seat != null) return;
                    const seat = reg.bind(g.name, wl.Seat, @min(g.version, 7)) catch return;
                    win.seat = seat;
                    seat.setListener(*Window, seatListener, win);
                }
            },
            .global_remove => {},
        }
    }

    // ---- wl_seat & Listeners ------------------------------------------------
    fn seatListener(seat: *wl.Seat, ev: wl.Seat.Event, win: *Window) void {
        switch (ev) {
            .capabilities => |c| {
                if (c.capabilities.pointer and win.pointer == null) {
                    const ptr = seat.getPointer() catch return;
                    win.pointer = ptr;
                    ptr.setListener(*Window, pointerListener, win);
                }
                if (c.capabilities.keyboard and win.keyboard == null) {
                    const kb = seat.getKeyboard() catch return;
                    win.keyboard = kb;
                    kb.setListener(*Window, keyboardListener, win);
                }
            },
            else => {},
        }
    }

    fn keyboardListener(_: *wl.Keyboard, ev: wl.Keyboard.Event, win: *Window) void {
        switch (ev) {
            .keymap => |k| {
                defer _ = std.os.linux.close(k.fd);
                if (k.format != .xkb_v1) return;
                const map = std.posix.mmap(null, k.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, k.fd, 0) catch return;
                defer std.posix.munmap(map);
                const ctx = win.xkb_ctx orelse blk: {
                    const c = xkb.Context.new(.no_flags) orelse return;
                    win.xkb_ctx = c;
                    break :blk c;
                };
                const km = xkb.Keymap.newFromBuffer(ctx, map.ptr, k.size - 1, .text_v1, .no_flags) orelse return;
                const st = xkb.State.new(km) orelse {
                    km.unref();
                    return;
                };
                if (win.xkb_state) |s| s.unref();
                if (win.xkb_keymap) |m| m.unref();
                win.xkb_keymap = km;
                win.xkb_state = st;
            },
            .modifiers => |m| {
                if (win.xkb_state) |s| _ = s.updateMask(m.mods_depressed, m.mods_latched, m.mods_locked, 0, 0, m.group);
            },
            .key => |k| {
                if (k.state != .pressed) return;
                const st = win.xkb_state orelse return;
                const code: u32 = @as(u32, k.key) + 8; // evdev -> xkb
                const sym = st.keyGetOneSym(code);

                // Ctrl+S saves, wherever the focus is.
                const ctrl = st.modNameIsActive(xkb.names.mod.ctrl, @enumFromInt(xkb.State.Component.mods_effective)) > 0;
                if (ctrl and (sym == xkb.Keysym.s or sym == xkb.Keysym.S)) {
                    win.save();
                    win.redraw();
                    return;
                }

                const t = win.focused_text orelse return;
                switch (sym) {
                    .BackSpace => t.backspace(),
                    .Return, .KP_Enter, .Escape => win.focused_text = null,
                    else => {
                        if (ctrl) return;
                        var buf: [8]u8 = undefined;
                        const n = st.keyGetUtf8(code, &buf);
                        if (n != 1) return;
                        // Text.append refuses control characters and a '#'
                        // that would start a comment.
                        t.append(buf[0]);
                    },
                }
                win.close_armed = false;
                win.redraw();
            },
            else => {},
        }
    }

    fn pointerListener(_: *wl.Pointer, ev: wl.Pointer.Event, win: *Window) void {
        switch (ev) {
            .enter => |e| {
                win.px = e.surface_x.toInt();
                win.py = e.surface_y.toInt();
            },
            .leave => win.dragging = false,
            .motion => |m| {
                win.px = m.surface_x.toInt();
                win.py = m.surface_y.toInt();
                if (win.dragging) win.dragScroller();
            },
            .button => |b| {
                const btn_left = 0x110;
                if (b.button != btn_left) return;
                if (b.state == .pressed) {
                    win.onPress();
                } else {
                    win.dragging = false;
                }
            },
            .axis => |a| {
                if (a.axis != .vertical_scroll) return;
                const v = a.value.toInt();
                if (win.py >= strip_y and win.py < strip_y + strip_h and win.px >= strip_x and win.px < strip_x + strip_w) {
                    win.setScroll(win.scroll_x + @divTrunc(v * 3, 2) * 2);
                    return;
                }
                // The key binding list scrolls three rows per wheel click.
                if (win.selected == .keyboard_shortcuts and win.py >= frame_top) {
                    const step: i32 = if (v > 0) 3 else if (v < 0) -3 else 0;
                    const max = panels.bindMaxScroll(win.prefs.bind_list.len);
                    const next = std.math.clamp(win.bind_scroll + step, 0, max);
                    if (next != win.bind_scroll) {
                        win.bind_scroll = next;
                        win.redraw();
                    }
                }
            },
            else => {},
        }
    }

    fn panelClick(win: *Window, cat: Category, x: i32, y: i32) void {
        var ctx: panels.Ctx = .{ .mode = .click, .cx = x, .cy = y, .focused = win.focused_text, .icons = &win.icon_set };
        if (!win.runPanel(cat, &ctx)) return;
        win.focused_text = ctx.res.focus;
        if (ctx.res.changed) {
            win.status[0] = 0;
            win.close_armed = false;
            win.redraw();
        } else if (ctx.res.focus != null or ctx.res.redraw) {
            win.redraw();
        } else if (win.focused_text != null) {
            win.focused_text = null;
            win.redraw();
        }
    }

    /// Run the page of `cat` in `ctx`. false: the section has no page of
    /// its own (placeholder).
    fn runPanel(win: *Window, cat: Category, ctx: *panels.Ctx) bool {
        const ox = frame_left + 2;
        const oy = frame_top + 2;
        const s = win.cur();
        switch (cat) {
            .focus => panels.focus(ctx, ox, oy, s),
            .window_handling => panels.windowHandling(ctx, ox, oy, s),
            .workspace => panels.workspace(ctx, ox, oy, s),
            .appearance => panels.appearance(ctx, ox, oy, s),
            .mouse_settings => panels.mouse(ctx, ox, oy, s),
            .ergonomic => panels.ergonomic(ctx, ox, oy, s),
            .docks => panels.docks(ctx, ox, oy, s),
            .configurations => panels.configurations(ctx, ox, oy, s),
            .keyboard_shortcuts => panels.shortcuts(ctx, ox, oy, win.prefs.bind_list, &win.bind_scroll),
            else => return false,
        }
        return true;
    }

    fn dragScroller(win: *Window) void {
        const th = thumb();
        const track = strip_w - 4 - th.w;
        if (track <= 0) return;
        const rel = win.px - win.drag_off - (strip_x + 2);
        win.setScroll(@divTrunc(rel * maxScroll(), track));
    }

    fn redraw(win: *Window) void {
        win.draw() catch |err| std.log.err("draw failed: {t}", .{err});
    }

    fn setScroll(win: *Window, v: i32) void {
        const clamped = std.math.clamp(v, 0, maxScroll());
        if (clamped == win.scroll_x) return;
        win.scroll_x = clamped;
        win.redraw();
    }

    fn onPress(win: *Window) void {
        const x = win.px;
        const y = win.py;

        // Scroller track
        if (x >= strip_x and x < strip_x + strip_w and
            y >= strip_y + icon_viewport_h and y < strip_y + strip_h)
        {
            const th = thumb();
            const tx = th.x(win.scroll_x);
            if (x >= tx and x < tx + th.w) {
                win.dragging = true;
                win.drag_off = x - tx;
            } else if (x < tx) {
                win.setScroll(win.scroll_x - strip_w);
            } else {
                win.setScroll(win.scroll_x + strip_w);
            }
            return;
        }

        // Section icons
        if (win.handleClick(x, y)) {
            if (win.selected) |cat| {
                if (win.toplevel) |t| t.setTitle(cat.label());
            }
            win.focused_text = null;
            win.prefs.snapshotPage();
            win.close_armed = false;
            win.redraw();
            return;
        }

        // Panel-Controls
        if (win.selected) |cat| {
            if (x >= frame_left and x < frame_left + frame_width and y >= frame_top and y < frame_top + frame_height) {
                win.panelClick(cat, x, y);
                return;
            }
        }

        // Button bar
        if (y >= button_y and y < button_y + button_h) {
            if (x >= close_x and x < close_x + save_close_w) {
                win.onClose();
            } else if (x >= save_x and x < save_x + save_close_w) {
                if (win.prefs.dirty()) {
                    win.save();
                    win.redraw();
                }
            } else if (x >= revert_all_x and x < revert_all_x + cmd_button_w) {
                if (win.prefs.dirty()) {
                    win.prefs.revertAll();
                    win.focused_text = null;
                    win.close_armed = false;
                    win.setStatus("Reverted all");
                    win.redraw();
                }
            } else if (x >= revert_page_x and x < revert_page_x + cmd_button_w) {
                if (win.selected != null and win.prefs.dirty()) {
                    win.prefs.revertPage();
                    win.focused_text = null;
                    win.setStatus("Reverted page");
                    win.redraw();
                }
            }
        }
    }

    /// Close. With unsaved changes the first click only warns -- a second
    /// one discards them.
    fn onClose(win: *Window) void {
        if (win.prefs.dirty() and !win.close_armed) {
            win.close_armed = true;
            win.setStatus("Unsaved changes! Click Close again to discard them");
            win.redraw();
            return;
        }
        win.closed = true;
    }

    fn handleClick(win: *Window, x: i32, y: i32) bool {
        if (y < strip_y or y >= strip_y + icon_viewport_h) return false;
        if (x < strip_x + 2 or x >= strip_x + strip_w - 2) return false;
        const rel_x = x - (strip_x + 2) + win.scroll_x;
        const index = @divTrunc(rel_x, icon_size);
        if (index < 0 or index >= Category.all.len) return false;
        const cat = Category.all[@intCast(index)];
        if (win.selected == cat) return false;
        win.selected = cat;
        return true;
    }

    // ---- xdg_wm_base / xdg_surface / xdg_toplevel ---------------------------
    pub fn wmBaseListener(base: *xdg.WmBase, ev: xdg.WmBase.Event, _: *Window) void {
        switch (ev) {
            .ping => |p| base.pong(p.serial),
        }
    }

    pub fn xdgSurfaceListener(surf: *xdg.Surface, ev: xdg.Surface.Event, win: *Window) void {
        switch (ev) {
            .configure => |c| {
                surf.ackConfigure(c.serial);
                win.configured = true;
                win.draw() catch |err| {
                    std.log.err("draw failed: {t}", .{err});
                };
            },
        }
    }

    pub fn toplevelListener(_: *xdg.Toplevel, ev: xdg.Toplevel.Event, win: *Window) void {
        switch (ev) {
            .configure => {},
            .close => win.closed = true,
        }
    }

    pub fn create(win: *Window) !void {
        const compositor = win.compositor orelse return error.MissingGlobal;
        const wm_base = win.wm_base orelse return error.MissingGlobal;

        const surface = try compositor.createSurface();
        win.surface = surface;

        const xdg_surface = try wm_base.getXdgSurface(surface);
        win.xdg_surface = xdg_surface;
        xdg_surface.setListener(*Window, xdgSurfaceListener, win);

        const toplevel = try xdg_surface.getToplevel();
        win.toplevel = toplevel;
        toplevel.setListener(*Window, toplevelListener, win);

        toplevel.setTitle("Window Maker Preferences");
        toplevel.setAppId("wlprefs");
        toplevel.setMinSize(win_width, win_height);
        toplevel.setMaxSize(win_width, win_height);

        try win.loadIcons();
        try win.createBuffer();

        surface.commit();
    }

    fn loadIcons(win: *Window) !void {
        var loaded: usize = 0;
        errdefer for (win.icons[0..loaded]) |*img| img.deinit();
        for (Category.all, 0..) |cat, i| {
            win.icons[i] = try gfx.Image.fromPngBytes(cat.icon());
            loaded += 1;
        }
        win.menu_imgs = try panel_menu.Images.load();
        win.icon_set = icons.Set.load();
        win.icons_loaded = true;
    }

    /// The window's single buffer: a memfd, mapped for the whole life of the
    /// window, wrapped in one wl_buffer. The pool is released at once; the
    /// buffer keeps the memory alive.
    fn createBuffer(win: *Window) !void {
        const shm = win.shm orelse return error.MissingGlobal;
        const stride = win_width * 4;
        const size: usize = @intCast(stride * win_height);

        const fd = try std.posix.memfd_create("wlprefs-buffer", 0);
        defer _ = std.os.linux.close(fd);
        switch (std.posix.errno(std.os.linux.ftruncate(fd, @intCast(size)))) {
            .SUCCESS => {},
            else => return error.SystemResources,
        }
        win.shm_data = try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        errdefer std.posix.munmap(win.shm_data);

        const pool = try shm.createPool(fd, @intCast(size));
        defer pool.destroy();
        const buf = try pool.createBuffer(0, win_width, win_height, stride, .argb8888);
        buf.setListener(*Window, bufferListener, win);
        win.buffer = buf;
    }

    fn bufferListener(_: *wl.Buffer, ev: wl.Buffer.Event, win: *Window) void {
        switch (ev) {
            .release => {
                win.buf_busy = false;
                if (win.redraw_pending) {
                    win.redraw_pending = false;
                    win.redraw();
                }
            },
        }
    }

    pub fn deinit(win: *Window) void {
        if (win.icons_loaded) {
            for (&win.icons) |*img| img.deinit();
            win.menu_imgs.deinit();
            win.icon_set.deinit();
        }
        win.prefs.deinit();
        if (win.buffer) |b| b.destroy();
        if (win.shm_data.len > 0) std.posix.munmap(win.shm_data);
        if (win.xkb_state) |s| s.unref();
        if (win.xkb_keymap) |m| m.unref();
        if (win.xkb_ctx) |c| c.unref();
        if (win.toplevel) |t| t.destroy();
        if (win.xdg_surface) |s| s.destroy();
        if (win.surface) |s| s.destroy();
    }

    // ---- drawing --------------------------------------------------------------
    fn draw(win: *Window) !void {
        if (!win.configured) return;
        const surface = win.surface orelse return error.MissingGlobal;
        const buffer = win.buffer orelse return error.MissingGlobal;

        // The compositor still reads the buffer: draw when it lets go.
        if (win.buf_busy) {
            win.redraw_pending = true;
            return;
        }

        try win.paintAll(win.shm_data.ptr);

        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, win_width, win_height);
        surface.commit();
        win.buf_busy = true;
    }

    /// The whole window into `data` (win_width x win_height ARGB32).
    fn paintAll(win: *Window, data: [*]u8) !void {
        var cv = try gfx.Canvas.initForData(data, win_width, win_height, win_width * 4);
        defer cv.deinit();
        cv.clear(widget_face);
        paintStrip(&cv, win);
        paintFrame(&cv, win);
        paintButtons(&cv, win);
        cv.flush();
    }

    /// `wlprefs --shot DIR`: every page as a PNG, without a compositor. For
    /// screenshots in the docs, and for looking at a change without
    /// restarting a session. Needs no Wayland: icons are loaded from files and
    /// the binary only.
    pub fn snapshotAll(win: *Window, dir: []const u8) !void {
        try win.loadIcons();
        const bytes = try win.gpa.alloc(u8, @intCast(win_width * win_height * 4));
        defer win.gpa.free(bytes);

        // The banner first (nothing selected), then every section.
        var i: usize = 0;
        while (i <= Category.all.len) : (i += 1) {
            win.selected = if (i == 0) null else Category.all[i - 1];
            @memset(bytes, 0);
            try win.paintAll(bytes.ptr);

            var cv = try gfx.Canvas.initForData(bytes.ptr, win_width, win_height, win_width * 4);
            defer cv.deinit();
            var name_buf: [64]u8 = undefined;
            const name = if (win.selected) |cat| @tagName(cat) else "start";
            const path = try std.fmt.allocPrintSentinel(win.gpa, "{s}/{d:0>2}-{s}.png", .{ dir, i, name }, 0);
            defer win.gpa.free(path);
            _ = &name_buf;
            if (gfx.c.cairo_surface_write_to_png(cv.surface, path.ptr) != gfx.c.CAIRO_STATUS_SUCCESS) return error.WritePng;
        }
    }

    fn paintStrip(cv: *gfx.Canvas, win: *Window) void {
        cv.relief(strip_x, strip_y, strip_w, strip_h, .sunken);

        const clip_x = strip_x + 2;
        const clip_y = strip_y + 2;
        const clip_w = strip_w - 4;
        const clip_h = icon_viewport_h - 2;

        for (Category.all, 0..) |cat, i| {
            const ix = clip_x + @as(i32, @intCast(i)) * icon_size - win.scroll_x;
            if (ix + icon_size <= clip_x or ix >= clip_x + clip_w) continue;

            const is_sel = (win.selected == cat);
            gfx.c.cairo_save(cv.cr);
            gfx.c.cairo_rectangle(cv.cr, @floatFromInt(clip_x), @floatFromInt(clip_y), @floatFromInt(clip_w), @floatFromInt(clip_h));
            gfx.c.cairo_clip(cv.cr);

            cv.relief(ix, clip_y, icon_size, icon_size, if (is_sel) .sunken else .raised);

            gfx.c.cairo_restore(cv.cr);
            if (win.icons_loaded) {
                const off: i32 = if (is_sel) 1 else 0;
                cv.drawImageClipped(&win.icons[i], ix + 8 + off, clip_y + 8 + off, clip_x, clip_y, clip_w, clip_h);
            }
        }

        const sy = strip_y + icon_viewport_h;
        cv.fillRect(strip_x + 2, sy, strip_w - 4, scroller_h - 2, widget_face);
        cv.relief(strip_x + 1, sy - 1, strip_w - 2, scroller_h, .sunken);

        const th = thumb();
        const tx = th.x(win.scroll_x);
        cv.relief(tx, sy + 1, th.w, scroller_h - 4, .raised);
    }

    fn paintFrame(cv: *gfx.Canvas, win: *Window) void {
        if (win.selected == null) {
            cv.relief(frame_left, frame_top, frame_width, frame_height, .sunken);
            paintBanner(cv, win);
        } else {
            cv.relief(frame_left, frame_top, frame_width, frame_height, .groove);
            if (win.selected) |cat| paintPanel(cv, win, cat);
        }
    }

    fn paintBanner(cv: *gfx.Canvas, win: *Window) void {
        const title = "Window Maker Preferences";
        const ver = "Version " ++ root.version_string;
        const status = "Select a section icon above to begin.";

        cv.drawText(title, frame_left + 140, frame_top + 50, font_bold_title, text_black);
        cv.drawText(ver, frame_left + 220, frame_top + 88, font, text_black);
        cv.drawText(status, frame_left + 150, frame_top + 120, font, text_black);

        // Which file this edits: the one thing worth knowing before changing it.
        if (win.prefs.path) |path| {
            var buf: [300:0]u8 = undefined;
            const shown = std.fmt.bufPrintZ(&buf, "Editing {s}", .{tailOf(path, 70)}) catch "";
            cv.drawTextCentered(shown, frame_left + @divTrunc(frame_width, 2), frame_top + 160, font, text_dim);
        }
    }

    /// The last `n` bytes of `s`, starting at a character boundary.
    fn tailOf(s: []const u8, n: usize) []const u8 {
        if (s.len <= n) return s;
        var start = s.len - n;
        while (start < s.len and (s[start] & 0xC0) == 0x80) start += 1;
        return s[start..];
    }

    fn paintPanel(cv: *gfx.Canvas, win: *Window, cat: Category) void {
        const x = frame_left + 2;
        const y = frame_top + 2;

        if (cat == .menu_preferences) {
            panel_menu.paint(cv, x + 2, y + 2, win.menu_state, &win.menu_imgs);
            return;
        }

        var ctx: panels.Ctx = .{ .mode = .paint, .cv = cv, .focused = win.focused_text, .icons = &win.icon_set };
        if (win.runPanel(cat, &ctx)) return;

        const why = unavailableReason(cat);
        panels.unavailable(&ctx, x, y, why.headline, why.text);
    }

    const Why = struct { headline: [:0]const u8, text: [:0]const u8 };

    /// For a section with no page: what it is, and where to go instead.
    fn unavailableReason(cat: Category) Why {
        return switch (cat) {
            .icons => .{
                .headline = "Not available in wmaker-wl",
                .text = "Windows sit in columns of a scrolling strip; there are no\n" ++
                    "icons or miniwindows on the desktop to place or animate.\n\n" ++
                    "(Dock and Clip tile icons: see the Dock Preferences and\ndockapps.conf.)",
            },
            .paths => .{
                .headline = "Nothing to configure here",
                .text = "wmaker-wl looks for tile icons in the icon theme directories\n" ++
                    "(hicolor, pixmaps) and takes an explicit `icon =` path from\n" ++
                    "dockapps.conf. There is no PixmapPath/FontPath list.",
            },
            .menu => .{
                .headline = "Not part of wlprefs yet",
                .text = "The applications menu is the file\n" ++
                    "~/.config/wmaker-wl/RootMenu (text or property list format).\n" ++
                    "Edit it by hand; it is reloaded together with config.conf.\n\n" ++
                    "A menu editor is on the list in docs/TODO.md.",
            },
            .hot_corner_shortcuts => .{
                .headline = "Not implemented in wmaker-wl",
                .text = "Hot corners have no counterpart yet. Use a key binding\n" ++
                    "instead (Keyboard Shortcuts).",
            },
            .font_simple => .{
                .headline = "Not configurable yet",
                .text = "wmaker-wl draws its menus with Pango's default \"Sans\".\n" ++
                    "Fonts will arrive with themes (docs/WMPREFS.md, section 3.3).",
            },
            .expert => .{
                .headline = "Nothing to configure here",
                .text = "These are X11 rendering switches (dithering, backing store,\n" ++
                    "colour reservation) that do not exist on Wayland.",
            },
            else => .{ .headline = "", .text = "" },
        };
    }

    fn paintButtons(cv: *gfx.Canvas, win: *Window) void {
        const dirty = win.prefs.dirty();
        drawButton(cv, revert_page_x, button_y, cmd_button_w, button_h, "Revert Page", win.selected != null and dirty);
        drawButton(cv, revert_all_x, button_y, cmd_button_w, button_h, "Revert All", dirty);
        drawButton(cv, save_x, button_y, save_close_w, button_h, "Save", dirty and win.prefs.canSave());
        drawButton(cv, close_x, button_y, save_close_w, button_h, "Close", true);

        if (win.status[0] != 0) {
            cv.drawText(&win.status, balloon_x, button_y + @divTrunc(button_h, 2) - 5, font_small, text_dim);
        } else if (dirty) {
            var buf: [48:0]u8 = undefined;
            const n = win.prefs.changed();
            const t = std.fmt.bufPrintZ(&buf, "{d} unsaved change{s}", .{ n, if (n == 1) "" else "s" }) catch "";
            cv.drawText(t, balloon_x, button_y + @divTrunc(button_h, 2) - 5, font_small, text_dim);
        }
    }

    fn drawButton(cv: *gfx.Canvas, x: i32, y: i32, w: i32, h: i32, label: [:0]const u8, enabled: bool) void {
        cv.relief(x, y, w, h, .raised);
        const col = if (enabled) text_black else text_dim;
        cv.drawTextCentered(label, x + @divTrunc(w, 2), y + @divTrunc(h, 2) - 4, font, col);
    }
};
