// SPDX-License-Identifier: GPL-3.0
//
// `wlprefs --check`: look at config.lua the way the settings window would,
// say what is wrong with it, and leave with an exit code a script can use.
// No window, no Wayland connection, and nothing is written.
//
// Exit code 0: nothing wrong (notes are fine). 1: something is wrong --
// the file cannot be read, a key has a value of the wrong kind (the
// compositor refuses it and keeps the default) or a value the window would
// refuse to save. 2 is for a bad command line, see main.zig.
//
// Notes (exit code stays 0): keys the file computes with an expression and
// lines that make key bindings in a way the window's list cannot show. Both
// work in the compositor; the window shows the one with its default value, the
// other not at all, and leaves both alone (a computed key only gives way when
// the user changes it in the window).

const std = @import("std");
const prefs_mod = @import("prefs.zig");
const settings = @import("settings.zig");
const configfile = @import("configfile.zig");

/// Write the report for `p` (a loaded `Prefs`) to `w`; the exit code.
pub fn report(p: *const prefs_mod.Prefs, w: *std.Io.Writer) !u8 {
    const path = p.path orelse {
        try w.writeAll("wlprefs: no HOME / XDG_CONFIG_HOME: cannot find config.lua\n");
        return 1;
    };
    if (p.load_error) |e| {
        try w.print("{s}: {s}\n", .{ path, configfile.readErrorText(e) });
        return 1;
    }
    if (p.is_new) {
        try w.print("{s}: does not exist yet (the compositor uses its defaults): OK\n", .{path});
        return 0;
    }

    var bad: usize = 0;

    for (settings.keys, 0..) |name, i| {
        switch (p.base.odd[i]) {
            .none => {},
            .wrong_type => {
                try w.print("{s}: `{s}` has the wrong kind of value; the compositor ignores it\n", .{ path, name });
                bad += 1;
            },
            .computed => try w.print("{s}: note: `{s}` is computed by the script; wlprefs shows its default and leaves the line alone unless you change that key there\n", .{ path, name }),
        }
    }

    var storage: [96]u8 = undefined;
    if (settings.problem(&p.base, &storage)) |pr| {
        try w.print("{s}: {s}\n", .{ path, pr.message });
        bad += 1;
    }

    if (p.computed_binds > 0) {
        try w.print("{s}: note: {d} line{s} make key bindings the list cannot show (loops, computed keys); they are kept as they are\n", .{
            path,
            p.computed_binds,
            if (p.computed_binds == 1) "" else "s",
        });
    }

    if (bad > 0) {
        try w.print("{s}: {d} problem{s}\n", .{ path, bad, if (bad == 1) "" else "s" });
        return 1;
    }
    try w.print("{s}: OK\n", .{path});
    return 0;
}

/// `wlprefs --check [--config FILE]`: load, report to stderr, return the exit code.
pub fn run(gpa: std.mem.Allocator, config_path: ?[]const u8) !u8 {
    var p = try prefs_mod.Prefs.init(gpa, config_path);
    defer p.deinit();
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const code = report(&p, &w) catch |err| switch (err) {
        // The message did not fit: say what we have.
        error.WriteFailed => 1,
    };
    std.debug.print("{s}", .{w.buffered()});
    return code;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn reportFor(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u8)) !u8 {
    var p = try prefs_mod.Prefs.init(gpa, "/nonexistent/check-test/config.lua");
    defer p.deinit();
    // Feed the text the way load() does for a file that was read.
    p.is_new = false;
    p.base = settings.Settings.init();
    settings.parse(&p.base, text);
    p.computed_binds = @import("binds.zig").computedBindLines(text);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const code = try report(&p, &w);
    try out.appendSlice(gpa, w.buffered());
    return code;
}

test "check: a clean file is OK, exit 0" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), try reportFor(gpa, "gap = 10\nbind(\"Super+x\", \"close\")\n", &out));
    try testing.expect(std.mem.endsWith(u8, out.items, ": OK\n"));
}

test "check: a wrong kind of value is a problem, exit 1" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), try reportFor(gpa, "gap = \"12\"\ndock_edge = 3\n", &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "`gap` has the wrong kind") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "`dock_edge` has the wrong kind") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "2 problems") != null);
}

test "check: computed values and loop binds are notes, not problems" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const text =
        \\local base = 4
        \\gap = base * 2
        \\for i = 1, 9 do bind("Super+" .. i, "workspace " .. i) end
    ;
    try testing.expectEqual(@as(u8, 0), try reportFor(gpa, text, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "note: `gap` is computed") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "1 line make key bindings") != null);
}
