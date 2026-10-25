// SPDX-License-Identifier: GPL-3.0
//
// Fuzzing of everything that reads a file or a string somebody else wrote:
// the property lists (root menu, WMState, WMWindowAttributes), XPM icons,
// config.lua and key-binding commands. Nothing here checks WHAT a parser
// makes of an input (the modules' own tests do that); it checks that no input
// crashes it, hangs it or leaks memory. An error return is a fine answer.
//
// Two kinds of input: bytes drawn from the characters of the format (so that
// the parser gets past its first line), and a valid document with a few bytes
// flipped, inserted and cut out (so that it gets deep into the grammar). The
// generator is seeded, so a failure repeats; the loop count is kept low enough
// for `zig build test`. For a long run raise `rounds`.

const std = @import("std");
const plist = @import("plist.zig");
const wm_menu = @import("wm_menu.zig");
const wm_attr = @import("wm_attr.zig");
const dockapp = @import("dockapp.zig");
const config = @import("config.zig");
const action = @import("action.zig");

const rounds = 1500;

const menu_seed =
    \\("Applications",
    \\  ("Terminal", EXEC, "foot"),
    \\  ("Files", SHEXEC, "ls | less"),
    \\  ("Sub", ("A", EXEC, "a -b"), ("B", WORKSPACE_MENU)),
    \\  ("Win", WINDOWS_MENU),
    \\  ("Quit", EXIT)
    \\)
;

const wmstate_seed =
    \\{
    \\  Dock = { Position = "-64,0"; Applications = (
    \\    { Name = "foo.Foo"; Command = "foo --bar"; Lock = No; AutoLaunch = No;
    \\      Forced = No; BuggyApplication = No; Position = "0,1"; }
    \\  ); };
    \\  Workspaces = ({ Name = "Main"; Clip = { Applications = (); }; }, { Name = "Web"; });
    \\  Drawers = ({ Name = "tools"; Position = "0,2"; });
    \\}
;

const attr_seed =
    \\{
    \\  "*" = { Icon = "x.xpm"; };
    \\  "foo.Foo" = { NoTitlebar = Yes; Workspace = 2; StartMinimized = No; };
    \\  "Bar" = { Unfocusable = Yes; };
    \\}
;

const xpm_seed =
    \\/* XPM */
    \\static char *x[] = {
    \\"4 3 3 1",
    \\"a c #ff0000",
    \\"b c None",
    \\"c c gray50 m black",
    \\"aabb",
    \\"bbcc",
    \\"cacb"
    \\};
;

const lua_seed =
    \\gap = 10
    \\local a = "#aabbcc"
    \\border_focused = a
    \\terminal = { "foot", "-e", "htop" }
    \\workspace_names = { "a", "b" }
    \\bind("Super+x", "close")
    \\bind("Super+y", function() run("workspace 2") end)
    \\for i = 1, 3 do bind("Super+" .. i, "workspace " .. i) end
    \\unbind("Super+q")
;

const command_seed = "spawn foot -e \"htop -d 5\"";

fn prng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

/// `n` bytes drawn from `alphabet` (plus now and then any byte at all).
fn randomText(a: std.mem.Allocator, rand: std.Random, alphabet: []const u8, max_len: usize) ![]u8 {
    const len = rand.uintLessThan(usize, max_len + 1);
    const out = try a.alloc(u8, len);
    for (out) |*b| {
        b.* = if (rand.uintLessThan(u8, 16) == 0) rand.int(u8) else alphabet[rand.uintLessThan(usize, alphabet.len)];
    }
    return out;
}

/// `seed` with a few bytes flipped, inserted, removed or a piece repeated.
fn mutate(a: std.mem.Allocator, rand: std.Random, seed: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, seed);
    const edits = 1 + rand.uintLessThan(usize, 6);
    for (0..edits) |_| {
        if (list.items.len == 0) break;
        const at = rand.uintLessThan(usize, list.items.len);
        switch (rand.uintLessThan(u8, 5)) {
            0 => list.items[at] ^= @as(u8, 1) << @intCast(rand.uintLessThan(u8, 8)),
            1 => try list.insert(a, at, rand.int(u8)),
            2 => _ = list.orderedRemove(at),
            3 => { // cut a piece out
                const n = @min(list.items.len - at, 1 + rand.uintLessThan(usize, 12));
                try list.replaceRange(a, at, n, &.{});
            },
            else => { // repeat a piece (deeply nested / very long inputs)
                const n = @min(list.items.len - at, 1 + rand.uintLessThan(usize, 24));
                const piece = try a.dupe(u8, list.items[at..][0..n]);
                const times = 1 + rand.uintLessThan(usize, 40);
                for (0..times) |_| try list.insertSlice(a, at, piece);
            },
        }
    }
    return list.toOwnedSlice(a);
}

