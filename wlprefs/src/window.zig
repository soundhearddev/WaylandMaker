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
const Category = root.Category;

// ---- NeXTSTEP palette -------------------------------------------------------

const widget_face = gfx.Color.rgb(0xaeaeae);
const text_black = gfx.Color.rgb(0x000000);
const text_dim = gfx.Color.rgb(0x505050);

const font = "Sans 10";
const font_bold_title = "Sans Bold 18";

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

// ---- small file helpers (libc, no std.Io needed) --------------------------
fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try gpa.dupeZ(u8, path);
    defer gpa.free(pz);
    const f = std.c.fopen(pz.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
        if (list.items.len > (1 << 20)) return error.FileTooBig;
    }
    return list.toOwnedSlice(gpa);
}

/// Atomic: write `path.tmp` first, then rename -- a crash in the middle of
/// saving leaves the old config.conf intact.
fn writeFile(a: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.tmp", .{path}, 0);
    const dst = try a.dupeZ(u8, path);
    const f = std.c.fopen(tmp.ptr, "wb") orelse return error.WriteFailed;
    if (std.c.fwrite(data.ptr, 1, data.len, f) != data.len) {
        _ = std.c.fclose(f);
        return error.WriteFailed;
    }
    if (std.c.fclose(f) != 0) return error.WriteFailed;
    if (std.c.rename(tmp.ptr, dst.ptr) != 0) return error.WriteFailed;
}

