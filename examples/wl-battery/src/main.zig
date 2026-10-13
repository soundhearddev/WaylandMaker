// SPDX-License-Identifier: 0BSD
//
// wl-battery: a battery DockApp for wmaker-wl, based on wl-clock.
//
// Same DockApp recipe as wl-clock:
//   1. app_id "dockapp:<name>", <name> being the program's own name.
//   2. No size hint: it is proposed one whole Dock tile (wmaker-wl's `dock_size`,
//      64 px by default); the 64x64 face is scaled to it (scale.zig).
// wmaker-wl does the rest (Dock tile, no frame, every workspace).
//
// Draws into two wl_shm buffers, sleeps in poll(2) until the next battery
// read (every --interval seconds, default 5) or until the compositor has
// something to say, and only redraws when what is shown would change.
// A click reads the battery again right away.
//
// Put `wl-battery &` in ~/.config/wmaker-wl/autostart.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;

const battery = @import("battery.zig");
const face = @import("face.zig");
const options = @import("options.zig");
const scale = @import("scale.zig");
const sysfs = @import("sysfs.zig");
const uevent = @import("uevent.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("poll.h");
});

test {
    _ = battery;
    _ = face;
    _ = options;
    _ = scale;
    _ = sysfs;
    _ = uevent;
}

/// linux/input-event-codes.h BTN_LEFT.
const btn_left = 0x110;

const Buf = struct {
    buffer: *wl.Buffer,
    /// The compositor still has it (attached, not yet released).
    busy: bool = false,
};

const State = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
    cursor_manager: ?*wp.CursorShapeManagerV1 = null,

    pointer: ?*wl.Pointer = null,
    cursor_device: ?*wp.CursorShapeDeviceV1 = null,

    surface: *wl.Surface = undefined,
    xdg_surface: *xdg.Surface = undefined,
    toplevel: *xdg.Toplevel = undefined,

    bufs: [2]Buf = undefined,
    /// Both buffers' pixels, one after the other.
    pixels: []u32 = &.{},
    /// The mapping behind `pixels`, and the side the buffers were made for.
    map: ?[]align(std.heap.page_size_min) u8 = null,
    buf_side: i32 = 0,
    /// The side the compositor proposed (xdg_toplevel.configure).
    side: i32 = face.tile,
    /// The 64x64 picture, before it is scaled into a buffer of `side`.
    frame: face.Pixels = undefined,

    /// Cached sysfs file descriptors: a read is a few pread() calls.
    reader: sysfs.Reader = .{},
    /// Kernel uevent socket, -1: none (then only the timer).
    uevent_fd: c_int = -1,
    verbose: bool = false,
    interval_ms: i64 = 5000,
    /// Monotonic ms of the next sysfs read; 0 = read at once.
    next_read: i64 = 0,
    /// Read again now (click).
    force: bool = false,
    bat: battery.Info = .{},

    running: bool = true,
    /// The first xdg_surface.configure has arrived: only now may we attach.
    configured: bool = false,
    /// Something other than the battery changed what must be shown.
    dirty: bool = true,
    /// What the last committed frame showed.
    shown: ?battery.Info = null,
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // program name
    const opts = options.parse(&args) catch |err| switch (err) {
        error.HelpRequested => {
            std.debug.print("{s}", .{options.usage});
            return;
        },
        else => {
            std.debug.print("wl-battery: {t}\n\n{s}", .{ err, options.usage });
            std.process.exit(2);
        },
    };

    var state: State = .{
        .reader = .{ .wanted = opts.battery },
        .verbose = opts.verbose,
        .interval_ms = @as(i64, opts.interval) * 1000,
    };

    // No compositor needed: draw one frame to a file. Handy for a preview
    // and for the screenshot in the README.
    if (opts.snapshot) |path| {
        var px: face.Pixels = undefined;
        var reader: sysfs.Reader = .{ .wanted = opts.battery };
        face.render(&px, reader.read());
        writeSnapshot(path, &px, opts.size) catch |err| {
            std.debug.print("wl-battery: cannot write {s}: {t}\n", .{ path, err });
            std.process.exit(1);
        };
        return;
    }

    const gpa = init.gpa;

    const display = wl.Display.connect(null) catch |err| {
        std.log.err("cannot connect to a Wayland compositor: {t}", .{err});
        std.log.err("(is $WAYLAND_DISPLAY set? are you running inside river/wmaker-wl?)", .{});
        return err;
    };
    defer display.disconnect();

    // Without this SIGINT/SIGTERM would kill us at the default disposition and
    // skip every `defer` below. The handlers only set a flag; poll() is what
    // notices (it returns EINTR), see run loop.
    installExitSignalHandlers();
    state.uevent_fd = uevent.open();

    const registry = try display.getRegistry();
    registry.setListener(*State, registryListener, &state);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    _ = state.shm orelse return error.NoWlShm;
    const compositor = state.compositor orelse return error.NoWlCompositor;
    const wm_base = state.wm_base orelse return error.NoXdgWmBase;
    wm_base.setListener(*State, wmBaseListener, &state);
    if (state.seat) |seat| seat.setListener(*State, seatListener, &state);

    // The buffers are made (and made again) in redrawIfNeeded, for the side
    // the compositor proposes.
    defer freeBuffers(&state);

    // ---- the window ---------------------------------------------------------

    const surface = try compositor.createSurface();
    defer surface.destroy();
    state.surface = surface;

    const xdg_surface = try wm_base.getXdgSurface(surface);
    defer xdg_surface.destroy();
    state.xdg_surface = xdg_surface;
    xdg_surface.setListener(*State, xdgSurfaceListener, &state);

    const toplevel = try xdg_surface.getToplevel();
    defer toplevel.destroy();
    state.toplevel = toplevel;
    toplevel.setListener(*State, toplevelListener, &state);

    // ---- the tag that makes this a DockApp -----------------------

    const app_id = try std.fmt.allocPrintSentinel(gpa, "dockapp:{s}", .{opts.name}, 0);
    defer gpa.free(app_id);
    toplevel.setAppId(app_id.ptr);
    toplevel.setTitle("Battery");
    // No min/max size: a DockApp without a size hint is proposed one whole
    // Dock tile, whatever wmaker-wl's `dock_size` is (xdg_toplevel.configure).

    surface.commit();

    // An xdg_surface must not get a buffer before its first configure.
    while (!state.configured and state.running) {
        if (should_exit.load(.monotonic)) return;
        const err = display.dispatch();
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.DispatchFailed;
    }

    try runLoop(display, &state);
}

