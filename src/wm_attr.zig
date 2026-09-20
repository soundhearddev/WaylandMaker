// SPDX-License-Identifier: 0BSD
//
// Window Maker's WMWindowAttributes: per-application window rules.
//
//     {
//       "*" = { NoBorder = No; };
//       "xterm.XTerm" = { Omnipresent = Yes; StartWorkspace = 2; };
//       Firefox = { NoTitlebar = Yes; };
//     }
//
// Window Maker matches the X11 window class as "instance.class", "instance",
// "class", then "*", and the first hit wins *per option*. Wayland has one
// identifier, the app_id, which plays both roles. Because X11 classes are
// capitalised ("Firefox") and app_ids usually are not ("firefox"), keys also
// match case-insensitively, so existing Window Maker files keep working.
//
// Every attribute Window Maker knows is parsed and stored. Which ones
// wmaker-wl acts on today is the job of window.zig; the rest is kept for
// the UI layer (title bars, dock, icons).

const std = @import("std");
const plist = @import("plist.zig");

/// A workspace reference: Window Maker accepts a 1-based number or a name.
pub const WorkspaceRef = union(enum) {
    /// 0-based.
    index: u32,
    name: []const u8,
};

pub const Attributes = struct {
    // ---- decoration ------------------------------------------------------
    no_titlebar: ?bool = null,
    no_resizebar: ?bool = null,
    no_miniaturize_button: ?bool = null,
    no_close_button: ?bool = null,
    no_language_button: ?bool = null,
    no_border: ?bool = null,
    ignore_decoration_changes: ?bool = null,

    // ---- behaviour -------------------------------------------------------
    no_miniaturizable: ?bool = null,
    no_hide_others: ?bool = null,
    no_mouse_bindings: ?bool = null,
    no_key_bindings: ?bool = null,
    keep_on_top: ?bool = null,
    keep_on_bottom: ?bool = null,
    omnipresent: ?bool = null,
    skip_window_list: ?bool = null,
    skip_switch_panel: ?bool = null,
    keep_inside_screen: ?bool = null,
    unfocusable: ?bool = null,
    focus_across_workspace: ?bool = null,
    full_maximize: ?bool = null,

    // ---- start state -----------------------------------------------------
    start_miniaturized: ?bool = null,
    start_hidden: ?bool = null,
    start_maximized: ?bool = null,
    dont_save_session: ?bool = null,

    // ---- application icon / dock -------------------------------------------
    no_app_icon: ?bool = null,
    always_user_icon: ?bool = null,
    emulate_app_icon: ?bool = null,
    shared_app_icon: ?bool = null,

    // ---- values ------------------------------------------------------------
    start_workspace: ?WorkspaceRef = null,
    icon: ?[]const u8 = null,

    // ---- wmaker-wl extension (not part of Window Maker) --------------------
    /// `Floating = Yes/No`: open this application floating / tiled, overriding
    /// the defaults. Not a Window Maker option.
    floating: ?bool = null,

    /// Fill in every field that `self` leaves unset from `lower`.
    pub fn withDefaults(self: Attributes, lower: Attributes) Attributes {
        var out = self;
        inline for (@typeInfo(Attributes).@"struct".fields) |f| {
            if (@field(out, f.name) == null) @field(out, f.name) = @field(lower, f.name);
        }
        return out;
    }

    // Convenience readers: unset means "no".
    pub fn is(self: Attributes, comptime field: []const u8) bool {
        return @field(self, field) orelse false;
    }
};

/// `no_titlebar` -> `NoTitlebar`
fn optionName(comptime snake: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var buf: [snake.len]u8 = undefined;
        var n: usize = 0;
        var upper = true;
        for (snake) |c| {
            if (c == '_') {
                upper = true;
                continue;
            }
            buf[n] = if (upper) std.ascii.toUpper(c) else c;
            n += 1;
            upper = false;
        }
        const final = buf[0..n].*;
        return &final;
    }
}

pub const Rule = struct {
    /// The dictionary key: "instance.class", "instance", "class" or "*".
    key: []const u8,
    attrs: Attributes,
};

pub const Table = struct {
    rules: []const Rule = &.{},

    pub fn isEmpty(t: Table) bool {
        return t.rules.len == 0;
    }

    /// Attributes for a window with this app_id. Precedence per option,
    /// most specific first: `app_id.app_id`, `app_id`, `*`.
    pub fn lookup(t: Table, app_id: ?[]const u8) Attributes {
        var result: Attributes = .{};
        if (app_id) |id| {
            if (id.len > 0) {
                for (t.rules) |r| {
                    if (matches(r.key, id, true)) result = result.withDefaults(r.attrs);
                }
                for (t.rules) |r| {
                    if (matches(r.key, id, false)) result = result.withDefaults(r.attrs);
                }
            }
        }
        for (t.rules) |r| {
            if (std.mem.eql(u8, r.key, "*")) result = result.withDefaults(r.attrs);
        }
        return result;
    }
};

