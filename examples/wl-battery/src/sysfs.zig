// SPDX-License-Identifier: 0BSD
//
// Reads /sys/class/power_supply and turns it into a battery.Info.
// libc stdio/dirent on purpose (same as wl-clock): no std.Io plumbing.
//
// Which battery: --battery NAME if given, else the first one by name
// (BAT0 before BAT1) that is not a peripheral (scope "Device", e.g. a
// wireless mouse). AC: any non-battery supply (Mains, USB, ...) that is online.

const std = @import("std");
const battery = @import("battery.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("dirent.h");
});

const base = "/sys/class/power_supply";

fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return null;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Contents of <base>/<dir>/<file>, trimmed, in `out`.
fn readAttr(dir: []const u8, file: []const u8, out: []u8) ?[]const u8 {
    var pbuf: [320]u8 = undefined;
    const path = pathZ(&pbuf, base ++ "/{s}/{s}", .{ dir, file }) orelse return null;
    const f = c.fopen(path.ptr, "r") orelse return null;
    defer _ = c.fclose(f);
    const n = c.fread(out.ptr, 1, out.len, f);
    if (n == 0) return null;
    return std.mem.trim(u8, out[0..n], " \t\r\n");
}

fn readInt(dir: []const u8, file: []const u8) ?i64 {
    var b: [64]u8 = undefined;
    const s = readAttr(dir, file, &b) orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn readBattery(name: []const u8, ac: bool) battery.Raw {
    var raw: battery.Raw = .{ .present = true, .ac = ac };
    if ((readInt(name, "present") orelse 1) == 0) raw.present = false;

    var sb: [32]u8 = undefined;
    if (readAttr(name, "status", &sb)) |s| raw.status = battery.parseStatus(s);

    raw.capacity = readInt(name, "capacity");
    if (readInt(name, "energy_full")) |full| {
        raw.full = full;
        raw.now = readInt(name, "energy_now");
        raw.design = readInt(name, "energy_full_design");
    } else if (readInt(name, "charge_full")) |full| {
        raw.charge_based = true;
        raw.full = full;
        raw.now = readInt(name, "charge_now");
        raw.design = readInt(name, "charge_full_design");
    }
    raw.power_uw = readInt(name, "power_now");
    raw.current_ua = readInt(name, "current_now");
    raw.voltage_uv = readInt(name, "voltage_now");
    return raw;
}

pub fn read(wanted: ?[]const u8) battery.Info {
    const dir = c.opendir(base) orelse return .{};
    defer _ = c.closedir(dir);

    var ac = false;
    var chosen: [64]u8 = undefined;
    var chosen_len: usize = 0;

    while (c.readdir(dir)) |ent| {
        const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (name.len == 0 or name[0] == '.') continue;

        var tb: [32]u8 = undefined;
        const kind = readAttr(name, "type", &tb) orelse continue;

        if (std.ascii.eqlIgnoreCase(kind, "Battery")) {
            if (name.len > chosen.len) continue;
            if (wanted) |w| {
                if (!std.mem.eql(u8, w, name)) continue;
            } else {
                var sc: [16]u8 = undefined;
                if (readAttr(name, "scope", &sc)) |scope| {
                    if (std.ascii.eqlIgnoreCase(scope, "Device")) continue;
                }
            }
            if (chosen_len == 0 or std.mem.lessThan(u8, name, chosen[0..chosen_len])) {
                @memcpy(chosen[0..name.len], name);
                chosen_len = name.len;
            }
        } else if ((readInt(name, "online") orelse 0) == 1) {
            ac = true;
        }
    }

    if (chosen_len == 0) return battery.summarize(.{ .ac = ac });
    return battery.summarize(readBattery(chosen[0..chosen_len], ac));
}
