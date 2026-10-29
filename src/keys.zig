// SPDX-License-Identifier: GPL-3.0
//
// Key bindings, the part that needs neither wlroots nor a seat: which of
// `cfg.binds` does a key press trigger?
//
// The compositor sees raw key events, so matching them against the binds
// is done here. The rules are
// the ones config.lua documents:
//
//   * A bind names a keysym and modifiers: `Super+Shift+e`, `Super+1`,
//     `Super+ü`. The keysym is the one the key has WITHOUT any modifier
//     (level 0) in the layout in use. That is why `Super+Shift+e` matches
//     although Shift turns the key into `E`, and `Super+Shift+1` matches
//     although it produces `!`.
//   * By default the layout in use is the active one; `bind_layout = N`
//     pins every bind to layout N of the keyboard.
//   * Caps Lock and Num Lock never count as modifiers.
//   * What a bind does not name must not be held: `Super+q` does not fire
//     on `Super+Shift+q`.

const std = @import("std");
const xkb = @import("xkbcommon");
const model = @import("model.zig");
const config = model.config;
const types = model.types;

/// Modifier bits a bind can name: Shift, Ctrl, Alt (mod1), mod3, Super
/// (mod4), mod5. Caps Lock (bit 1) and Num Lock (mod2, bit 4) are left out.
pub const relevant: u32 = 0b1110_1101;

pub fn normalize(mods: u32) u32 {
    return mods & relevant;
}

/// Most keysyms one key press is looked up by (level 0 of the layout plus
/// what the key really produces).
pub const max_syms = 8;

pub const Syms = struct {
    items: [max_syms]u32 = undefined,
    len: usize = 0,

    pub fn add(s: *Syms, sym: u32) void {
        if (sym == 0) return; // NoSymbol
        for (s.slice()) |have| if (have == sym) return;
        if (s.len == max_syms) return;
        s.items[s.len] = sym;
        s.len += 1;
    }

    pub fn slice(s: *const Syms) []const u32 {
        return s.items[0..s.len];
    }
};

/// The keysyms a bind for the key `keycode` (an xkb keycode, i.e. evdev + 8)
/// may be written with: level 0 of the pinned (or active) layout first, then
/// the symbols the key produces with the modifiers held.
pub fn candidates(
    keymap: *xkb.Keymap,
    state: *xkb.State,
    pinned_layout: ?u32,
    keycode: xkb.Keycode,
) Syms {
    var out: Syms = .{};

    var layout: xkb.LayoutIndex = state.keyGetLayout(keycode);
    if (pinned_layout) |n| {
        // A layout this keyboard does not have: fall back to the active one.
        if (n < keymap.numLayoutsForKey(keycode)) layout = n;
    }
    for (keymap.keyGetSymsByLevel(keycode, layout, 0)) |sym| out.add(@intFromEnum(sym));

    // The same key as the user sees it: lets `Super+Return` and friends
    // work on keys whose level 0 is empty, and `Super+ü` on a key whose
    // base symbol is not what the layout labels it.
    for (state.keyGetSyms(keycode)) |sym| out.add(@intFromEnum(sym));
    return out;
}

/// Index into `binds` of the first bind this press triggers.
pub fn find(binds: []const config.Bind, mods: u32, syms: []const u32) ?usize {
    const held = normalize(mods);
    for (binds, 0..) |b, i| {
        if (normalize(config.modsBits(b.mods)) != held) continue;
        for (syms) |s| if (s == b.keysym) return i;
    }
    return null;
}

/// Does holding the key of this bind fire the command again? Moving around,
/// scrolling, resizing and the volume / brightness keys do; opening programs,
/// closing windows and toggles do not (a held `Super+q` must not close every
/// window in turn).
pub fn repeats(cmd: types.Command, syms: []const u32) bool {
    switch (cmd) {
        .focus_left,
        .focus_right,
        .focus_up,
        .focus_down,
        .move_column_left,
        .move_column_right,
        .move_window_up,
        .move_window_down,
        .scroll_left,
        .scroll_right,
        .widen_column,
        .narrow_column,
        .float_move,
        .float_resize,
        .focus_window_or_workspace_up,
        .focus_window_or_workspace_down,
        .focus_column_or_output_left,
        .focus_column_or_output_right,
        => return true,
        // A volume or brightness key runs a program (`wpctl`, `brightnessctl`):
        // holding it should keep turning it up.
        .spawn, .shell, .lua => {
            for (syms) |s| if (isLevelKey(s)) return true;
            return false;
        },
        else => return false,
    }
}

