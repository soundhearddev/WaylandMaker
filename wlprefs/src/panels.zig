// SPDX-License-Identifier: 0BSD
//
// The settings pages of wlprefs. Each page maps a WPrefs.app section onto
// the config.conf keys wmaker-wl really has (docs/WMPREFS.md). A section
// without a counterpart says so and says why, instead of showing controls
// that would do nothing.
//
// Structure: a page is ONE function that is run twice per interaction -- once
// with mode = .paint to draw it, once with mode = .click to find out what was
// hit. Drawing and hit areas are the same code, so they cannot drift apart.

const std = @import("std");
const gfx = @import("gfx.zig");
const settings = @import("settings.zig");
const icons = @import("icons.zig");
const binds = @import("binds.zig");
const Settings = settings.Settings;

const face = gfx.Color.rgb(0xaeaeae);
const black = gfx.Color.rgb(0x000000);
const white = gfx.Color.rgb(0xffffff);
const dim = gfx.Color.rgb(0x505050);
const font = "Sans 10";
const font_small = "Sans 7";

pub const Mode = enum { paint, click };

/// What effect a click had.
pub const Result = struct {
    /// A value was changed -> redraw + the Save button lights up.
    changed: bool = false,
    /// A text field gained focus.
    focus: ?*settings.Text = null,
    /// The click did something that needs a redraw but changes no setting
    /// (scrolling a list).
    redraw: bool = false,
};

