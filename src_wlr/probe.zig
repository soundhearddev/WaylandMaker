// SPDX-License-Identifier: 0BSD (tinywl.zig, zig-wlroots) / GPL-3.0 (glue)
//
// wlroots compositor driven by the wmaker-wl data model (src/model.zig):
// layout, workspaces, key bindings and config come from the model, wlroots
// only supplies outputs, input, xdg-shell and rendering.
//
//   zig build wlr-probe
//   WLR_BACKENDS=wayland ./zig-out/bin/wlr-probe [shell command]

const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const model = @import("model");
const wm_backend = @import("backend");

const types = model.types;
const workspace = model.workspace;
const layout = model.layout;
const action = model.action;
const config = model.config;

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.probe);

/// Nested in another compositor (river, ...) the parent grabs Super. With
/// this on, Alt counts as Super for the key bindings from config.lua.
/// Turn it off when running on a TTY.
const alt_as_super = true;

/// Keycodes the "was this press consumed by a binding" set can track.
const max_keycodes = 768;

var dummy_byte: u8 = 0;

pub fn main(init: std.process.Init) anyerror!void {
    wlr.log.init(.info, null);
    ignoreSigchld();

    var server: Server = undefined;
    try server.init(init.io);
    defer server.deinit();

    var buf: [11]u8 = undefined;
    const socket = try server.wl_server.addSocketAuto(&buf);

    server.env_map = try init.minimal.environ.createMap(gpa);
    defer server.env_map.deinit();
    try server.env_map.put("WAYLAND_DISPLAY", socket);

    try server.backend.start();
    log.info("running on WAYLAND_DISPLAY={s}", .{socket});

    for (server.wm.cfg.spawn_at_startup) |argv| server.spawn(argv);
    const args = init.minimal.args.vector;
    if (args.len >= 2) server.spawn(&.{ "/bin/sh", "-c", std.mem.span(args[1]) });

    server.wl_server.run();
}

/// Children are never waited for: let the kernel reap them.
fn ignoreSigchld() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.CHLD, &act, null);
}

fn closeToplevel(w: *wm_backend.Window) void {
    const toplevel: *Toplevel = @ptrCast(@alignCast(w));
    toplevel.xdg_toplevel.sendClose();
}

fn toplevelOf(win: *types.Window) *Toplevel {
    return @ptrCast(@alignCast(win.obj));
}

fn lowerKeysym(sym: u32) u32 {
    return if (sym >= 'A' and sym <= 'Z') sym + 32 else sym;
}

/// Lookup key of a binding: modifier bits in the high word, lower-case keysym below.
fn bindKey(mods: u32, sym: u32) u64 {
    return (@as(u64, mods) << 32) | lowerKeysym(sym);
}

fn keyMods(mask: wlr.Keyboard.ModifierMask) u32 {
    return config.modsBits(.{
        .shift = mask.shift,
        .ctrl = mask.ctrl,
        .mod1 = mask.alt and !alt_as_super,
        .mod3 = mask.mod3,
        .mod4 = mask.logo or (alt_as_super and mask.alt),
        .mod5 = mask.mod5,
    });
}

const GrabMode = enum { move, resize };

const Grab = struct {
    toplevel: *Toplevel,
    mode: GrabMode,
    edges: wlr.Edges,
    /// Cursor position and the window's float_rect (output-local) at the start.
    cursor_x: f64,
    cursor_y: f64,
    rect: types.Rect,
};

