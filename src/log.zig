// SPDX-License-Identifier: GPL-3.0
//
// Which log messages wmaker-wl prints, decided at run time.
//
// Every source file logs through its own scope (`std.log.scoped(.window)` ...),
// so a line reads `info(window): ...` like river's own `debug(wm): ...`. What is
// printed is a filter, set with the environment variable WMAKER_LOG or the
// option `--log`:
//
//     WMAKER_LOG=debug                everything, all scopes
//     WMAKER_LOG=warn                 only warnings and errors
//     WMAKER_LOG=info,anim=debug      the default, plus every animation detail
//     WMAKER_LOG=warn,window=debug    quiet, but follow what happens to windows
//     WMAKER_LOG=off                  nothing (warnings and errors are still
//                                     counted for `--check`)
//
// A bare level sets the default for every scope, `SCOPE=LEVEL` overrides it for
// one scope (the last rule for a scope wins), `all=LEVEL` sets the default
// again. Rules are separated by commas or blanks. Levels: off, err, warn, info,
// debug (and the aliases error, warning, quiet, none). Without a filter the
// level is `info`.
//
// Scopes: main sequence window anim action config seat ui dock dockhost dockapp
// files compat svg process output.
//
// The filter works at run time, so main.zig sets `std_options.log_level` to
// `.debug` (nothing is dropped at compile time) and this file decides.

const std = @import("std");

pub const Level = enum(u8) { off, err, warn, info, debug };

/// Warnings and errors logged so far, whether they were printed or not;
/// `--check` turns them into its exit code.
pub var problems: u32 = 0;

pub const max_rules = 32;
pub const max_spec = 256;

pub const ParseError = error{ BadLevel, TooManyRules, TooLong };

const Rule = struct { scope: []const u8, level: Level };

pub const Filter = struct {
    default: Level = .info,
    n: usize = 0,
    rules: [max_rules]Rule = undefined,

    /// The level that applies to `scope` (the last rule for it wins).
    pub fn levelFor(f: *const Filter, scope: []const u8) Level {
        var i = f.n;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, f.rules[i].scope, scope)) return f.rules[i].level;
        }
        return f.default;
    }

    pub fn allows(f: *const Filter, level: std.log.Level, scope: []const u8) bool {
        return rank(level) <= @intFromEnum(f.levelFor(scope));
    }
};

fn rank(level: std.log.Level) u8 {
    return switch (level) {
        .err => 1,
        .warn => 2,
        .info => 3,
        .debug => 4,
    };
}

pub fn parseLevel(text: []const u8) ?Level {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(text, "off") or eql(text, "quiet") or eql(text, "none")) return .off;
    if (eql(text, "err") or eql(text, "error")) return .err;
    if (eql(text, "warn") or eql(text, "warning")) return .warn;
    if (eql(text, "info")) return .info;
    if (eql(text, "debug")) return .debug;
    return null;
}

/// Read a filter. The rules point into `spec`, which has to outlive the result.
pub fn parse(spec: []const u8) ParseError!Filter {
    var f: Filter = .{};
    var it = std.mem.tokenizeAny(u8, spec, ", \t");
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            const scope = tok[0..eq];
            const level = parseLevel(tok[eq + 1 ..]) orelse return error.BadLevel;
            if (scope.len == 0) return error.BadLevel;
            if (std.mem.eql(u8, scope, "all") or std.mem.eql(u8, scope, "*")) {
                f.default = level;
                continue;
            }
            if (f.n == max_rules) return error.TooManyRules;
            f.rules[f.n] = .{ .scope = scope, .level = level };
            f.n += 1;
        } else {
            f.default = parseLevel(tok) orelse return error.BadLevel;
        }
    }
    return f;
}

var spec_store: [max_spec]u8 = undefined;
var spec_len: usize = 0;
var active: Filter = .{};

/// Install a filter. Checked first: a refused spec changes nothing.
pub fn setSpec(spec: []const u8) ParseError!void {
    if (spec.len > max_spec) return error.TooLong;
    _ = try parse(spec);
    @memcpy(spec_store[0..spec.len], spec);
    spec_len = spec.len;
    active = parse(spec_store[0..spec_len]) catch unreachable;
}

/// The filter text in force ("" = the default, `info`).
pub fn currentSpec() []const u8 {
    return spec_store[0..spec_len];
}

/// WMAKER_LOG, if set. A bad value is reported and ignored.
pub fn initFromEnv() void {
    const p = std.c.getenv("WMAKER_LOG") orelse return;
    const text = std.mem.span(p);
    setSpec(text) catch |err| std.log.warn("WMAKER_LOG `{s}` is ignored: {t} (example: info,anim=debug)", .{ text, err });
}

