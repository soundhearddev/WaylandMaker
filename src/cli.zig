// SPDX-License-Identifier: GPL-3.0
//
// The command line of wmaker-wl. Nothing here touches the system: main.zig
// acts on what `parseArgs` returns.

const std = @import("std");

pub const usage =
    \\usage: wmaker-wl [OPTION]
    \\
    \\A Wayland compositor (wlroots) with a scrolling tiling layout and a Window
    \\Maker feel. Without an option it starts the session: from a TTY on the real
    \\screen, or nested in a running session (WLR_BACKENDS=wayland or x11 to force).
    \\
    \\  -h, --help          show this text and exit
    \\  -V, --version       show the version and exit
    \\      --config FILE   read FILE instead of the default config.lua
    \\      --config-dir DIR
    \\                      use DIR instead of ~/.config/wmaker-wl for config.lua,
    \\                      RootMenu, WMWindowAttributes and autostart
    \\      --check         read config.lua, the key bindings, the root menu,
    \\                      WMWindowAttributes, WMState and the autostart path,
    \\                      report what is wrong and exit (0: fine, 1: problems);
    \\                      needs no display
    \\      --paths         list the files wmaker-wl reads (and which exist), exit
    \\      --binds         list the key bindings in effect (config.lua on top of the
    \\                      defaults), one `KEYS  command` per line, and exit
    \\      --print-config  print the built-in default config.lua and exit, e.g.
    \\                      wmaker-wl --print-config > ~/.config/wmaker-wl/config.lua
    \\      --log FILTER    what to log, e.g. `debug`, `warn` or `info,anim=debug`
    \\                      (levels: off err warn info debug; a SCOPE=LEVEL pair
    \\                      changes one scope: main sequence window anim action
    \\                      config seat keyboard boot server ui dock dockhost dockapp files compat svg
    \\                      process output). The same as the environment variable
    \\                      WMAKER_LOG; the default is `info`
    \\
    \\      --install-session    install the login session: wmaker-wl-session,
    \\                      wmaker-wl.desktop, systemd user units, portal config,
    \\                      wlprefs.desktop and themes; also copies wmaker-wl and
    \\                      wlprefs into BINDIR when they are not there yet. Needs
    \\                      no display. (`zig build install` does the same.)
    \\      --uninstall-session
    \\                      remove those files (not the programs); exit
    \\      --session-status
    \\                      show which of them are installed and current; exit
    \\                      (0: all, 1: something missing)
    \\      --prefix DIR    for the three options above: install below DIR
    \\                      (default /usr/local, /usr if run from /usr/bin)
    \\      --destdir DIR   stage everything below DIR (packaging)
    \\      --user          install below ~/.local instead of a system prefix
    \\      --dry-run       only say what would be done
    \\
    \\A running session reloads its files on `pkill -HUP wmaker-wl`.
    \\
;

/// What the command line asks for.
pub const Cli = struct {
    check_only: bool = false,
    show_paths: bool = false,
    show_binds: bool = false,
    print_config: bool = false,
    config_path: ?[]const u8 = null,
    config_dir: ?[]const u8 = null,
    log_spec: ?[]const u8 = null,
    session: ?SessionAction = null,
    prefix: ?[]const u8 = null,
    destdir: ?[]const u8 = null,
    user_install: bool = false,
    dry_run: bool = false,
};

pub const SessionAction = enum { install, uninstall, status };

pub const Parsed = union(enum) {
    /// Start (or `--check`, `--paths`, `--print-config`).
    run: Cli,
    help,
    version,
    /// An argument that is no option.
    unknown: []const u8,
    /// An option that needs a value and has none (the option).
    needs_value: []const u8,
    /// An option that only goes with --install-session, --uninstall-session
    /// or --session-status, given without one (the option).
    needs_session: []const u8,
    /// Two options that exclude each other (the second).
    conflict: []const u8,
};

