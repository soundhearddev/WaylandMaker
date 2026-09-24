// SPDX-License-Identifier: 0BSD
//
// The Window Maker root menu: data model and the two file formats.
//
//  1. Property-list form (WMRootMenu, plmenu):
//
//       ("Applications",
//         ("XTerm", EXEC, "xterm -sb"),#
//         ("Editors", ("Vim", SHEXEC, "xterm -e vim"), ("Emacs", EXEC, emacs)),
//         ("Workspaces", WORKSPACE_MENU),
//         ("Exit", EXIT))
//
//     An item is `(label, COMMAND, args...)`. If the element after the label
//     is itself an array, the item is a submenu. `SHORTCUT, "key"` may sit
//     between the label and the command.
//
//  2. Text form (`menu`):
//
//       "Applications" MENU
//           "XTerm"  EXEC xterm -sb
//           "Editors" MENU
//               "Vim" SHEXEC xterm -e vim
//           "Editors" END
//       "Applications" END
//
// wlmaker's spelling of the same commands (Execute, ShellExecute, Quit,
// WorkspaceNext, ...) is accepted as well, so both projects' menu files work.
//
// This module only builds the tree. Showing it and running items is done by
// the UI layer; `Action.isImplemented` says which entries can do something.

const std = @import("std");
const plist = @import("plist.zig");

pub const Builtin = enum {
    exit,
    restart,
    refresh,
    arrange_icons,
    shutdown,
    show_all,
    hide_others,
    save_session,
    clear_session,
    info_panel,
    legal_panel,
    /// Expands to one entry per workspace.
    workspace_menu,
    /// Expands to one entry per window.
    windows_menu,
    /// Menu generated from a file, directory or pipe (`OPEN_MENU`).
    open_menu,
    workspace_next,
    workspace_prev,
    workspace_add,
    workspace_destroy_last,
    lock_screen,

    /// Can wmaker-wl act on it? Everything else is shown but disabled.
    pub fn isImplemented(b: Builtin) bool {
        return switch (b) {
            .exit,
            .refresh,
            .workspace_menu,
            .windows_menu,
            .workspace_next,
            .workspace_prev,
            => true,
            else => false,
        };
    }
};

pub const Action = union(enum) {
    /// Program and arguments, split into words when run.
    exec: []const u8,
    /// Run through `/bin/sh -c`.
    shexec: []const u8,
    builtin: Builtin,
    /// `OPEN_MENU` source, kept verbatim.
    open_menu: []const u8,
    submenu: *const Menu,
    /// A command name we do not know; kept for the log and shown disabled.
    unknown: []const u8,
};

pub const Item = struct {
    label: []const u8,
    shortcut: ?[]const u8 = null,
    action: Action,

    pub fn enabled(i: Item) bool {
        return switch (i.action) {
            .exec, .shexec, .submenu => true,
            .builtin => |b| b.isImplemented(),
            .open_menu, .unknown => false,
        };
    }
};

pub const Menu = struct {
    title: []const u8,
    items: []const Item,

    /// Number of entries, submenus included.
    pub fn count(m: *const Menu) usize {
        var n: usize = 0;
        for (m.items) |it| {
            n += 1;
            switch (it.action) {
                .submenu => |s| n += s.count(),
                else => {},
            }
        }
        return n;
    }
};

pub const Parsed = struct {
    menu: *const Menu,
    /// Human-readable problems; the menu is still usable.
    warnings: []const []const u8,
};

pub const Error = error{ Syntax, Empty, OutOfMemory };

/// Parse either format; the first significant character decides.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Parsed {
    return parseDiag(arena, text, null);
}

/// Like `parse`; on a syntax error `diag` says where and why.
pub fn parseDiag(arena: std.mem.Allocator, text: []const u8, diag: ?*plist.Diag) Error!Parsed {
    var b: Builder = .{ .a = arena, .diag = diag };
    var i: usize = 0;
    // Skip leading whitespace and comments to find the format marker.
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
        } else if (c == '#' or (c == '/' and i + 1 < text.len and text[i + 1] == '/')) {
            while (i < text.len and text[i] != '\n') i += 1;
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            i = @min(text.len, i + 2);
        } else break;
    }
    if (i >= text.len) return error.Empty;

    const menu = if (text[i] == '(') try b.fromPlist(text) else try b.fromText(text);
    return .{ .menu = menu, .warnings = try b.warnings.toOwnedSlice(arena) };
}

