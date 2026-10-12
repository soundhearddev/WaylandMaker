// SPDX-License-Identifier: 0BSD
//
// Pure battery maths: raw sysfs numbers in, display values out.
// No libc, no Wayland, no file access -> fully unit-testable.

const std = @import("std");

pub const Status = enum { unknown, charging, discharging, full, idle };

pub fn parseStatus(s: []const u8) Status {
    if (std.ascii.eqlIgnoreCase(s, "Charging")) return .charging;
    if (std.ascii.eqlIgnoreCase(s, "Discharging")) return .discharging;
    if (std.ascii.eqlIgnoreCase(s, "Full")) return .full;
    if (std.ascii.eqlIgnoreCase(s, "Not charging")) return .idle;
    return .unknown;
}

/// What /sys/class/power_supply/<BAT>/ says (micro-units, as the kernel
/// reports them). `now`/`full`/`design` are µWh, or µAh if `charge_based`.
pub const Raw = struct {
    present: bool = false,
    ac: bool = false,
    status: Status = .unknown,
    capacity: ?i64 = null, // percent
    now: ?i64 = null,
    full: ?i64 = null,
    design: ?i64 = null,
    charge_based: bool = false,
    power_uw: ?i64 = null,
    current_ua: ?i64 = null,
    voltage_uv: ?i64 = null,
};

/// What the face shows.
pub const Info = struct {
    present: bool = false,
    ac: bool = false,
    status: Status = .unknown,
    percent: u8 = 0,
    power_mw: ?u32 = null,
    /// Time to empty (discharging) or to full (charging).
    minutes: ?u32 = null,
    voltage_mv: ?u32 = null,
    /// full / design capacity in percent.
    health: ?u8 = null,
};

fn absI(v: i64) i64 {
    return if (v < 0) -v else v;
}

fn clampInt(comptime T: type, v: i64, max: i64) T {
    return @intCast(std.math.clamp(v, 0, max));
}

/// Hours >= 100 are not shown (the face has room for "99:59").
fn minutesFor(amount: i64, rate: i64) ?u32 {
    if (amount < 0 or rate <= 0) return null;
    const m = @divTrunc(amount * 60, rate);
    if (m >= 100 * 60) return null;
    return @intCast(m);
}

pub fn summarize(r: Raw) Info {
    var out: Info = .{ .present = r.present, .ac = r.ac, .status = r.status };
    if (!r.present) return out;

    const have_full = r.now != null and r.full != null and r.full.? > 0;
    const pct: i64 = if (r.capacity) |cap|
        cap
    else if (have_full)
        @divTrunc(r.now.? * 100 + @divTrunc(r.full.?, 2), r.full.?)
    else
        0;
    out.percent = clampInt(u8, pct, 100);

    // Korrigierter Maximalwert für mV (100.000 mV = 100 V)
    if (r.voltage_uv) |v| {
        out.voltage_mv = clampInt(u32, @divTrunc(absI(v), 1000), 100_000);
    }

    // Power: power_now, or current * voltage.
    var power_uw: ?i64 = null;
    if (r.power_uw) |p| {
        power_uw = absI(p);
    } else if (r.current_ua != null and r.voltage_uv != null) {
        power_uw = @divTrunc(absI(r.current_ua.?) * absI(r.voltage_uv.?), 1_000_000);
    }
    // Maximalwert für Leistung auf 10.000.000 mW (10 kW) begrenzt
    if (power_uw) |p| {
        out.power_mw = clampInt(u32, @divTrunc(p, 1000), 10_000_000);
    }

    // Remaining time
    const rate: i64 = if (r.charge_based)
        (if (r.current_ua) |ci| absI(ci) else 0)
    else
        (power_uw orelse 0);

    if (rate > 0) {
        switch (r.status) {
            .discharging => {
                if (r.now) |n| out.minutes = minutesFor(n, rate);
            },
            .charging => {
                if (r.now != null and r.full != null) {
                    out.minutes = minutesFor(r.full.? - r.now.?, rate);
                }
            },
            else => {},
        }
    }

    if (r.design != null and r.full != null and r.design.? > 0) {
        const health_pct = @divTrunc(r.full.? * 100 + @divTrunc(r.design.?, 2), r.design.?);
        out.health = clampInt(u8, health_pct, 100);
    }
    return out;
}

pub fn main() !void {
    // Einstiegspunkt für den Compiler, damit build-exe nicht fehlschlägt
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "parseStatus" {
    try std.testing.expectEqual(Status.charging, parseStatus("Charging"));
    try std.testing.expectEqual(Status.discharging, parseStatus("discharging"));
    try std.testing.expectEqual(Status.full, parseStatus("Full"));
    try std.testing.expectEqual(Status.idle, parseStatus("Not charging"));
    try std.testing.expectEqual(Status.unknown, parseStatus("whatever"));
}

test "energy based, discharging" {
    const i = summarize(.{
        .present = true,
        .status = .discharging,
        .capacity = 60,
        .now = 30_000_000,
        .full = 50_000_000,
        .design = 60_000_000,
        .power_uw = 10_000_000,
        .voltage_uv = 12_000_000,
    });
    try std.testing.expectEqual(@as(u8, 60), i.percent);
    try std.testing.expectEqual(@as(?u32, 10_000), i.power_mw);
    try std.testing.expectEqual(@as(?u32, 180), i.minutes);
    try std.testing.expectEqual(@as(?u8, 83), i.health);
    try std.testing.expectEqual(@as(?u32, 12_000), i.voltage_mv);
}

test "energy based, charging: time to full" {
    const i = summarize(.{
        .present = true,
        .status = .charging,
        .now = 30_000_000,
        .full = 50_000_000,
        .power_uw = 10_000_000,
    });
    try std.testing.expectEqual(@as(u8, 60), i.percent);
    try std.testing.expectEqual(@as(?u32, 120), i.minutes);
}

test "charge based: current and voltage give the power" {
    const i = summarize(.{
        .present = true,
        .status = .discharging,
        .charge_based = true,
        .now = 2_000_000,
        .full = 4_000_000,
        .current_ua = -1_000_000,
        .voltage_uv = 10_000_000,
    });
    try std.testing.expectEqual(@as(u8, 50), i.percent);
    try std.testing.expectEqual(@as(?u32, 10_000), i.power_mw);
    try std.testing.expectEqual(@as(?u32, 120), i.minutes);
}

test "no battery, full battery, absurdly long times" {
    const none = summarize(.{ .ac = true });
    try std.testing.expect(!none.present);
    try std.testing.expect(none.ac);
    try std.testing.expectEqual(@as(?u32, null), none.minutes);

    const full = summarize(.{ .present = true, .status = .full, .capacity = 100, .now = 5, .full = 5, .power_uw = 1 });
    try std.testing.expectEqual(@as(?u32, null), full.minutes);

    const slow = summarize(.{ .present = true, .status = .discharging, .now = 50_000_000, .power_uw = 1000 });
    try std.testing.expectEqual(@as(?u32, null), slow.minutes);
}
