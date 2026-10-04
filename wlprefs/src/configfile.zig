// SPDX-License-Identifier: 0BSD
//
// Everything wlprefs does to files and processes, kept free of Wayland and
// cairo so it can be tested on its own.
//
// The rules, in the order they matter:
//
//   1. NEVER write a file we could not read. `read()` tells "does not exist"
//      (fine: we create it) from "exists but cannot be read" (not fine: the
//      caller must refuse to save, or the next save would replace the user's
//      config with whatever the GUI happens to hold).
//   2. Writing is atomic: a temporary file next to the target, flushed to
//      disk, then rename(2) over it. A crash or a full disk leaves the old
//      file untouched.
//   3. A symlinked config.conf (a dotfile manager's) stays a symlink: the
//      file it points to is replaced, not the link.
//   4. The permissions of the old file are kept (a 0600 config stays 0600).
//   5. The first save of a session keeps the previous contents as
//      `config.conf.bak`.
//   6. After a save the compositor is told to reload (SIGHUP, which
//      wmaker-wl already handles), by looking through /proc for its
//      processes -- no `pkill` needed, so it works wherever /proc does.

const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/wait.h");
});

/// Biggest config file we are willing to read. A real one is a few KB.
pub const max_size: usize = 1 << 20;

pub const ReadError = error{
    /// Exists, but is not a regular file we can open (a directory, no
    /// permission, ...).
    Unreadable,
    /// Bigger than `max_size`.
    TooBig,
    OutOfMemory,
};

pub const Read = union(enum) {
    /// The contents. Owned by the caller.
    text: []u8,
    /// There is no such file (yet).
    missing,
    failed: ReadError,

    pub fn deinit(r: Read, gpa: std.mem.Allocator) void {
        switch (r) {
            .text => |t| gpa.free(t),
            else => {},
        }
    }
};

fn errnoValue() c_int {
    return c.__errno_location().*;
}

pub fn read(gpa: std.mem.Allocator, path: []const u8) Read {
    const pz = gpa.dupeZ(u8, path) catch return .{ .failed = error.OutOfMemory };
    defer gpa.free(pz);

    const f = c.fopen(pz.ptr, "rb") orelse {
        return if (errnoValue() == c.ENOENT) .missing else .{ .failed = error.Unreadable };
    };
    defer _ = c.fclose(f);

    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n > 0) {
            if (list.items.len + n > max_size) {
                list.deinit(gpa);
                return .{ .failed = error.TooBig };
            }
            list.appendSlice(gpa, buf[0..n]) catch {
                list.deinit(gpa);
                return .{ .failed = error.OutOfMemory };
            };
        }
        if (n < buf.len) break;
    }
    // fopen("rb") on a directory succeeds on Linux; the read is what fails.
    if (c.ferror(f) != 0) {
        list.deinit(gpa);
        return .{ .failed = error.Unreadable };
    }
    return .{ .text = list.toOwnedSlice(gpa) catch return .{ .failed = error.OutOfMemory } };
}

/// Human text for the status line.
pub fn readErrorText(e: ReadError) []const u8 {
    return switch (e) {
        error.Unreadable => "config.conf exists but cannot be read -- saving is disabled",
        error.TooBig => "config.conf is too big to be a config -- saving is disabled",
        error.OutOfMemory => "out of memory while reading config.conf -- saving is disabled",
    };
}

// ----------------------------------------------------------------------------
// Paths
// ----------------------------------------------------------------------------

/// `$XDG_CONFIG_HOME/wmaker-wl/config.conf`, else
/// `~/.config/wmaker-wl/config.conf` -- the rule of the compositor's
/// config.userConfigPath(), duplicated because wlprefs does not link
/// against it. null if neither variable is set. Caller owns the result.
pub fn defaultConfigPath(gpa: std.mem.Allocator) !?[]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const dir = std.mem.span(x);
        if (dir.len > 0) return try std.fmt.allocPrint(gpa, "{s}/wmaker-wl/config.conf", .{dir});
    }
    if (std.c.getenv("HOME")) |h| {
        const home = std.mem.span(h);
        if (home.len > 0) return try std.fmt.allocPrint(gpa, "{s}/.config/wmaker-wl/config.conf", .{home});
    }
    return null;
}