/// A small menu used when the user has none: it works out of the box.
pub fn builtinDefault(
    arena: std.mem.Allocator,
    terminal: []const u8,
    launcher: []const u8,
    browser: []const u8,
) Error!*const Menu {
    const items = try arena.alloc(Item, 6);
    items[0] = .{ .label = "Terminal", .action = .{ .exec = terminal } };
    items[1] = .{ .label = "Launcher", .action = .{ .exec = launcher } };
    items[2] = .{ .label = "Browser", .action = .{ .exec = browser } };
    items[3] = .{ .label = "Windows", .action = .{ .builtin = .windows_menu } };
    items[4] = .{ .label = "Workspaces", .action = .{ .builtin = .workspace_menu } };
    items[5] = .{ .label = "Exit", .action = .{ .builtin = .exit } };
    const m = try arena.create(Menu);
    m.* = .{ .title = "Root Menu", .items = items };
    return m;
}

// ----------------------------------------------------------------------------
// Command names
// ----------------------------------------------------------------------------

const CommandKind = union(enum) {
    exec,
    shexec,
    open_menu,
    builtin: Builtin,
};

/// Window Maker names and wlmaker names for the same thing.
fn commandKind(name: []const u8) ?CommandKind {
    const table = [_]struct { []const u8, CommandKind }{
        .{ "EXEC", .exec },
        .{ "Execute", .exec },
        .{ "SHEXEC", .shexec },
        .{ "ShellExecute", .shexec },
        .{ "OPEN_MENU", .open_menu },
        .{ "EXIT", .{ .builtin = .exit } },
        .{ "Quit", .{ .builtin = .exit } },
        .{ "Exit", .{ .builtin = .exit } },
        .{ "RESTART", .{ .builtin = .restart } },
        .{ "REFRESH", .{ .builtin = .refresh } },
        .{ "ARRANGE_ICONS", .{ .builtin = .arrange_icons } },
        .{ "SHUTDOWN", .{ .builtin = .shutdown } },
        .{ "SHOW_ALL", .{ .builtin = .show_all } },
        .{ "HIDE_OTHERS", .{ .builtin = .hide_others } },
        .{ "SAVE_SESSION", .{ .builtin = .save_session } },
        .{ "CLEAR_SESSION", .{ .builtin = .clear_session } },
        .{ "INFO_PANEL", .{ .builtin = .info_panel } },
        .{ "LEGAL_PANEL", .{ .builtin = .legal_panel } },
        .{ "WORKSPACE_MENU", .{ .builtin = .workspace_menu } },
        .{ "WINDOWS_MENU", .{ .builtin = .windows_menu } },
        .{ "WorkspaceNext", .{ .builtin = .workspace_next } },
        .{ "WorkspacePrevious", .{ .builtin = .workspace_prev } },
        .{ "WorkspaceAdd", .{ .builtin = .workspace_add } },
        .{ "WorkspaceDestroyLast", .{ .builtin = .workspace_destroy_last } },
        .{ "LockScreen", .{ .builtin = .lock_screen } },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}

// ----------------------------------------------------------------------------
// Builder
// ----------------------------------------------------------------------------

/// Maximum nesting depth for menus (plist and text formats).
/// Prevents stack exhaustion from deeply nested or circular menu structures.
/// 32 levels allows deeply nested menus while protecting against pathological input.
const MAX_MENU_DEPTH = 32;

/// Maximum number of items in a single menu.
/// Prevents excessive memory allocation from malformed input.
const MAX_ITEMS_PER_MENU = 10000;

/// Maximum number of warnings collected during parsing.
/// Prevents memory exhaustion from spammy/malformed input.
const MAX_WARNINGS = 1000;

const Builder = struct {
    a: std.mem.Allocator,
    diag: ?*plist.Diag = null,
    warnings: std.ArrayList([]const u8) = .empty,
    depth: u32 = 0,

    fn warn(b: *Builder, comptime fmt: []const u8, args: anytype) Error!void {
        if (b.warnings.items.len >= MAX_WARNINGS) {
            return;
        }

        const message = try std.fmt.allocPrint(b.a, fmt, args);
        try b.warnings.append(b.a, message);
    }

    fn action(b: *Builder, kind: CommandKind, arg: ?[]const u8, label: []const u8) Error!?Action {
        switch (kind) {
            .exec => {
                const a = arg orelse {
                    try b.warn("`{s}`: EXEC without a command", .{label});
                    return null;
                };
                return .{ .exec = a };
            },
            .shexec => {
                const a = arg orelse {
                    try b.warn("`{s}`: SHEXEC without a command", .{label});
                    return null;
                };
                return .{ .shexec = a };
            },
            .open_menu => return .{ .open_menu = arg orelse "" },
            .builtin => |x| return .{ .builtin = x },
        }
    }

    // ---- plist form ---------------------------------------------------------

    fn fromPlist(b: *Builder, text: []const u8) Error!*const Menu {
        const root = try plist.parse(b.a, text, b.diag);
        const arr = root.items() orelse {
            if (b.diag) |d| d.* = .{ .line = 1, .message = "the menu must be a list ( ... )" };
            return error.Syntax;
        };
        if (arr.len == 0) return error.Empty;
        return b.plistMenu(arr, "Root Menu");
    }

    /// `(title, item, item, ...)`
    fn plistMenu(b: *Builder, arr: []const plist.Value, fallback_title: []const u8) Error!*const Menu {
        if (b.depth >= MAX_MENU_DEPTH) {
            try b.warn("menu nesting too deep (limit: {d}), stopping recursion", .{MAX_MENU_DEPTH});
            return error.Syntax;
        }

        b.depth += 1;
        defer b.depth -= 1;

        var title = fallback_title;
        var rest = arr;
        if (arr.len > 0) if (arr[0].str()) |t| {
            title = t;
            rest = arr[1..];
        };

        var items: std.ArrayList(Item) = .empty;
        for (rest) |el| {
            if (items.items.len >= MAX_ITEMS_PER_MENU) {
                try b.warn("menu `{s}`: too many items (limit: {d}), stopping", .{ title, MAX_ITEMS_PER_MENU });
                break;
            }
            const tuple = el.items() orelse {
                try b.warn("menu `{s}`: entry is not a list, skipped", .{title});
                continue;
            };
            if (try b.plistItem(tuple)) |it| {
                try items.append(b.a, it);
            }
        }
        const m = try b.a.create(Menu);
        m.* = .{ .title = title, .items = try items.toOwnedSlice(b.a) };
        return m;
    }

    /// `(label, COMMAND, args...)`, `(label, SHORTCUT, key, COMMAND, args...)`
    /// or `(label, item, item, ...)` for a submenu.
    fn plistItem(b: *Builder, t: []const plist.Value) Error!?Item {
        if (t.len == 0) return null;
        const label = t[0].str() orelse {
            try b.warn("menu entry without a label, skipped", .{});
            return null;
        };
        if (t.len == 1) {
            try b.warn("`{s}`: entry has no command, skipped", .{label});
            return null;
        }

        // Submenu: the element after the label is a list.
        if (t.len > 1 and t[1].items() != null) {
            const sub = try b.plistMenu(t, label);
            return .{ .label = label, .action = .{ .submenu = sub } };
        }

        var idx: usize = 1;
        var shortcut: ?[]const u8 = null;

        // Sichere Bounds-Checks für SHORTCUT-Parsing
        if (idx < t.len) {
            if (t[idx].str()) |s| {
                if (std.mem.eql(u8, s, "SHORTCUT") and t.len > idx + 2) {
                    shortcut = t[idx + 1].str();
                    idx += 2;
                }
            }
        }

        // Überprüfe, dass wir noch einen Command haben
        if (idx >= t.len) {
            try b.warn("`{s}`: entry has no command after SHORTCUT, skipped", .{label});
            return null;
        }

        const cmd_name = t[idx].str() orelse {
            try b.warn("`{s}`: command is not a word, skipped", .{label});
            return null;
        };
        const arg: ?[]const u8 = if (t.len > idx + 1) t[idx + 1].str() else null;

        const kind = commandKind(cmd_name) orelse {
            try b.warn("`{s}`: unknown command `{s}`", .{ label, cmd_name });
            return .{ .label = label, .shortcut = shortcut, .action = .{ .unknown = cmd_name } };
        };
        const act = (try b.action(kind, arg, label)) orelse return null;
        return .{ .label = label, .shortcut = shortcut, .action = act };
    }

    // ---- text form ----------------------------------------------------------

    fn fromText(b: *Builder, text: []const u8) Error!*const Menu {
        const Frame = struct { title: []const u8, items: std.ArrayList(Item) = .empty };
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            var it = stack.items;
            while (it.len > 0) : (it = it[1..]) {
                it[0].items.deinit(b.a);
            }
            stack.deinit(b.a);
        }
        var root: ?*const Menu = null;

        var in_block_comment = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            var line = std.mem.trim(u8, raw, " \t\r");

            if (in_block_comment) {
                if (std.mem.indexOf(u8, line, "*/")) |e| {
                    line = std.mem.trim(u8, line[e + 2 ..], " \t");
                    in_block_comment = false;
                } else continue;
            }
            if (std.mem.startsWith(u8, line, "/*")) {
                if (std.mem.indexOf(u8, line, "*/")) |e| {
                    line = std.mem.trim(u8, line[e + 2 ..], " \t");
                } else {
                    in_block_comment = true;
                    continue;
                }
            }
            if (line.len == 0 or line[0] == '#') continue;

            const title = nextWord(&line) orelse continue;
            var word = nextWord(&line) orelse {
                try b.warn("line {d}: `{s}` has no command, skipped", .{ line_no, title });
                continue;
            };

            var shortcut: ?[]const u8 = null;
            if (std.mem.eql(u8, word, "SHORTCUT")) {
                shortcut = nextWord(&line);
                word = nextWord(&line) orelse {
                    try b.warn("line {d}: `{s}` has no command, skipped", .{ line_no, title });
                    continue;
                };
            }
            const params = unquoteWhole(std.mem.trim(u8, line, " \t"));

            if (std.mem.eql(u8, word, "MENU")) {
                if (stack.items.len >= MAX_MENU_DEPTH) {
                    try b.warn("line {d}: menu nesting too deep (limit: {d}), ignored", .{ line_no, MAX_MENU_DEPTH });
                    continue;
                }
                stack.append(b.a, .{ .title = title }) catch |err| {
                    if (err == error.OutOfMemory) {
                        try b.warn("line {d}: out of memory", .{line_no});
                        return error.OutOfMemory;
                    }
                };
            } else if (std.mem.eql(u8, word, "END")) {
                var frame = stack.pop() orelse {
                    try b.warn("line {d}: END without a matching MENU, ignored", .{line_no});
                    continue;
                };
                const m = try b.a.create(Menu);
                m.* = .{ .title = frame.title, .items = try frame.items.toOwnedSlice(b.a) };
                if (stack.items.len == 0) {
                    root = m;
                } else {
                    stack.items[stack.items.len - 1].items.append(b.a, .{
                        .label = frame.title,
                        .action = .{ .submenu = m },
                    }) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                    };
                }
            } else {
                if (stack.items.len > 0 and stack.items[stack.items.len - 1].items.items.len >= MAX_ITEMS_PER_MENU) {
                    try b.warn("line {d}: menu too many items (limit: {d}), stopping", .{ line_no, MAX_ITEMS_PER_MENU });
                    continue;
                }
                const kind = commandKind(word) orelse {
                    try b.warn("line {d}: `{s}`: unknown command `{s}`", .{ line_no, title, word });
                    if (stack.items.len > 0) {
                        stack.items[stack.items.len - 1].items.append(b.a, .{
                            .label = title,
                            .shortcut = shortcut,
                            .action = .{ .unknown = word },
                        }) catch |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;
                        };
                    }
                    continue;
                };
                if (stack.items.len == 0) {
                    try b.warn("line {d}: `{s}` is outside any MENU, ignored", .{ line_no, title });
                    continue;
                }
                const arg: ?[]const u8 = if (params.len > 0) params else null;
                if (try b.action(kind, arg, title)) |act| {
                    stack.items[stack.items.len - 1].items.append(b.a, .{
                        .label = title,
                        .shortcut = shortcut,
                        .action = act,
                    }) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                    };
                }
            }
        }

        // MENUs that were never closed still become part of the tree.
        while (stack.pop()) |*frame_ptr| {
            var frame = frame_ptr.*;
            try b.warn("menu `{s}` is not closed with END", .{frame.title});
            const m = try b.a.create(Menu);
            m.* = .{ .title = frame.title, .items = try frame.items.toOwnedSlice(b.a) };
            if (stack.items.len == 0) {
                root = m;
            } else {
                try stack.items[stack.items.len - 1].items.append(b.a, .{
                    .label = frame.title,
                    .action = .{ .submenu = m },
                });
            }
        }
        return root orelse error.Empty;
    }
};

