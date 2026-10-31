// SPDX-License-Identifier: GPL-3.0
//
// The login session: the files that make WaylandMaker show up in a login
// manager and start properly (session script, wmaker-wl.desktop, systemd user
// units, portal config), and the systemd readiness notification.
//
// `zig build install` puts these files in place (build.zig uses `items` and
// `render` from here, so there is one list). `wmaker-wl --install-session`,
// `--uninstall-session` and `--session-status` do the same from the binary
// itself, for builds that did not go through `zig build install`.
//
// Nothing here needs a display or wlroots.

const std = @import("std");

// ---- the files ---------------------------------------------------------------

pub const Place = enum {
    bin,
    sessions,
    units,
    portals,
    applications,
    themes,
};

pub const Item = struct {
    place: Place,
    file: []const u8,
    body: []const u8,
    mode: u32,
};

/// `@BINDIR@` in `body` is replaced by the directory of wmaker-wl.
pub const items = [_]Item{
    .{ .place = .bin, .file = "wmaker-wl-session", .body = @embedFile("share/wmaker-wl-session"), .mode = 0o755 },
    .{ .place = .sessions, .file = "wmaker-wl.desktop", .body = @embedFile("share/wmaker-wl.desktop"), .mode = 0o644 },
    .{ .place = .units, .file = "wmaker-wl.service", .body = @embedFile("share/wmaker-wl.service"), .mode = 0o644 },
    .{ .place = .units, .file = "wmaker-wl-shutdown.target", .body = @embedFile("share/wmaker-wl-shutdown.target"), .mode = 0o644 },
    .{ .place = .portals, .file = "wmaker-wl-portals.conf", .body = @embedFile("share/wmaker-wl-portals.conf"), .mode = 0o644 },
    .{ .place = .applications, .file = "wlprefs.desktop", .body = @embedFile("share/wlprefs.desktop"), .mode = 0o644 },
    .{ .place = .themes, .file = "gruvbox.lua", .body = @embedFile("share/Themes/gruvbox.lua"), .mode = 0o644 },
    .{ .place = .themes, .file = "nord.lua", .body = @embedFile("share/Themes/nord.lua"), .mode = 0o644 },
    .{ .place = .themes, .file = "next.lua", .body = @embedFile("share/Themes/next.lua"), .mode = 0o644 },
    .{ .place = .themes, .file = "graphite.lua", .body = @embedFile("share/Themes/graphite.lua"), .mode = 0o644 },
};

/// Where the files go, as paths below `prefix`.
pub const Layout = struct {
    prefix: []const u8,
    /// systemd reads `lib/systemd/user` only below /usr and /usr/local; a
    /// per-user prefix uses `share/systemd/user` (XDG_DATA_HOME).
    unit_subdir: []const u8 = "lib/systemd/user",

    pub fn subdir(l: Layout, place: Place) []const u8 {
        return switch (place) {
            .bin => "bin",
            .sessions => "share/wayland-sessions",
            .units => l.unit_subdir,
            .portals => "share/xdg-desktop-portal",
            .applications => "share/applications",
            .themes => "share/wmaker-wl/Themes",
        };
    }

    /// The final path of a file (without a staging directory).
    pub fn path(l: Layout, a: std.mem.Allocator, item: Item) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ l.prefix, l.subdir(item.place), item.file });
    }

    pub fn bindir(l: Layout, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/bin", .{l.prefix});
    }
};

/// The text of a file as installed: `@BINDIR@` filled in.
pub fn render(a: std.mem.Allocator, item: Item, bindir: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, item.body, "@BINDIR@", bindir);
}

// ---- the command line options ---------------------------------------------------

pub const Action = enum { install, uninstall, status };

pub const Options = struct {
    /// Install prefix; default /usr/local (/usr when this binary is in /usr/bin).
    prefix: ?[]const u8 = null,
    /// Stage below this directory (packaging); paths inside the files stay final.
    destdir: ?[]const u8 = null,
    /// Use ~/.local, for login managers that read the user's data directory.
    user: bool = false,
    dry_run: bool = false,
};

