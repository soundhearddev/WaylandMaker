// SPDX-License-Identifier: GPL-3.0
//
// Command line of wmaker-wlr.

const std = @import("std");

pub const Cli = struct {
    config_path: ?[]const u8 = null,
    config_dir: ?[]const u8 = null,
    log_spec: ?[]const u8 = null,
};

pub const Parsed = union(enum) {
    run: Cli,
    help,
    version,
    unknown: []const u8,
    needs_value: []const u8,
};

/// `args` is anything with a `next()` that gives the arguments after argv[0].
pub fn parseArgs(args: anytype) Parsed {
    var cli: Cli = .{};
    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) return .help;
        if (eql(arg, "-V") or eql(arg, "--version")) return .version;
        if (valueOf(arg, "--config", args)) |r| switch (r) {
            .ok => |v| cli.config_path = v,
            .missing => return .{ .needs_value = "--config" },
        } else if (valueOf(arg, "--config-dir", args)) |r| switch (r) {
            .ok => |v| cli.config_dir = v,
            .missing => return .{ .needs_value = "--config-dir" },
        } else if (valueOf(arg, "--log", args)) |r| switch (r) {
            .ok => |v| cli.log_spec = v,
            .missing => return .{ .needs_value = "--log" },
        } else return .{ .unknown = arg };
    }
    return .{ .run = cli };
}

const Value = union(enum) { ok: []const u8, missing };

/// `--name VALUE` or `--name=VALUE`; null when `arg` is some other option.
fn valueOf(arg: []const u8, comptime name: []const u8, args: anytype) ?Value {
    if (eql(arg, name)) return if (args.next()) |v| .{ .ok = v } else .missing;
    if (std.mem.startsWith(u8, arg, name ++ "=")) return .{ .ok = arg[name.len + 1 ..] };
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}


test "options" {
    const Args = struct {
        items: []const []const u8,
        i: usize = 0,
        fn next(a: *@This()) ?[]const u8 {
            if (a.i == a.items.len) return null;
            defer a.i += 1;
            return a.items[a.i];
        }
    };
    var a: Args = .{ .items = &.{ "--config", "x.lua", "--log=info" } };
    const p = parseArgs(&a);
    try std.testing.expectEqualStrings("x.lua", p.run.config_path.?);
    try std.testing.expectEqualStrings("info", p.run.log_spec.?);
    var b: Args = .{ .items = &.{"--config"} };
    try std.testing.expectEqualStrings("--config", parseArgs(&b).needs_value);
    var c: Args = .{ .items = &.{"--nope"} };
    try std.testing.expectEqualStrings("--nope", parseArgs(&c).unknown);
}
