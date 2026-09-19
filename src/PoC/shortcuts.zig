// Window Maker keyboard shortcuts: spec parsing ("Mod1+Control+Right") and
// the full table of WKBD_* actions with their *real* default bindings.
//
// C origin: src/keybind.h, src/defaults.c (shortcut entries), src/event.c
// (handleKeyPress). The table below is generated from defaults.c so key
// names ("RootMenuKey", "Workspace1Key", ...) match a real WindowMaker
// defaults file 1:1 and can be loaded straight from it.
//
// This file is deliberately free of Wayland imports (unit-testable):

const std = @import("std");

// ============================================================================
// Modifiers / key specs
// ============================================================================

/// Same bit meaning as river_seat_v1.modifiers, but independent of the
/// generated Wayland bindings. Convert with toRiver() in wm.zig / seat glue.
pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    mod1: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,
    _pad: u2 = 0,

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

pub const KeySpec = struct {
    mods: Mods = .{},
    /// xkbcommon keysym (value of XKB_KEY_*), NOT a Linux evdev code.
    keysym: u32,
};

pub const ParseError = error{ Empty, UnknownModifier, UnknownKey };

/// Parse a Window Maker shortcut. Returns null for "None"/"NONE"/"" which
/// means "unbound" in WindowMaker's defaults.
///
///   "Mod1+M"  "Control+Escape"  "Mod1+Shift+Tab"  "F12"  "None"
///
/// `mod_key` is what the literal word "Mod" would mean; wmaker's own
/// "ModifierKey" default is Mod1. We also accept the aliases Alt/Meta
/// (=Mod1), Super/Win/Logo (=Mod4) and Ctrl (=Control).
pub fn parse(spec: []const u8) ParseError!?KeySpec {
    const s = std.mem.trim(u8, spec, " \t");
    if (s.len == 0 or std.ascii.eqlIgnoreCase(s, "none")) return null;

    var mods: Mods = .{};
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        // A trailing "+" IS the key ("Mod1++" = Mod1 and plus).
        if (i == rest.len - 1 and i == 0) break;
        if (i == 0) break;
        const word = rest[0..i];
        if (!applyModifier(&mods, word)) return error.UnknownModifier;
        rest = rest[i + 1 ..];
        if (rest.len == 0) return error.UnknownKey;
    }

    const keysym = keysymFromName(rest) orelse return error.UnknownKey;
    return KeySpec{ .mods = mods, .keysym = keysym };
}

fn applyModifier(m: *Mods, word: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(word, "shift")) m.shift = true else if (eq(word, "control") or eq(word, "ctrl")) m.ctrl = true else if (eq(word, "mod1") or eq(word, "alt") or eq(word, "meta")) m.mod1 = true else if (eq(word, "mod3")) m.mod3 = true else if (eq(word, "mod4") or eq(word, "super") or eq(word, "win") or eq(word, "logo")) m.mod4 = true else if (eq(word, "mod5")) m.mod5 = true else return false;
    return true;
}

const NamedKey = struct { name: []const u8, sym: u32 };

// Values from <xkbcommon/xkbcommon-keysyms.h>.
const named_keys = [_]NamedKey{
    .{ .name = "BackSpace", .sym = 0xff08 },
    .{ .name = "Tab", .sym = 0xff09 },
    .{ .name = "Return", .sym = 0xff0d },
    .{ .name = "Enter", .sym = 0xff0d },
    .{ .name = "Pause", .sym = 0xff13 },
    .{ .name = "Scroll_Lock", .sym = 0xff14 },
    .{ .name = "Escape", .sym = 0xff1b },
    .{ .name = "Delete", .sym = 0xffff },
    .{ .name = "Home", .sym = 0xff50 },
    .{ .name = "Left", .sym = 0xff51 },
    .{ .name = "Up", .sym = 0xff52 },
    .{ .name = "Right", .sym = 0xff53 },
    .{ .name = "Down", .sym = 0xff54 },
    .{ .name = "Prior", .sym = 0xff55 },
    .{ .name = "Page_Up", .sym = 0xff55 },
    .{ .name = "Next", .sym = 0xff56 },
    .{ .name = "Page_Down", .sym = 0xff56 },
    .{ .name = "End", .sym = 0xff57 },
    .{ .name = "Print", .sym = 0xff61 },
    .{ .name = "Insert", .sym = 0xff63 },
    .{ .name = "Menu", .sym = 0xff67 },
    .{ .name = "Num_Lock", .sym = 0xff7f },
    .{ .name = "KP_Enter", .sym = 0xff8d },
    .{ .name = "KP_Multiply", .sym = 0xffaa },
    .{ .name = "KP_Add", .sym = 0xffab },
    .{ .name = "KP_Subtract", .sym = 0xffad },
    .{ .name = "KP_Divide", .sym = 0xffaf },
    .{ .name = "space", .sym = 0x0020 },
    .{ .name = "comma", .sym = ',' },
    .{ .name = "period", .sym = '.' },
    .{ .name = "minus", .sym = '-' },
    .{ .name = "plus", .sym = '+' },
    .{ .name = "equal", .sym = '=' },
    .{ .name = "slash", .sym = '/' },
    .{ .name = "backslash", .sym = '\\' },
    .{ .name = "semicolon", .sym = ';' },
    .{ .name = "apostrophe", .sym = '\'' },
    .{ .name = "grave", .sym = '`' },
    .{ .name = "bracketleft", .sym = '[' },
    .{ .name = "bracketright", .sym = ']' },
    .{ .name = "XF86AudioLowerVolume", .sym = 0x1008ff11 },
    .{ .name = "XF86AudioMute", .sym = 0x1008ff12 },
    .{ .name = "XF86AudioRaiseVolume", .sym = 0x1008ff13 },
    .{ .name = "XF86AudioPlay", .sym = 0x1008ff14 },
    .{ .name = "XF86AudioStop", .sym = 0x1008ff15 },
    .{ .name = "XF86AudioPrev", .sym = 0x1008ff16 },
    .{ .name = "XF86AudioNext", .sym = 0x1008ff17 },
    .{ .name = "XF86MonBrightnessUp", .sym = 0x1008ff02 },
    .{ .name = "XF86MonBrightnessDown", .sym = 0x1008ff03 },
};

