// SPDX-License-Identifier: GPL-3.0
//
// Reads /sys/class/power_supply and turns it into a battery.Info.
//
// Cheap on purpose: the directory is scanned once (and again only when a
// power supply appears or vanishes). The attribute files stay open, and every
// read is one pread() per attribute -- no open/close, no directory walk.
//
// Which battery: --battery NAME if given, else the first one by name
// (BAT0 before BAT1) that is not a peripheral (scope "Device", e.g. a
// wireless mouse). AC: any non-battery supply (Mains, USB, ...) that is online.

const std = @import("std");
const battery = @import("battery.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const base = "/sys/class/power_supply";
const max_ac = 8;

fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return null;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// An attribute file kept open, or -1.
fn openAttr(dir: []const u8, file: []const u8) c_int {
    var pbuf: [320]u8 = undefined;
    const path = pathZ(&pbuf, base ++ "/{s}/{s}", .{ dir, file }) orelse return -1;
    return c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
}

fn closeFd(fd: *c_int) void {
    if (fd.* >= 0) _ = c.close(fd.*);
    fd.* = -1;
}

/// The whole attribute from offset 0, trimmed. sysfs files can be re-read
/// with pread(0), which is what makes keeping them open possible.
fn preadAttr(fd: c_int, buf: []u8) ?[]const u8 {
    if (fd < 0) return null;
    const n = c.pread(fd, buf.ptr, buf.len, 0);
    if (n <= 0) return null;
    return std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
}

fn preadInt(fd: c_int) ?i64 {
    var b: [32]u8 = undefined;
    const s = preadAttr(fd, &b) orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// One-shot read, for discovery only.
fn readOnce(dir: []const u8, file: []const u8, out: []u8) ?[]const u8 {
    var fd = openAttr(dir, file);
    defer closeFd(&fd);
    return preadAttr(fd, out);
}

pub const Reader = struct {
    /// --battery NAME (null: the first battery).
    wanted: ?[]const u8 = null,
    discovered: bool = false,
    present: bool = false,
    charge_based: bool = false,

    status: c_int = -1,
    capacity: c_int = -1,
    now: c_int = -1,
    full: c_int = -1,
    design: c_int = -1,
    power: c_int = -1,
    current: c_int = -1,
    voltage: c_int = -1,
    ac: [max_ac]c_int = [_]c_int{-1} ** max_ac,
    ac_n: usize = 0,

    /// Scan the directory again at the next read().
    pub fn rediscover(self: *Reader) void {
        self.discovered = false;
    }

    fn closeAll(self: *Reader) void {
        closeFd(&self.status);
        closeFd(&self.capacity);
        closeFd(&self.now);
        closeFd(&self.full);
        closeFd(&self.design);
        closeFd(&self.power);
        closeFd(&self.current);
        closeFd(&self.voltage);
        for (&self.ac) |*fd| closeFd(fd);
        self.ac_n = 0;
        self.present = false;
        self.charge_based = false;
    }

    fn discover(self: *Reader) void {
        self.closeAll();
        self.discovered = true;

        const dir = c.opendir(base) orelse return;
        defer _ = c.closedir(dir);

        var chosen: [64]u8 = undefined;
        var chosen_len: usize = 0;

        while (c.readdir(dir)) |ent| {
            const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
            if (name.len == 0 or name[0] == '.') continue;

            var tb: [32]u8 = undefined;
            const kind = readOnce(name, "type", &tb) orelse continue;

            if (std.ascii.eqlIgnoreCase(kind, "Battery")) {
                if (name.len > chosen.len) continue;
                if (self.wanted) |w| {
                    if (!std.mem.eql(u8, w, name)) continue;
                } else {
                    var sc: [16]u8 = undefined;
                    if (readOnce(name, "scope", &sc)) |scope| {
                        if (std.ascii.eqlIgnoreCase(scope, "Device")) continue;
                    }
                }
                if (chosen_len == 0 or std.mem.lessThan(u8, name, chosen[0..chosen_len])) {
                    @memcpy(chosen[0..name.len], name);
                    chosen_len = name.len;
                }
            } else if (self.ac_n < max_ac) {
                const fd = openAttr(name, "online");
                if (fd >= 0) {
                    self.ac[self.ac_n] = fd;
                    self.ac_n += 1;
                }
            }
        }

        if (chosen_len == 0) return;
        const name = chosen[0..chosen_len];

        var pb: [8]u8 = undefined;
        if (readOnce(name, "present", &pb)) |p| {
            if (std.mem.eql(u8, p, "0")) return;
        }
        self.present = true;

        self.status = openAttr(name, "status");
        self.capacity = openAttr(name, "capacity");
        self.full = openAttr(name, "energy_full");
        if (self.full >= 0) {
            self.now = openAttr(name, "energy_now");
            self.design = openAttr(name, "energy_full_design");
        } else {
            self.charge_based = true;
            self.full = openAttr(name, "charge_full");
            self.now = openAttr(name, "charge_now");
            self.design = openAttr(name, "charge_full_design");
        }
        self.power = openAttr(name, "power_now");
        self.current = openAttr(name, "current_now");
        self.voltage = openAttr(name, "voltage_now");
    }

    pub fn read(self: *Reader) battery.Info {
        if (!self.discovered) self.discover();

        var raw: battery.Raw = .{ .present = self.present, .charge_based = self.charge_based };
        for (self.ac[0..self.ac_n]) |fd| {
            if ((preadInt(fd) orelse 0) == 1) {
                raw.ac = true;
                break;
            }
        }
        if (!self.present) return battery.summarize(raw);

        var sb: [32]u8 = undefined;
        if (preadAttr(self.status, &sb)) |s| raw.status = battery.parseStatus(s);
        raw.capacity = preadInt(self.capacity);
        raw.now = preadInt(self.now);
        raw.full = preadInt(self.full);
        raw.design = preadInt(self.design);
        raw.power_uw = preadInt(self.power);
        raw.current_ua = preadInt(self.current);
        raw.voltage_uv = preadInt(self.voltage);

        // The battery went away under us (hot unplug): look again next time.
        if (raw.capacity == null and raw.now == null and raw.full == null) {
            self.discovered = false;
            raw.present = false;
        }
        return battery.summarize(raw);
    }
};
