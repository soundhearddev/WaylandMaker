// SPDX-License-Identifier: GPL-3.0
//
// Kernel uevents for the power_supply subsystem (netlink, no root needed).
// The kernel sends one when the battery or the AC adapter changes, so a
// plug/unplug shows up at once and nothing has to poll for it.
// If the socket cannot be opened, open() returns -1 and the timer in main.zig
// is all there is.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("linux/netlink.h");
    @cInclude("unistd.h");
});

pub const Kind = enum {
    none,
    /// A power supply changed (value, status, AC).
    change,
    /// A power supply appeared or vanished: look at the directory again.
    topology,
};

/// Non-blocking socket subscribed to the kernel's uevents, or -1.
pub fn open() c_int {
    const kind: c_int = @intCast(c.SOCK_DGRAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK);
    const fd = c.socket(c.AF_NETLINK, kind, c.NETLINK_KOBJECT_UEVENT);
    if (fd < 0) return -1;
    var addr = std.mem.zeroes(c.struct_sockaddr_nl);
    addr.nl_family = c.AF_NETLINK;
    addr.nl_groups = 1; // the kernel's own events
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_nl)) < 0) {
        _ = c.close(fd);
        return -1;
    }
    return fd;
}

/// What one uevent message is about. A message is "ACTION@DEVPATH\0KEY=VALUE\0...".
pub fn classify(msg: []const u8) Kind {
    if (std.mem.indexOf(u8, msg, "SUBSYSTEM=power_supply") == null) return .none;
    if (std.mem.startsWith(u8, msg, "add@") or std.mem.startsWith(u8, msg, "remove@")) return .topology;
    return .change;
}

/// Read everything that is waiting; the strongest kind wins.
pub fn drain(fd: c_int) Kind {
    var result: Kind = .none;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.recv(fd, &buf, buf.len, 0);
        if (n <= 0) break;
        switch (classify(buf[0..@intCast(n)])) {
            .none => {},
            .change => if (result == .none) {
                result = .change;
            },
            .topology => result = .topology,
        }
    }
    return result;
}

test "classify" {
    try std.testing.expectEqual(Kind.change, classify("change@/devices/ACPI0003:00/power_supply/AC\x00ACTION=change\x00SUBSYSTEM=power_supply\x00"));
    try std.testing.expectEqual(Kind.topology, classify("add@/devices/x/power_supply/BAT0\x00ACTION=add\x00SUBSYSTEM=power_supply\x00"));
    try std.testing.expectEqual(Kind.topology, classify("remove@/devices/x/power_supply/BAT0\x00SUBSYSTEM=power_supply\x00"));
    try std.testing.expectEqual(Kind.none, classify("change@/devices/x/block/sda\x00SUBSYSTEM=block\x00"));
}