pub const Error = error{ BadPrefix, NoHome, WriteFailed } || std.mem.Allocator.Error;

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn validPrefix(p: []const u8) bool {
    if (p.len == 0 or p[0] != '/') return false;
    for (p) |ch| if (ch <= ' ' or ch == 0x7f or ch == '%' or ch == '"' or ch == '\\') return false;
    return true;
}

fn trimSlashes(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

/// Choose the layout. `exe` is the path of this binary (null if unknown).
pub fn resolveLayout(a: std.mem.Allocator, opts: Options, exe: ?[]const u8, home: ?[]const u8) Error!Layout {
    if (opts.user) {
        const h = home orelse return error.NoHome;
        if (!validPrefix(h)) return error.NoHome;
        return .{
            .prefix = try std.fmt.allocPrint(a, "{s}/.local", .{trimSlashes(h)}),
            .unit_subdir = "share/systemd/user",
        };
    }
    if (opts.prefix) |p| {
        if (!validPrefix(p)) return error.BadPrefix;
        const t = trimSlashes(p);
        return .{ .prefix = try a.dupe(u8, t) };
    }
    if (exe) |e| {
        if (std.mem.eql(u8, e, "/usr/bin/wmaker-wl")) return .{ .prefix = "/usr" };
    }
    return .{ .prefix = "/usr/local" };
}

// ---- file system -------------------------------------------------------------

extern "c" fn umask(mask: c_uint) c_uint;

const max_file: usize = 512 << 20;

fn staged(a: std.mem.Allocator, destdir: ?[]const u8, final: []const u8) ![]u8 {
    if (destdir) |d| return std.fmt.allocPrint(a, "{s}{s}", .{ trimSlashes(d), final });
    return a.dupe(u8, final);
}

fn readIfThere(io: std.Io, a: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn writeFileAtomic(io: std.Io, path: []const u8, data: []const u8, mode: u32) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .fromMode(@intCast(mode)),
        .make_path = true,
        .replace = true,
    });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, data);
    // Not left to the umask: a login manager must be able to read the file.
    try af.file.setPermissions(io, .fromMode(@intCast(mode)));
    try af.replace(io);
}

fn modeOf(io: std.Io, path: []const u8) ?u32 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(st.permissions.toMode() & 0o777);
}

const State = enum { missing, differs, ok };

fn stateOf(io: std.Io, a: std.mem.Allocator, path: []const u8, want: []const u8, mode: u32) !State {
    const have = (try readIfThere(io, a, path)) orelse return .missing;
    defer a.free(have);
    if (!std.mem.eql(u8, have, want)) return .differs;
    if (modeOf(io, path)) |m| {
        if ((m & 0o111 != 0) != (mode & 0o111 != 0)) return .differs;
    }
    return .ok;
}

fn permissionHint(err: anyerror) bool {
    return err == error.AccessDenied or err == error.PermissionDenied or err == error.ReadOnlyFileSystem;
}

pub const binaries = [_][]const u8{ "wmaker-wl", "wlprefs" };

