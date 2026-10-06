// SPDX-License-Identifier: 0BSD
//
// The commands a `bind =` line can name, as wmaker-wl's action.zig parses
// them. wlprefs uses this to refuse an action the compositor would reject
// (it would then bind the key to nothing, with only a log warning).
//
// The list is a copy; src/model_test.zig of the compositor compares it with
// `types.Command` and with the three extra spellings, so adding a command
// there fails a test here until this list follows.

const std = @import("std");

/// Commands that take no arguments (`close`, `focus_left`, ...), plus the
/// `spawn_*` shortcuts. Every field of types.Command except `none` and the
/// ones that take arguments.
pub const simple = [_][]const u8{
    "close",
    "exit",
    "toggle_floating",
    "toggle_fullscreen",
    "maximize_column",
    "focus_left",
    "focus_right",
    "focus_up",
    "focus_down",
    "focus_first_column",
    "focus_last_column",
    "focus_previous",
    "focus_toggle_floating",
    "move_column_left",
    "move_column_right",
    "move_column_first",
    "move_column_last",
    "move_window_up",
    "move_window_down",
    "consume_left",
    "expel_right",
    "scroll_left",
    "scroll_right",
    "center_column",
    "cycle_column_width",
    "widen_column",
    "narrow_column",
    "workspace_next",
    "workspace_prev",
    "minimize",
    "restore",
    "show_all",
    "hide_others",
    "hide_app",
    "focus_output_next",
    "focus_output_prev",
    "move_to_output_next",
    "move_to_output_prev",
    "spawn_terminal",
    "spawn_launcher",
    "spawn_browser",
};

/// Commands that need arguments, and what kind.
pub const Arg = enum { program, shell_text, workspace, two_numbers };

pub const with_args = [_]struct { name: []const u8, arg: Arg }{
    .{ .name = "spawn", .arg = .program },
    .{ .name = "shell", .arg = .shell_text },
    .{ .name = "exec", .arg = .shell_text },
    .{ .name = "shexec", .arg = .shell_text },
    .{ .name = "workspace", .arg = .workspace },
    .{ .name = "move_to_workspace", .arg = .workspace },
    .{ .name = "float_move", .arg = .two_numbers },
    .{ .name = "float_resize", .arg = .two_numbers },
};

/// The first word of `action`.
fn firstWord(action: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, action, " \t");
    return it.next() orelse "";
}

fn rest(action: []const u8) []const u8 {
    const t = std.mem.trim(u8, action, " \t");
    const i = std.mem.indexOfAny(u8, t, " \t") orelse return "";
    return std.mem.trim(u8, t[i..], " \t");
}

/// Is `name` a command at all?
pub fn known(name: []const u8) bool {
    for (simple) |n| if (std.mem.eql(u8, n, name)) return true;
    for (with_args) |a| if (std.mem.eql(u8, a.name, name)) return true;
    return false;
}

/// Why the compositor would reject `action`, or null if it accepts it.
/// `workspaces` is the configured workspace_count.
pub fn problem(action: []const u8, workspaces: u32) ?[]const u8 {
    const name = firstWord(action);
    if (name.len == 0) return "Action: empty";
    const args = rest(action);

    for (simple) |n| {
        if (std.mem.eql(u8, n, name)) return null; // extra words are ignored by the compositor
    }
    for (with_args) |a| {
        if (!std.mem.eql(u8, a.name, name)) continue;
        switch (a.arg) {
            .program, .shell_text => return if (args.len == 0) "Action: this command needs a program or text after it" else null,
            .workspace => {
                const n = std.fmt.parseInt(u32, args, 10) catch return "Action: needs a workspace number";
                return if (n < 1 or n > workspaces) "Action: workspace number out of range" else null;
            },
            .two_numbers => {
                var it = std.mem.tokenizeAny(u8, args, " \t");
                for (0..2) |_| {
                    const tok = it.next() orelse return "Action: needs two whole numbers";
                    _ = std.fmt.parseInt(i32, tok, 10) catch return "Action: needs two whole numbers";
                }
                return null;
            },
        }
    }
    return "Action: unknown command";
}

test "known and problem agree with the documented commands" {
    try std.testing.expect(known("close"));
    try std.testing.expect(known("spawn"));
    try std.testing.expect(known("shexec"));
    try std.testing.expect(!known("none")); // `none` is not something to bind
    try std.testing.expect(!known("clsoe"));

    try std.testing.expect(problem("close", 4) == null);
    try std.testing.expect(problem("  focus_left  ", 4) == null);
    try std.testing.expect(problem("", 4) != null);
    try std.testing.expect(problem("clsoe", 4) != null);

    try std.testing.expect(problem("spawn foot -e htop", 4) == null);
    try std.testing.expect(problem("spawn", 4) != null);
    try std.testing.expect(problem("shell grim -g \"$(slurp)\" ~/x.png", 4) == null);
    try std.testing.expect(problem("shell", 4) != null);

    try std.testing.expect(problem("workspace 3", 4) == null);
    try std.testing.expect(problem("workspace 0", 4) != null);
    try std.testing.expect(problem("workspace 5", 4) != null);
    try std.testing.expect(problem("workspace x", 4) != null);
    try std.testing.expect(problem("move_to_workspace 2", 4) == null);

    try std.testing.expect(problem("float_move -40 0", 4) == null);
    try std.testing.expect(problem("float_move 40", 4) != null);
    try std.testing.expect(problem("float_resize a b", 4) != null);
}

test "no name appears twice" {
    for (simple, 0..) |a, i| {
        for (simple[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));
        for (with_args) |w| try std.testing.expect(!std.mem.eql(u8, a, w.name));
    }
}
