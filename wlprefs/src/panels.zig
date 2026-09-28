// SPDX-License-Identifier: 0BSD
//
// Real settings panels for wlprefs. Each panel maps a WPrefs section
// to the wmaker-wl-config.conf keys that actually exist (see
// docs/WMPREFS.md §1/§2). Sections without a Wayland equivalent (Icons,
// Hot Corners, Expert, ...) deliberately remain placeholders (§4).
//
// Structure: `layout()` runs over a panel once per frame and calls `w.checkbox/stepper/...`
// for each widget. The same code serves both for drawing (mode = .paint) and for
// hit-testing (mode = .click) -- this ensures drawing and click areas can never desynchronize.

const std = @import("std");
const gfx = @import("gfx.zig");
const settings = @import("settings.zig");
const Settings = settings.Settings;

const face = gfx.Color.rgb(0xaeaeae);
const black = gfx.Color.rgb(0x000000);
const dim = gfx.Color.rgb(0x505050);
const font = "Sans 10";

pub const Mode = enum { paint, click };

/// What effect a click had.
pub const Result = struct {
    /// A value was changed -> redraw window + mark "dirty".
    changed: bool = false,
    /// A text field gained focus.
    focus: ?*settings.Text = null,
};

/// Context for a single layout() pass.
pub const Ctx = struct {
    mode: Mode,
    cv: ?*gfx.Canvas = null,
    /// Click position (only mode == .click).
    cx: i32 = 0,
    cy: i32 = 0,
    /// Currently focused text field (for the cursor).
    focused: ?*settings.Text = null,
    res: Result = .{},

    fn hit(c: *const Ctx, x: i32, y: i32, w: i32, h: i32) bool {
        return c.mode == .click and c.cx >= x and c.cx < x + w and c.cy >= y and c.cy < y + h;
    }

    // ---- Labels ---------------------------------------------------------

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

    // ---- Checkbox (WMCreateSwitchButton) --------------------------------

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

    // ---- Radio (Enum selection) -----------------------------------------

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

    // ---- Stepper: [-] value [+] ------------------------------------------

    fn stepBtn(c: *Ctx, x: i32, y: i32, sym: [:0]const u8) bool {
        const s: i32 = 20;
        if (c.cv) |cv| {
            cv.fillRect(x, y, s, s, face);
            cv.relief(x, y, s, s, .raised);
            cv.drawTextCentered(sym, x + @divTrunc(s, 2), y + 2, font, black);
        }
        return c.hit(x, y, s, s);
    }

    /// Integer stepper with label on the left. Returns: value changed.
    pub fn stepInt(c: *Ctx, x: i32, y: i32, text: [:0]const u8, v: anytype, lo: i64, hi: i64, step: i64) void {
        c.label(x, y + 2, text);
        const bx = x + 190;
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

    // ---- Color Field: Preview + Hex stepper per channel ------------------

    pub fn colour(c: *Ctx, x: i32, y: i32, text: [:0]const u8, v: *u32) void {
        c.label(x, y + 2, text);
        const bx = x + 150;
        if (c.cv) |cv| {
            cv.fillRect(bx, y, 44, 20, gfx.Color.rgb(v.*));
            cv.relief(bx, y, 44, 20, .sunken);
        }
        // R/G/B each -/+ in steps of 16.
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

    // ---- Text Field --------------------------------------------------------

    pub fn textField(c: *Ctx, x: i32, y: i32, w: i32, text: [:0]const u8, t: *settings.Text) void {
        c.label(x, y + 4, text);
        const fx = x + 110;
        const fw = w - 110;
        if (c.cv) |cv| {
            cv.fillRect(fx, y, fw, 24, gfx.Color.rgb(0xffffff));
            cv.relief(fx, y, fw, 24, .sunken);
            var buf: [200:0]u8 = undefined;
            const n = @min(t.len, buf.len - 1);
            @memcpy(buf[0..n], t.get()[0..n]);
            buf[n] = 0;
            cv.drawText(buf[0..n :0], fx + 5, y + 4, font, black);
            if (c.focused == t) {
                const tw = gfx.measureText(buf[0..n :0], font).w;
                cv.fillRect(fx + 5 + tw + 1, y + 4, 1, 15, black);
            }
        }
        if (c.hit(fx, y, fw, 24)) c.res.focus = t;
    }
};

// ---------------------------------------------------------------------------
// Panels. Origin (ox,oy) = top-left corner of the content box.
// Area: ~520 x 231 px.
// ---------------------------------------------------------------------------

pub fn focus(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 20, oy + 14, 480, 96, "Focus");
    c.checkbox(ox + 40, oy + 40, "Focus follows mouse (sloppy focus)", &s.focus_follows_mouse);
    c.hint(ox + 40, oy + 62, "Focus changes as soon as the mouse pointer enters a window.");
    c.hint(ox + 40, oy + 80, "Off: Focus only via click or keyboard shortcut.");

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
    c.frame(ox + 20, oy + 14, 480, 78, "Workspaces");
    c.stepInt(ox + 40, oy + 40, "Number of workspaces:", &s.workspace_count, 1, settings.max_workspaces, 1);
    c.hint(ox + 40, oy + 66, "Maximum 16. Names: see docs/WMPREFS.md §3.2 (not yet in compositor).");

    c.frame(ox + 20, oy + 104, 480, 112, "Column Width");
    c.stepFrac(ox + 40, oy + 130, "Default width:", &s.default_column_width, 0.05);
    c.stepFrac(ox + 40, oy + 156, "Step size (Wider/Narrower):", &s.width_step, 0.05);
    c.hint(ox + 40, oy + 184, "Presets (width_presets) remain editable in config.conf.");
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
    c.frame(ox + 20, oy + 14, 480, 100, "Mouse Modifier");
    c.label(ox + 40, oy + 40, "Move (left) / Resize (right) with:");
    if (s.mouse_mod_raw) {
        c.hint(ox + 40, oy + 68, "Custom value in config.conf -- will not be overwritten.");
    } else {
        var m = s.mouse_mod;
        if (c.radio(ox + 40, oy + 72, "Super", m == .super)) m = .super;
        if (c.radio(ox + 140, oy + 72, "Alt", m == .alt)) m = .alt;
        if (c.radio(ox + 220, oy + 72, "Ctrl", m == .ctrl)) m = .ctrl;
        if (c.radio(ox + 310, oy + 72, "Shift", m == .shift)) m = .shift;
        s.mouse_mod = m;
    }

    c.frame(ox + 20, oy + 126, 480, 96, "Floating Windows");
    c.stepInt(ox + 40, oy + 152, "Drag threshold to float (px):", &s.drag_threshold, 0, 200, 4);
    c.stepFrac(ox + 40, oy + 182, "Size of new floating windows:", &s.floating_size, 0.05);
}

pub fn ergonomic(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    // WPrefs' "Application Preferences": Default applications.
    c.frame(ox + 20, oy + 14, 480, 132, "Default Applications");
    c.textField(ox + 40, oy + 40, 440, "Terminal:", &s.terminal);
    c.textField(ox + 40, oy + 72, 440, "Launcher:", &s.launcher);
    c.textField(ox + 40, oy + 104, 440, "Browser:", &s.browser);
    c.hint(ox + 40, oy + 158, "Program directly (without shell), arguments separated by space.");
    c.hint(ox + 40, oy + 176, "Sets spawn_terminal / spawn_launcher / spawn_browser.");
}

pub fn docks(c: *Ctx, ox: i32, oy: i32, s: *Settings) void {
    c.frame(ox + 20, oy + 14, 480, 150, "Session & Compatibility");
    c.checkbox(ox + 40, oy + 40, "Automatically start DockApps on launch", &s.enable_dockapps);
    c.checkbox(ox + 40, oy + 68, "Run autostart script on launch", &s.enable_autostart);
    c.checkbox(ox + 40, oy + 96, "Read Window Maker files (~/GNUstep/...)", &s.enable_wmaker_compat);
    c.hint(ox + 40, oy + 124, "Files in ~/.config/wmaker-wl always take precedence.");
    c.hint(ox + 20, oy + 178, "Dock Editor (Icons/Position): awaiting Phase 5, see docs/TODO.md.");
}