// ----------------------------------------------------------------------------
// The loop: draw if something changed, then sleep until something can change.
// ----------------------------------------------------------------------------

fn runLoop(display: *wl.Display, state: *State) !void {
    while (state.running and !should_exit.load(.monotonic)) {
        redrawIfNeeded(state);

        // The documented libwayland pattern for a poll()-based loop: nothing
        // may be left in the default queue when we go to sleep.
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.FlushFailed;
        }

        var pfds = [2]c.struct_pollfd{
            .{
                .fd = display.getFd(),
                .events = @intCast(c.POLLIN | (if (flushed == .AGAIN) c.POLLOUT else 0)),
                .revents = 0,
            },
            .{ .fd = state.uevent_fd, .events = @intCast(c.POLLIN), .revents = 0 },
        };
        const nfds: c.nfds_t = if (state.uevent_fd >= 0) 2 else 1;
        const rc = c.poll(&pfds, nfds, msUntilNextRead(state));

        if (rc > 0 and pfds[0].revents & c.POLLIN != 0) {
            if (display.readEvents() != .SUCCESS) return error.DispatchFailed;
        } else {
            display.cancelRead();
            // The compositor went away.
            if (rc > 0 and pfds[0].revents & (c.POLLERR | c.POLLHUP) != 0) return;
        }

        // The kernel says a power supply changed: read now, not at the next tick.
        if (rc > 0 and nfds == 2 and pfds[1].revents & c.POLLIN != 0) {
            switch (uevent.drain(state.uevent_fd)) {
                .none => {},
                .change => state.force = true,
                .topology => {
                    state.reader.rediscover();
                    state.force = true;
                },
            }
        }
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    }
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Without a battery nothing changes by itself (a new one announces itself
/// by uevent), so the timer can be slow.
const idle_ms: i64 = 60_000;

/// Milliseconds until the battery is read next.
fn msUntilNextRead(state: *const State) c_int {
    const wait = state.next_read - nowMs();
    return @intCast(std.math.clamp(wait, 1, @max(state.interval_ms, idle_ms)));
}

fn redrawIfNeeded(state: *State) void {
    const t = nowMs();
    if (state.force or t >= state.next_read) {
        state.bat = state.reader.read();
        state.next_read = t + (if (state.bat.present) state.interval_ms else idle_ms);
        state.force = false;
    }
    if (!state.dirty) {
        if (state.shown) |s| {
            if (std.meta.eql(s, state.bat)) return;
        }
    }

    // Both buffers with the compositor: wait for a `release` (the loop wakes
    // up for it) instead of drawing into memory it is still reading.
    ensureBuffers(state) catch |err| {
        std.log.err("cannot make the {d}x{d} buffers: {t}", .{ state.side, state.side, err });
        return;
    };
    const idx: usize = if (!state.bufs[0].busy) 0 else if (!state.bufs[1].busy) 1 else return;

    face.render(&state.frame, state.bat);
    const side: usize = @intCast(state.side);
    scale.resize(state.pixels[idx * side * side ..][0 .. side * side], side, &state.frame, face.side);

    state.surface.attach(state.bufs[idx].buffer, 0, 0);
    state.surface.damageBuffer(0, 0, state.side, state.side);
    state.surface.commit();
    state.bufs[idx].busy = true;
    state.shown = state.bat;
    state.dirty = false;
    if (state.verbose) {
        const b = state.bat;
        std.debug.print("wl-battery: draw present={} {d}% {t} ac={} power={any}mW time={any}min\n", .{ b.present, b.percent, b.status, b.ac, b.power_mw, b.minutes });
    }
}

// ----------------------------------------------------------------------------
// Buffers: one memfd, one pool, two wl_buffers. They are `side` x `side`, the
// side wmaker-wl proposes (its `dock_size`), and are made again when it changes.
// ----------------------------------------------------------------------------

fn freeBuffers(state: *State) void {
    const map = state.map orelse return;
    for (&state.bufs) |b| b.buffer.destroy();
    posix.munmap(map);
    state.map = null;
    state.pixels = &.{};
    state.buf_side = 0;
}

fn ensureBuffers(state: *State) !void {
    if (state.map != null and state.buf_side == state.side) return;
    const shm = state.shm orelse return error.NoWlShm;
    freeBuffers(state);

    const side: usize = @intCast(state.side);
    const stride: i32 = state.side * 4;
    const one: usize = side * side * 4;
    const size: usize = one * 2;

    const rc = linux.memfd_create("wl-battery", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.MemfdCreate;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.Truncate;

    const map = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    errdefer posix.munmap(map);

    // The pool can go as soon as the buffers exist; they keep the memory.
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();

    var made: usize = 0;
    errdefer for (state.bufs[0..made]) |b| b.buffer.destroy();
    for (&state.bufs, 0..) |*b, i| {
        b.* = .{
            .buffer = try pool.createBuffer(@intCast(i * one), state.side, state.side, stride, .argb8888),
        };
        made += 1;
        b.buffer.setListener(*Buf, bufferListener, b);
    }
    state.map = map;
    state.pixels = std.mem.bytesAsSlice(u32, map);
    state.buf_side = state.side;
}

// ----------------------------------------------------------------------------
// --snapshot
// ----------------------------------------------------------------------------

/// Binary PPM (P6), no alpha: the face is opaque. libc stdio on purpose, so
/// this stays free of the std.Io plumbing.
fn writePpm(path: [:0]const u8, px: []const u32, side: usize) !void {
    const f = c.fopen(path.ptr, "wb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    if (c.fprintf(f, "P6\n%d %d\n255\n", @as(c_int, @intCast(side)), @as(c_int, @intCast(side))) < 0) return error.WriteFailed;
    for (px[0 .. side * side]) |p| {
        const rgb = [3]u8{
            @truncate(p >> 16),
            @truncate(p >> 8),
            @truncate(p),
        };
        if (c.fwrite(&rgb, 1, 3, f) != 3) return error.WriteFailed;
    }
}

/// --snapshot: the 64x64 picture scaled to `--size` (the way a DockApp
/// shows it in a bigger or smaller Dock).
fn writeSnapshot(path: [:0]const u8, px: *const face.Pixels, side: u16) !void {
    var out: [scale.max_side * scale.max_side]u32 = undefined;
    scale.resize(&out, side, px, face.side);
    try writePpm(path, &out, side);
}

// ----------------------------------------------------------------------------
// SIGINT/SIGTERM: leave the loop cleanly. poll() returns EINTR, the loop
// re-checks the flag. Same "only set a flag in the handler" rule as
// wmaker-wl's own SIGHUP handler.
// ----------------------------------------------------------------------------

var should_exit = std.atomic.Value(bool).init(false);

fn onExitSignal(_: std.os.linux.SIG) callconv(.c) void {
    should_exit.store(true, .monotonic);
}

fn installExitSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onExitSignal },
        .mask = posix.sigemptyset(),
        .flags = 0, // no SA_RESTART: poll() must see EINTR
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
}

// ----------------------------------------------------------------------------
// Wayland listeners
// ----------------------------------------------------------------------------

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *State) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            const eql = std.mem.eql;

            if (eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                state.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 4)) catch |err| {
                    std.log.err("bind wl_compositor: {t}", .{err});
                    return;
                };
            } else if (eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                state.shm = registry.bind(g.name, wl.Shm, 1) catch |err| {
                    std.log.err("bind wl_shm: {t}", .{err});
                    return;
                };
            } else if (eql(u8, name, std.mem.span(xdg.WmBase.interface.name))) {
                state.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 3)) catch |err| {
                    std.log.err("bind xdg_wm_base: {t}", .{err});
                    return;
                };
            } else if (eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                // Only the first seat: one pointer is enough.
                if (state.seat == null) {
                    state.seat = registry.bind(g.name, wl.Seat, @min(g.version, 5)) catch |err| {
                        std.log.err("bind wl_seat: {t}", .{err});
                        return;
                    };
                }
            } else if (eql(u8, name, std.mem.span(wp.CursorShapeManagerV1.interface.name))) {
                // Optional. Without it the compositor keeps whatever cursor
                // it had, which is acceptable here.
                state.cursor_manager = registry.bind(g.name, wp.CursorShapeManagerV1, 1) catch null;
            }
        },
        else => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *State) void {
    switch (event) {
        .ping => |p| wm_base.pong(p.serial),
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, state: *State) void {
    switch (event) {
        .configure => |cfg| {
            xdg_surface.ackConfigure(cfg.serial);
            state.configured = true;
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *State) void {
    switch (event) {
        // We set no size hint, so the compositor proposes one whole Dock
        // tile (wmaker-wl's dock_size, 64 by default). The 64x64 picture is
        // scaled to it.
        .configure => |cfg| {
            const side = scale.proposedSide(cfg.width, cfg.height, face.tile);
            if (side != state.side) {
                state.side = side;
                state.dirty = true;
            }
        },
        .close => state.running = false,
    }
}

fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, buf: *Buf) void {
    switch (event) {
        .release => buf.busy = false,
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, state: *State) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.pointer and state.pointer == null) {
                const pointer = seat.getPointer() catch |err| {
                    std.log.err("wl_seat.get_pointer: {t}", .{err});
                    return;
                };
                state.pointer = pointer;
                pointer.setListener(*State, pointerListener, state);
                if (state.cursor_manager) |mgr| {
                    state.cursor_device = mgr.getPointer(pointer) catch null;
                }
            }
        },
        else => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, state: *State) void {
    switch (event) {
        // The compositor hands the cursor to us on enter; say "arrow".
        .enter => |e| if (state.cursor_device) |dev| dev.setShape(e.serial, .default),
        .button => |b| {
            if (b.state == .pressed and b.button == btn_left) {
                state.force = true;
            }
        },
        else => {},
    }
}