/// Run `action`. Messages go to `w`. Returns true when everything is as it
/// should be (install/uninstall: nothing failed; status: all files match).
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    action: Action,
    opts: Options,
    exe: ?[]const u8,
    w: *std.Io.Writer,
) Error!bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const layout = resolveLayout(a, opts, exe, getenv("HOME")) catch |err| {
        switch (err) {
            error.BadPrefix => w.writeAll("wmaker-wl: --prefix must be an absolute path without spaces\n") catch {},
            error.NoHome => w.writeAll("wmaker-wl: --user needs $HOME\n") catch {},
            else => {},
        }
        return err;
    };
    const bindir = try layout.bindir(a);
    _ = umask(0o022);

    var failed: u32 = 0;
    var todo: u32 = 0;

    // The binaries come first: the session files point to them.
    if (action == .install) {
        if (exe) |e| {
            const exe_dir = e[0 .. std.mem.lastIndexOfScalar(u8, e, '/') orelse 0];
            for (binaries) |bin| {
                const src = try std.fmt.allocPrint(a, "{s}/{s}", .{ exe_dir, bin });
                const final = try std.fmt.allocPrint(a, "{s}/{s}", .{ bindir, bin });
                if (opts.destdir == null and std.mem.eql(u8, src, final)) continue;
                const data = (readIfThere(io, a, src) catch null) orelse continue;
                const dest = try staged(a, opts.destdir, final);
                const st = stateOf(io, a, dest, data, 0o755) catch .missing;
                if (st == .ok) {
                    try w.print("  unchanged  {s}\n", .{final});
                    continue;
                }
                if (opts.dry_run) {
                    try w.print("  would copy {s} -> {s}\n", .{ src, final });
                    continue;
                }
                writeFileAtomic(io, dest, data, 0o755) catch |err| {
                    failed += 1;
                    try w.print("  FAILED     {s}: {t}\n", .{ final, err });
                    if (permissionHint(err)) todo += 1;
                    continue;
                };
                try w.print("  copied     {s}\n", .{final});
            }
        }
    }

    var all_ok = true;
    for (items) |item| {
        const final = try layout.path(a, item);
        const dest = try staged(a, opts.destdir, final);
        const text = try render(a, item, bindir);

        switch (action) {
            .status => {
                const st = stateOf(io, a, dest, text, item.mode) catch .missing;
                if (st != .ok) all_ok = false;
                try w.print("  [{s}] {s}\n", .{ switch (st) {
                    .ok => "ok     ",
                    .differs => "differs",
                    .missing => "missing",
                }, final });
            },
            .install => {
                const st = stateOf(io, a, dest, text, item.mode) catch .missing;
                if (st == .ok) {
                    try w.print("  unchanged  {s}\n", .{final});
                    continue;
                }
                if (opts.dry_run) {
                    try w.print("  would {s} {s}\n", .{ if (st == .missing) "install" else "update ", final });
                    continue;
                }
                writeFileAtomic(io, dest, text, item.mode) catch |err| {
                    failed += 1;
                    try w.print("  FAILED     {s}: {t}\n", .{ final, err });
                    if (permissionHint(err)) todo += 1;
                    continue;
                };
                try w.print("  {s}  {s}\n", .{ if (st == .missing) "installed" else "updated  ", final });
            },
            .uninstall => {
                if (opts.dry_run) {
                    try w.print("  would remove {s}\n", .{final});
                    continue;
                }
                std.Io.Dir.cwd().deleteFile(io, dest) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => {
                        failed += 1;
                        try w.print("  FAILED     {s}: {t}\n", .{ final, err });
                        if (permissionHint(err)) todo += 1;
                        continue;
                    },
                };
                try w.print("  removed    {s}\n", .{final});
            },
        }
    }

    if (action == .uninstall and !opts.dry_run) {
        // Leave nothing but our own empty directory behind.
        for ([_][]const u8{ "share/wmaker-wl/Themes", "share/wmaker-wl" }) |sub| {
            const final = try std.fmt.allocPrint(a, "{s}/{s}", .{ layout.prefix, sub });
            const dest = try staged(a, opts.destdir, final);
            std.Io.Dir.cwd().deleteDir(io, dest) catch {};
        }
    }

    switch (action) {
        .status => {
            for (binaries) |bin| {
                const final = try std.fmt.allocPrint(a, "{s}/{s}", .{ bindir, bin });
                const dest = try staged(a, opts.destdir, final);
                const there = modeOf(io, dest) != null;
                if (!there and std.mem.eql(u8, bin, "wmaker-wl")) all_ok = false;
                try w.print("  [{s}] {s}\n", .{ if (there) "ok     " else "missing", final });
            }
            return all_ok;
        },
        .install => {
            if (failed > 0) {
                if (todo > 0) try w.writeAll("wmaker-wl: permission denied: run as root (sudo), or use --user or --destdir\n");
                return false;
            }
            if (opts.dry_run) return true;
            if (opts.user) {
                try w.writeAll("note: most login managers read only /usr/share/wayland-sessions and\n" ++
                    "      /usr/local/share/wayland-sessions, not ~/.local; from a TTY run\n" ++
                    "      `wmaker-wl-session` instead.\n");
            } else if (!std.mem.eql(u8, layout.prefix, "/usr") and !std.mem.eql(u8, layout.prefix, "/usr/local")) {
                try w.writeAll("note: systemd and many login managers look in /usr and /usr/local only;\n" ++
                    "      below another prefix the session works but starts without the\n" ++
                    "      systemd unit unless you add its data directory to XDG_DATA_DIRS.\n");
            } else if (std.mem.eql(u8, layout.prefix, "/usr/local")) {
                try w.writeAll("note: if your login manager does not list WaylandMaker, it may read only\n" ++
                    "      /usr/share/wayland-sessions: use --prefix /usr.\n");
            }
            try w.writeAll("done: pick WaylandMaker in the login manager (or run wmaker-wl-session).\n");
            return true;
        },
        .uninstall => {
            if (failed > 0) {
                if (todo > 0) try w.writeAll("wmaker-wl: permission denied: run as root (sudo)\n");
                return false;
            }
            if (!opts.dry_run) try w.writeAll("done: wmaker-wl and wlprefs themselves were left in place.\n");
            return true;
        },
    }
}