const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    scene: *wlr.Scene,

    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    new_output: wl.Listener(*wlr.Output) = .init(newOutput),

    xdg_shell: *wlr.XdgShell,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevel),
    new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopup),

    seat: *wlr.Seat,
    new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelection),
    keyboards: wl.list.Head(Keyboard, .link) = undefined,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = .init(cursorFrame),

    /// Pointer move/resize of a floating window, started by the client.
    grab: ?Grab = null,

    // ---- wmaker model ----
    wm: *types.WindowManager = undefined,
    io: std.Io = undefined,
    env_map: std.process.Environ.Map = undefined,
    /// bindKey(mods, keysym) -> index into wm.cfg.binds / wm.commands.
    binds: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn init(server: *Server, io: std.Io) !void {
        const wl_server = try wl.Server.create();
        const loop = wl_server.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, null);
        const renderer = try wlr.Renderer.autocreate(backend);
        const output_layout = try wlr.OutputLayout.create(wl_server);
        const scene = try wlr.Scene.create();
        server.* = .{
            .wl_server = wl_server,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .seat = try wlr.Seat.create(wl_server, "default"),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
            .io = io,
        };

        try server.renderer.initServer(wl_server);

        _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);

        server.backend.events.new_output.add(&server.new_output);

        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);

        server.backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
        server.keyboards.init();

        server.cursor.attachOutputLayout(server.output_layout);
        try server.cursor_mgr.load(1);
        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);

        try server.initModel();
        wm_backend.close_fn = closeToplevel;
    }

    fn deinit(server: *Server) void {
        server.wl_server.destroyClients();

        server.new_input.link.remove();
        server.new_output.link.remove();

        server.new_xdg_toplevel.link.remove();
        server.new_xdg_popup.link.remove();
        server.request_set_cursor.link.remove();
        server.request_set_selection.link.remove();
        server.cursor_motion.link.remove();
        server.cursor_motion_absolute.link.remove();
        server.cursor_button.link.remove();
        server.cursor_axis.link.remove();
        server.cursor_frame.link.remove();

        server.binds.deinit(gpa);
        server.backend.destroy();
        server.wl_server.destroy();
    }

    // ---- model ---------------------------------------------------------------

    fn initModel(server: *Server) !void {
        const wm = try gpa.create(types.WindowManager);
        errdefer gpa.destroy(wm);
        wm.* = .{
            .gpa = gpa,
            .io = server.io,
            .cfg = try config.load(server.io, gpa),
            .obj = @ptrCast(&dummy_byte),
            .obj_version = 6,
            .outputs = undefined,
            .windows = undefined,
            .dock_windows = undefined,
            .seats = undefined,
        };
        wm.outputs.init();
        wm.windows.init();
        wm.dock_windows.init();
        wm.seats.init();
        wm.commands = try action.parseAll(wm.cfg.arena.allocator(), &wm.cfg);
        server.wm = wm;

        // One hash lookup per key press instead of a scan over every binding.
        // The first binding of a key wins; unparsable ones are skipped.
        try server.binds.ensureTotalCapacity(gpa, @intCast(wm.cfg.binds.len));
        for (wm.cfg.binds, 0..) |b, i| {
            if (i >= wm.commands.len) break;
            switch (wm.commands[i]) {
                .none => continue,
                else => {},
            }
            const gop = server.binds.getOrPutAssumeCapacity(bindKey(config.modsBits(b.mods), b.keysym));
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        }
        log.info("model ready: {d} binds ({d} usable keys), {d} workspaces per output", .{
            wm.cfg.binds.len, server.binds.count(), wm.cfg.workspace_count,
        });
    }

    fn spawn(server: *Server, argv: []const []const u8) void {
        if (argv.len == 0) return;
        log.info("spawn `{s}`", .{argv[0]});
        _ = std.process.spawn(server.io, .{
            .argv = argv,
            .environ_map = &server.env_map,
            .stdin = .ignore,
            // Keep the child's output so "not found" or a Wayland connection
            // error shows up in our log.
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            log.err("failed to spawn `{s}`: {t}", .{ argv[0], err });
        };
    }

    /// Run a command from config.lua. Spawning is done here so that children
    /// get our WAYLAND_DISPLAY; everything else is the model's action.run.
    fn runCommand(server: *Server, cmd: types.Command) void {
        log.debug("command {s}", .{@tagName(cmd)});
        switch (cmd) {
            .spawn => |argv| server.spawn(argv),
            .shell => |sh| server.spawn(&.{ "/bin/sh", "-c", sh }),
            else => action.run(server.wm, cmd),
        }
        server.manage();
    }

    /// `key` is the level-0 symbol of the pressed key (no modifier applied).
    fn handleKeybind(server: *Server, key: xkb.Keysym, mask: wlr.Keyboard.ModifierMask) bool {
        // Emergency exit, independent of config.lua.
        if (mask.alt and key == xkb.Keysym.Escape) {
            server.wl_server.terminate();
            return true;
        }
        const idx = server.binds.get(bindKey(keyMods(mask), @intFromEnum(key))) orelse return false;
        server.runCommand(server.wm.commands[idx]);
        return true;
    }

    fn addWindow(server: *Server, toplevel: *Toplevel) void {
        const wm = server.wm;
        const out = types.workingOutput(wm) orelse {
            log.warn("toplevel {*}: no output yet, left unmanaged", .{toplevel});
            return;
        };

        const win = gpa.create(types.Window) catch return;
        win.* = .{ .obj = @ptrCast(toplevel), .node = @ptrCast(toplevel.scene_tree) };
        win.ready = true;
        win.new = false;
        wm.windows.append(win);
        workspace.placeTiled(wm, out.ws(), win) catch |err| {
            log.err("placeTiled failed: {t}", .{err});
            types.unlink(&win.link);
            gpa.destroy(win);
            return;
        };
        toplevel.win = win;
        wm.focus_request = win;
        wm.follow_request = true;
        server.manage();
    }

    fn removeWindow(server: *Server, toplevel: *Toplevel) void {
        const win = toplevel.win orelse return;
        toplevel.win = null;
        if (server.grab) |g| {
            if (g.toplevel == toplevel) server.grab = null;
        }

        const wm = server.wm;
        const ws = win.workspace;
        if (wm.focus_request == win) wm.focus_request = null;
        workspace.unplace(wm, win);
        types.unlink(&win.link);
        gpa.destroy(win);

        if (ws) |w| {
            if (workspace.defaultFocus(w)) |next| wm.focus_request = next;
        }
        server.manage();
    }

    /// What river calls a manage sequence: focus, layout, apply.
    fn manage(server: *Server) void {
        const wm = server.wm;

        if (wm.focus_request) |win| {
            wm.focus_request = null;
            if (win.workspace != null) {
                const t = toplevelOf(win);
                server.focusView(t, t.xdg_toplevel.base.surface);
            }
        }

        const follow = wm.follow_request;
        wm.follow_request = false;
        wm.focus_by_pointer = false;
        server.layoutAll(follow);

        if (wm.quit) server.wl_server.terminate();
    }

    fn layoutAll(server: *Server, follow: bool) void {
        const wm = server.wm;

        // Minimized windows belong to no workspace: keep them hidden.
        var wit = wm.windows.first();
        while (wit) |win| : (wit = types.nextWindow(win, wm)) {
            if (win.workspace == null) toplevelOf(win).apply(false, win.target);
        }

        var oit = wm.outputs.first();
        while (oit) |out| : (oit = types.nextOutput(out, wm)) {
            if (!types.liveOutput(out)) continue;
            var i: u32 = 0;
            while (i < out.workspace_count) : (i += 1) {
                const ws = &out.workspaces[i];
                const shown = i == out.active;
                if (shown) layout.compute(ws, &wm.cfg, follow);
                applyWorkspace(ws, shown);
            }
        }
    }

    fn applyWorkspace(ws: *types.Workspace, shown: bool) void {
        var cit = ws.strip.columns.first();
        while (cit) |col| : (cit = types.nextCol(col)) {
            var wit = col.windows.first();
            while (wit) |win| : (wit = types.nextWin(win)) toplevelOf(win).apply(shown, win.target);
        }
        var fit = ws.floating.first();
        while (fit) |win| : (fit = types.nextFloating(win)) toplevelOf(win).apply(shown, win.target);
    }

    // ---- pointer move / resize of floating windows -----------------------------

    fn beginGrab(server: *Server, toplevel: *Toplevel, mode: GrabMode, edges: wlr.Edges) void {
        const win = toplevel.win orelse return;
        // Tiled and fullscreen geometry belongs to the layout.
        if (win.mode != .floating or !win.has_float_rect) return;
        server.grab = .{
            .toplevel = toplevel,
            .mode = mode,
            .edges = edges,
            .cursor_x = server.cursor.x,
            .cursor_y = server.cursor.y,
            .rect = win.float_rect,
        };
    }

    fn updateGrab(server: *Server) void {
        const g = server.grab orelse return;
        const win = g.toplevel.win orelse {
            server.grab = null;
            return;
        };
        const out = (win.workspace orelse return).output;
        const dx: i32 = @intFromFloat(server.cursor.x - g.cursor_x);
        const dy: i32 = @intFromFloat(server.cursor.y - g.cursor_y);

        var r = g.rect;
        switch (g.mode) {
            .move => {
                r.x += dx;
                r.y += dy;
            },
            .resize => {
                if (g.edges.left) {
                    r.x += dx;
                    r.w -= dx;
                } else if (g.edges.right) r.w += dx;
                if (g.edges.top) {
                    r.y += dy;
                    r.h -= dy;
                } else if (g.edges.bottom) r.h += dy;

                // Respect the size limits; the edge opposite to the dragged one stays put.
                const c = win.clampSize(r.w, r.h, server.wm.cfg.min_window_size);
                if (g.edges.left) r.x += r.w - c.w;
                if (g.edges.top) r.y += r.h - c.h;
                r.w = c.w;
                r.h = c.h;
            },
        }

        win.float_rect = r;
        win.target = .{ .x = out.rect.x + r.x, .y = out.rect.y + r.y, .w = r.w, .h = r.h };
        g.toplevel.apply(true, win.target);
    }

    // ---- outputs ---------------------------------------------------------------

    fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output", listener);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return;

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) return;

        Output.create(server, wlr_output) catch {
            log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };
    }

    // ---- xdg-shell -------------------------------------------------------------

    fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_xdg_toplevel", listener);
        const xdg_surface = xdg_toplevel.base;

        const toplevel = gpa.create(Toplevel) catch {
            log.err("failed to allocate new toplevel", .{});
            return;
        };

        toplevel.* = .{
            .server = server,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = server.scene.tree.createSceneXdgSurface(xdg_surface) catch {
                gpa.destroy(toplevel);
                log.err("failed to allocate new toplevel", .{});
                return;
            },
        };
        toplevel.scene_tree.node.data = toplevel;
        xdg_surface.data = toplevel.scene_tree;

        xdg_surface.surface.events.commit.add(&toplevel.commit);
        xdg_surface.surface.events.map.add(&toplevel.map);
        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
    }

    fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const xdg_surface = xdg_popup.base;

        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
            // The xdg surface user data could be left null due to allocation failure.
            return;
        };
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = scene_tree;

        const popup = gpa.create(Popup) catch {
            log.err("failed to allocate new popup", .{});
            return;
        };
        popup.* = .{
            .xdg_popup = xdg_popup,
        };

        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    const ViewAtResult = struct {
        toplevel: *Toplevel,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    fn viewAt(server: *Server, lx: f64, ly: f64) ?ViewAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*Toplevel, @ptrCast(@alignCast(n.node.data)))) |toplevel| {
                    return ViewAtResult{
                        .toplevel = toplevel,
                        .surface = scene_surface.surface,
                        .sx = sx,
                        .sy = sy,
                    };
                }
            }
        }
        return null;
    }

    fn focusView(server: *Server, toplevel: *Toplevel, surface: *wlr.Surface) void {
        if (toplevel.win) |w| workspace.activate(w);

        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                if (xdg_surface.role_data.toplevel) |previous| _ = previous.setActivated(false);
            }
        }

        toplevel.scene_tree.node.raiseToTop();
        _ = toplevel.xdg_toplevel.setActivated(true);

        const wlr_keyboard = server.seat.getKeyboard() orelse return;
        server.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    // ---- input -----------------------------------------------------------------

    fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => Keyboard.create(server, device) catch |err| {
                log.err("failed to create keyboard: {t}", .{err});
                return;
            },
            .pointer => server.cursor.attachInputDevice(device),
            else => {},
        }

        server.seat.setCapabilities(.{
            .pointer = true,
            .keyboard = server.keyboards.length() > 0,
        });
    }

    fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_cursor", listener);
        if (event.seat_client == server.seat.pointer_state.focused_client)
            server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_selection", listener);
        server.seat.setSelection(event.source, event.serial);
    }

    fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion", listener);
        server.cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion_absolute", listener);
        server.cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    fn processCursorMotion(server: *Server, time_msec: u32) void {
        if (server.grab != null) return server.updateGrab();

        if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
            server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
        } else {
            server.cursor.setXcursor(server.cursor_mgr, "default");
            server.seat.pointerClearFocus();
        }
    }

    fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_button", listener);
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (event.state == .released) {
            server.grab = null;
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.toplevel, res.surface);
        }
    }

    fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_axis", listener);
        server.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const server: *Server = @fieldParentPtr("cursor_frame", listener);
        server.seat.pointerNotifyFrame();
    }
};

