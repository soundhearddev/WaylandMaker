// SPDX-License-Identifier: GPL-3.0
//
// wmaker-wlr: wmaker-wl as its own compositor on wlroots (milestone A of
// docs/TODO wlroots.md). The river build (src/main.zig) is untouched.
//
//   WLR_BACKENDS=wayland wmaker-wlr      nested in the current session
//   wmaker-wlr                           from a TTY: DRM, libinput, logind/seatd
//
// A crash here takes the whole session with it; wlroots logs go to stderr.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.main);

const wlr = @import("wlroots");
const model = @import("model");
const types = model.types;
const config = model.config;
const action = model.action;

const boot = @import("boot.zig");
const Server = @import("server.zig").Server;
const cli_mod = @import("cli.zig");

/// Every message reaches the model's log filter (WMAKER_LOG, `--log`).
pub const std_options: std.Options = .{ .log_level = .debug, .logFn = model.log.logFn };

const usage =
    \\usage: wmaker-wlr [OPTION]
    \\
    \\wmaker-wl as a Wayland compositor (wlroots backend).
    \\
    \\  -h, --help            this text
    \\  -V, --version         print the version
    \\      --config FILE     read FILE instead of the default config.lua
    \\      --config-dir DIR  look for config.lua, RootMenu, WMWindowAttributes
    \\                        and autostart in DIR
    \\      --log SPEC        what to log, e.g. `info,server=debug`
    \\                        (the same as the environment variable WMAKER_LOG)
    \\
    \\Nested in a running session, set WLR_BACKENDS=wayland (or x11).
    \\`pkill -HUP wmaker-wlr` reloads the config.
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("wmaker-wlr: " ++ fmt ++ "\n\ntry `wmaker-wlr --help`\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    config.runner = action.runFromLua;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const cli = switch (cli_mod.parseArgs(&args)) {
        .run => |c| c,
        .help => return print(io, "{s}", .{usage}),
        .version => return print(io, "wmaker-wlr {s} (zig {s}, wlroots {s})\n", .{ version, builtin.zig_version_string, wlr.version.str }),
        .unknown => |a| fail("unknown argument `{s}`", .{a}),
        .needs_value => |a| fail("{s} needs a value", .{a}),
    };
    config.config_path_override = cli.config_path;
    config.config_dir_override = cli.config_dir;

    model.log.initFromEnv();
    if (cli.log_spec) |spec| model.log.setSpec(spec) catch |err| fail("--log `{s}`: {t}", .{ spec, err });

    // A file named with --config must exist: silently falling back to the
    // defaults would look like "my config is not loaded".
    if (cli.config_path) |p| {
        const text = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, p, gpa, .limited(1 << 20)) catch |err| {
            std.debug.print("wmaker-wlr: cannot read {s}: {t}\n", .{ p, err });
            std.process.exit(1);
        };
        gpa.free(text);
    }

    wlr.log.init(.info, null);
    boot.ignoreSigchld();
    log.info("wmaker-wlr {s}, wlroots {s}", .{ version, wlr.version.str });

    // ---- the model ---------------------------------------------------------------
    const wm = try gpa.create(types.WindowManager);
    defer gpa.destroy(wm);
    wm.* = .{
        .gpa = gpa,
        .io = io,
        .cfg = try config.load(io, gpa),
        .obj = undefined,
        .obj_version = 0,
        .outputs = undefined,
        .windows = undefined,
        .dock_windows = undefined,
        .seats = undefined,
    };
    defer wm.cfg.deinit();
    wm.outputs.init();
    wm.windows.init();
    wm.dock_windows.init();
    wm.seats.init();
    action.global = wm;

    const startup = boot.loadModel(wm) catch return error.ConfigLoadFailed;

    // ---- the compositor ----------------------------------------------------------
    const server = try Server.create(gpa, wm);
    defer server.destroy();

    const socket = try server.listen();
    defer gpa.free(socket);

    // `environment` first (the programs below inherit it), then the programs.
    boot.applyEnvironment(wm.cfg.environment);
    log.info("running on WAYLAND_DISPLAY={s} (config: {s})", .{ socket, wm.cfg.config_file });
    boot.runAutostart(wm, startup.autostart);

    try server.run();
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.print(fmt, args);
    try fw.interface.flush();
}

const version = model.version.version;