/// Context for a single pass over a page.
pub const Ctx = struct {
    mode: Mode,
    cv: ?*gfx.Canvas = null,
    /// Click position (only mode == .click).
    cx: i32 = 0,
    cy: i32 = 0,
    /// The text field that has the keyboard (for its cursor).
    focused: ?*settings.Text = null,
    icons: ?*const icons.Set = null,
    res: Result = .{},

    fn hit(c: *const Ctx, x: i32, y: i32, w: i32, h: i32) bool {
        return c.mode == .click and c.cx >= x and c.cx < x + w and c.cy >= y and c.cy < y + h;
    }

    // ---- labels ---------------------------------------------------------

    /// WMFrame with a title: groove border starting half a line down, the
    /// title interrupting the top edge.
    pub fn frame(c: *Ctx, x: i32, y: i32, w: i32, h: i32, title: ?[:0]const u8) void {
        const cv = c.cv orelse return;
        const top: i32 = if (title != null) 7 else 0;
        cv.relief(x, y + top, w, h - top, .groove);
        if (title) |t| {
            const size = gfx.measureText(t, font);
            cv.fillRect(x + 8, y, size.w + 6, size.h, face);
            cv.drawText(t, x + 11, y, font, black);
        }
    }

    pub fn label(c: *Ctx, x: i32, y: i32, text: [:0]const u8) void {
        const cv = c.cv orelse return;
        cv.drawText(text, x, y, font, black);
    }

    pub fn hint(c: *Ctx, x: i32, y: i32, text: [:0]const u8) void {
        const cv = c.cv orelse return;
        cv.drawText(text, x, y, font, dim);
    }

    // ---- checkbox (WMCreateSwitchButton) --------------------------------

    pub fn checkbox(c: *Ctx, x: i32, y: i32, text: [:0]const u8, v: *bool) void {
        const box: i32 = 14;
        if (c.cv) |cv| {
            cv.fillRect(x, y, box, box, face);
            cv.relief(x, y, box, box, .sunken);
            if (v.*) cv.fillRect(x + 4, y + 4, box - 8, box - 8, black);
            cv.drawText(text, x + box + 8, y - 1, font, black);
        }
        const w = box + 8 + (if (c.mode == .click) gfx.measureText(text, font).w else 0);
        if (c.hit(x, y, w, box)) {
            v.* = !v.*;
            c.res.changed = true;
        }
    }

    // ---- radio ------------------------------------------------------------

    pub fn radio(c: *Ctx, x: i32, y: i32, text: [:0]const u8, selected: bool) bool {
        const r: i32 = 7;
        if (c.cv) |cv| {
            cv.fillRect(x, y, 2 * r, 2 * r, face);
            cv.relief(x, y, 2 * r, 2 * r, .sunken);
            if (selected) cv.fillCircle(x + r, y + r, 3, black);
            cv.drawText(text, x + 2 * r + 8, y - 1, font, black);
        }
        const w = 2 * r + 8 + (if (c.mode == .click) gfx.measureText(text, font).w else 0);
        if (c.hit(x, y, w, 2 * r)) {
            c.res.changed = true;
            return true;
        }
        return false;
    }

    // ---- a radio made of a picture (WBTOnOff image buttons) ---------------

    /// A 48x48 button showing icon `id` -- or, when no icon has been
    /// provided, the marked fallback -- pushed in when selected, with its
    /// text label under it.
    pub fn iconRadio(c: *Ctx, x: i32, y: i32, id: icons.Id, selected: bool) bool {
        const sp = icons.spec(id);
        const pad: i32 = 2;
        const bw = sp.w + 2 * pad;
        const bh = sp.h + 2 * pad;
        if (c.cv) |cv| {
            cv.fillRect(x, y, bw, bh, face);
            cv.relief(x, y, bw, bh, if (selected) .pushed else .raised);
            const off: i32 = if (selected) 1 else 0;
            if (c.icons) |set| {
                icons.draw(cv, set, id, x + pad + off, y + pad + off);
            } else {
                icons.drawFallback(cv, id, x + pad + off, y + pad + off);
            }
            const t = gfx.measureText(sp.label, font_small);
            cv.drawText(sp.label, x + @divTrunc(bw - t.w, 2), y + bh + 2, font_small, if (selected) black else dim);
        }
        if (c.hit(x, y, bw, bh)) {
            c.res.changed = true;
            return true;
        }
        return false;
    }

    // ---- stepper: [-] value [+] -----------------------------------------

    fn stepBtn(c: *Ctx, x: i32, y: i32, sym: [:0]const u8) bool {
        const s: i32 = 20;
        if (c.cv) |cv| {
            cv.fillRect(x, y, s, s, face);
            cv.relief(x, y, s, s, .raised);
            cv.drawTextCentered(sym, x + @divTrunc(s, 2), y + 2, font, black);
        }
        return c.hit(x, y, s, s);
    }

    /// Integer stepper; the label gets `lw` px.
    pub fn stepIntW(c: *Ctx, x: i32, y: i32, lw: i32, text: [:0]const u8, v: anytype, lo: i64, hi: i64, step: i64) void {
        c.label(x, y + 2, text);
        const bx = x + lw;
        if (c.stepBtn(bx, y, "-")) {
            v.* = @intCast(@max(lo, @as(i64, v.*) - step));
            c.res.changed = true;
        }
        if (c.cv) |cv| {
            var buf: [24:0]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d}", .{v.*}) catch "?";
            cv.fillRect(bx + 22, y, 52, 20, face);
            cv.relief(bx + 22, y, 52, 20, .sunken);
            cv.drawTextCentered(s, bx + 22 + 26, y + 2, font, black);
        }
        if (c.stepBtn(bx + 76, y, "+")) {
            v.* = @intCast(@min(hi, @as(i64, v.*) + step));
            c.res.changed = true;
        }
    }

    pub fn stepInt(c: *Ctx, x: i32, y: i32, text: [:0]const u8, v: anytype, lo: i64, hi: i64, step: i64) void {
        c.stepIntW(x, y, 190, text, v, lo, hi, step);
    }

    /// Fraction stepper (0.05..1.0), displayed as a percentage.
    pub fn stepFrac(c: *Ctx, x: i32, y: i32, text: [:0]const u8, v: *f64, step: f64) void {
        c.label(x, y + 2, text);
        const bx = x + 190;
        if (c.stepBtn(bx, y, "-")) {
            v.* = @max(0.05, @round((v.* - step) * 1000) / 1000);
            c.res.changed = true;
        }
        if (c.cv) |cv| {
            var buf: [24:0]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d:.0} %", .{v.* * 100}) catch "?";
            cv.fillRect(bx + 22, y, 52, 20, face);
            cv.relief(bx + 22, y, 52, 20, .sunken);
            cv.drawTextCentered(s, bx + 22 + 26, y + 2, font, black);
        }
        if (c.stepBtn(bx + 76, y, "+")) {
            v.* = @min(1.0, @round((v.* + step) * 1000) / 1000);
            c.res.changed = true;
        }
    }

    // ---- colour: preview + R/G/B steppers ----------------------------------

    pub fn colour(c: *Ctx, x: i32, y: i32, text: [:0]const u8, v: *u32) void {
        c.label(x, y + 2, text);
        const bx = x + 150;
        if (c.cv) |cv| {
            cv.fillRect(bx, y, 44, 20, gfx.Color.rgb(v.*));
            cv.relief(bx, y, 44, 20, .sunken);
        }
        const names = [_][:0]const u8{ "R", "G", "B" };
        inline for (names, 0..) |n, i| {
            const shift: u5 = @intCast(16 - 8 * i);
            const px = bx + 56 + @as(i32, @intCast(i)) * 96;
            c.label(px, y + 2, n);
            var ch: i64 = (v.* >> shift) & 0xff;
            if (c.stepBtn(px + 12, y, "-")) {
                ch = @max(0, ch - 16);
                v.* = (v.* & ~(@as(u32, 0xff) << shift)) | (@as(u32, @intCast(ch)) << shift);
                c.res.changed = true;
            }
            if (c.stepBtn(px + 34, y, "+")) {
                ch = @min(255, ch + 16);
                v.* = (v.* & ~(@as(u32, 0xff) << shift)) | (@as(u32, @intCast(ch)) << shift);
                c.res.changed = true;
            }
        }
        if (c.cv) |cv| {
            var buf: [16:0]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "#{x:0>6}", .{v.*}) catch "?";
            cv.drawText(s, bx + 56 + 3 * 96 - 6, y + 2, font, dim);
        }
    }

    // ---- text field ---------------------------------------------------------

    pub fn textField(c: *Ctx, x: i32, y: i32, w: i32, text: [:0]const u8, t: *settings.Text) void {
        c.label(x, y + 4, text);
        const fx = x + 110;
        const fw = w - 110;
        if (c.cv) |cv| {
            cv.fillRect(fx, y, fw, 24, white);
            cv.relief(fx, y, fw, 24, .sunken);
            var buf: [settings.Text.capacity + 1:0]u8 = undefined;
            const n = @min(t.len, buf.len - 1);
            @memcpy(buf[0..n], t.get()[0..n]);
            buf[n] = 0;
            // Show the END of a long value, where the typing happens.
            var start: usize = 0;
            while (start < n and gfx.measureText(buf[start..n :0], font).w > fw - 12) start += 1;
            cv.drawText(buf[start..n :0], fx + 5, y + 4, font, black);
            if (c.focused == t) {
                const tw = gfx.measureText(buf[start..n :0], font).w;
                cv.fillRect(fx + 5 + tw + 1, y + 4, 1, 15, black);
            }
        }
        if (c.hit(fx, y, fw, 24)) c.res.focus = t;
    }
};