/// XF86AudioLowerVolume / RaiseVolume, XF86MonBrightnessDown / Up,
/// XF86KbdBrightnessDown / Up.
fn isLevelKey(sym: u32) bool {
    return switch (sym) {
        0x1008ff11, 0x1008ff13, 0x1008ff03, 0x1008ff02, 0x1008ff06, 0x1008ff05 => true,
        else => false,
    };
}

/// `XF86Switch_VT_1` .. `XF86Switch_VT_12` -> 1 .. 12. The kernel's virtual
/// terminal switch, which a session must do itself: the keymap only names it.
pub fn vtOf(sym: u32) ?u32 {
    const first: u32 = 0x1008fe01;
    if (sym < first or sym >= first + 12) return null;
    return sym - first + 1;
}

/// A bind's key combination the way config.lua writes it: `Super+Shift+Return`.
/// For `wmaker-wl --binds` and for messages.
pub fn writeCombo(w: *std.Io.Writer, mods: config.Modifiers, keysym: u32) std.Io.Writer.Error!void {
    if (mods.mod4) try w.writeAll("Super+");
    if (mods.ctrl) try w.writeAll("Ctrl+");
    if (mods.mod1) try w.writeAll("Alt+");
    if (mods.shift) try w.writeAll("Shift+");
    if (mods.mod3) try w.writeAll("Mod3+");
    if (mods.mod5) try w.writeAll("Mod5+");
    var name: [64]u8 = undefined;
    const n = xkb.Keysym.getName(@enumFromInt(keysym), &name, name.len);
    if (n > 0 and n < 64) {
        try w.writeAll(name[0..@intCast(n)]);
    } else {
        try w.print("0x{x}", .{keysym});
    }
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "writeCombo: modifiers in a fixed order, then the keysym name" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeCombo(&w, .{ .mod4 = true, .shift = true }, @intFromEnum(xkb.Keysym.Return));
    try testing.expectEqualStrings("Super+Shift+Return", w.buffered());

    var w2: std.Io.Writer = .fixed(&buf);
    try writeCombo(&w2, .{}, @intFromEnum(xkb.Keysym.XF86AudioMute));
    try testing.expectEqualStrings("XF86AudioMute", w2.buffered());

    var w3: std.Io.Writer = .fixed(&buf);
    try writeCombo(&w3, .{ .ctrl = true, .mod1 = true }, @intFromEnum(xkb.Keysym.Delete));
    try testing.expectEqualStrings("Ctrl+Alt+Delete", w3.buffered());
}

fn bind(mods: config.Modifiers, name: [:0]const u8) config.Bind {
    return .{ .mods = mods, .keysym = @intFromEnum(xkb.Keysym.fromName(name, .no_flags)), .command = "none" };
}

test "caps lock and num lock are not modifiers" {
    const caps: u32 = 1 << 1;
    const num: u32 = 1 << 4;
    const logo: u32 = 1 << 6;
    try testing.expectEqual(logo, normalize(logo | caps | num));
    try testing.expectEqual(@as(u32, 0), normalize(caps | num));
}

