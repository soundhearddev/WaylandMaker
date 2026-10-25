// SPDX-License-Identifier: GPL-3.0
//
// wmaker-wl: a Wayland compositor on wlroots.
//
//   wmaker-wl                            from a TTY: DRM, libinput, logind/seatd
//   WLR_BACKENDS=wayland wmaker-wl       nested in a running Wayland session
//   zig build run                        the same, from the source tree
//
// A crash here takes the whole session with it; wlroots logs to stderr.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.main);

const wlr = @import("wlroots");
const model = @import("model.zig");
const types = model.types;
const config = model.config;
const action = model.action;
const wm_files = model.wm_files;
const log_mod = model.log;

const boot = @import("boot.zig");
const cli_mod = @import("cli.zig");
const diag = @import("diag.zig");
const Server = @import("server.zig").Server;

/// Every message reaches `log_mod.logFn`, which counts warnings and errors for
/// `--check` and prints what the filter (WMAKER_LOG, `--log`) lets through.
pub const std_options: std.Options = .{ .log_level = .debug, .logFn = log_mod.logFn };

/// Print to stdout (not the log): for the output of options that are meant
/// to be read or piped.
fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.print(fmt, args);
    try fw.interface.flush();
}

fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("wmaker-wl: " ++ fmt ++ "\n\ntry `wmaker-wl --help`\n", args);
    std.process.exit(2);
}

/// `wmaker-wl --paths`
fn showPaths(io: std.Io, gpa: std.mem.Allocator) !void {
    var cfg = try config.load(io, gpa);
    defer cfg.deinit();
    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try wm_files.printPaths(&fw.interface, io, cfg.arena.allocator(), &cfg);
    try fw.interface.flush();
}

/// `wmaker-wl --check`: read everything the session would read (config.lua,
/// the key bindings it makes, the root menu, WMWindowAttributes, WMState and
/// the autostart path), say what is wrong with it, and exit with 0 (clean) or
/// 1 (problems), without a display. For dotfile pipelines and a quick look
/// after editing. A broken file is reported and, like in the session, skipped
/// in favour of the next candidate.
fn checkConfig(io: std.Io, gpa: std.mem.Allocator) !void {
    var cfg = try config.load(io, gpa);
    defer cfg.deinit();
    const arena = cfg.arena.allocator();
    _ = try action.parseAll(arena, &cfg);
    _ = try wm_files.load(io, arena, &cfg);
    if (log_mod.problems > 0) {
        std.debug.print("{s}: {d} problem(s), see the messages above\n", .{ cfg.config_file, log_mod.problems });
        std.process.exit(1);
    }
    std.debug.print("{s}: OK\n", .{cfg.config_file});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    config.runner = action.runFromLua;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const cli = switch (cli_mod.parseArgs(&args)) {
        .run => |parsed_cli| parsed_cli,
        .help => return stdoutPrint(io, "{s}", .{cli_mod.usage}),
        .version => return stdoutPrint(io, "wmaker-wl {s} (built with zig {s}, wlroots {s})\n", .{ model.version.version, builtin.zig_version_string, wlr.version.str }),
        .unknown => |bad_arg| usageError("unknown argument `{s}`", .{bad_arg}),
        .needs_value => |bad_opt| usageError("{s} needs a value", .{bad_opt}),
    };
    config.config_path_override = cli.config_path;
    config.config_dir_override = cli.config_dir;

    // What is logged: WMAKER_LOG first, the option wins over it.
    log_mod.initFromEnv();
    diag.initFromEnv();
    if (cli.log_spec) |spec| log_mod.setSpec(spec) catch |err| usageError("--log `{s}`: {t}", .{ spec, err });

    if (cli.print_config) return stdoutPrint(io, "{s}", .{config.builtin_text});
    if (cli.show_paths) return showPaths(io, gpa);

    // A file named with --config must exist: silently falling back to the
    // defaults would look like "my config is not loaded".
    if (config.config_path_override) |p| {
        const text = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, p, gpa, .limited(1 << 20)) catch |err| {
            std.debug.print("wmaker-wl: cannot read {s}: {t}\n", .{ p, err });
            std.process.exit(1);
        };
        gpa.free(text);
    }

    if (cli.check_only) return checkConfig(io, gpa);

    wlr.log.init(.info, null);
    boot.ignoreSigchld();
    log.info("wmaker-wl {s}, wlroots {s}", .{ model.version.version, wlr.version.str });

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