/// Where a write to `path` must go: the file a symlink points to, otherwise
/// `path` itself. Caller owns the result.
pub fn writeTarget(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try gpa.dupeZ(u8, path);
    defer gpa.free(pz);
    // realpath fails for a file that does not exist yet -- then the path is
    // what we create.
    const resolved = c.realpath(pz.ptr, null) orelse return gpa.dupe(u8, path);
    defer c.free(resolved);
    return gpa.dupe(u8, std.mem.span(resolved));
}

/// `mkdir -p` for the directory part of `path`.
pub fn makeParentDirs(gpa: std.mem.Allocator, path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    const dir = try gpa.dupeZ(u8, path[0..slash]);
    defer gpa.free(dir);

    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const saved = dir[i];
            dir[i] = 0;
            const rc = c.mkdir(dir.ptr, 0o755);
            dir[i] = saved;
            if (rc != 0 and errnoValue() != c.EEXIST) return error.CannotCreateDirectory;
        }
    }
}

// ----------------------------------------------------------------------------
// Writing
// ----------------------------------------------------------------------------

pub const WriteError = error{
    CannotCreateDirectory,
    BackupFailed,
    WriteFailed,
    OutOfMemory,
};

pub const WriteOptions = struct {
    /// Keep the old contents as `<file>.bak` first.
    backup: bool = true,
};

pub fn writeErrorText(e: WriteError) []const u8 {
    return switch (e) {
        error.CannotCreateDirectory => "Save failed: cannot create the config directory",
        error.BackupFailed => "Save failed: cannot write the .bak backup (nothing was changed)",
        error.WriteFailed => "Save failed: cannot write the file (permissions? disk full?)",
        error.OutOfMemory => "Save failed: out of memory",
    };
}

fn writeAll(path: [:0]const u8, data: []const u8, sync: bool) bool {
    const f = c.fopen(path.ptr, "wb") orelse return false;
    var ok = data.len == 0 or c.fwrite(data.ptr, 1, data.len, f) == data.len;
    if (c.fflush(f) != 0) ok = false;
    if (sync and c.fsync(c.fileno(f)) != 0) ok = false;
    if (c.fclose(f) != 0) ok = false;
    return ok;
}

/// Replace the contents of `path` with `data`, by the rules at the top of
/// this file. `path` may be a symlink.
pub fn writeAtomic(gpa: std.mem.Allocator, path: []const u8, data: []const u8, opts: WriteOptions) WriteError!void {
    const target = writeTarget(gpa, path) catch return error.OutOfMemory;
    defer gpa.free(target);

    makeParentDirs(gpa, target) catch return error.CannotCreateDirectory;

    const tz = gpa.dupeZ(u8, target) catch return error.OutOfMemory;
    defer gpa.free(tz);

    // The old file: its mode is kept, its contents are the backup.
    var st: c.struct_stat = undefined;
    const existed = c.stat(tz.ptr, &st) == 0;

    if (existed and opts.backup) {
        const old = read(gpa, target);
        defer old.deinit(gpa);
        switch (old) {
            .text => |t| {
                const bak = std.fmt.allocPrintSentinel(gpa, "{s}.bak", .{target}, 0) catch return error.OutOfMemory;
                defer gpa.free(bak);
                if (!writeAll(bak, t, true)) return error.BackupFailed;
            },
            // Nothing readable to keep. Writing over a file we cannot read
            // is the caller's decision (window.zig refuses before it gets
            // here); do not pretend there was a backup.
            else => return error.BackupFailed,
        }
    }

    const tmp = std.fmt.allocPrintSentinel(gpa, "{s}.wlprefs-tmp", .{target}, 0) catch return error.OutOfMemory;
    defer gpa.free(tmp);

    if (!writeAll(tmp, data, true)) {
        _ = c.unlink(tmp.ptr);
        return error.WriteFailed;
    }
    if (existed) _ = c.chmod(tmp.ptr, st.st_mode & 0o7777);
    if (c.rename(tmp.ptr, tz.ptr) != 0) {
        _ = c.unlink(tmp.ptr);
        return error.WriteFailed;
    }
}

