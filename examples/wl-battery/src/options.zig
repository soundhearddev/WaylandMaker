// SPDX-License-Identifier: 0BSD
//
// Command line of wl-battery. Pure, so it can be tested without a compositor.
//
// The one option that matters for the dock is --name: the window's app_id is
// "dockapp:<name>". The default is the program's own name, `wl-battery`, so
// "Keep Icon" in wmaker-wl (which saves the command `<name>`) starts it
// again.

const std = @import("std");

pub const usage =
    \\usage: wl-battery [options]
    \\
    \\A 64x64 battery monitor for the dock of wmaker-wl (a DockApp). It sets its
    \\app_id to "dockapp:<name>"; wmaker-wl docks it by itself, no entry or config
    \\needed. Shows status, AC, power, time left, percent, voltage and health.
    \\
    \\options:
    \\  -n, --name NAME      app_id suffix; keep it equal to the program name (default: wl-battery)
    \\  -b, --battery NAME   power supply to show, e.g. BAT1 (default: the first battery)
    \\  -i, --interval SEC   read the battery at least every SEC seconds, 1..3600 (default: 5);
    \\                       plug/unplug and charge changes arrive as kernel events at once
    \\  -v, --verbose        print every redraw to stderr (to see what it does)
    \\      --snapshot FILE  draw one frame into FILE (PPM image) and exit; no
    \\                       Wayland connection needed
    \\  -h, --help           show this text
    \\
    \\A click on the tile reads the battery again right away.
    \\
;

pub const Options = struct {
    name: []const u8 = "wl-battery",
    battery: ?[]const u8 = null,
    interval: u32 = 5,
    verbose: bool = false,
    snapshot: ?[:0]const u8 = null,
};

pub const Error = error{
    HelpRequested,
    UnknownOption,
    MissingValue,
    InvalidName,
    InvalidValue,
};

pub const max_name = 32;
pub const max_battery = 64;

/// Parse the arguments after the program name. `it` is anything with
/// `fn next(*@TypeOf(it.*)) ?[:0]const u8` (std.process.Args.Iterator, or a
/// slice walker in the tests). The returned strings point into the
/// arguments, which live as long as the process.
pub fn parse(it: anytype) Error!Options {
    var o: Options = .{};
    while (it.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) return error.HelpRequested;

        if (eql(arg, "-v") or eql(arg, "--verbose")) {
            o.verbose = true;
        } else if (try value(arg, "-n", "--name", it)) |v| {
            if (!validName(v)) return error.InvalidName;
            o.name = v;
        } else if (try value(arg, "-b", "--battery", it)) |v| {
            if (!validSupply(v)) return error.InvalidValue;
            o.battery = v;
        } else if (try value(arg, "-i", "--interval", it)) |v| {
            const n = std.fmt.parseInt(u32, v, 10) catch return error.InvalidValue;
            if (n < 1 or n > 3600) return error.InvalidValue;
            o.interval = n;
        } else if (try value(arg, "", "--snapshot", it)) |v| {
            if (v.len == 0) return error.InvalidValue;
            o.snapshot = v;
        } else {
            return error.UnknownOption;
        }
    }
    return o;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `-n VALUE`, `--name VALUE` or `--name=VALUE`: the value, or null if `arg`
/// is some other option.
fn value(arg: [:0]const u8, short: []const u8, long: []const u8, it: anytype) Error!?[:0]const u8 {
    if ((short.len > 0 and eql(arg, short)) or eql(arg, long)) {
        return it.next() orelse error.MissingValue;
    }
    if (arg.len > long.len and std.mem.startsWith(u8, arg, long) and arg[long.len] == '=') {
        return arg[long.len + 1 ..];
    }
    return null;
}

/// A name becomes part of an app_id and is compared with an entry name, so
/// keep it to what a config file can spell without quoting. It must also be
/// a name wmaker-wl accepts for a tile (dockapp.validAppId: letters, digits,
/// `.-_+`, not starting with `.` or `-`); otherwise the compositor gives the
/// window no tile and never shows it.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return name[0] != '-';
}

/// A directory name below /sys/class/power_supply: no path tricks.
pub fn validSupply(name: []const u8) bool {
    if (name.len == 0 or name.len > max_battery) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.' and ch != '+') return false;
    }
    return name[0] != '.';
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const TestIter = struct {
    args: []const [:0]const u8,
    i: usize = 0,

    pub fn next(self: *TestIter) ?[:0]const u8 {
        if (self.i >= self.args.len) return null;
        defer self.i += 1;
        return self.args[self.i];
    }
};

fn run(args: []const [:0]const u8) Error!Options {
    var it: TestIter = .{ .args = args };
    return parse(&it);
}

test "no arguments: the defaults" {
    const o = try run(&.{});
    try std.testing.expectEqualStrings("wl-battery", o.name);
    try std.testing.expect(o.battery == null and o.snapshot == null);
    try std.testing.expectEqual(@as(u32, 5), o.interval);
    try std.testing.expect(!o.verbose);
}

test "verbose" {
    try std.testing.expect((try run(&.{"-v"})).verbose);
    try std.testing.expect((try run(&.{"--verbose"})).verbose);
}

test "every option, in all its spellings" {
    const o = try run(&.{ "-n", "bat", "--battery", "BAT1", "-i", "30", "--snapshot", "/tmp/x.ppm" });
    try std.testing.expectEqualStrings("bat", o.name);
    try std.testing.expectEqualStrings("BAT1", o.battery.?);
    try std.testing.expectEqual(@as(u32, 30), o.interval);
    try std.testing.expectEqualStrings("/tmp/x.ppm", o.snapshot.?);

    const p = try run(&.{ "--name=a-b_c", "-b", "macsmc-battery", "--interval=1" });
    try std.testing.expectEqualStrings("a-b_c", p.name);
    try std.testing.expectEqualStrings("macsmc-battery", p.battery.?);
    try std.testing.expectEqual(@as(u32, 1), p.interval);
}

test "errors" {
    try std.testing.expectError(error.HelpRequested, run(&.{"--help"}));
    try std.testing.expectError(error.UnknownOption, run(&.{"--bogus"}));
    try std.testing.expectError(error.MissingValue, run(&.{"--battery"}));
    try std.testing.expectError(error.MissingValue, run(&.{"-i"}));
    try std.testing.expectError(error.InvalidName, run(&.{ "--name", "has space" }));
    try std.testing.expectError(error.InvalidValue, run(&.{ "-b", "../etc" }));
    try std.testing.expectError(error.InvalidValue, run(&.{ "-b", ".hidden" }));
    try std.testing.expectError(error.InvalidValue, run(&.{ "-i", "0" }));
    try std.testing.expectError(error.InvalidValue, run(&.{ "-i", "3601" }));
    try std.testing.expectError(error.InvalidValue, run(&.{ "-i", "abc" }));
    try std.testing.expectError(error.InvalidValue, run(&.{ "--snapshot", "" }));
}

test "validName" {
    try std.testing.expect(validName("wl-battery"));
    try std.testing.expect(!validName("-bat"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a b"));
    try std.testing.expect(!validName("a:b"));
    try std.testing.expect(validName("x" ** max_name));
    try std.testing.expect(!validName("x" ** (max_name + 1)));
}

test "validSupply" {
    try std.testing.expect(validSupply("BAT0"));
    try std.testing.expect(validSupply("hid-1.2"));
    try std.testing.expect(!validSupply("a/b"));
    try std.testing.expect(!validSupply(".."));
    try std.testing.expect(!validSupply(""));
}