// ---- systemd readiness -----------------------------------------------------------

var notify_path: [108]u8 = undefined;
var notify_len: usize = 0;

extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Remember $NOTIFY_SOCKET (set by systemd for `Type=notify`) and remove it
/// from the environment, so that no program started later talks to it.
/// Call once, early.
pub fn captureNotifySocket() void {
    const p = getenv("NOTIFY_SOCKET") orelse return;
    _ = unsetenv("NOTIFY_SOCKET");
    if (p.len < 2 or p.len >= notify_path.len) return;
    if (p[0] != '/' and p[0] != '@') return;
    @memcpy(notify_path[0..p.len], p);
    notify_len = p.len;
}

/// Send `state` ("READY=1", "STOPPING=1", "STATUS=...") to systemd. Does nothing
/// when we were not started with a notify socket.
pub fn notify(state: []const u8) void {
    if (notify_len == 0) return;
    sendTo(notify_path[0..notify_len], state) catch |err| {
        std.log.scoped(.boot).warn("systemd notify failed: {t}", .{err});
    };
}

fn sendTo(path: []const u8, state: []const u8) !void {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.DGRAM | std.c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = std.c.close(fd);

    var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (path[0] == '@') addr.path[0] = 0; // abstract socket
    const len: std.c.socklen_t = @intCast(@offsetOf(std.c.sockaddr.un, "path") + path.len);
    const n = std.c.sendto(fd, state.ptr, state.len, std.c.MSG.NOSIGNAL, @ptrCast(&addr), len);
    if (n < 0) return error.SendFailed;
}

// ---- tests ---------------------------------------------------------------------

test "every file of the session is embedded and non-empty" {
    for (items) |it| try std.testing.expect(it.body.len > 0);
}

test "the session script is a POSIX shell script and the desktop file points at it" {
    try std.testing.expect(std.mem.startsWith(u8, items[0].body, "#!/bin/sh\n"));
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "@BINDIR@/wmaker-wl-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[2].body, "Type=notify") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[0].body, "\r") == null);
}

test "render fills in the bin directory everywhere" {
    const a = std.testing.allocator;
    for (items) |it| {
        const t = try render(a, it, "/opt/x/bin");
        defer a.free(t);
        try std.testing.expect(std.mem.indexOf(u8, t, "@BINDIR@") == null);
    }
}