/// Read the command line. `args` is anything with a `next()` that gives the
/// next argument or null (the process' arguments, or a list in a test).
/// `--help` and `--version` win over everything before them.
pub fn parseArgs(args: anytype) Parsed {
    var cli: Cli = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--check")) {
            cli.check_only = true;
        } else if (std.mem.eql(u8, arg, "--paths")) {
            cli.show_paths = true;
        } else if (std.mem.eql(u8, arg, "--binds")) {
            cli.show_binds = true;
        } else if (std.mem.eql(u8, arg, "--install-session") or
            std.mem.eql(u8, arg, "--uninstall-session") or
            std.mem.eql(u8, arg, "--session-status"))
        {
            if (cli.session != null) return .{ .conflict = arg };
            cli.session = if (std.mem.eql(u8, arg, "--install-session")) .install else if (std.mem.eql(u8, arg, "--uninstall-session")) .uninstall else .status;
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            cli.prefix = args.next() orelse return .{ .needs_value = "--prefix" };
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            cli.prefix = arg["--prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--destdir")) {
            cli.destdir = args.next() orelse return .{ .needs_value = "--destdir" };
        } else if (std.mem.startsWith(u8, arg, "--destdir=")) {
            cli.destdir = arg["--destdir=".len..];
        } else if (std.mem.eql(u8, arg, "--user")) {
            cli.user_install = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            cli.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--print-config")) {
            cli.print_config = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            cli.config_path = args.next() orelse return .{ .needs_value = "--config" };
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            cli.config_path = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "--config-dir")) {
            cli.config_dir = args.next() orelse return .{ .needs_value = "--config-dir" };
        } else if (std.mem.startsWith(u8, arg, "--config-dir=")) {
            cli.config_dir = arg["--config-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--log")) {
            cli.log_spec = args.next() orelse return .{ .needs_value = "--log" };
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            cli.log_spec = arg["--log=".len..];
        } else {
            return .{ .unknown = arg };
        }
    }
    if (cli.session == null) {
        if (cli.prefix != null) return .{ .needs_session = "--prefix" };
        if (cli.destdir != null) return .{ .needs_session = "--destdir" };
        if (cli.user_install) return .{ .needs_session = "--user" };
        if (cli.dry_run) return .{ .needs_session = "--dry-run" };
    } else if (cli.user_install and cli.prefix != null) {
        return .{ .conflict = "--user" };
    }
    return .{ .run = cli };
}

const TestArgs = struct {
    items: []const []const u8,
    i: usize = 0,

    fn next(t: *TestArgs) ?[]const u8 {
        if (t.i >= t.items.len) return null;
        const item = t.items[t.i];
        t.i += 1;
        return item;
    }
};

fn parseTest(items: []const []const u8) Parsed {
    var t: TestArgs = .{ .items = items };
    return parseArgs(&t);
}