/// `mkdir -p` for a single directory (~/.config/wmaker-wl).
fn mkdirP(dir: [:0]const u8) void {
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            var tmp: [512]u8 = undefined;
            if (i >= tmp.len) return;
            @memcpy(tmp[0..i], dir[0..i]);
            tmp[i] = 0;
            _ = std.c.mkdir(@ptrCast(&tmp), 0o755);
        }
    }
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

    icons: [Category.all.len]gfx.Image = undefined,
    icons_loaded: bool = false,

    menu_imgs: panel_menu.Images = undefined,
    menu_state: panel_menu.State = .{},

    // ---- settings -----------------------------------------------------------
    cur: settings.Settings = settings.Settings.init(),
    saved: settings.Settings = settings.Settings.init(),
    original: std.ArrayList(u8) = .empty,
    page_snapshot: settings.Settings = settings.Settings.init(),
    status: [64:0]u8 = [_:0]u8{0} ** 64,

    pub fn init(gpa: std.mem.Allocator) Window {
        return .{ .gpa = gpa };
    }

    // ---- load / save config.conf -------------------------------------
    fn setStatus(win: *Window, msg: []const u8) void {
        const n = @min(msg.len, win.status.len - 1);
        @memcpy(win.status[0..n], msg[0..n]);
        win.status[n] = 0;
    }

    pub fn loadSettings(win: *Window) void {
        var arena = std.heap.ArenaAllocator.init(win.gpa);
        defer arena.deinit();
        const path = (root.configPath(arena.allocator()) catch null) orelse return;
        var st = settings.Settings.init();
        win.original.clearRetainingCapacity();
        if (readFile(win.gpa, path)) |text| {
            defer win.gpa.free(text);
            win.original.appendSlice(win.gpa, text) catch {};
            settings.parse(&st, text);
        } else |_| {}
        win.cur = st;
        win.saved = st;
        win.page_snapshot = st;
    }

    fn dirty(win: *const Window) bool {
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        for (settings.keys) |k| {
            const x = settings.format(&win.cur, k, &a);
            const y = settings.format(&win.saved, k, &b);
            if ((x == null) != (y == null)) return true;
            if (x != null and !std.mem.eql(u8, x.?, y.?)) return true;
        }
        return false;
    }

    fn save(win: *Window) void {
        var arena = std.heap.ArenaAllocator.init(win.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = (root.configPath(a) catch null) orelse {
            win.setStatus("No HOME/XDG_CONFIG_HOME");
            return;
        };
        const out = settings.render(a, win.original.items, &win.cur, &win.saved) catch {
            win.setStatus("Save failed (memory)");
            return;
        };
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
            const dir_z = a.dupeZ(u8, path[0..i]) catch return;
            mkdirP(dir_z);
        }
        writeFile(a, path, out) catch {
            win.setStatus("Save failed (write permissions?)");
            return;
        };
        win.original.clearRetainingCapacity();
        win.original.appendSlice(win.gpa, out) catch {};
        win.saved = win.cur;
        win.page_snapshot = win.cur;
        settings.signalReload();
        win.setStatus("Saved, compositor reloaded");
    }

    // ---- wl_registry --------------------------------------------------------
    pub fn registryListener(reg: *wl.Registry, ev: wl.Registry.Event, win: *Window) void {
        switch (ev) {
            .global => |g| {
                if (std.mem.orderZ(u8, g.interface, wl.Compositor.interface.name) == .eq) {
                    win.compositor = reg.bind(g.name, wl.Compositor, 6) catch return;
                } else if (std.mem.orderZ(u8, g.interface, wl.Shm.interface.name) == .eq) {
                    win.shm = reg.bind(g.name, wl.Shm, 1) catch return;
                } else if (std.mem.orderZ(u8, g.interface, xdg.WmBase.interface.name) == .eq) {
                    win.wm_base = reg.bind(g.name, xdg.WmBase, 3) catch return;
                } else if (std.mem.orderZ(u8, g.interface, wl.Seat.interface.name) == .eq) {
                    const seat = reg.bind(g.name, wl.Seat, 7) catch return;
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
                const t = win.focused_text orelse return;
                const st = win.xkb_state orelse return;
                const code: u32 = @as(u32, k.key) + 8; // evdev -> xkb
                const sym = st.keyGetOneSym(code);
                switch (sym) {
                    .BackSpace => t.backspace(),
                    .Return, .KP_Enter, .Escape => win.focused_text = null,
                    else => {
                        var buf: [8]u8 = undefined;
                        const n = st.keyGetUtf8(code, &buf);
                        if (n != 1) return;
                        if (buf[0] < 0x20 or buf[0] == 0x7f) return;
                        t.append(buf[0]);
                    },
                }
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
                if (win.py < strip_y or win.py >= strip_y + strip_h) return;
                if (win.px < strip_x or win.px >= strip_x + strip_w) return;
                win.setScroll(win.scroll_x + @divTrunc(a.value.toInt() * 3, 2) * 2);
            },
            else => {},
        }
    }

    fn panelClick(win: *Window, cat: Category, x: i32, y: i32) void {
        var ctx: panels.Ctx = .{ .mode = .click, .cx = x, .cy = y, .focused = win.focused_text };
        if (!win.runPanel(cat, &ctx)) return;
        win.focused_text = ctx.res.focus;
        if (ctx.res.changed or ctx.res.focus != null) {
            win.status[0] = 0;
            win.redraw();
        } else if (win.focused_text != null) {
            win.focused_text = null;
            win.redraw();
        }
    }

    fn runPanel(win: *Window, cat: Category, ctx: *panels.Ctx) bool {
        const ox = frame_left + 2;
        const oy = frame_top + 2;
        switch (cat) {
            .focus => panels.focus(ctx, ox, oy, &win.cur),
            .window_handling => panels.windowHandling(ctx, ox, oy, &win.cur),
            .workspace => panels.workspace(ctx, ox, oy, &win.cur),
            .appearance => panels.appearance(ctx, ox, oy, &win.cur),
            .mouse_settings => panels.mouse(ctx, ox, oy, &win.cur),
            .ergonomic => panels.ergonomic(ctx, ox, oy, &win.cur),
            .docks => panels.docks(ctx, ox, oy, &win.cur),
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
            win.page_snapshot = win.cur;
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
                win.closed = true;
            } else if (x >= save_x and x < save_x + save_close_w) {
                if (win.selected != null) {
                    win.save();
                    win.redraw();
                }
            } else if (x >= revert_all_x and x < revert_all_x + cmd_button_w) {
                win.cur = win.saved;
                win.focused_text = null;
                win.setStatus("Reverted all");
                win.redraw();
            } else if (x >= revert_page_x and x < revert_page_x + cmd_button_w) {
                win.cur = win.page_snapshot;
                win.focused_text = null;
                win.setStatus("Reverted page");
                win.redraw();
            }
        }
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

        surface.commit();
    }

    fn loadIcons(win: *Window) !void {
        for (Category.all, 0..) |cat, i| {
            win.icons[i] = try gfx.Image.fromPngBytes(cat.icon());
        }
        win.menu_imgs = try panel_menu.Images.load();
        win.icons_loaded = true;
    }

    pub fn deinit(win: *Window) void {
        if (win.icons_loaded) {
            for (&win.icons) |*img| img.deinit();
            win.menu_imgs.deinit();
        }
        win.original.deinit(win.gpa);
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
        const shm = win.shm orelse return error.MissingGlobal;
        const surface = win.surface orelse return error.MissingGlobal;

        const stride = win_width * 4;
        const size: usize = @intCast(stride * win_height);

        const fd = try std.posix.memfd_create("wlprefs-buffer", 0);
        defer _ = std.os.linux.close(fd);

        switch (std.posix.errno(std.os.linux.ftruncate(fd, @intCast(size)))) {
            .SUCCESS => {},
            else => return error.SystemResources,
        }

        const data = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        defer std.posix.munmap(data);

        var cv = try gfx.Canvas.initForData(data.ptr, win_width, win_height, stride);
        defer cv.deinit();

        cv.clear(widget_face);

        paintStrip(&cv, win);
        paintFrame(&cv, win);
        paintButtons(&cv, win);

        const pool = try shm.createPool(fd, @intCast(size));
        defer pool.destroy();

        const buf = try pool.createBuffer(
            0,
            win_width,
            win_height,
            stride,
            .argb8888,
        );
        defer buf.destroy();

        surface.attach(buf, 0, 0);
        surface.damageBuffer(0, 0, win_width, win_height);
        surface.commit();
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
            paintBanner(cv);
        } else {
            cv.relief(frame_left, frame_top, frame_width, frame_height, .groove);
            if (win.selected) |cat| paintPanel(cv, win, cat);
        }
    }

    fn paintBanner(cv: *gfx.Canvas) void {
        const title = "Window Maker Preferences";
        const ver = "Version " ++ root.version_string;
        const status = "Select a section icon above to begin.";

        cv.drawText(title, frame_left + 140, frame_top + 65, font_bold_title, text_black);
        cv.drawText(ver, frame_left + 220, frame_top + 105, font, text_black);
        cv.drawText(status, frame_left + 150, frame_top + 145, font, text_black);
    }

    fn paintPanel(cv: *gfx.Canvas, win: *Window, cat: Category) void {
        const x = frame_left + 2;
        const y = frame_top + 2;

        if (cat == .menu_preferences) {
            panel_menu.paint(cv, x + 2, y + 2, win.menu_state, &win.menu_imgs);
            return;
        }

        var ctx: panels.Ctx = .{ .mode = .paint, .cv = cv, .focused = win.focused_text };
        if (win.runPanel(cat, &ctx)) return;

        const placeholder = "(no Wayland equivalent or not yet implemented in compositor -- see docs/WMPREFS.md §4)";
        cv.drawText(placeholder, x + 30, y + 100, font, text_black);
    }

    fn paintButtons(cv: *gfx.Canvas, win: *Window) void {
        drawButton(cv, revert_page_x, button_y, cmd_button_w, button_h, "Revert Page", win.selected != null);
        drawButton(cv, revert_all_x, button_y, cmd_button_w, button_h, "Revert All", win.selected != null);
        drawButton(cv, save_x, button_y, save_close_w, button_h, "Save", win.selected != null and win.dirty());
        drawButton(cv, close_x, button_y, save_close_w, button_h, "Close", true);

        if (win.status[0] != 0) {
            cv.drawText(&win.status, balloon_x, button_y + @divTrunc(button_h, 2) - 5, font, text_dim);
        }
    }

    fn drawButton(cv: *gfx.Canvas, x: i32, y: i32, w: i32, h: i32, label: [:0]const u8, enabled: bool) void {
        cv.relief(x, y, w, h, .raised);
        const text_col = if (enabled) text_black else text_dim;
        const tx = x + @divTrunc(w - @as(i32, @intCast(label.len * 7)), 2);
        const ty = y + @divTrunc(h, 2) - 5;
        cv.drawText(label, tx, ty, font, text_col);
    }
};
