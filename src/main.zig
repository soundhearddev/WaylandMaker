const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");
const window_mod = @import("window.zig");
const output = @import("output.zig");
const seat = @import("seat.zig");

const WindowManager = types.WindowManager;

pub fn main(init: std.process.Init) !void {
    // Zig 0.16: std.process.Init hands us process-wide allocators and an
    // Io implementation already set up for us -- no need to build our own
    // std.Io.Threaded (or a DebugAllocator) by hand. init.gpa is
    // leak-checked in Debug builds the same way the old DebugAllocator
    // was.
    const allocator = init.gpa;
    const io = init.io;

    // DIAGNOSTIC (temporary): print an unmistakable ">>>TRACE<<<" line on
    // every major milestone. It's mixed in with river/wlroots/Xwayland's
    // own very noisy log output, so after `zig build run > log.txt 2>&1`,
    // pull out just these lines with:
    //   grep '>>>TRACE<<<' log.txt
    // This tells us, unambiguously, exactly how far we get: does main()
    // even start? Does the registry see river_window_manager_v1? Does
    // binding it succeed? Do output/seat/window events ever arrive? Does
    // manage_start ever fire? Remove this whole block (and the trace()
    // calls below) once that's answered.
    trace("main() entered");

    std.log.info("[INIT] Connecting to Wayland display...", .{});
    const display = wl.Display.connect(null) catch |err| {
        trace("wl.Display.connect FAILED");
        return err;
    };
    defer display.disconnect();
    trace("wl.Display.connect OK");

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);

    wm.* = .{
        .gpa = allocator,
        .io = io,
        .obj = null,
        .xkb_bindings = null,
        .outputs = undefined,
        .windows = undefined,
        .seats = undefined,
        .pending_windows = .empty,
        .needs_layout = true,
        .pending_focus = null,
        .pending_spawn = null,
        .pending_close = null,
    };

    wm.outputs.init();
    wm.windows.init();
    wm.seats.init();

    // See window.zig's global_wm doc comment: the closed-window handler
    // needs to reach the WindowManager and this is the simplest way given
    // there's only ever one instance.
    window_mod.global_wm = wm;

    const registry = try display.getRegistry();
    trace("getRegistry() OK, about to roundtrip");

    var context = Context{
        .wm = wm,
        .allocator = allocator,
    };

    registry.setListener(*Context, registryListener, &context);

    if (display.roundtrip() != .SUCCESS) {
        trace("FIRST roundtrip FAILED");
        std.log.err("[INIT] Initial display roundtrip failed.", .{});
        return;
    }
    trace("first roundtrip done (registry globals seen)");

    // A SECOND roundtrip, after the first one let registryListener bind
    // river_window_manager_v1 (if it was advertised). This flushes out
    // any events river_window_manager_v1 itself sends immediately upon
    // being bound (`output`, `seat`, possibly `unavailable`) *before* we
    // enter the dispatch loop, rather than relying on them showing up
    // whenever dispatch() next gets scheduled. Was previously missing --
    // may or may not be the actual bug, but it's cheap and correct to add
    // regardless (this mirrors the double-roundtrip pattern used by most
    // other river-window-management-v1 clients, e.g. rill).
    if (wm.obj != null) {
        if (display.roundtrip() != .SUCCESS) {
            trace("SECOND roundtrip FAILED");
        } else {
            trace("second roundtrip done (river_window_manager_v1 initial events, if any, now processed)");
        }
    } else {
        trace("wm.obj is NULL after first roundtrip -- river_window_manager_v1 was NEVER bound. " ++
            "This is the actual root cause if you see this line: either river did not advertise " ++
            "the interface at all, or the interface-name string comparison in registryListener " ++
            "never matched.");
    }

    std.log.info("[INIT] wmaker-wl started successfully. Entering event loop...", .{});
    trace("entering dispatch loop");

    while (display.dispatch() == .SUCCESS) {}

    trace("dispatch loop exited");
    std.log.warn("[EXIT] Event loop terminated.", .{});
}