/// Next whitespace-separated word, or a "quoted string". Advances `line`.
fn nextWord(line: *[]const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, line.*, " \t");
    if (s.len == 0) return null;
    if (s.len > 0 and s[0] == '"') {
        // Sichere Suche nach schließendem Quote, beginne nach dem öffnenden
        const end = if (s.len > 1) std.mem.indexOfScalarPos(u8, s, 1, '"') else null;
        const close_pos = end orelse s.len;
        const word = if (close_pos < s.len) s[1..close_pos] else s[1..];
        // Positionierung: wenn Quote gefunden, dann hinter dem schließenden Quote
        line.* = if (close_pos < s.len and close_pos + 1 < s.len) s[close_pos + 1 ..] else "";
        return word;
    }
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    const word = if (end <= s.len) s[0..end] else s;
    line.* = if (end < s.len) s[end..] else "";
    return word;
}

/// `"xterm -e vi"` -> `xterm -e vi` when the whole remainder is one quoted
/// string; anything else is left as written (`gimp >/dev/null`).
fn unquoteWhole(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    if (s[0] != '"' or s[s.len - 1] != '"') return s;

    const inner = s[1 .. s.len - 1];
    // Prüfe auf zusätzliche unescapierte Quotes im inneren
    if (std.mem.indexOfScalar(u8, inner, '"') != null) return s;

    return inner;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "plist form: leaves, submenu, builtin" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\("Applications",
        \\  ("XTerm", EXEC, "xterm -sb"),
        \\  ("Editors",
        \\    ("Vim", SHEXEC, "xterm -e vim"),
        \\    ("Emacs", EXEC, emacs)),
        \\  ("Workspaces", WORKSPACE_MENU),
        \\  ("Exit", EXIT))
    );
    try std.testing.expectEqualStrings("Applications", r.menu.title);
    try std.testing.expectEqual(@as(usize, 4), r.menu.items.len);
    try std.testing.expectEqualStrings("xterm -sb", r.menu.items[0].action.exec);

    const editors = r.menu.items[1].action.submenu;
    try std.testing.expectEqualStrings("Editors", editors.title);
    try std.testing.expectEqual(@as(usize, 2), editors.items.len);
    try std.testing.expectEqualStrings("xterm -e vim", editors.items[0].action.shexec);
    try std.testing.expectEqualStrings("emacs", editors.items[1].action.exec);

    try std.testing.expect(r.menu.items[2].action.builtin == .workspace_menu);
    try std.testing.expect(r.menu.items[3].action.builtin == .exit);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
    try std.testing.expectEqual(@as(usize, 6), r.menu.count());
}

