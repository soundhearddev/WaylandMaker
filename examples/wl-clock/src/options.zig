// SPDX-License-Identifier: 0BSD
//
// Command line of wl-clock. Pure, so it can be tested without a compositor.
//
// The one option that matters for the dock is --name: the window's app_id is
// "dockapp:<name>", and that is what wmaker-wl matches against the entry of
// the same name in dockapps.conf to put the window into that entry's tile.
// Two clocks therefore need two names:
//
//     [berlin]                          [tokyo]
//     command = wl-clock                command = wl-clock --name tokyo --tz Asia/Tokyo --label tokyo

const std = @import("std");

pub const usage =
    \\usage: wl-clock [options]
    \\
    \\A 64x64 clock for the dock of wmaker-wl (a DockApp). It sets its app_id to
    \\"dockapp:<name>", so wmaker-wl puts it into the dock tile of that name.
    \\
    \\options:
    \\  -n, --name NAME     app_id suffix, the entry name in dockapps.conf (default: clock)
    \\  -z, --tz ZONE       time zone, e.g. Europe/Berlin or Asia/Tokyo (default: local)
    \\  -l, --label TEXT    shown instead of the month name (up to 8 characters)
    \\      --12h           start in 12-hour mode with AM/PM
    \\      --24h           start in 24-hour mode (default); a click toggles the mode
    \\      --no-seconds    no seconds bar and no blinking colon: one redraw a minute
    \\      --snapshot FILE draw one frame into FILE (PPM image) and exit; no
    \\                      Wayland connection needed
    \\  -h, --help          show this text
    \\
;

pub const Options = struct {
    name: []const u8 = "clock",
    tz: ?[:0]const u8 = null,
    label: ?[]const u8 = null,
    hour12: bool = false,
    seconds: bool = true,
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
/// keep it to what a config file can spell without quoting.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
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
    try std.testing.expectEqualStrings("clock", o.name);
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
    try std.testing.expect(validName("Berlin_2-a"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a b"));
    try std.testing.expect(!validName("a:b"));
    try std.testing.expect(!validName("ä"));
    try std.testing.expect(!validName("x" ** (max_name + 1)));
    try std.testing.expect(validName("x" ** max_name));
}