/// Print `msg` with a monotonic counter and an unmistakable ">>>TRACE<<<"
/// marker straight to stderr via std.debug.print, which is unbuffered and
/// flushes immediately -- so it shows up even if the process is killed
/// right after, and survives being interleaved with river/wlroots/Xwayland
/// log noise on the same terminal. Deliberately NOT using
/// std.fs.createFileAbsolute here: Zig 0.16's release notes state "All fs
/// APIs are migrated to Io" (see https://ziglang.org/download/0.16.0/
/// release-notes.html), and we've already hit one build break from
/// assuming an old std.fs/std.process signature still existed -- no
/// reason to risk a second one in throwaway diagnostic code.
/// To see ONLY these lines: `zig build run 2>&1 | grep '>>>TRACE<<<'`
var trace_counter: u32 = 0;
fn trace(msg: []const u8) void {
    trace_counter += 1;
    std.debug.print(">>>TRACE<<< [{d}] {s}\n", .{ trace_counter, msg });
}

const Context = struct {
    wm: *WindowManager,
    allocator: std.mem.Allocator,
};

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    ctx: *Context,
) void {
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);
            // Trace EVERY global the compositor advertises, not just the
            // ones we recognize -- if river_window_manager_v1 is never
            // among these lines in /tmp/wmaker-wl-trace.log, it proves
            // river never advertised it to us at all (nothing we do in
            // Zig can fix that -- it'd be a river/session configuration
            // issue), as opposed to us failing to match/bind a global
            // that *was* offered.
            trace(interface_name);

            if (std.mem.eql(u8, interface_name, std.mem.span(river.WindowManagerV1.interface.name))) {
                std.log.info("[REGISTRY] Binding river_window_manager_v1 (Name: {d})", .{global.name});
                trace("registry saw river_window_manager_v1 global, binding it");
                const river_wm = registry.bind(global.name, river.WindowManagerV1, 1) catch {
                    trace("registry.bind(river_window_manager_v1) FAILED");
                    return;
                };
                ctx.wm.obj = river_wm;
                river_wm.setListener(*WindowManager, riverWmListener, ctx.wm);
                trace("river_window_manager_v1 bound + listener set");
            } else if (std.mem.eql(u8, interface_name, std.mem.span(river.XkbBindingsV1.interface.name))) {
                std.log.info("[REGISTRY] Binding river_xkb_bindings_v1", .{});
                const xkb_bindings = registry.bind(global.name, river.XkbBindingsV1, 1) catch return;
                ctx.wm.xkb_bindings = xkb_bindings;

                // Flag any seats already created as needing bindings.
                // Actual setupBindings() (and the enable() requests it
                // makes) happens in handleManageStart, since that's a
                // protocol requirement -- see seat.create()'s comment.
                var seat_it = ctx.wm.seats.first();
                while (seat_it) |s| : (seat_it = seat.nextSeat(s)) {
                    s.needs_binding_setup = true;
                }
                ctx.wm.needs_layout = true;
            }
            // NOTE: river_output_v1 and river_seat_v1 are deliberately NOT
            // handled here. They are not advertised as wl_registry globals
            // at all -- grep the protocol XML yourself:
            //   grep -n 'interface name="river_output_v1"\|interface name="river_seat_v1"'
            //     protocol/river-window-management-v1.xml
            // finds only the <interface> *definitions*, never a place
            // where wl_registry could bind one directly. Instead, per the
            // protocol, river_window_manager_v1 sends `output` and `seat`
            // events (each carrying a new_id) once *it* is bound -- see
            // riverWmListener below. The previous version of this file
            // tried to registry.bind() them here, which silently matched
            // nothing (no such global exists), so create() was never
            // called, outputs/seats never existed, isReady() was never
            // true, and layout.zig's math never got applied to anything.
        },
        else => {},
    }
}