/// `std_options.logFn`: counts warnings and errors, then prints what the
/// filter lets through, in the standard format.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (level == .warn or level == .err) problems +%= 1;
    if (!active.allows(level, @tagName(scope))) return;
    std.log.defaultLog(level, scope, format, args);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "parseLevel: names, case and aliases" {
    try std.testing.expectEqual(@as(?Level, .debug), parseLevel("debug"));
    try std.testing.expectEqual(@as(?Level, .info), parseLevel("Info"));
    try std.testing.expectEqual(@as(?Level, .warn), parseLevel("WARN"));
    try std.testing.expectEqual(@as(?Level, .warn), parseLevel("warning"));
    try std.testing.expectEqual(@as(?Level, .err), parseLevel("error"));
    try std.testing.expectEqual(@as(?Level, .off), parseLevel("off"));
    try std.testing.expectEqual(@as(?Level, .off), parseLevel("quiet"));
    try std.testing.expectEqual(@as(?Level, null), parseLevel("loud"));
    try std.testing.expectEqual(@as(?Level, null), parseLevel(""));
}

test "parse: no filter means info for every scope" {
    const f = try parse("");
    try std.testing.expectEqual(Level.info, f.levelFor("window"));
    try std.testing.expect(f.allows(.err, "window"));
    try std.testing.expect(f.allows(.warn, "window"));
    try std.testing.expect(f.allows(.info, "window"));
    try std.testing.expect(!f.allows(.debug, "window"));
}

test "parse: a bare level is the default, scope=level overrides it" {
    const f = try parse("warn,anim=debug,ui=off");
    try std.testing.expectEqual(Level.warn, f.levelFor("window"));
    try std.testing.expectEqual(Level.debug, f.levelFor("anim"));
    try std.testing.expectEqual(Level.off, f.levelFor("ui"));
    try std.testing.expect(f.allows(.warn, "window"));
    try std.testing.expect(!f.allows(.info, "window"));
    try std.testing.expect(f.allows(.debug, "anim"));
    try std.testing.expect(!f.allows(.err, "ui"));
}

test "parse: the last rule for a scope wins, all= sets the default, blanks and commas separate" {
    const f = try parse("anim=info anim=debug\tall=err,seat=warn");
    try std.testing.expectEqual(Level.debug, f.levelFor("anim"));
    try std.testing.expectEqual(Level.warn, f.levelFor("seat"));
    try std.testing.expectEqual(Level.err, f.levelFor("window"));

    // The default can come after the rules and still not touch them.
    const g = try parse("anim=debug,warn");
    try std.testing.expectEqual(Level.debug, g.levelFor("anim"));
    try std.testing.expectEqual(Level.warn, g.levelFor("ui"));
}

test "parse: bad levels and too many rules are errors" {
    try std.testing.expectError(error.BadLevel, parse("loud"));
    try std.testing.expectError(error.BadLevel, parse("anim=loud"));
    try std.testing.expectError(error.BadLevel, parse("=debug"));
    try std.testing.expectError(error.BadLevel, parse("info,anim="));
    const many = "a=info," ** (max_rules + 1);
    try std.testing.expectError(error.TooManyRules, parse(many));
    const fits = "a=info," ** max_rules;
    _ = try parse(fits);
}

test "setSpec: a refused spec changes nothing, the text is kept as given" {
    defer setSpec("") catch unreachable;
    try setSpec("info,anim=debug");
    try std.testing.expectEqualStrings("info,anim=debug", currentSpec());
    try std.testing.expect(active.allows(.debug, "anim"));
    try std.testing.expect(!active.allows(.debug, "ui"));

    try std.testing.expectError(error.BadLevel, setSpec("anim=loud"));
    try std.testing.expectEqualStrings("info,anim=debug", currentSpec());
    try std.testing.expect(active.allows(.debug, "anim"));

    try std.testing.expectError(error.TooLong, setSpec("a" ** (max_spec + 1)));
    try std.testing.expectEqualStrings("info,anim=debug", currentSpec());

    try setSpec("");
    try std.testing.expectEqualStrings("", currentSpec());
    try std.testing.expect(!active.allows(.debug, "anim"));
}

test "logFn: warnings and errors are counted even when the filter hides them" {
    defer setSpec("") catch unreachable;
    try setSpec("off");
    const before = problems;
    logFn(.info, .logtest, "not a problem", .{});
    logFn(.debug, .logtest, "not a problem either", .{});
    try std.testing.expectEqual(before, problems);
    logFn(.warn, .logtest, "a warning, hidden by the filter", .{});
    logFn(.err, .logtest, "an error, hidden by the filter", .{});
    try std.testing.expectEqual(before + 2, problems);
}