/// Hand `check` many inputs: random ones from `alphabet` and mutations of `seed`.
fn drive(seed: []const u8, alphabet: []const u8, rng_seed: u64, check: *const fn (std.mem.Allocator, []const u8) anyerror!void) !void {
    var p = prng(rng_seed);
    const rand = p.random();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The valid seed itself must be fine too.
    try check(std.testing.allocator, seed);
    for (0..rounds) |i| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const input = if (i % 3 == 0)
            try randomText(a, rand, alphabet, 200)
        else
            try mutate(a, rand, seed);
        try check(std.testing.allocator, input);
    }
}

fn okOrParseError(err: anyerror) !void {
    switch (err) {
        // What a parser may answer for a bad input. Anything else (a leak is
        // caught by the testing allocator, a crash kills the test) is a bug.
        error.Syntax, error.Empty, error.Invalid, error.TooBig, error.UnknownCommand, error.BadArguments => {},
        else => return err, // including OutOfMemory: nothing here may run out
    }
}

fn checkPlist(gpa: std.mem.Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = plist.parse(arena.allocator(), text, null) catch |e| return okOrParseError(e);
}

fn checkMenu(gpa: std.mem.Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = wm_menu.parse(arena.allocator(), text) catch |e| return okOrParseError(e);
}

fn checkWmState(gpa: std.mem.Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = dockapp.parseWMStateAll(arena.allocator(), text) catch |e| return okOrParseError(e);
}

fn checkAttr(gpa: std.mem.Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = wm_attr.parse(arena.allocator(), text) catch |e| return okOrParseError(e);
}

fn checkLua(gpa: std.mem.Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cfg: config.Config = .{ .arena = .init(gpa) };
    defer cfg.deinit();
    var binds: std.ArrayList(config.Bind) = .empty;
    // parse() never fails but for out-of-memory: a bad script is a warning.
    try config.parse(arena.allocator(), text, &cfg, &binds, "<fuzz>");
}

fn checkCommand(gpa: std.mem.Allocator, text: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cfg: config.Config = .{ .arena = .init(gpa) };
    defer cfg.deinit();
    _ = action.parse(arena.allocator(), &cfg, text) catch |e| return okOrParseError(e);
}

const plist_chars = "(){}=;,\" \n\t/*\\<>abcXYZ019.-_#";
const lua_chars = "abc_ =\"'(){},.0123456789\n+-*/#<>~:;[]\\function end do if then for in bind unbind run gap";
const cmd_chars = "abc \"'_-=/\\0123456789\tspawn shell workspace";

test "fuzz: property lists (plist)" {
    try drive(menu_seed, plist_chars, 1, checkPlist);
    try drive(wmstate_seed, plist_chars, 2, checkPlist);
}

test "fuzz: root menu (wm_menu)" {
    try drive(menu_seed, plist_chars, 3, checkMenu);
}

test "fuzz: WMState (dockapp)" {
    try drive(wmstate_seed, plist_chars, 4, checkWmState);
}

test "fuzz: window attributes (wm_attr)" {
    try drive(attr_seed, plist_chars, 5, checkAttr);
}

test "fuzz: config.lua" {
    // The Lua state is the slow part; fewer rounds keep the test quick.
    var p = prng(7);
    const rand = p.random();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try checkLua(std.testing.allocator, lua_seed);
    for (0..250) |i| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const input = if (i % 4 == 0) try randomText(a, rand, lua_chars, 200) else try mutate(a, rand, lua_seed);
        try checkLua(std.testing.allocator, input);
    }
}

test "fuzz: key-binding commands" {
    try drive(command_seed, cmd_chars, 8, checkCommand);
}