test "plist form: wlmaker spelling and unquoted title" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\// wlmaker style
        \\("Root Menu",
        \\  ("Terminal", Execute, "/usr/bin/foot"),
        \\  ("Chrome", ShellExecute, "google-chrome --ozone-platform=wayland"),
        \\  ("Lock", LockScreen),
        \\  (Exit, Quit))
    );
    try std.testing.expectEqualStrings("/usr/bin/foot", r.menu.items[0].action.exec);
    try std.testing.expect(r.menu.items[1].action == .shexec);
    try std.testing.expect(r.menu.items[2].action.builtin == .lock_screen);
    try std.testing.expectEqualStrings("Exit", r.menu.items[3].label);
    try std.testing.expect(r.menu.items[3].action.builtin == .exit);
}

test "plist form: shortcut" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\("M", ("Term", SHORTCUT, "Mod1+1", EXEC, xterm))
    );
    try std.testing.expectEqualStrings("Mod1+1", r.menu.items[0].shortcut.?);
    try std.testing.expectEqualStrings("xterm", r.menu.items[0].action.exec);
}

test "plist form: bad entries become warnings, the rest survives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\("M",
        \\  ("Good", EXEC, ls),
        \\  ("Odd", FROBNICATE, x),
        \\  ("NoCmd"),
        \\  "not a list",
        \\  ("Empty exec", EXEC))
    );
    try std.testing.expectEqual(@as(usize, 2), r.menu.items.len);
    try std.testing.expect(r.menu.items[1].action == .unknown);
    try std.testing.expect(!r.menu.items[1].enabled());
    try std.testing.expect(r.warnings.len >= 3);
}

