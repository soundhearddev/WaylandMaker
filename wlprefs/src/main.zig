// SPDX-License-Identifier: 0BSD
//
// wlprefs entry point: connect, bind globals, create the window, pump the
// Wayland event loop until the window is closed.

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;

const c = @cImport({
    @cInclude("poll.h");
});

const wlprefs = @import("wlprefs");
const Window = wlprefs.window.Window;

const usage =
    \\usage: wlprefs [--config FILE] [--shot DIR]
    \\
    \\The settings window of wmaker-wl. It edits wmaker-wl's config.conf
    \\($XDG_CONFIG_HOME/wmaker-wl/config.conf, else ~/.config/wmaker-wl/) and
    \\changes only the keys you change.
    \\
    \\  --config FILE   edit FILE instead (to try wlprefs out)
    \\  --shot DIR      draw every page into DIR/NN-name.png and exit; needs no
    \\                  Wayland session (for screenshots)
    \\  -h, --help      show this text
    \\
;

var should_exit = std.atomic.Value(bool).init(false);

fn onExitSignal(_: std.os.linux.SIG) callconv(.c) void {
    should_exit.store(true, .monotonic);
}

/// SIGINT/SIGTERM: leave the loop (the blocking dispatch returns EINTR)
/// instead of dying with the window half torn down.
fn installExitSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onExitSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var config_path: ?[]const u8 = null;
    var shot_dir: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse {
                std.debug.print("wlprefs: --config needs a file\n\n{s}", .{usage});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--shot")) {
            shot_dir = args.next() orelse {
                std.debug.print("wlprefs: --shot needs a directory\n\n{s}", .{usage});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            config_path = arg["--config=".len..];
        } else {
            std.debug.print("wlprefs: unknown argument `{s}`\n\n{s}", .{ arg, usage });
            std.process.exit(2);
        }
    }

    // Read the config BEFORE anything else: if that goes wrong we want to say
    // so, not discover it after a window is already open.
    var win = try Window.init(gpa, config_path);
    defer win.deinit();

    if (shot_dir) |dir| {
        win.snapshotAll(dir) catch |err| {
            std.debug.print("wlprefs: cannot write the pages to {s}: {t}\n", .{ dir, err });
            std.process.exit(1);
        };
        return;
    }

    const display = wl.Display.connect(null) catch |err| {
        std.log.err("could not connect to Wayland display: {t}", .{err});
        return err;
    };
    defer display.disconnect();

    installExitSignalHandlers();

    const registry = try display.getRegistry();
    registry.setListener(*Window, Window.registryListener, &win);

    // First roundtrip: collect every global the compositor advertises.
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    if (win.wm_base) |wm_base| {
        wm_base.setListener(*Window, Window.wmBaseListener, &win);
    } else {
        std.log.err("compositor does not support xdg_wm_base", .{});
        return error.MissingGlobal;
    }
    if (win.compositor == null) {
        std.log.err("compositor does not support wl_compositor", .{});
        return error.MissingGlobal;
    }
    if (win.shm == null) {
        std.log.err("compositor does not support wl_shm", .{});
        return error.MissingGlobal;
    }

    try win.create();

    // Second roundtrip: let the compositor send the initial
    // xdg_surface.configure, which unblocks the first draw().
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    try runLoop(display, &win);
}

/// The documented libwayland loop for poll(2). A plain `display.dispatch()`
/// would not do: libwayland retries its internal poll after EINTR, so a
/// SIGTERM/SIGINT would never get the loop to look at `should_exit`.
fn runLoop(display: *wl.Display, win: *Window) !void {
    while (!win.closed and !should_exit.load(.monotonic)) {
        // Nothing may be left in the queue when we go to sleep.
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.FlushFailed;
        }

        var pfd: c.struct_pollfd = .{
            .fd = display.getFd(),
            .events = @intCast(c.POLLIN | (if (flushed == .AGAIN) c.POLLOUT else 0)),
            .revents = 0,
        };
        const rc = c.poll(&pfd, 1, -1);

        if (rc > 0 and pfd.revents & c.POLLIN != 0) {
            if (display.readEvents() != .SUCCESS) return error.DispatchFailed;
        } else {
            display.cancelRead();
            // The compositor went away.
            if (rc > 0 and pfd.revents & (c.POLLERR | c.POLLHUP) != 0) return;
        }
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    }
}