test "command line: no argument starts the session, nothing else is switched on" {
    switch (parseTest(&.{})) {
        .run => |cli| {
            try std.testing.expect(!cli.check_only and !cli.show_paths and !cli.show_binds and !cli.print_config);
            try std.testing.expect(cli.config_path == null and cli.config_dir == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "command line: --help and --version (long and short) are answered, whatever comes with them" {
    try std.testing.expect(parseTest(&.{"--help"}) == .help);
    try std.testing.expect(parseTest(&.{"-h"}) == .help);
    try std.testing.expect(parseTest(&.{"--version"}) == .version);
    try std.testing.expect(parseTest(&.{"-V"}) == .version);
    try std.testing.expect(parseTest(&.{ "--check", "--version" }) == .version);
    // The very bug this was written for: `wmaker-wl --version` started the whole session.
    try std.testing.expect(parseTest(&.{"--version"}) != .run);
}

test "command line: --binds" {
    switch (parseTest(&.{"--binds"})) {
        .run => |cli| try std.testing.expect(cli.show_binds and !cli.check_only),
        else => return error.TestUnexpectedResult,
    }
}

test "command line: --check, --paths and --print-config combine" {
    switch (parseTest(&.{ "--check", "--paths", "--print-config" })) {
        .run => |cli| try std.testing.expect(cli.check_only and cli.show_paths and cli.print_config),
        else => return error.TestUnexpectedResult,
    }
}

test "command line: --config and --config-dir, with a space or an equals sign" {
    switch (parseTest(&.{ "--config", "a.lua", "--config-dir", "/d" })) {
        .run => |cli| {
            try std.testing.expectEqualStrings("a.lua", cli.config_path.?);
            try std.testing.expectEqualStrings("/d", cli.config_dir.?);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{ "--config=b.lua", "--config-dir=/e" })) {
        .run => |cli| {
            try std.testing.expectEqualStrings("b.lua", cli.config_path.?);
            try std.testing.expectEqualStrings("/e", cli.config_dir.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "command line: a missing value and an unknown argument are reported, not ignored" {
    switch (parseTest(&.{"--config"})) {
        .needs_value => |opt| try std.testing.expectEqualStrings("--config", opt),
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{ "--check", "--config-dir" })) {
        .needs_value => |opt| try std.testing.expectEqualStrings("--config-dir", opt),
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{ "--check", "--bogus" })) {
        .unknown => |arg| try std.testing.expectEqualStrings("--bogus", arg),
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{"somefile"})) {
        .unknown => |arg| try std.testing.expectEqualStrings("somefile", arg),
        else => return error.TestUnexpectedResult,
    }
}

test "command line: the help text names every option parseArgs knows" {
    for ([_][]const u8{ "-h", "--help", "-V", "--version", "--check", "--paths", "--print-config", "--config", "--config-dir", "--log", "--install-session", "--uninstall-session", "--session-status", "--prefix", "--destdir", "--user", "--dry-run" }) |opt| {
        try std.testing.expect(std.mem.indexOf(u8, usage, opt) != null);
    }
}

test "command line: --log takes a filter, with a space or an equals sign" {
    switch (parseTest(&.{ "--log", "info,anim=debug" })) {
        .run => |cli| try std.testing.expectEqualStrings("info,anim=debug", cli.log_spec.?),
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{ "--check", "--log=warn" })) {
        .run => |cli| {
            try std.testing.expect(cli.check_only);
            try std.testing.expectEqualStrings("warn", cli.log_spec.?);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{"--log"})) {
        .needs_value => |opt| try std.testing.expectEqualStrings("--log", opt),
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{})) {
        .run => |cli| try std.testing.expect(cli.log_spec == null),
        else => return error.TestUnexpectedResult,
    }
}

test "main() takes its options from parseArgs and prints help and version on stdout" {
    const src = @embedFile("main.zig");
    const start = std.mem.indexOf(u8, src, "pub fn main(init: std.process.Init) !void {").?;
    const end = std.mem.indexOfPos(u8, src, start, "\n}\n").?;
    const body = src[start..end];
    const parse_at = std.mem.indexOf(u8, body, "cli_mod.parseArgs(&args)").?;
    // Options are handled before anything is loaded or connected.
    try std.testing.expect(parse_at < std.mem.indexOf(u8, body, "config.load(").?);
    try std.testing.expect(parse_at < std.mem.indexOf(u8, body, "ignoreSigchld()").?);
    try std.testing.expect(std.mem.indexOf(u8, body, ".help => return stdoutPrint(io") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".version => return stdoutPrint(io") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "config.config_path_override = cli.config_path") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "config.config_dir_override = cli.config_dir") != null);
}