fn riverWmListener(
    river_wm: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    wm: *WindowManager,
) void {
    trace("riverWmListener called");
    switch (event) {
        .unavailable => {
            trace("event: unavailable");
            // FACT (verified in protocol/river-window-management-v1.xml,
            // event "unavailable"): "This event indicates that window
            // management is not available to the client, perhaps due to
            // another window management client already running... If
            // sent, this event is guaranteed to be the first and only
            // event sent by the server." We previously had NO case for
            // this at all -- it fell into `else => {}` and was silently
            // swallowed. That means if river ever refused us the window
            // manager role, our process would sit in the dispatch loop
            // forever getting no output/seat/window/manage_start events
            // and doing nothing -- with zero indication why, which
            // matches everything observed (process "runs", nothing we
            // change in layout/window code has any visible effect). This
            // log line turns that silent, indistinguishable-from-a-hang
            // failure into an explicit, unmissable one.
            std.log.err("[RIVER] !!! river_window_manager_v1 is UNAVAILABLE -- " ++
                "another window manager client is likely already connected to " ++
                "this river session (or the compositor otherwise refused us). " ++
                "No output/seat/window/manage_start events will ever arrive on " ++
                "this connection. Check for another wmaker-wl/rivertile/river-wm " ++
                "process already running against the same river instance.", .{});
            river_wm.stop();
            std.process.exit(1);
        },
        .window => |ev| {
            trace("event: window");
            std.log.info("[RIVER] -> New window event received", .{});
            _ = window_mod.create(wm, ev.id, null) catch |err| {
                std.log.err("[WINDOW] Failed to create window: {}", .{err});
            };
        },
        .output => |ev| {
            trace("event: output");
            std.log.info("[RIVER] -> New output event received", .{});
            _ = output.create(wm, ev.id) catch |err| {
                std.log.err("[OUTPUT] Failed to create output: {}", .{err});
            };
        },
        .seat => |ev| {
            trace("event: seat");
            std.log.info("[RIVER] -> New seat event received", .{});
            _ = seat.create(wm, ev.id) catch |err| {
                std.log.err("[SEAT] Failed to create seat: {}", .{err});
            };
        },
        .manage_start => {
            trace("event: manage_start");
            handleManageStart(river_wm, wm);
        },
        .render_start => {
            trace("event: render_start");
            handleRenderStart(river_wm, wm);
        },
        .finished => {
            trace("event: finished");
            std.log.warn("[RIVER] river_window_manager_v1 finished -- exiting.", .{});
            std.process.exit(0);
        },
        else => {
            trace("event: <other, unhandled>");
            std.log.debug("[RIVER] Unhandled river_window_manager_v1 event", .{});
        },
    }
}

fn handleManageStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    std.log.info("[RIVER] -> MANAGE_START received", .{});

    // Bindings can only be enabled inside a manage sequence (protocol
    // requirement) -- do any pending setup now, for every seat that
    // needs it (newly created seats, or seats that existed before
    // xkb_bindings was bound).
    var seat_it = wm.seats.first();
    while (seat_it) |s| : (seat_it = seat.nextSeat(s)) {
        if (s.needs_binding_setup) seat.setupBindings(wm, s);
    }

    // Clean up any outputs river told us about via `removed` since the
    // last manage_start (e.g. a monitor was unplugged). output.reap()
    // existed but was never called anywhere before this fix.
    output.reap(wm);

    // Manage every window that hasn't been assigned to a column yet.
    // This also does the propose_dimensions request for it (window
    // management state), which -- like enable() above -- may only
    // happen here, not in render_start.
    var count: u32 = 0;
    var win_it = wm.windows.first();
    while (win_it) |win| {
        count += 1;
        const next_win = types.nextWindow(win, wm);

        if (win.new) {
            std.log.info("[MANAGE] Managing window {x}", .{@intFromPtr(win)});
            window_mod.manage(win, wm);
            wm.needs_layout = true;
        }
        win_it = next_win;
    }

    // Re-propose dimensions for every already-managed, ready window too:
    // this is what actually keeps windows tiled to the current layout
    // after a column is added/removed/focused, since layout.zig only
    // computes numbers -- it never talks to Wayland itself. Without this
    // loop, only brand-new windows would ever get a propose_dimensions
    // call and old windows would keep whatever size they had at creation.
    if (wm.needs_layout) applyLayout(wm);

    // Apply a focus change requested by a keybinding (action.zig). Must
    // happen here, not in the xkb_binding pressed callback that set this
    // field -- focus_window is manage-sequence-only, see types.zig's
    // comment on pending_focus.
    if (wm.pending_focus) |win| {
        if (wm.seats.first()) |s| s.obj.focusWindow(win.obj);
        wm.pending_focus = null;
    }

    // Ask the window to close, requested by a keybinding (e.g. mod+C).
    // Same manage-sequence-only reasoning as pending_focus. We don't
    // touch our own data structures here -- river will send a `closed`
    // event for the window later (see window.zig's handleClosed), and
    // that's where we actually unlink/free it.
    if (wm.pending_close) |win| {
        win.obj.close();
        wm.pending_close = null;
    }

    // Spawn a command requested by a keybinding (e.g. mod+Return ->
    // spawn_terminal). Deferred here alongside pending_focus purely to
    // keep all action side effects in one place; unlike focus_window this
    // isn't a Wayland request so it has no sequencing requirement of its
    // own.
    if (wm.pending_spawn) |argv| {
        spawn(wm, argv);
        wm.pending_spawn = null;
    }

    river_wm.manageFinish();
    std.log.info("[RIVER] <- MANAGE_FINISH sent ({d} windows checked)", .{count});
}