test "text form: nested menus, quoting, comments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\/* my menu
        \\   two lines */
        \\# a comment
        \\"Applications" MENU
        \\    "XTerm"   EXEC xterm -sb
        \\    "Gimp"    SHEXEC gimp >/dev/null
        \\    "Quoted"  EXEC "xterm -e vi"
        \\    "Editors" MENU
        \\        "Vim" SHEXEC xterm -e vim
        \\    "Editors" END
        \\    "Exit"    EXIT
        \\"Applications" END
    );
    try std.testing.expectEqualStrings("Applications", r.menu.title);
    try std.testing.expectEqual(@as(usize, 5), r.menu.items.len);
    try std.testing.expectEqualStrings("xterm -sb", r.menu.items[0].action.exec);
    try std.testing.expectEqualStrings("gimp >/dev/null", r.menu.items[1].action.shexec);
    try std.testing.expectEqualStrings("xterm -e vi", r.menu.items[2].action.exec);
    try std.testing.expectEqualStrings("xterm -e vim", r.menu.items[3].action.submenu.items[0].action.shexec);
    try std.testing.expect(r.menu.items[4].action.builtin == .exit);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
}

test "text form: shortcut, unclosed menu, stray END" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\"Root" MENU
        \\  "Term" SHORTCUT Mod1+1 EXEC xterm
        \\"Root" END
        \\"Extra" END
    );
    try std.testing.expectEqualStrings("Mod1+1", r.menu.items[0].shortcut.?);
    try std.testing.expectEqual(@as(usize, 1), r.warnings.len);

    const r2 = try parse(arena.allocator(),
        \\"Root" MENU
        \\  "Term" EXEC xterm
    );
    try std.testing.expectEqual(@as(usize, 1), r2.menu.items.len);
    try std.testing.expectEqual(@as(usize, 1), r2.warnings.len);
}

test "empty and broken input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Empty, parse(arena.allocator(), "  \n # only a comment\n"));
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "(\"M\", (\"a\", EXEC, "));
}

test "builtinDefault has the entries a user needs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try builtinDefault(arena.allocator(), "foot", "fuzzel", "firefox");
    try std.testing.expectEqual(@as(usize, 6), m.items.len);
    for (m.items) |it| try std.testing.expect(it.enabled());
}

test "which builtins are implemented" {
    try std.testing.expect(Builtin.exit.isImplemented());
    try std.testing.expect(Builtin.workspace_menu.isImplemented());
    try std.testing.expect(!Builtin.info_panel.isImplemented());
    try std.testing.expect(!Builtin.shutdown.isImplemented());
}

test "parseDiag says where the menu is broken" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: plist.Diag = .{};
    try std.testing.expectError(error.Syntax, parseDiag(arena.allocator(), "(\"M\",\n  (\"a\" EXEC x))", &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
}