// ----------------------------------------------------------------------------
// Reload: SIGHUP to wmaker-wl
// ----------------------------------------------------------------------------

/// The name of the compositor process (/proc/<pid>/comm, 15 chars at most).
pub const compositor_comm = "wmaker-wl";

/// `comm` as read from /proc/<pid>/comm, newline included.
pub fn isComm(comm: []const u8, wanted: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, comm, "\n"), wanted);
}

pub fn isCompositorComm(comm: []const u8) bool {
    return isComm(comm, compositor_comm);
}

/// A directory name in /proc that is a process id.
pub fn parsePid(name: []const u8) ?c.pid_t {
    if (name.len == 0 or name.len > 10) return null;
    for (name) |ch| if (!std.ascii.isDigit(ch)) return null;
    const v = std.fmt.parseInt(c.pid_t, name, 10) catch return null;
    return if (v > 1) v else null;
}

/// Send `sig` to every process of this user whose name (/proc/<pid>/comm)
/// is `comm`. Returns how many were signalled.
pub fn signalByComm(comm: []const u8, sig: c_int) usize {
    const dir = c.opendir("/proc") orelse return 0;
    defer _ = c.closedir(dir);

    const me = c.getuid();
    var count: usize = 0;
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        const pid = parsePid(name) orelse continue;

        var buf: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrintZ(&buf, "/proc/{d}/comm", .{pid}) catch continue;
        var got: [32]u8 = undefined;
        const f = c.fopen(comm_path.ptr, "rb") orelse continue;
        const n = c.fread(&got, 1, got.len, f);
        _ = c.fclose(f);
        if (!isComm(got[0..n], comm)) continue;

        // Only our own: another user's process is none of our business.
        var dir_path: [32]u8 = undefined;
        const dp = std.fmt.bufPrintZ(&dir_path, "/proc/{d}", .{pid}) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(dp.ptr, &st) != 0 or st.st_uid != me) continue;

        if (c.kill(pid, sig) == 0) count += 1;
    }
    return count;
}

/// Tell wmaker-wl to reload its config (SIGHUP, see its
/// installSighupHandler). Returns how many compositors were told; 0 means
/// none is running, which is fine for a save.
pub fn signalReload() usize {
    return signalByComm(compositor_comm, c.SIGHUP);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

/// A fresh directory under /tmp, removed (with what the tests put in it)
/// by `cleanup`.
const TmpDir = struct {
    path: [:0]u8,

    fn make(gpa: std.mem.Allocator) !TmpDir {
        var tmpl = "/tmp/wlprefs-test-XXXXXX".*;
        const made = c.mkdtemp(&tmpl) orelse return error.MkdTemp;
        return .{ .path = try gpa.dupeZ(u8, std.mem.span(made)) };
    }

    fn file(d: TmpDir, gpa: std.mem.Allocator, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ d.path, name }, 0);
    }

    fn cleanup(d: TmpDir, gpa: std.mem.Allocator) void {
        const cmd = std.fmt.allocPrintSentinel(gpa, "rm -rf '{s}'", .{d.path}, 0) catch return;
        defer gpa.free(cmd);
        _ = c.system(cmd.ptr);
        gpa.free(d.path);
    }
};

fn mustRead(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return switch (read(gpa, path)) {
        .text => |t| t,
        else => error.CouldNotRead,
    };
}