test "layout: prefixes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/usr/local", (try resolveLayout(a, .{}, null, null)).prefix);
    try std.testing.expectEqualStrings("/usr", (try resolveLayout(a, .{}, "/usr/bin/wmaker-wl", null)).prefix);
    try std.testing.expectEqualStrings("/usr/local", (try resolveLayout(a, .{}, "/home/u/zig-out/bin/wmaker-wl", null)).prefix);
    try std.testing.expectEqualStrings("/opt/wm", (try resolveLayout(a, .{ .prefix = "/opt/wm//" }, null, null)).prefix);
    const u = try resolveLayout(a, .{ .user = true }, null, "/home/max");
    try std.testing.expectEqualStrings("/home/max/.local", u.prefix);
    try std.testing.expectEqualStrings("share/systemd/user", u.unit_subdir);
    try std.testing.expectError(error.BadPrefix, resolveLayout(a, .{ .prefix = "rel" }, null, null));
    try std.testing.expectError(error.BadPrefix, resolveLayout(a, .{ .prefix = "/a b" }, null, null));
    try std.testing.expectError(error.NoHome, resolveLayout(a, .{ .user = true }, null, null));
}

test "install, status, update and uninstall below a destdir" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &rbuf);
    const dest = rbuf[0..n];

    var out: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    const opts: Options = .{ .prefix = "/usr", .destdir = dest };

    try std.testing.expect(!(try run(io, gpa, .status, opts, null, &w)));
    w = .fixed(&out);
    try std.testing.expect(try run(io, gpa, .install, opts, null, &w));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "FAILED") == null);

    const p = try std.fmt.allocPrint(gpa, "{s}/usr/bin/wmaker-wl-session", .{dest});
    defer gpa.free(p);
    try std.testing.expect(modeOf(io, p).? & 0o111 == 0o111);
    const d = try std.fmt.allocPrint(gpa, "{s}/usr/share/wayland-sessions/wmaker-wl.desktop", .{dest});
    defer gpa.free(d);
    const text = (try readIfThere(io, gpa, d)).?;
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Exec=/usr/bin/wmaker-wl-session") != null);
    try std.testing.expect(modeOf(io, d).? & 0o044 == 0o044);

    // Second run changes nothing; a damaged file is repaired.
    w = .fixed(&out);
    try std.testing.expect(try run(io, gpa, .install, opts, null, &w));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "installed") == null);
    try writeFileAtomic(io, d, "junk\n", 0o644);
    w = .fixed(&out);
    try std.testing.expect(!(try run(io, gpa, .status, opts, null, &w)));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "differs") != null);
    w = .fixed(&out);
    try std.testing.expect(try run(io, gpa, .install, opts, null, &w));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "updated") != null);

    // Dry run touches nothing.
    w = .fixed(&out);
    try std.testing.expect(try run(io, gpa, .uninstall, .{ .prefix = "/usr", .destdir = dest, .dry_run = true }, null, &w));
    try std.testing.expect(modeOf(io, d) != null);

    w = .fixed(&out);
    try std.testing.expect(try run(io, gpa, .uninstall, opts, null, &w));
    try std.testing.expect(modeOf(io, d) == null);
    try std.testing.expect(modeOf(io, p) == null);
}

test "notify: a datagram reaches the socket" {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.DGRAM | std.c.SOCK.CLOEXEC, 0);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
    const name = "@wmaker-wl-notify-test";
    @memcpy(addr.path[0..name.len], name);
    addr.path[0] = 0;
    const len: std.c.socklen_t = @intCast(@offsetOf(std.c.sockaddr.un, "path") + name.len);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(fd, @ptrCast(&addr), len));

    try sendTo(name, "READY=1");
    var buf: [32]u8 = undefined;
    const got = std.c.recv(fd, &buf, buf.len, 0);
    try std.testing.expectEqualStrings("READY=1", buf[0..@intCast(got)]);
}