const Output = struct {
    server: *Server,
    wlr_output: *wlr.Output,
    /// The model output (rect, workspaces).
    model: ?*types.Output = null,

    frame: wl.Listener(*wlr.Output) = .init(handleFrame),
    request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
    destroy: wl.Listener(*wlr.Output) = .init(handleDestroy),

    // The wlr.Output should be destroyed by the caller on failure to trigger cleanup.
    fn create(server: *Server, wlr_output: *wlr.Output) !void {
        const output = try gpa.create(Output);
        errdefer gpa.destroy(output);

        output.* = .{
            .server = server,
            .wlr_output = wlr_output,
        };

        const layout_output = try server.output_layout.addAuto(wlr_output);
        const scene_output = try server.scene.createSceneOutput(wlr_output);
        server.scene_output_layout.addOutput(layout_output, scene_output);

        try output.addModel(layout_output);

        // Listeners last: nothing above can fail after they are registered.
        wlr_output.events.frame.add(&output.frame);
        wlr_output.events.request_state.add(&output.request_state);
        wlr_output.events.destroy.add(&output.destroy);
    }

    fn addModel(output: *Output, layout_output: *wlr.OutputLayout.Output) !void {
        const server = output.server;
        const wm = server.wm;

        const mo = try gpa.create(types.Output);
        errdefer gpa.destroy(mo);
        mo.* = .{ .obj = @ptrCast(output) };
        mo.rect = .{
            .x = layout_output.x,
            .y = layout_output.y,
            .w = output.wlr_output.width,
            .h = output.wlr_output.height,
        };
        _ = workspace.setWorkspaceCount(wm, mo, wm.cfg.workspace_count);
        wm.outputs.append(mo);
        if (wm.active_output == null) wm.active_output = mo;
        output.model = mo;
        log.info("output {d},{d} {d}x{d}, {d} workspaces", .{ mo.rect.x, mo.rect.y, mo.rect.w, mo.rect.h, mo.workspace_count });
        server.manage();
    }

    fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("frame", listener);

        const scene_output = output.server.scene.getSceneOutput(output.wlr_output).?;
        _ = scene_output.commit(null);

        var now = timestamp();
        scene_output.sendFrameDone(&now);
    }

    fn handleRequestState(
        listener: *wl.Listener(*wlr.Output.event.RequestState),
        event: *wlr.Output.event.RequestState,
    ) void {
        const output: *Output = @fieldParentPtr("request_state", listener);

        if (!output.wlr_output.commitState(event.state)) return;

        // The nested window was resized (or the mode changed): the model's
        // output rect has to follow, and only then is a relayout needed.
        const m = output.model orelse return;
        const w = output.wlr_output.width;
        const h = output.wlr_output.height;
        if (m.rect.w == w and m.rect.h == h) return;
        m.rect.w = w;
        m.rect.h = h;
        log.info("output resized to {d}x{d}", .{ w, h });
        output.server.manage();
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("destroy", listener);

        output.frame.link.remove();
        output.request_state.link.remove();
        output.destroy.link.remove();

        if (output.model) |m| m.removed = true;
        gpa.destroy(output);
    }
};