fn modeOf(path: [:0]const u8) c.mode_t {
    var st: c.struct_stat = undefined;
    _ = c.stat(path.ptr, &st);
    return st.st_mode & 0o7777;
}

test "read: text, missing, and 'exists but cannot be read' are three different things" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);

    const f = try d.file(gpa, "a.conf");
    defer gpa.free(f);
    try std.testing.expect(read(gpa, f) == .missing);

    try writeAtomic(gpa, f, "gap = 3\n", .{});
    const t = try mustRead(gpa, f);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("gap = 3\n", t);

    // A directory where the file should be: this must NOT look like "missing".
    const sub = try d.file(gpa, "dir");
    defer gpa.free(sub);
    _ = c.mkdir(sub.ptr, 0o755);
    switch (read(gpa, sub)) {
        .failed => |e| try std.testing.expectEqual(error.Unreadable, e),
        else => return error.ShouldHaveFailed,
    }
}

test "read: refuses a file that is far too big" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);
    const f = try d.file(gpa, "big.conf");
    defer gpa.free(f);

    const big = try gpa.alloc(u8, max_size + 10);
    defer gpa.free(big);
    @memset(big, 'x');
    try std.testing.expect(writeAll(f, big, false));
    switch (read(gpa, f)) {
        .failed => |e| try std.testing.expectEqual(error.TooBig, e),
        else => return error.ShouldHaveFailed,
    }
}

test "writeAtomic: creates parent directories and the file" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);
    const f = try std.fmt.allocPrintSentinel(gpa, "{s}/a/b/c/config.conf", .{d.path}, 0);
    defer gpa.free(f);

    try writeAtomic(gpa, f, "x = 1\n", .{});
    const t = try mustRead(gpa, f);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("x = 1\n", t);
}

test "writeAtomic: keeps the permissions of the old file" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);
    const f = try d.file(gpa, "config.conf");
    defer gpa.free(f);

    try writeAtomic(gpa, f, "a\n", .{});
    _ = c.chmod(f.ptr, 0o600);
    try writeAtomic(gpa, f, "b\n", .{});
    try std.testing.expectEqual(@as(c.mode_t, 0o600), modeOf(f));
}

test "writeAtomic: a symlinked config stays a symlink and its target is updated" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);

    const real = try d.file(gpa, "dotfiles-config.conf");
    defer gpa.free(real);
    const link = try d.file(gpa, "config.conf");
    defer gpa.free(link);

    try std.testing.expect(writeAll(real, "old\n", false));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(real.ptr, link.ptr));

    try writeAtomic(gpa, link, "new\n", .{});

    // The link is still a link ...
    var st: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.lstat(link.ptr, &st));
    try std.testing.expect((st.st_mode & c.S_IFMT) == c.S_IFLNK);
    // ... and what it points to has the new contents (and the backup the old).
    const t = try mustRead(gpa, real);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("new\n", t);
    const bak = try std.fmt.allocPrintSentinel(gpa, "{s}.bak", .{real}, 0);
    defer gpa.free(bak);
    const b = try mustRead(gpa, bak);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("old\n", b);
}

test "writeAtomic: backup holds the previous contents, and can be switched off" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);
    const f = try d.file(gpa, "config.conf");
    defer gpa.free(f);
    const bak = try d.file(gpa, "config.conf.bak");
    defer gpa.free(bak);

    // First ever write: nothing to back up.
    try writeAtomic(gpa, f, "one\n", .{});
    try std.testing.expect(read(gpa, bak) == .missing);

    try writeAtomic(gpa, f, "two\n", .{});
    const b = try mustRead(gpa, bak);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("one\n", b);

    // A later save of the same session does not eat the backup.
    try writeAtomic(gpa, f, "three\n", .{ .backup = false });
    const b2 = try mustRead(gpa, bak);
    defer gpa.free(b2);
    try std.testing.expectEqualStrings("one\n", b2);
    const t = try mustRead(gpa, f);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("three\n", t);
}