// ---------------------------------------------------------------------------
// Pages. Origin (ox, oy) = top-left of the content box, about 520 x 231 px.
// ---------------------------------------------------------------------------

pub fn focus(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 20, oy + 14, 480, 96, "Focus");
    c.checkbox(ox + 40, oy + 40, "Focus follows mouse (sloppy focus)", &s.focus_follows_mouse);
    c.hint(ox + 40, oy + 62, "Focus changes as soon as the mouse pointer enters a window.");
    c.hint(ox + 40, oy + 80, "Off: focus only via click or keyboard shortcut.");

    c.frame(ox + 20, oy + 122, 480, 96, "Scrolling");
    c.label(ox + 40, oy + 146, "Center focused column:");
    var m = s.center_focused_column;
    if (c.radio(ox + 40, oy + 170, "on overflow", m == .on_overflow)) m = .on_overflow;
    if (c.radio(ox + 190, oy + 170, "always", m == .always)) m = .always;
    if (c.radio(ox + 300, oy + 170, "never", m == .never)) m = .never;
    s.center_focused_column = m;
}

pub fn windowHandling(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 20, oy + 10, 480, 90, "New Windows");
    c.label(ox + 40, oy + 34, "Placement:");
    var nw = s.new_window;
    if (c.radio(ox + 40, oy + 58, "new column on right", nw == .new_column)) nw = .new_column;
    if (c.radio(ox + 250, oy + 58, "stack in column", nw == .stack)) nw = .stack;
    s.new_window = nw;

    c.frame(ox + 20, oy + 108, 480, 116, "Gaps & Sizes");
    c.stepInt(ox + 40, oy + 130, "Gap between windows:", &s.gap, 0, 64, 1);
    c.stepInt(ox + 40, oy + 156, "Gap to screen edge:", &s.outer_gap, 0, 64, 1);
    c.stepInt(ox + 40, oy + 182, "Minimum window size (px):", &s.min_window_size, 40, 600, 10);
}