test "main() sets the log filter before it loads anything" {
    const src = @embedFile("main.zig");
    const start = std.mem.indexOf(u8, src, "pub fn main(init: std.process.Init) !void {").?;
    const end = std.mem.indexOfPos(u8, src, start, "\n}\n").?;
    const body = src[start..end];
    const env_at = std.mem.indexOf(u8, body, "log_mod.initFromEnv()").?;
    const opt_at = std.mem.indexOf(u8, body, "log_mod.setSpec(spec)").?;
    try std.testing.expect(env_at < opt_at);
    try std.testing.expect(opt_at < std.mem.indexOf(u8, body, "config.load(").?);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const std_options: std.Options = .{ .log_level = .debug, .logFn = log_mod.logFn }") != null);
}

test "command line: the session options" {
    switch (parseTest(&.{ "--install-session", "--prefix", "/usr", "--destdir=/pkg", "--dry-run" })) {
        .run => |cli| {
            try std.testing.expect(cli.session.? == .install and cli.dry_run);
            try std.testing.expectEqualStrings("/usr", cli.prefix.?);
            try std.testing.expectEqualStrings("/pkg", cli.destdir.?);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parseTest(&.{ "--session-status", "--user" })) {
        .run => |cli| try std.testing.expect(cli.session.? == .status and cli.user_install),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(parseTest(&.{ "--install-session", "--uninstall-session" }) == .conflict);
    try std.testing.expect(parseTest(&.{ "--install-session", "--user", "--prefix=/usr" }) == .conflict);
    try std.testing.expect(parseTest(&.{"--prefix=/usr"}) == .needs_session);
    try std.testing.expect(parseTest(&.{"--dry-run"}) == .needs_session);
    try std.testing.expect(parseTest(&.{ "--install-session", "--prefix" }) == .needs_value);
}

// ---- the README and --help say the same --------------------------------------------------

/// Every `--option` word in `text`, once each, in order of appearance.
fn optionWords(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "--")) |at| {
        var end = at + 2;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
        i = end;
        // `--` alone, or the `--` of a longer dash run, is not an option.
        if (end - at < 3 or !std.ascii.isAlphanumeric(text[at + 2]) or (at > 0 and text[at - 1] == '-')) continue;
        const word = text[at..end];
        var seen = false;
        for (out.items) |w| {
            if (std.mem.eql(u8, w, word)) seen = true;
        }
        if (!seen) try out.append(gpa, word);
    }
    return out;
}

test "the command-line block of README.md and --help name the same options" {
    const gpa = std.testing.allocator;
    const readme = @embedFile("README.md");

    // The block that starts with the `wmaker-wl [OPTION]` line, up to its fence.
    const start = std.mem.indexOf(u8, readme, "wmaker-wl [OPTION]") orelse return error.NoCommandLineBlock;
    const stop = std.mem.indexOfPos(u8, readme, start, "```") orelse return error.NoCommandLineBlock;
    const block = readme[start..stop];

    var in_readme = try optionWords(gpa, block);
    defer in_readme.deinit(gpa);
    var in_help = try optionWords(gpa, usage);
    defer in_help.deinit(gpa);

    for (in_help.items) |w| {
        var found = false;
        for (in_readme.items) |r| {
            if (std.mem.eql(u8, r, w)) found = true;
        }
        if (!found) {
            std.debug.print("`{s}` is in --help but not in README.md's command line block\n", .{w});
            return error.ReadmeMissesOption;
        }
    }
    for (in_readme.items) |r| {
        var found = false;
        for (in_help.items) |w| {
            if (std.mem.eql(u8, r, w)) found = true;
        }
        if (!found) {
            std.debug.print("`{s}` is in README.md's command line block but not in --help\n", .{r});
            return error.HelpMissesOption;
        }
    }
    try std.testing.expect(in_help.items.len >= 10);
}

test "optionWords: options once each, no bare dashes" {
    const gpa = std.testing.allocator;
    var w = try optionWords(gpa, "-h, --help  --config FILE -- x --help --a-b ---c");
    defer w.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), w.items.len);
    try std.testing.expectEqualStrings("--help", w.items[0]);
    try std.testing.expectEqualStrings("--config", w.items[1]);
    try std.testing.expectEqualStrings("--a-b", w.items[2]);
}