const Toplevel = struct {
    server: *Server,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,
    /// The model window; set between map and unmap.
    win: ?*types.Window = null,

    /// What was last sent to the scene / the client, so that only changes
    /// cost anything (a configure per layout pass would wake every client).
    enabled: bool = true,
    last: types.Rect = .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32), .w = -1, .h = -1 },

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    map: wl.Listener(void) = .init(handleMap),
    unmap: wl.Listener(void) = .init(handleUnmap),
    destroy: wl.Listener(void) = .init(handleDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),

    fn apply(toplevel: *Toplevel, shown: bool, t: types.Rect) void {
        if (toplevel.enabled != shown) {
            toplevel.enabled = shown;
            toplevel.scene_tree.node.setEnabled(shown);
        }
        if (!shown) return;
        if (t.x != toplevel.last.x or t.y != toplevel.last.y) {
            toplevel.scene_tree.node.setPosition(t.x, t.y);
        }
        if (t.w != toplevel.last.w or t.h != toplevel.last.h) {
            _ = toplevel.xdg_toplevel.setSize(t.w, t.h);
        }
        toplevel.last = t;
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const toplevel: *Toplevel = @fieldParentPtr("commit", listener);
        if (toplevel.xdg_toplevel.base.initial_commit) {
            _ = toplevel.xdg_toplevel.setSize(0, 0);
        }
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("map", listener);
        toplevel.server.addWindow(toplevel);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("unmap", listener);
        toplevel.server.removeWindow(toplevel);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);
        toplevel.server.removeWindow(toplevel);

        toplevel.commit.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.destroy.link.remove();
        toplevel.request_move.link.remove();
        toplevel.request_resize.link.remove();

        gpa.destroy(toplevel);
    }

    fn handleRequestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);
        toplevel.server.beginGrab(toplevel, .move, .{});
    }

    fn handleRequestResize(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
        event: *wlr.XdgToplevel.event.Resize,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_resize", listener);
        toplevel.server.beginGrab(toplevel, .resize, event.edges);
    }
};