pub fn workspace(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 14, oy + 6, 492, 100, "Workspaces");
    c.stepInt(ox + 34, oy + 28, "Number of workspaces:", &s.workspace_count, 1, settings.max_workspaces, 1);
    c.textField(ox + 34, oy + 54, 452, "Names:", &s.workspace_names);
    c.hint(ox + 34, oy + 82, "Comma separated; shown in the Clip and the menu. Empty = no name.");

    c.frame(ox + 14, oy + 112, 492, 112, "Columns");
    c.stepFrac(ox + 34, oy + 134, "Default width:", &s.default_column_width, 0.05);
    c.stepFrac(ox + 34, oy + 160, "Step size (Wider / Narrower):", &s.width_step, 0.05);
    c.textField(ox + 34, oy + 188, 452, "Presets:", &s.width_presets);
}

pub fn appearance(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 14, oy + 8, 492, 152, "Window Frame");
    c.stepInt(ox + 34, oy + 32, "Border width (px):", &s.border_width, 0, 16, 1);
    c.colour(ox + 34, oy + 62, "Focused:", &s.border_focused);
    c.colour(ox + 34, oy + 90, "Unfocused:", &s.border_unfocused);
    c.colour(ox + 34, oy + 118, "Floating:", &s.border_floating);

    if (c.cv) |cv| {
        // Live preview of the three frames.
        const py = oy + 168;
        const cols = [_]u32{ s.border_focused, s.border_unfocused, s.border_floating };
        const names = [_][:0]const u8{ "focused", "unfocused", "floating" };
        for (cols, 0..) |col, i| {
            const x = ox + 34 + @as(i32, @intCast(i)) * 160;
            const bw: i32 = @max(1, @min(6, s.border_width));
            cv.fillRect(x, py, 140, 46, gfx.Color.rgb(col));
            cv.fillRect(x + bw, py + bw, 140 - 2 * bw, 46 - 2 * bw, gfx.Color.rgb(0x282828));
            cv.drawTextCentered(names[i], x + 70, py + 14, font, gfx.Color.rgb(0xd4d4d4));
        }
    }
}