/// `dotted` selects the "instance.class" form; otherwise the plain
/// "instance"/"class" form. Case-insensitive, see the header comment.
fn matches(key: []const u8, app_id: []const u8, dotted: bool) bool {
    if (dotted) {
        // "<app_id>.<app_id>", compared without allocating.
        if (key.len != app_id.len * 2 + 1) return false;
        return std.ascii.eqlIgnoreCase(key[0..app_id.len], app_id) and
            key[app_id.len] == '.' and
            std.ascii.eqlIgnoreCase(key[app_id.len + 1 ..], app_id);
    }
    return std.ascii.eqlIgnoreCase(key, app_id);
}

pub const Loaded = struct {
    table: Table,
    warnings: []const []const u8,
};

pub const Error = error{ Syntax, OutOfMemory };

/// Parse WMWindowAttributes text.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Loaded {
    return parseDiag(arena, text, null);
}

/// Like `parse`; on a syntax error `diag` says where and why.
pub fn parseDiag(arena: std.mem.Allocator, text: []const u8, diag: ?*plist.Diag) Error!Loaded {
    var warnings: std.ArrayList([]const u8) = .empty;
    const root = try plist.parse(arena, text, diag);
    const entries = root.entries() orelse {
        if (diag) |d| d.* = .{ .line = 1, .message = "the top level must be a dictionary { ... }" };
        return error.Syntax;
    };

    var rules: std.ArrayList(Rule) = .empty;
    for (entries) |e| {
        if (e.value.entries() == null) {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "`{s}` is not a dictionary, skipped", .{e.key}));
            continue;
        }
        const attrs = try parseAttributes(arena, e.key, e.value, &warnings);
        try rules.append(arena, .{ .key = e.key, .attrs = attrs });
    }
    return .{ .table = .{ .rules = try rules.toOwnedSlice(arena) }, .warnings = try warnings.toOwnedSlice(arena) };
}

fn parseAttributes(
    arena: std.mem.Allocator,
    rule_key: []const u8,
    dict: plist.Value,
    warnings: *std.ArrayList([]const u8),
) Error!Attributes {
    var out: Attributes = .{};
    for (dict.entries().?) |e| {
        var known = false;

        inline for (@typeInfo(Attributes).@"struct".fields) |f| {
            const opt = comptime optionName(f.name);
            if (std.mem.eql(u8, e.key, opt)) {
                known = true;
                switch (f.type) {
                    ?bool => {
                        if (e.value.boolean()) |b| {
                            @field(out, f.name) = b;
                        } else try badValue(arena, warnings, rule_key, e.key);
                    },
                    ?[]const u8 => {
                        if (e.value.str()) |s| {
                            @field(out, f.name) = s;
                        } else try badValue(arena, warnings, rule_key, e.key);
                    },
                    ?WorkspaceRef => {
                        if (e.value.str()) |s| {
                            @field(out, f.name) = parseWorkspace(s);
                        } else try badValue(arena, warnings, rule_key, e.key);
                    },
                    else => comptime unreachable,
                }
            }
        }
        if (!known) {
            try warnings.append(arena, try std.fmt.allocPrint(
                arena,
                "`{s}`: unknown option `{s}`",
                .{ rule_key, e.key },
            ));
        }
    }
    return out;
}

fn badValue(arena: std.mem.Allocator, warnings: *std.ArrayList([]const u8), rule_key: []const u8, opt: []const u8) Error!void {
    try warnings.append(arena, try std.fmt.allocPrint(
        arena,
        "`{s}`: bad value for `{s}`",
        .{ rule_key, opt },
    ));
}