test "find: exact modifiers, first match, any listed keysym" {
    const binds = [_]config.Bind{
        bind(.{ .mod4 = true }, "q"),
        bind(.{ .mod4 = true, .shift = true }, "q"),
        bind(.{ .mod4 = true }, "Return"),
    };
    const logo: u32 = 1 << 6;
    const shift: u32 = 1 << 0;
    const q: u32 = @intFromEnum(xkb.Keysym.fromName("q", .no_flags));
    const ret: u32 = @intFromEnum(xkb.Keysym.Return);

    try testing.expectEqual(@as(?usize, 0), find(&binds, logo, &.{q}));
    try testing.expectEqual(@as(?usize, 1), find(&binds, logo | shift, &.{q}));
    try testing.expectEqual(@as(?usize, 2), find(&binds, logo, &.{ 0xdead, ret }));
    // A modifier the bind does not name, or one it names but is not held.
    try testing.expectEqual(@as(?usize, null), find(&binds, logo | (1 << 2), &.{q}));
    try testing.expectEqual(@as(?usize, null), find(&binds, 0, &.{q}));
    // Locks do not matter.
    try testing.expectEqual(@as(?usize, 0), find(&binds, logo | (1 << 1) | (1 << 4), &.{q}));
}

test "vtOf" {
    try testing.expectEqual(@as(?u32, 1), vtOf(@intFromEnum(xkb.Keysym.XF86Switch_VT_1)));
    try testing.expectEqual(@as(?u32, 12), vtOf(@intFromEnum(xkb.Keysym.XF86Switch_VT_1) + 11));
    try testing.expectEqual(@as(?u32, null), vtOf(@intFromEnum(xkb.Keysym.XF86Switch_VT_1) + 12));
    try testing.expectEqual(@as(?u32, null), vtOf(@intFromEnum(xkb.Keysym.Return)));
}

test "repeats: moving and volume keys do, closing and launching do not" {
    const none: []const u32 = &.{};
    const vol_up: u32 = @intFromEnum(xkb.Keysym.XF86AudioRaiseVolume);
    const ret: u32 = @intFromEnum(xkb.Keysym.Return);
    try testing.expect(repeats(.focus_left, none));
    try testing.expect(repeats(.{ .float_move = .{ .dx = 40, .dy = 0 } }, none));
    try testing.expect(repeats(.{ .shell = "wpctl" }, &.{vol_up}));
    try testing.expect(!repeats(.{ .shell = "foot" }, &.{ret}));
    try testing.expect(!repeats(.close, none));
    try testing.expect(!repeats(.exit, none));
    try testing.expect(!repeats(.toggle_fullscreen, none));
}

test "Syms drops duplicates and NoSymbol" {
    var s: Syms = .{};
    s.add(0);
    s.add(5);
    s.add(5);
    s.add(6);
    try testing.expectEqualSlices(u32, &.{ 5, 6 }, s.slice());
}

test "Shift does not hide the bind's keysym: Super+Shift+e and Super+Shift+1" {
    const ctx = xkb.Context.new(.no_flags) orelse return error.SkipZigTest;
    defer ctx.unref();
    const names: xkb.RuleNames = .{ .rules = null, .model = null, .layout = "us", .variant = null, .options = null };
    const keymap = xkb.Keymap.newFromNames(ctx, &names, .no_flags) orelse return error.SkipZigTest;
    defer keymap.unref();
    const state = xkb.State.new(keymap) orelse return error.SkipZigTest;
    defer state.unref();

    // evdev KEY_E = 18, KEY_1 = 2; xkb keycodes are evdev + 8.
    const key_e: xkb.Keycode = 18 + 8;
    const key_1: xkb.Keycode = 2 + 8;
    // Hold Shift: the keymap's Shift modifier index.
    const shift_idx = keymap.modGetIndex("Shift");
    _ = state.updateMask(@as(xkb.ModMask, 1) << @intCast(shift_idx), 0, 0, 0, 0, 0);

    const binds = [_]config.Bind{
        bind(.{ .mod4 = true, .shift = true }, "e"),
        bind(.{ .mod4 = true, .shift = true }, "1"),
    };
    const logo_shift: u32 = (1 << 6) | 1;

    const e = candidates(keymap, state, null, key_e);
    try testing.expectEqual(@as(?usize, 0), find(&binds, logo_shift, e.slice()));
    const one = candidates(keymap, state, null, key_1);
    try testing.expectEqual(@as(?usize, 1), find(&binds, logo_shift, one.slice()));
}