pub fn mouse(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 20, oy + 14, 480, 108, "Mouse Modifier");
    c.label(ox + 40, oy + 38, "Move (left button) / resize (right button) while holding:");
    if (s.mouse_mod.raw) {
        c.hint(ox + 40, oy + 70, "A custom value in config.conf (e.g. with Mod3/Mod5).");
        c.hint(ox + 40, oy + 90, "It is kept exactly as it is and will not be overwritten.");
    } else {
        c.checkbox(ox + 40, oy + 66, "Super", &s.mouse_mod.super);
        c.checkbox(ox + 140, oy + 66, "Alt", &s.mouse_mod.alt);
        c.checkbox(ox + 220, oy + 66, "Ctrl", &s.mouse_mod.ctrl);
        c.checkbox(ox + 310, oy + 66, "Shift", &s.mouse_mod.shift);
        if (!s.mouse_mod.any()) c.hint(ox + 40, oy + 92, "Select at least one modifier.");
    }

    c.frame(ox + 20, oy + 134, 480, 90, "Floating Windows");
    c.stepInt(ox + 40, oy + 158, "Drag threshold to float (px):", &s.drag_threshold, 0, 200, 4);
    c.stepFrac(ox + 40, oy + 188, "New floating window size:", &s.floating_size, 0.05);
}

/// WPrefs' "Miscellaneous Ergonomic Preferences" holds the default
/// applications in wmaker-wl.
pub fn ergonomic(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 20, oy + 14, 480, 132, "Default Applications");
    c.textField(ox + 40, oy + 40, 440, "Terminal:", &s.terminal);
    c.textField(ox + 40, oy + 72, 440, "Launcher:", &s.launcher);
    c.textField(ox + 40, oy + 104, 440, "Browser:", &s.browser);
    c.hint(ox + 40, oy + 158, "A program and its arguments, separated by spaces (no shell).");
    c.hint(ox + 40, oy + 176, "Started by the spawn_terminal / spawn_launcher / spawn_browser keys.");
}

/// Dock and Clip.
pub fn docks(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    // ---- Dock ---------------------------------------------------------------
    c.frame(ox + 12, oy + 6, 252, 216, "Dock");
    c.checkbox(ox + 28, oy + 28, "Show the Dock", &s.dock_enabled);
    c.label(ox + 28, oy + 50, "Edge of the screen:");
    var e = s.dock_edge;
    if (c.iconRadio(ox + 48, oy + 70, .dock_left, e == .left)) e = .left;
    if (c.iconRadio(ox + 136, oy + 70, .dock_right, e == .right)) e = .right;
    s.dock_edge = e;
    c.stepIntW(ox + 28, oy + 144, 130, "From the top (px):", &s.dock_offset, 0, 4000, 10);
    c.checkbox(ox + 28, oy + 170, "Keep on top of windows", &s.dock_on_top);
    c.checkbox(ox + 28, oy + 192, "Keep windows out from under it", &s.dock_reserve_space);

    // ---- Clip ---------------------------------------------------------------
    c.frame(ox + 272, oy + 6, 238, 216, "Clip");
    c.checkbox(ox + 288, oy + 28, "Show the Clip", &s.clip_enabled);
    c.label(ox + 288, oy + 50, "Corner of the screen:");
    var k = s.clip_corner;
    if (c.iconRadio(ox + 282, oy + 70, .clip_top_left, k == .top_left)) k = .top_left;
    if (c.iconRadio(ox + 336, oy + 70, .clip_top_right, k == .top_right)) k = .top_right;
    if (c.iconRadio(ox + 390, oy + 70, .clip_bottom_left, k == .bottom_left)) k = .bottom_left;
    if (c.iconRadio(ox + 444, oy + 70, .clip_bottom_right, k == .bottom_right)) k = .bottom_right;
    s.clip_corner = k;
    c.checkbox(ox + 288, oy + 160, "Keep on top of windows", &s.clip_on_top);
    c.checkbox(ox + 288, oy + 184, "Start collapsed", &s.clip_collapsed);
}