test "writeAtomic: leaves no temporary file behind, and a failed write leaves the old file alone" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);
    const f = try d.file(gpa, "config.conf");
    defer gpa.free(f);
    const tmp = try d.file(gpa, "config.conf.wlprefs-tmp");
    defer gpa.free(tmp);

    try writeAtomic(gpa, f, "keep me\n", .{});
    try std.testing.expect(read(gpa, tmp) == .missing);

    // Make the temp file impossible to create: a directory in its place.
    _ = c.mkdir(tmp.ptr, 0o755);
    try std.testing.expectError(error.WriteFailed, writeAtomic(gpa, f, "lost\n", .{ .backup = false }));
    const t = try mustRead(gpa, f);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("keep me\n", t);
}

test "writeTarget: resolves links, passes through paths that do not exist" {
    const gpa = std.testing.allocator;
    const d = try TmpDir.make(gpa);
    defer d.cleanup(gpa);
    const nope = try d.file(gpa, "nope.conf");
    defer gpa.free(nope);
    const t = try writeTarget(gpa, nope);
    defer gpa.free(t);
    try std.testing.expectEqualStrings(nope, t);
}

test "process matching: only wmaker-wl, only real pids" {
    try std.testing.expect(isCompositorComm("wmaker-wl\n"));
    try std.testing.expect(isCompositorComm("wmaker-wl"));
    try std.testing.expect(!isCompositorComm("wmaker-wl-prefs\n"));
    try std.testing.expect(!isCompositorComm("river\n"));
    try std.testing.expect(!isCompositorComm(""));

    try std.testing.expect(parsePid("1234") != null);
    try std.testing.expect(parsePid("self") == null);
    try std.testing.expect(parsePid("") == null);
    try std.testing.expect(parsePid("12a") == null);
    // Never pid 1 or 0 (kill(0, ...) would signal our whole process group).
    try std.testing.expect(parsePid("0") == null);
    try std.testing.expect(parsePid("1") == null);
    try std.testing.expect(parsePid("99999999999") == null);
}

test "signalByComm: nobody by that name, nobody signalled" {
    try std.testing.expectEqual(@as(usize, 0), signalByComm("wlprefs-no-such-process", c.SIGHUP));
}

test "signalByComm: finds a process by its name and signals exactly it" {
    // A child that renames itself and waits for a signal. SIGHUP's default
    // action ends it, which is what the parent then observes.
    const pid = c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = c.prctl(c.PR_SET_NAME, @as(c_ulong, @intFromPtr("wlprefs-fake")), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        while (true) _ = c.pause();
    }

    // Wait until the rename is visible in /proc.
    var tries: usize = 0;
    var found = false;
    var path_buf: [64]u8 = undefined;
    const comm_path = try std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid});
    while (tries < 200 and !found) : (tries += 1) {
        const f = c.fopen(comm_path.ptr, "rb");
        if (f) |fp| {
            var got: [32]u8 = undefined;
            const n = c.fread(&got, 1, got.len, fp);
            _ = c.fclose(fp);
            found = isComm(got[0..n], "wlprefs-fake");
        }
        if (!found) _ = c.usleep(5000);
    }
    defer {
        _ = c.kill(pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 1), signalByComm("wlprefs-fake", c.SIGHUP));

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expect(c.WIFSIGNALED(status));
    try std.testing.expectEqual(@as(c_int, c.SIGHUP), c.WTERMSIG(status));
    // Reaped already; the deferred kill/waitpid is a harmless no-op.
}

test "defaultConfigPath ends in wmaker-wl/config.conf when it resolves" {
    const gpa = std.testing.allocator;
    const p = try defaultConfigPath(gpa);
    defer if (p) |v| gpa.free(v);
    if (p) |v| try std.testing.expect(std.mem.endsWith(u8, v, "/wmaker-wl/config.conf"));
}
