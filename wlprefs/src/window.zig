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
//     WMCustomButtons in WIPImageOnly mode, no per-icon caption;
//   * a single content frame at (-2,105), sized 524x235, flat until the
//     first click and then WRGroove (WPrefs.c: changeSection() flips
//     WPrefs.banner's relief from WRFlat to WRGroove on first use);
//     it shows a centered banner (title/version/status) until a
//     section is picked, then that section's panel;
//   * a row of raised command buttons along the bottom (y=350): Balloon
//     Help (a toggle, unused here) on the left, Revert Page / Revert
//     All / Save / Close on the right;
//   * the window title becomes the selected section's name, exactly as
//     WMSetWindowTitle(WPrefs.win, rec->sectionName) does.
//
// See root.zig's doc comment for what's real vs. stubbed: this is the
// shell only, no section has actual controls yet.
//
// Deliberately NOT a river-window-management client: wlprefs is meant to
// be an ordinary app that wmaker-wl manages like any other window, so it
// only speaks wl_compositor / wl_shm / xdg_wm_base / wl_seat.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const gfx = @import("gfx.zig");
const root = @import("root.zig");
const Category = root.Category;

// ---- NeXTSTEP palette -------------------------------------------------------
// The standard WINGs widget face colour (0xaeaaae, see WINGs/widgets.c
// loadPixmaps()) plus pure black/white for text and relief edges. No
// accent colour anywhere -- selection is shown by sinking a button, not
// by tinting it.

const widget_face = gfx.Color.rgb(0xaeaeae);
const text_black = gfx.Color.rgb(0x000000);
const text_dim = gfx.Color.rgb(0x505050);

const font = "Helvetica 10";
const font_bold_title = "Helvetica Bold 18";

// ---- geometry, ported 1:1 from WPrefs.app/WPrefs.c's createMainWindow -----

const win_width: i32 = 520;
const win_height: i32 = 390;

const strip_x: i32 = 10;
const strip_y: i32 = 10;
const strip_w: i32 = 500;
const strip_h: i32 = 87;

const icon_size: i32 = 64;

const frame_left: i32 = -2; // FRAME_LEFT
const frame_top: i32 = 105; // FRAME_TOP
const frame_width: i32 = 524; // FRAME_WIDTH
const frame_height: i32 = 235; // FRAME_HEIGHT

const button_y: i32 = 350;
const button_h: i32 = 28;
const balloon_x: i32 = 15;
const balloon_w: i32 = 200;
const revert_page_x: i32 = 135;
const revert_all_x: i32 = 235;
const save_x: i32 = 335;
const close_x: i32 = 425;
const cmd_button_w: i32 = 90; // Revert buttons; Save/Close are narrower below
const save_close_w: i32 = 80;