/// WPrefs' "Other Configurations": session and compatibility switches.
pub fn configurations(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 20, oy + 14, 480, 160, "Session & Compatibility");
    c.checkbox(ox + 40, oy + 42, "Start the DockApps marked autolaunch on launch", &s.enable_dockapps);
    c.checkbox(ox + 40, oy + 70, "Run the autostart script on launch", &s.enable_autostart);
    c.checkbox(ox + 40, oy + 98, "Also read Window Maker's files (~/GNUstep/...)", &s.enable_wmaker_compat);
    c.hint(ox + 40, oy + 130, "Files in ~/.config/wmaker-wl always take precedence over those.");
    c.hint(ox + 40, oy + 148, "Autostart and autolaunch only run when wmaker-wl starts.");
}

/// A section that has no counterpart (yet): the reason, not dead controls.
pub fn unavailable(c: *Ctx, ox: i32, oy: i32, headline: [:0]const u8, text: [:0]const u8) void {
    c.frame(ox + 20, oy + 14, 480, 200, null);
    c.label(ox + 40, oy + 34, headline);
    c.hint(ox + 40, oy + 66, text);
}

// ---- Keyboard shortcuts: read-only list -----------------------------------

pub const bind_rows = 10;
const bind_row_h = 17;

/// How far the list can scroll.
pub fn bindMaxScroll(n: usize) i32 {
    if (n <= bind_rows) return 0;
    return @intCast(n - bind_rows);
}

fn clipText(buf: []u8, s: []const u8, max_chars: usize) [:0]const u8 {
    var end = @min(s.len, max_chars);
    // Never cut a UTF-8 sequence in half.
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    const cut = end < s.len;
    const keep = if (cut and end >= 3) end - 3 else end;
    const n = @min(keep, buf.len - 4);
    @memcpy(buf[0..n], s[0..n]);
    var len = n;
    if (cut) {
        @memcpy(buf[len..][0..3], "...");
        len += 3;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

pub fn shortcuts(c: *Ctx, ox: i32, oy: i32, list: []const binds.Entry, scroll: *i32) void {
    c.hint(ox + 20, oy + 8, "Read-only. * = from your config.conf. Edit the `bind =` lines by hand.");

    const lx = ox + 20;
    const ly = oy + 30;
    const lw = 458;
    const lh = bind_rows * bind_row_h + 4;
    const max_scroll = bindMaxScroll(list.len);
    scroll.* = std.math.clamp(scroll.*, 0, max_scroll);

    if (c.cv) |cv| {
        cv.fillRect(lx, ly, lw, lh, white);
        cv.relief(lx, ly, lw, lh, .sunken);
        var i: usize = 0;
        while (i < bind_rows) : (i += 1) {
            const idx: usize = @intCast(scroll.*);
            if (idx + i >= list.len) break;
            const e = list[idx + i];
            const y = ly + 2 + @as(i32, @intCast(i)) * bind_row_h;
            var b1: [64]u8 = undefined;
            var b2: [96]u8 = undefined;
            if (e.user) cv.drawText("*", lx + 4, y, font, black);
            cv.drawText(clipText(&b1, e.combo, 24), lx + 16, y, font, black);
            cv.drawText(clipText(&b2, e.action, 52), lx + 200, y, font, if (e.user) black else dim);
        }
        if (list.len == 0) cv.drawText("(no key bindings)", lx + 16, ly + 4, font, dim);
    }

    // Scroll buttons.
    const bx = lx + lw + 4;
    if (c.stepBtn(bx, ly, "^") and scroll.* > 0) {
        scroll.* -= 1;
        c.res.redraw = true;
    }
    if (c.stepBtn(bx, ly + lh - 20, "v") and scroll.* < max_scroll) {
        scroll.* += 1;
        c.res.redraw = true;
    }
    if (c.cv) |cv| {
        var buf: [32:0]u8 = undefined;
        if (list.len > bind_rows) {
            const s = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{ scroll.* + 1, list.len }) catch "";
            cv.drawText(s, bx - 4, ly + 28, font_small, dim);
        }
    }
}
