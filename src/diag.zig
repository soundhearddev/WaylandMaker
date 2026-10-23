// SPDX-License-Identifier: GPL-3.0
//
// The switches and hooks for debugging a running wmaker-wl:
//
//   WMAKER_CHECKS=1   after every manage sequence, check the data-model
//                     invariants (invariants.zig) and log violations as
//                     `err(check)`. Costs O(windows) per sequence.
//   WMAKER_TRACE=1    keep `debug` log lines in the flight recorder too.
//   pkill -USR1 wmaker-wl
//                     write a state dump (dump.zig) to
//                     $XDG_RUNTIME_DIR/wmaker-wl-state.txt (else /tmp) and
//                     into the log.
//
// The signal handler only sets a flag; the dump itself happens in the next
// manage sequence (it reads the model, which must not change underneath).

const std = @import("std");
const log = std.log.scoped(.check);
const types = @import("types.zig");
const invariants = @import("invariants.zig");
const dump = @import("dump.zig");
const trace = @import("trace.zig");
const perf = @import("perf.zig");

pub var checks_enabled = false;
var dump_requested = std.atomic.Value(bool).init(false);
/// How many sequences broke an invariant (for the dump and for tests).
pub var violations_seen: u64 = 0;

pub fn initFromEnv() void {
    trace.initFromEnv();
    if (std.c.getenv("WMAKER_CHECKS")) |p| {
        const v = std.mem.span(p);
        checks_enabled = v.len > 0 and !std.mem.eql(u8, v, "0");
    }
}

fn onUsr1(_: std.os.linux.SIG) callconv(.c) void {
    dump_requested.store(true, .monotonic);
}

pub fn installSignalHandler() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onUsr1 },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.USR1, &act, null);
}

/// A SIGUSR1 came in and has not been served yet (the loop wakes up for it).
pub fn dumpPending() bool {
    return dump_requested.load(.monotonic);
}

/// Run the invariant check if it is switched on; log what it finds.
pub fn maybeCheck(wm: *types.WindowManager) void {
    if (!checks_enabled) return;
    const span = perf.start(wm.io, .checks);
    defer _ = perf.stop(wm.io, span);
    const rep = invariants.check(wm);
    if (rep.clean()) return;
    violations_seen += 1;
    log.err("{d} invariant violation(s) after manage sequence:", .{rep.total});
    for (0..rep.n) |i| log.err("  {s}", .{rep.message(i)});
}

/// Serve a pending SIGUSR1.
pub fn maybeDump(wm: *types.WindowManager) void {
    if (!dump_requested.swap(false, .monotonic)) return;
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    dump.write(wm, &w, 80) catch {}; // too long: what fitted is still useful
    const text = w.buffered();

    var path_buf: [256]u8 = undefined;
    const dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
    const path = std.fmt.bufPrint(&path_buf, "{s}/wmaker-wl-state.txt", .{dir}) catch "/tmp/wmaker-wl-state.txt";
    if (std.Io.Dir.cwd().writeFile(wm.io, .{ .sub_path = path, .data = text })) {
        std.log.scoped(.dump).info("state dump written to {s} ({d} bytes)", .{ path, text.len });
    } else |err| {
        std.log.scoped(.dump).warn("cannot write {s}: {t}; dump follows in the log", .{ path, err });
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| std.log.scoped(.dump).info("{s}", .{l});
    }
}
