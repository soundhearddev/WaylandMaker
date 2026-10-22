// SPDX-License-Identifier: GPL-3.0
//
// Command line of wl-clock. Pure, so it can be tested without a compositor.
//
// The one option that matters for the dock is --name: the window's app_id is
// "dockapp:<name>". The default is the program's own name, `wl-clock`, so
// "Keep Icon" in wmaker-wl (which saves the command `<name>`) starts it
// again. Two clocks at once need two names (`--name tokyo`); a Dock entry
// for the second one then has to be written into WMState by hand, because
// its command is not `<name>`.

const std = @import("std");
const scale = @import("scale.zig");

pub const usage =
    \\usage: wl-clock [options]
    \\
    \\A clock for the dock of wmaker-wl (a DockApp): drawn at the
    \\dock's tile size (`dock_size`), pixel for pixel, not stretched. It sets its app_id to
    \\"dockapp:<name>"; wmaker-wl docks it by itself, no entry or config needed.
    \\
    \\options:
    \\  -n, --name NAME     app_id suffix, app_id suffix; keep it equal to the program name (default: wl-clock)
    \\  -z, --tz ZONE       time zone, e.g. Europe/Berlin or Asia/Tokyo (default: local)
    \\  -l, --label TEXT    shown instead of the month name (up to 8 characters)
    \\      --12h           start in 12-hour mode with AM/PM
    \\      --24h           start in 24-hour mode (default); a click toggles the mode
    \\      --no-seconds    no seconds bar and no blinking colon: one redraw a minute
    \\      --snapshot FILE draw one frame into FILE (PPM image) and exit; no
    \\                      Wayland connection needed
    \\      --size PX       with --snapshot: draw the picture at PX x PX (16..256, default 64)
    \\  -h, --help          show this text
    \\
;

pub const Options = struct {
    name: []const u8 = "wl-clock",
    tz: ?[:0]const u8 = null,
    label: ?[]const u8 = null,
    hour12: bool = false,
    seconds: bool = true,
    snapshot: ?[:0]const u8 = null,
    /// With --snapshot: the picture is drawn at this many pixels a side.
    size: u16 = 64,
};

pub const Error = error{
    HelpRequested,
    UnknownOption,
    MissingValue,
    InvalidName,
    InvalidValue,
};

pub const max_name = 32;
pub const max_tz = 64;
pub const max_label = 32;

/// Parse the arguments after the program name. `it` is anything with
/// `fn next(*@TypeOf(it.*)) ?[:0]const u8` (std.process.Args.Iterator, or a
/// slice walker in the tests). The returned strings point into the
/// arguments, which live as long as the process.
pub fn parse(it: anytype) Error!Options {
    var o: Options = .{};
    while (it.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) return error.HelpRequested;

        if (eql(arg, "--12h")) {
            o.hour12 = true;
        } else if (eql(arg, "--24h")) {
            o.hour12 = false;
        } else if (eql(arg, "--no-seconds")) {
            o.seconds = false;
        } else if (try value(arg, "-n", "--name", it)) |v| {
            if (!validName(v)) return error.InvalidName;
            o.name = v;
        } else if (try value(arg, "-z", "--tz", it)) |v| {
            if (v.len == 0 or v.len > max_tz) return error.InvalidValue;
            o.tz = v;
        } else if (try value(arg, "-l", "--label", it)) |v| {
            if (v.len > max_label) return error.InvalidValue;
            o.label = v;
        } else if (try value(arg, "", "--size", it)) |v| {
            const n = std.fmt.parseInt(u16, v, 10) catch return error.InvalidValue;
            if (n < scale.min_side or n > scale.max_side) return error.InvalidValue;
            o.size = n;
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
    try std.testing.expectEqualStrings("wl-clock", o.name);
    try std.testing.expect(o.tz == null and o.label == null and o.snapshot == null);
    try std.testing.expect(!o.hour12);
    try std.testing.expect(o.seconds);
}

test "every option, in all its spellings" {
    const o = try run(&.{ "-n", "tokyo", "--tz", "Asia/Tokyo", "--label=TKY", "--12h", "--no-seconds", "--snapshot", "/tmp/x.ppm" });
    try std.testing.expectEqualStrings("tokyo", o.name);
    try std.testing.expectEqualStrings("Asia/Tokyo", o.tz.?);
    try std.testing.expectEqualStrings("TKY", o.label.?);
    try std.testing.expect(o.hour12);
    try std.testing.expect(!o.seconds);
    try std.testing.expectEqualStrings("/tmp/x.ppm", o.snapshot.?);

    const p = try run(&.{ "--name=a-b_c", "-z", "UTC", "-l", "x" });
    try std.testing.expectEqualStrings("a-b_c", p.name);
    try std.testing.expectEqualStrings("UTC", p.tz.?);
    // The last of --12h / --24h wins.
    try std.testing.expect(!(try run(&.{ "--12h", "--24h" })).hour12);
}

test "errors" {
    try std.testing.expectError(error.HelpRequested, run(&.{"--help"}));
    try std.testing.expectError(error.HelpRequested, run(&.{ "--12h", "-h" }));
    try std.testing.expectError(error.UnknownOption, run(&.{"--bogus"}));
    try std.testing.expectError(error.UnknownOption, run(&.{"clock"}));
    try std.testing.expectError(error.MissingValue, run(&.{"--tz"}));
    try std.testing.expectError(error.MissingValue, run(&.{"-n"}));
    try std.testing.expectError(error.InvalidName, run(&.{ "--name", "has space" }));
    try std.testing.expectError(error.InvalidName, run(&.{ "--name", "dockapp:x" }));
    try std.testing.expectError(error.InvalidName, run(&.{"--name="}));
    try std.testing.expectError(error.InvalidValue, run(&.{"--tz="}));
    try std.testing.expectError(error.InvalidValue, run(&.{ "--snapshot", "" }));
    // Long garbage is refused, not truncated.
    const long = "x" ** (max_tz + 1);
    try std.testing.expectError(error.InvalidValue, run(&.{ "--tz", long }));
}

test "validName" {
    try std.testing.expect(validName("clock"));
    try std.testing.expect(validName("wl-clock"));
    try std.testing.expect(!validName("-clock")); // the compositor would not give it a tile
    try std.testing.expect(validName("Berlin_2-a"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a b"));
    try std.testing.expect(!validName("a:b"));
    try std.testing.expect(!validName("ä"));
    try std.testing.expect(!validName("x" ** (max_name + 1)));
    try std.testing.expect(validName("x" ** max_name));
}

test "--size: default 64, 16..256" {
    try std.testing.expectEqual(@as(u16, 64), (try run(&.{})).size);
    try std.testing.expectEqual(@as(u16, 96), (try run(&.{ "--size", "96" })).size);
    try std.testing.expectEqual(@as(u16, 128), (try run(&.{"--size=128"})).size);
    try std.testing.expectError(error.InvalidValue, run(&.{ "--size", "8" }));
    try std.testing.expectError(error.InvalidValue, run(&.{ "--size", "300" }));
    try std.testing.expectError(error.InvalidValue, run(&.{"--size=x"}));
    try std.testing.expectError(error.MissingValue, run(&.{"--size"}));
}