pub const Window = struct {
    gpa: std.mem.Allocator,

    // ---- globals ------------------------------------------------------------
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,

    // ---- this window ----------------------------------------------------------
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,

    /// Set once the compositor has ack'd our first configure; only then
    /// are we allowed to attach a buffer.
    configured: bool = false,
    closed: bool = false,

    /// null = still showing the startup banner (WPrefs.currentPanel ==
    /// NULL); once a tile is clicked this is set and never goes back,
    /// same as upstream.
    selected: ?Category = null,
    /// Horizontal scroll offset of the icon strip, for when there are
    /// more icons than fit in strip_w (WPrefs' WMScrollView).
    scroll_x: i32 = 0,

    pub fn init(gpa: std.mem.Allocator) Window {
        return .{ .gpa = gpa };
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
                    win.seat = reg.bind(g.name, wl.Seat, 7) catch return;
                }
            },
            .global_remove => {},
        }
    }

    // ---- xdg_wm_base --------------------------------------------------------

    pub fn wmBaseListener(base: *xdg.WmBase, ev: xdg.WmBase.Event, _: *Window) void {
        switch (ev) {
            .ping => |p| base.pong(p.serial),
        }
    }

    // ---- xdg_surface --------------------------------------------------------

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

    // ---- xdg_toplevel ---------------------------------------------------------

    pub fn toplevelListener(_: *xdg.Toplevel, ev: xdg.Toplevel.Event, win: *Window) void {
        switch (ev) {
            // WPrefs pins min size == max size == its fixed 520x390; we
            // do the same; compositor-proposed sizes are ignored.
            .configure => {},
            .close => win.closed = true,
        }
    }

    /// Create the surface/xdg_surface/xdg_toplevel triple and map the
    /// window. Call once globals have been bound (after the first
    /// registry roundtrip).
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

        surface.commit();
    }

    pub fn deinit(win: *Window) void {
        if (win.toplevel) |t| t.destroy();
        if (win.xdg_surface) |s| s.destroy();
        if (win.surface) |s| s.destroy();
    }

    // ---- drawing --------------------------------------------------------------

    /// Render the current frame into a freshly-allocated wl_shm buffer and
    /// attach it. A fresh buffer per frame keeps this skeleton simple;
    /// double-buffering with a reused pool is future work once real
    /// controls make redraw frequency matter.
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

        var canvas = try gfx.Canvas.initForData(data.ptr, win_width, win_height, stride);
        defer canvas.deinit();

        win.paint(&canvas);
        canvas.flush();

        const pool = try shm.createPool(fd, @intCast(size));
        defer pool.destroy();

        const buffer = try pool.createBuffer(0, win_width, win_height, stride, .argb8888);
        defer buffer.destroy();

        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, win_width, win_height);
        surface.commit();
    }

    fn paint(win: *Window, cv: *gfx.Canvas) void {
        cv.clear(widget_face);

        win.paintIconStrip(cv);

        if (win.selected) |cat| {
            win.paintPanel(cv, cat);
        } else {
            win.paintBanner(cv);
        }

        win.paintButtonBar(cv);
    }

    /// The scrollable strip of 64x64 section icons (WPrefs.scrollV /
    /// WPrefs.buttonF). Sunken frame; each tile is a raised button that
    /// sinks (.pushed) when it is the selected section, exactly like a
    /// WINGs WMCustomButton with WBBStateLightMask does when "on".
    fn paintIconStrip(win: *Window, cv: *gfx.Canvas) void {
        cv.fillRect(strip_x, strip_y, strip_w, strip_h, widget_face);
        cv.relief(strip_x, strip_y, strip_w, strip_h, .sunken);

        // Icons sit vertically centered in the 87px-tall strip, flush
        // left, one after another -- WMMoveWidget(bPtr, count*64, 0).
        const icon_y = strip_y + @divTrunc(strip_h - icon_size, 2);

        for (Category.all, 0..) |cat, i| {
            const icon_x = strip_x + 2 + @as(i32, @intCast(i)) * icon_size - win.scroll_x;
            if (icon_x + icon_size < strip_x or icon_x > strip_x + strip_w) continue;

            const pushed = win.selected != null and win.selected.? == cat;
            cv.fillRect(icon_x, icon_y, icon_size, icon_size, widget_face);
            cv.relief(icon_x, icon_y, icon_size, icon_size, if (pushed) .pushed else .raised);
            drawIcon(cv, cat, icon_x, icon_y, icon_size);
        }
    }

    /// Startup banner shown until a section is picked -- WPrefs.banner
    /// with nameL/versionL/statusL, flat relief, before changeSection()
    /// ever runs.
    fn paintBanner(win: *Window, cv: *gfx.Canvas) void {
        const x = frame_left;
        const y = frame_top;
        cv.fillRect(x, y, frame_width, frame_height, widget_face);
        // WRFlat: no relief drawn at all, matching WMSetFrameRelief(banner, WRFlat).
        _ = win;

        const cx = x + @divTrunc(frame_width, 2);
        cv.drawTextCentered("Window Maker Preferences", cx, y + 60, font_bold_title, text_black);
        cv.drawTextCentered("wlprefs 0.1.0", cx, y + 130, font, text_dim);
        cv.drawTextCentered("Select a section above to begin.", cx, y + 160, font, text_dim);
    }

    /// A section's content panel. WPrefs.banner switches to WRGroove
    /// once the first section is picked (changeSection()); no per-
    /// setting widgets exist yet, so this only shows the section title
    /// and a placeholder line, same position real controls will use.
    fn paintPanel(win: *Window, cv: *gfx.Canvas, cat: Category) void {
        _ = win;
        const x = frame_left;
        const y = frame_top;
        cv.fillRect(x, y, frame_width, frame_height, widget_face);
        cv.relief(x, y, frame_width, frame_height, .groove);

        cv.drawText(cat.label(), x + 14, y + 12, font_bold_title, text_black);
        cv.strokeLine(x + 14, y + 40, x + frame_width - 14, y + 40, 1, gfx.Color.rgb(0x707070));
        cv.drawText(
            "(this section has no controls yet -- placeholder panel)",
            x + 14,
            y + 56,
            font,
            text_dim,
        );
    }

    /// Bottom command-button row -- WPrefs.balloonBtn / undosBtn /
    /// undoBtn / saveBtn / closeBtn, all at y=350. The revert buttons
    /// stay hidden until a section is dirty in upstream; here (no real
    /// settings yet) they are simply drawn disabled-looking (dim label)
    /// since there is nothing to revert.
    fn paintButtonBar(win: *Window, cv: *gfx.Canvas) void {
        drawToggle(cv, balloon_x, button_y, balloon_w, button_h, "Balloon Help", false);

        drawButton(cv, revert_page_x, button_y, cmd_button_w, button_h, "Revert Page", true);
        drawButton(cv, revert_all_x, button_y, cmd_button_w, button_h, "Revert All", true);
        drawButton(cv, save_x, button_y, save_close_w, button_h, "Save", win.selected != null);
        drawButton(cv, close_x, button_y, save_close_w, button_h, "Close", true);
    }

    fn drawButton(cv: *gfx.Canvas, x: i32, y: i32, w: i32, h: i32, label: [:0]const u8, enabled: bool) void {
        cv.fillRect(x, y, w, h, widget_face);
        cv.relief(x, y, w, h, .raised);
        const cx = x + @divTrunc(w, 2);
        const cy = y + @divTrunc(h, 2) - 5;
        cv.drawTextCentered(label, cx, cy, font, if (enabled) text_black else text_dim);
    }

    fn drawToggle(cv: *gfx.Canvas, x: i32, y: i32, w: i32, h: i32, label: [:0]const u8, on: bool) void {
        _ = w; // Signalisiert dem Compiler, dass 'w' vorsätzlich nicht genutzt wird

        const box_size = 14;
        const box_y = y + @divTrunc(h - box_size, 2);
        cv.fillRect(x, box_y, box_size, box_size, widget_face);
        cv.relief(x, box_y, box_size, box_size, .sunken);
        if (on) cv.fillRect(x + 3, box_y + 3, box_size - 6, box_size - 6, text_black);

        cv.drawText(label, x + box_size + 8, y + @divTrunc(h, 2) - 5, font, text_black);
    }

    /// Simple placeholder glyphs, one per category, drawn from primitive
    /// shapes only -- real icon artwork (TIFF/XPM, as WPrefs itself
    /// ships in tiff/xpm/) can replace these later without touching
    /// layout or hit-testing.
    fn drawIcon(cv: *gfx.Canvas, cat: Category, x: i32, y: i32, size: i32) void {
        const cx = x + @divTrunc(size, 2);
        const cy = y + @divTrunc(size, 2);
        const r = @divTrunc(size, 2) - 14;
        switch (cat) {
            .layout => {
                const s = @divTrunc(size, 2) - 12;
                const gap = 4;
                cv.strokeRect(cx - s - gap / 2, cy - s - gap / 2, s, s, 1.2, text_black);
                cv.strokeRect(cx + gap / 2, cy - s - gap / 2, s, s, 1.2, text_black);
                cv.strokeRect(cx - s - gap / 2, cy + gap / 2, s, s, 1.2, text_black);
                cv.strokeRect(cx + gap / 2, cy + gap / 2, s, s, 1.2, text_black);
            },
            .look => {
                cv.strokeCircle(cx, cy, r, 1.2, text_black);
                cv.fillCircle(cx, cy, r - 2, gfx.Color.rgb(0x505050));
            },
            .workspaces => {
                const bar_w = 7;
                const bar_h = size - 28;
                var i: i32 = 0;
                while (i < 3) : (i += 1) {
                    const bx = x + 14 + i * (bar_w + 4);
                    cv.strokeRect(bx, cy - @divTrunc(bar_h, 2), bar_w, bar_h, 1.2, text_black);
                }
            },
            .programs => {
                cv.strokeRect(x + 12, y + 16, size - 24, size - 32, 1.2, text_black);
                cv.drawTextCentered(">_", cx, y + 26, "monospace 8", text_black);
            },
            .bindings => {
                cv.strokeRect(x + 16, y + 18, size - 32, size - 36, 1.2, text_black);
                cv.drawTextCentered("K", cx, y + 30, font, text_black);
            },
            .wmaker_compat => {
                cv.strokeCircle(cx - 6, cy, r - 4, 1.2, text_black);
                cv.strokeRect(cx - 2, cy - (r - 4), 2 * (r - 4), 2 * (r - 4), 1.2, text_black);
            },
        }
    }

    /// Hit-test the icon strip and update selection. Returns true if the
    /// selection changed (caller should redraw and update the window
    /// title, exactly as WMSetWindowTitle(win, sectionName) does).
    pub fn handleClick(win: *Window, x: i32, y: i32) bool {
        if (y < strip_y or y >= strip_y + strip_h) return false;
        const icon_y = strip_y + @divTrunc(strip_h - icon_size, 2);
        if (y < icon_y or y >= icon_y + icon_size) return false;

        for (Category.all, 0..) |cat, i| {
            const icon_x = strip_x + 2 + @as(i32, @intCast(i)) * icon_size - win.scroll_x;
            if (x >= icon_x and x < icon_x + icon_size) {
                if (win.selected != null and win.selected.? == cat) return false;
                win.selected = cat;
                return true;
            }
        }
        return false;
    }
};