fn spawn(wm: *WindowManager, argv: []const []const u8) void {
    // Zig 0.16 replaced the old two-step std.process.Child.init(argv, gpa)
    // + child.spawn(io) with a single std.process.spawn(io, .{...}) call
    // that builds and starts the child in one go (see the 0.16 release
    // notes' "std.process.Child" migration example, and
    // https://cookbook.ziglang.cc/08-02-external/). Child.init/the
    // Child.*_behavior fields are gone entirely -- SpawnOptions' stdin/
    // stdout/stderr fields (lowercase .ignore/.pipe/.inherit, not the old
    // .Ignore/.Pipe/.Inherit) replace them, and no allocator is needed at
    // all (that's what removed the wm.gpa argument we had here before).
    const child = std.process.spawn(wm.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.err("[ACTION] Failed to spawn {s}: {}", .{ argv[0], err });
        return;
    };
    // We deliberately never call child.wait(io): waiting would block our
    // single-threaded event loop until the spawned app (e.g. foot) exits,
    // which defeats the point of spawning it in the background. Since all
    // three stdio streams are .ignore (no pipes were opened for us to
    // leak), there's nothing left to clean up on our side -- the kernel
    // reparents the process and reaps it normally on exit, same as any
    // other WM's "fire and forget" spawn.
    _ = child;
}

/// Recompute geometry for the active workspace of every ready output and
/// push it to river as *window management* state (propose_dimensions).
/// Must only be called from within a manage sequence. Rendering state
/// (river_node.set_position) is pushed separately from render_start,
/// see handleRenderStart below -- the protocol treats the two as
/// distinct kinds of state that may be modified at different times.
fn applyLayout(wm: *WindowManager) void {
    var out_it = wm.outputs.first();
    while (out_it) |out| : (out_it = types.nextOutput(out)) {
        if (!out.isReady()) continue;

        const ws = out.activeWorkspace();
        const rect = out.usableRect();

        if (ws.strip.active_column) |active| {
            layout.scrollToColumn(&ws.strip, active, rect.width);
        }
        layout.snapToEdge(&ws.strip, rect.width);
        layout.recomputeGeometry(&ws.strip, rect);

        var col_it = ws.strip.columns.first();
        while (col_it) |col| : (col_it = types.nextColumn(col)) {
            var w_it = col.windows.first();
            while (w_it) |win| : (w_it = types.nextWindowInColumn(win)) {
                if (!win.ready) continue;
                win.obj.proposeDimensions(win.width, win.height);
            }
        }
    }

    wm.needs_layout = false;
}

fn handleRenderStart(river_wm: *river.WindowManagerV1, wm: *WindowManager) void {
    std.log.info("[RIVER] -> RENDER_START received", .{});

    // Only rendering state (node positions) is allowed here -- dimensions
    // were already proposed during manage_start (see applyLayout above).
    var out_it = wm.outputs.first();
    while (out_it) |out| : (out_it = types.nextOutput(out)) {
        if (!out.isReady()) continue;

        const ws = out.activeWorkspace();
        var col_it = ws.strip.columns.first();
        while (col_it) |col| : (col_it = types.nextColumn(col)) {
            var w_it = col.windows.first();
            while (w_it) |win| : (w_it = types.nextWindowInColumn(win)) {
                if (win.node) |node| node.setPosition(win.x, win.y);
            }
        }
    }

    river_wm.renderFinish();
    std.log.info("[RIVER] <- RENDER_FINISH sent", .{});
}