/// Window Maker: a number is 1-based (`%i`, so 0x hex works too), anything
/// else is a workspace name.
fn parseWorkspace(s: []const u8) WorkspaceRef {
    if (std.fmt.parseInt(i64, s, 0)) |n| {
        if (n >= 1 and n <= std.math.maxInt(u32)) return .{ .index = @intCast(n - 1) };
        return .{ .index = std.math.maxInt(u32) }; // out of range: never matches a workspace
    } else |_| {}
    return .{ .name = s };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "option names follow Window Maker's spelling" {
    try std.testing.expectEqualStrings("NoTitlebar", comptime optionName("no_titlebar"));
    try std.testing.expectEqualStrings("KeepOnTop", comptime optionName("keep_on_top"));
    try std.testing.expectEqualStrings("StartWorkspace", comptime optionName("start_workspace"));
    try std.testing.expectEqualStrings("Omnipresent", comptime optionName("omnipresent"));
    try std.testing.expectEqualStrings("NoMiniaturizeButton", comptime optionName("no_miniaturize_button"));
    try std.testing.expectEqualStrings("DontSaveSession", comptime optionName("dont_save_session"));
    try std.testing.expectEqualStrings("Icon", comptime optionName("icon"));
}

test "every option Window Maker documents is known" {
    // The list from Window Maker's own source.
    const wanted = [_][]const u8{
        "Icon",                 "NoTitlebar",              "NoResizebar",     "NoMiniaturizeButton",
        "NoMiniaturizable",     "NoCloseButton",           "NoBorder",        "NoHideOthers",
        "NoMouseBindings",      "NoKeyBindings",           "NoAppIcon",       "KeepOnTop",
        "KeepOnBottom",         "Omnipresent",             "SkipWindowList",  "SkipSwitchPanel",
        "KeepInsideScreen",     "Unfocusable",             "AlwaysUserIcon",  "StartMiniaturized",
        "StartHidden",          "StartMaximized",          "DontSaveSession", "EmulateAppIcon",
        "FocusAcrossWorkspace", "FullMaximize",            "SharedAppIcon",   "NoLanguageButton",
        "StartWorkspace",       "IgnoreDecorationChanges",
    };
    @setEvalBranchQuota(100_000);
    inline for (wanted) |name| {
        var found = false;
        inline for (@typeInfo(Attributes).@"struct".fields) |f| {
            if (std.mem.eql(u8, comptime optionName(f.name), name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "parse a rules file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\{
        \\  "*" = { NoBorder = No; };
        \\  "xterm.XTerm" = { Omnipresent = Yes; StartWorkspace = 2; };
        \\  Firefox = { NoTitlebar = Yes; Icon = "firefox.png"; };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), r.table.rules.len);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
    try std.testing.expectEqual(true, r.table.rules[1].attrs.omnipresent.?);
    try std.testing.expectEqual(@as(u32, 1), r.table.rules[1].attrs.start_workspace.?.index);
    try std.testing.expectEqualStrings("firefox.png", r.table.rules[2].attrs.icon.?);
}

test "lookup: X11 keys match Wayland app_ids, case-insensitively" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\{ "xterm.XTerm" = { Omnipresent = Yes; }; Firefox = { NoTitlebar = Yes; }; }
    );
    // X11 "xterm.XTerm" = instance "xterm", class "XTerm". A Wayland client only
    // has app_id "xterm", which plays both roles, so the existing rule applies.
    try std.testing.expect(r.table.lookup("xterm").omnipresent.?);
    // A different app_id must not match it.
    try std.testing.expect(r.table.lookup("xterm2").omnipresent == null);
    // "Firefox" (class) matches app_id "firefox".
    try std.testing.expect(r.table.lookup("firefox").no_titlebar.?);
    try std.testing.expect(r.table.lookup("FIREFOX").no_titlebar.?);
    try std.testing.expect(r.table.lookup("chromium").no_titlebar == null);
    try std.testing.expect(r.table.lookup(null).no_titlebar == null);
}

test "lookup: dotted form when instance and class are the same" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "{ \"foot.foot\" = { Omnipresent = Yes; }; }");
    try std.testing.expect(r.table.lookup("foot").omnipresent.?);
}

test "lookup: specific beats default, per option" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\{
        \\  "*" = { NoBorder = Yes; NoTitlebar = Yes; };
        \\  foot = { NoBorder = No; };
        \\}
    );
    const foot = r.table.lookup("foot");
    try std.testing.expectEqual(false, foot.no_border.?); // foot overrides
    try std.testing.expectEqual(true, foot.no_titlebar.?); // inherited from "*"
    const other = r.table.lookup("other");
    try std.testing.expectEqual(true, other.no_border.?);
}

test "workspace references" {
    try std.testing.expectEqual(@as(u32, 0), parseWorkspace("1").index);
    try std.testing.expectEqual(@as(u32, 3), parseWorkspace("4").index);
    try std.testing.expectEqualStrings("Mail", parseWorkspace("Mail").name);
    // 0 and negative numbers are not valid workspaces: never match one.
    try std.testing.expectEqual(std.math.maxInt(u32), parseWorkspace("0").index);
}

test "unknown options and bad values are warnings, not failures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\{ foot = { Omnipresent = maybe; FrobnicateWindow = Yes; NoBorder = Yes; }; broken = x; }
    );
    try std.testing.expectEqual(@as(usize, 1), r.table.rules.len);
    try std.testing.expectEqual(true, r.table.rules[0].attrs.no_border.?);
    try std.testing.expect(r.table.rules[0].attrs.omnipresent == null);
    try std.testing.expectEqual(@as(usize, 3), r.warnings.len);
}

test "syntax errors are reported with the line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "{ foot = { NoBorder Yes; }; }"));
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "(1, 2)"));
}

test "empty table returns the defaults" {
    const t: Table = .{};
    try std.testing.expect(t.isEmpty());
    try std.testing.expect(!t.lookup("foot").is("omnipresent"));
}

test "parseDiag says where the file is broken" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: plist.Diag = .{};
    try std.testing.expectError(error.Syntax, parseDiag(arena.allocator(), "{\n  foot = {\n    NoBorder Yes;\n  };\n}", &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.line);
    try std.testing.expectError(error.Syntax, parseDiag(arena.allocator(), "(a, b)", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "dictionary") != null);
}