const Popup = struct {
    xdg_popup: *wlr.XdgPopup,

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *Popup = @fieldParentPtr("commit", listener);
        if (popup.xdg_popup.base.initial_commit) {
            _ = popup.xdg_popup.base.scheduleConfigure();
        }
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("destroy", listener);

        popup.commit.link.remove();
        popup.destroy.link.remove();

        gpa.destroy(popup);
    }
};

const Keyboard = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,
    /// Keymap state without modifiers: gives the level-0 symbol of a key
    /// (Super+Shift+1 still reports `1`).
    plain_state: ?*xkb.State = null,
    /// Keys whose press ran a binding: their release is not forwarded either.
    consumed: std.StaticBitSet(max_keycodes) = .initEmpty(),

    modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
    destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

    fn create(server: *Server, device: *wlr.InputDevice) !void {
        const keyboard = try gpa.create(Keyboard);
        errdefer gpa.destroy(keyboard);

        keyboard.* = .{
            .server = server,
            .device = device,
        };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();
        keyboard.plain_state = xkb.State.new(keymap);

        const wlr_keyboard = device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 600);

        wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
        wlr_keyboard.events.key.add(&keyboard.key);
        device.events.destroy.add(&keyboard.destroy);

        server.seat.setKeyboard(wlr_keyboard);
        server.keyboards.append(keyboard);
    }

    fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
        keyboard.server.seat.setKeyboard(wlr_keyboard);
        keyboard.server.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }

    fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const wlr_keyboard = keyboard.device.toKeyboard();
        const server = keyboard.server;

        var handled = false;
        if (event.state == .pressed) {
            // libinput keycode -> xkbcommon keycode
            const plain = keyboard.plain_state orelse wlr_keyboard.xkb_state.?;
            const mask = wlr_keyboard.getModifiers();
            for (plain.keyGetSyms(event.keycode + 8)) |sym| {
                if (server.handleKeybind(sym, mask)) {
                    handled = true;
                    break;
                }
            }
            if (handled and event.keycode < max_keycodes) keyboard.consumed.set(event.keycode);
        } else if (event.state == .released) {
            if (event.keycode < max_keycodes and keyboard.consumed.isSet(event.keycode)) {
                keyboard.consumed.unset(event.keycode);
                handled = true;
            }
        }

        if (!handled) {
            server.seat.setKeyboard(wlr_keyboard);
            server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const keyboard: *Keyboard = @fieldParentPtr("destroy", listener);

        keyboard.link.remove();
        if (keyboard.plain_state) |s| s.unref();

        keyboard.modifiers.link.remove();
        keyboard.key.link.remove();
        keyboard.destroy.link.remove();

        gpa.destroy(keyboard);
    }
};

fn timestamp() posix.timespec {
    var timespec: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &timespec))) {
        .SUCCESS => return timespec,
        else => @panic("CLOCK_MONOTONIC not supported"),
    }
}