/// Resolve a keysym name without libxkbcommon. Handles named keys above,
/// F1..F35, KP_0..KP_9, single ASCII characters and "U+XXXX"/"0xNNNN".
///
/// Letters map to their LOWER-case keysym: river matches the keysym with
/// modifiers already applied, so Shift+H is "h" + Shift in the binding.
pub fn keysymFromName(name: []const u8) ?u32 {
    if (name.len == 0) return null;

    for (named_keys) |k| {
        if (std.ascii.eqlIgnoreCase(k.name, name)) return k.sym;
    }

    if (name.len >= 2 and (name[0] == 'F' or name[0] == 'f')) {
        if (std.fmt.parseInt(u32, name[1..], 10)) |n| {
            if (n >= 1 and n <= 35) return 0xffbe + (n - 1);
        } else |_| {}
    }

    if (name.len == 4 and std.ascii.startsWithIgnoreCase(name, "KP_")) {
        if (std.fmt.charToDigit(name[3], 10)) |d| {
            return 0xffb0 + @as(u32, d);
        } else |_| {}
    }

    if (name.len == 1) {
        const c = name[0];
        if (c >= 0x20 and c < 0x7f) return std.ascii.toLower(c);
    }

    if (std.ascii.startsWithIgnoreCase(name, "U+")) {
        const cp = std.fmt.parseInt(u32, name[2..], 16) catch return null;
        return if (cp < 0x100) cp else 0x01000000 + cp;
    }
    if (std.mem.startsWith(u8, name, "0x")) {
        return std.fmt.parseInt(u32, name[2..], 16) catch null;
    }
    return null;
}

// ============================================================================
// The WKBD_* action table (generated from src/defaults.c)
// ============================================================================

/// One entry per WKBD_* constant of Window Maker (name lower-cased).
pub const Kbd = enum(u16) {
    workspace3,
    // Add additional enum variants here as needed
};

pub const KbdInfo = struct {
    kbd: Kbd,
    /// Key in the "WindowMaker" defaults domain, e.g. "RootMenuKey".
    name: []const u8,
    /// Default spec as shipped by Window Maker ("None" = unbound).
    default: []const u8,
};

pub const kbd_table = [_]KbdInfo{
    .{ .kbd = .workspace3, .name = "Workspace3Key", .default = "Mod1+3" },
    // Add additional table rows here as needed
};

/// Extension-action ids handed to the core (Action.ext): 0 is "none",
/// Kbd values are shifted by one, and everything from user_base up is free
/// for your own actions.
pub const ext_id_kbd_base: u32 = 1;
pub const ext_id_user_base: u32 = 0x1000;

pub fn kbdToExtId(k: Kbd) u32 {
    return ext_id_kbd_base + @intFromEnum(k);
}

pub fn extIdToKbd(id: u32) ?Kbd {
    if (id < ext_id_kbd_base or id >= ext_id_kbd_base + kbd_table.len) return null;
    return @enumFromInt(@as(u16, @intCast(id - ext_id_kbd_base)));
}

pub fn infoFor(k: Kbd) *const KbdInfo {
    return &kbd_table[@intFromEnum(k)];
}

// ============================================================================
// Tests
// ============================================================================

test "table is in enum order" {
    for (kbd_table, 0..) |row, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i)), @intFromEnum(row.kbd));
    }
}

test "parse defaults from real wmaker" {
    const a = (try parse("Mod1+Control+Right")).?;
    try std.testing.expect(a.mods.mod1 and a.mods.ctrl and !a.mods.shift);
    try std.testing.expectEqual(@as(u32, 0xff53), a.keysym);

    const b = (try parse("Mod1+Shift+Tab")).?;
    try std.testing.expect(b.mods.mod1 and b.mods.shift);
    try std.testing.expectEqual(@as(u32, 0xff09), b.keysym);

    const f = (try parse("F12")).?;
    try std.testing.expectEqual(@as(u32, 0xffc9), f.keysym);

    try std.testing.expect((try parse("None")) == null);
    try std.testing.expect((try parse("")) == null);
}

test "every shipped default parses" {
    for (kbd_table) |row| {
        _ = parse(row.default) catch |err| {
            std.debug.print("bad default {s} = '{s}': {}\n", .{ row.name, row.default, err });
            return err;
        };
    }
}

test "letters and digits" {
    try std.testing.expectEqual(@as(u32, 'm'), (try parse("Mod1+M")).?.keysym);
    try std.testing.expectEqual(@as(u32, '1'), (try parse("Mod4+1")).?.keysym);
    try std.testing.expectEqual(@as(u32, 0xffb5), (try parse("KP_5")).?.keysym);
}

test "errors" {
    try std.testing.expectError(error.UnknownModifier, parse("Hyper+x"));
    try std.testing.expectError(error.UnknownKey, parse("Mod1+NoSuchKey"));
}

test "ext id round trip" {
    const k: Kbd = .workspace3;
    try std.testing.expectEqual(k, extIdToKbd(kbdToExtId(k)).?);
    try std.testing.expect(extIdToKbd(0) == null);
    try std.testing.expect(extIdToKbd(ext_id_user_base) == null);
}
