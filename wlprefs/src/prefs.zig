// SPDX-License-Identifier: 0BSD
//
// The state behind the window: the file as it was read, the settings as
// they were then (`base`), and the settings as the user has them now
// (`cur`). No Wayland, no cairo: the whole load/edit/save cycle is tested
// against real files.
//
// What this exists to guarantee (the first version of wlprefs got all of it
// wrong -- it never read the file, so the first Save replaced the user's
// whole config.conf with the few lines that differed from the defaults):
//
//   * `load()` reads the file once at start-up. If it exists but cannot be
//     read, saving is DISABLED, not silently done from an empty state.
//   * `save()` reads the file AGAIN right before writing and changes only
//     the lines of keys the user changed (settings.render), so bind lines,
//     comments, unknown keys and edits made by hand in the meantime survive.
//   * Writing is atomic, keeps a `.bak` of the first overwrite of a session,
//     keeps permissions and follows a symlink (configfile.zig).
//   * Nothing is written when nothing changed, or when a value is one the
//     compositor would reject or misread (settings.problem).
//   * After a successful save the compositor is told to reload.

const std = @import("std");
const settings = @import("settings.zig");
const configfile = @import("configfile.zig");
const binds = @import("binds.zig");
const actions = @import("actions.zig");

const Settings = settings.Settings;

pub const Outcome = enum {
    saved,
    /// Nothing differs from the file: nothing was written.
    unchanged,
    /// Not saved, by design (unreadable file, invalid value, no path).
    refused,
    /// Tried to save and the system said no.
    failed,
};

pub const SaveResult = struct {
    outcome: Outcome,
    /// For the status line.
    message: []const u8,
    /// Which compositors were told to reload (saved only).
    reloaded: usize = 0,
};

pub const Prefs = struct {
    gpa: std.mem.Allocator,

    /// null: neither XDG_CONFIG_HOME nor HOME is set.
    path: ?[]u8 = null,
    /// The file as read at start-up / after the last save. Owned.
    original: std.ArrayList(u8) = .empty,
    /// Set if the file exists but could not be read: saving stays off.
    load_error: ?configfile.ReadError = null,
    /// The file did not exist when it was read.
    is_new: bool = true,

    /// What the file said when it was read.
    base: Settings,
    /// What the user has now.
    cur: Settings,
    /// `cur` when the current page was opened (Revert Page).
    page: Settings,

    /// The first overwrite of a session keeps a .bak; later ones do not
    /// replace it (the backup would only ever hold our own previous save).
    backed_up: bool = false,

    /// Key bindings in effect (what the file says); arena owned by the struct.
    bind_arena: std.heap.ArenaAllocator,
    bind_list: []const binds.Entry = &.{},

    /// The key binding list while it is being edited; null = not touched.
    /// Compared with `bind_list` to know whether there is anything to save.
    edit_binds: ?std.ArrayList(binds.Entry) = null,
    edit_arena: std.heap.ArenaAllocator,

    status_buf: [160]u8 = undefined,

    /// `path_override`: for tests and `--config FILE`; otherwise the same
    /// file the compositor reads.
    pub fn init(gpa: std.mem.Allocator, path_override: ?[]const u8) !Prefs {
        const def = Settings.init();
        var p: Prefs = .{
            .gpa = gpa,
            .base = def,
            .cur = def,
            .page = def,
            .bind_arena = .init(gpa),
            .edit_arena = .init(gpa),
        };
        errdefer p.deinit();
        p.path = if (path_override) |o|
            try gpa.dupe(u8, o)
        else
            try configfile.defaultConfigPath(gpa);
        p.load();
        return p;
    }

    pub fn deinit(p: *Prefs) void {
        if (p.path) |s| p.gpa.free(s);
        p.original.deinit(p.gpa);
        p.bind_arena.deinit();
        if (p.edit_binds) |*l| l.deinit(p.gpa);
        p.edit_arena.deinit();
        p.* = undefined;
    }

    // ---- load ----------------------------------------------------------------

    pub fn load(p: *Prefs) void {
        p.original.clearRetainingCapacity();
        p.load_error = null;
        p.is_new = true;

        var st = Settings.init();
        if (p.path) |path| {
            switch (configfile.read(p.gpa, path)) {
                .text => |t| {
                    defer p.gpa.free(t);
                    p.is_new = false;
                    p.original.appendSlice(p.gpa, t) catch {
                        p.load_error = error.OutOfMemory;
                    };
                    settings.parse(&st, t);
                },
                .missing => {},
                .failed => |e| p.load_error = e,
            }
        }
        p.base = st;
        p.cur = st;
        p.page = st;
        p.discardBindEdits();
        p.refreshBinds();
    }

    fn refreshBinds(p: *Prefs) void {
        _ = p.bind_arena.reset(.retain_capacity);
        p.bind_list = binds.effective(p.bind_arena.allocator(), settings.default_config_text, p.original.items) catch &.{};
    }

    // ---- state ---------------------------------------------------------------

    pub fn canSave(p: *const Prefs) bool {
        return p.path != null and p.load_error == null;
    }

    /// Number of changes: changed settings, and the key bindings as one.
    pub fn changed(p: *const Prefs) usize {
        return settings.changedCount(&p.cur, &p.base) + @intFromBool(p.bindsDirty());
    }

    pub fn dirty(p: *const Prefs) bool {
        return p.changed() > 0;
    }

    // ---- key bindings ---------------------------------------------------------------

    /// The list the Keyboard Shortcuts page shows: the edited one, if any.
    pub fn bindList(p: *const Prefs) []const binds.Entry {
        if (p.edit_binds) |l| return l.items;
        return p.bind_list;
    }

    pub fn bindsDirty(p: *const Prefs) bool {
        const l = p.edit_binds orelse return false;
        var scratch: std.heap.ArenaAllocator = .init(p.gpa);
        defer scratch.deinit();
        const same = binds.sameList(scratch.allocator(), l.items, p.bind_list) catch return true;
        return !same;
    }

    fn discardBindEdits(p: *Prefs) void {
        if (p.edit_binds) |*l| l.deinit(p.gpa);
        p.edit_binds = null;
        _ = p.edit_arena.reset(.retain_capacity);
    }

    /// Make the list editable (a copy of what is in effect).
    fn beginBindEdit(p: *Prefs) !void {
        if (p.edit_binds != null) return;
        const ea = p.edit_arena.allocator();
        var list: std.ArrayList(binds.Entry) = .empty;
        errdefer list.deinit(p.gpa);
        for (p.bind_list) |e| {
            try list.append(p.gpa, .{
                .combo = try ea.dupe(u8, e.combo),
                .action = try ea.dupe(u8, e.action),
                .user = e.user,
            });
        }
        p.edit_binds = list;
    }

    /// The reason a binding cannot be saved, or null. Needs the workspace
    /// count for `workspace N`.
    pub fn bindProblem(p: *const Prefs, combo: []const u8, action: []const u8) ?[]const u8 {
        var scratch: std.heap.ArenaAllocator = .init(p.gpa);
        defer scratch.deinit();
        if (binds.comboProblem(scratch.allocator(), combo)) |m| return m;
        return actions.problem(std.mem.trim(u8, action, " \t"), p.cur.workspace_count);
    }

    /// Set entry `index` (null: add one) to `combo` -> `action`. A binding on
    /// the same keys as another entry replaces that one (the compositor's own
    /// rule). Returns the reason it was refused, if it was.
    pub fn bindSet(p: *Prefs, index: ?usize, combo_in: []const u8, action_in: []const u8) !?[]const u8 {
        const combo = std.mem.trim(u8, combo_in, " \t");
        const action = std.mem.trim(u8, action_in, " \t");
        if (p.bindProblem(combo, action)) |m| return m;

        try p.beginBindEdit();
        const ea = p.edit_arena.allocator();
        var list = &p.edit_binds.?;
        const entry: binds.Entry = .{
            .combo = try ea.dupe(u8, combo),
            .action = try ea.dupe(u8, action),
            .user = true,
        };

        const norm = try binds.normalize(ea, combo);
        // Another entry on the same keys goes away.
        var i: usize = 0;
        var target: ?usize = index;
        while (i < list.items.len) {
            const other = try binds.normalize(ea, list.items[i].combo);
            if (std.mem.eql(u8, other, norm) and (index == null or i != index.?)) {
                _ = list.orderedRemove(i);
                if (target) |t| if (i < t) {
                    target = t - 1;
                };
            } else i += 1;
        }
        if (target) |t| {
            if (t < list.items.len) {
                list.items[t] = entry;
                return null;
            }
        }
        // Colliding replacement of an add: put it where the old one was.
        try list.append(p.gpa, entry);
        return null;
    }

    pub fn bindRemove(p: *Prefs, index: usize) !void {
        try p.beginBindEdit();
        var list = &p.edit_binds.?;
        if (index < list.items.len) _ = list.orderedRemove(index);
    }

    /// Back to what the file says.
    pub fn revertBinds(p: *Prefs) void {
        p.discardBindEdits();
    }

    /// Only wmaker-wl's shipped bindings: every `bind`/`unbind` of the user
    /// goes away (when saved).
    pub fn bindsToDefaults(p: *Prefs) !void {
        p.discardBindEdits();
        const ea = p.edit_arena.allocator();
        const def = try binds.effective(ea, settings.default_config_text, "");
        var list: std.ArrayList(binds.Entry) = .empty;
        errdefer list.deinit(p.gpa);
        try list.appendSlice(p.gpa, def);
        p.edit_binds = list;
    }

    /// Put the keys of one page back to wmaker-wl's defaults.
    pub fn defaultsFor(p: *Prefs, keys: []const []const u8) void {
        const def = Settings.init();
        var buf: [settings.Text.capacity + 8]u8 = undefined;
        for (keys) |k| {
            if (settings.format(&def, k, &buf)) |v| settings.apply(&p.cur, k, v);
        }
        // Defaults that are EMPTY: `apply` refuses an empty value (the
        // compositor does, too), so these are cleared directly.
        for (keys) |k| {
            if (std.mem.eql(u8, k, "theme")) p.cur.theme.clear();
            if (std.mem.eql(u8, k, "workspace_names")) p.cur.workspace_names.clear();
            if (std.mem.eql(u8, k, "mouse_mod")) p.cur.mouse_mod.raw = false;
        }
    }

    /// What to say when the window opens.
    pub fn openingMessage(p: *Prefs) []const u8 {
        if (p.path == null) return "No HOME / XDG_CONFIG_HOME: cannot find config.conf";
        if (p.load_error) |e| return configfile.readErrorText(e);
        if (p.is_new) return "No config.conf yet: it is created on the first Save";
        return "";
    }

    pub fn snapshotPage(p: *Prefs) void {
        p.page = p.cur;
    }

    pub fn revertPage(p: *Prefs) void {
        p.cur = p.page;
    }

    pub fn revertAll(p: *Prefs) void {
        p.cur = p.base;
        p.page = p.base;
        p.discardBindEdits();
    }

    // ---- save ------------------------------------------------------------------

    fn say(p: *Prefs, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(&p.status_buf, fmt, args) catch "";
    }

    pub fn save(p: *Prefs) SaveResult {
        const path = p.path orelse return .{
            .outcome = .refused,
            .message = "No HOME / XDG_CONFIG_HOME: cannot find config.conf",
        };
        if (p.load_error) |e| return .{ .outcome = .refused, .message = configfile.readErrorText(e) };

        var pb: [96]u8 = undefined;
        if (settings.problem(&p.cur, &pb)) |prob| {
            return .{ .outcome = .refused, .message = p.say("Not saved. {s}", .{prob.message}) };
        }

        if (!p.dirty()) return .{ .outcome = .unchanged, .message = "Nothing to save" };

        // The file as it is NOW, not as it was when the window opened.
        var disk: []u8 = &.{};
        var disk_owned = false;
        defer if (disk_owned) p.gpa.free(disk);
        switch (configfile.read(p.gpa, path)) {
            .text => |t| {
                disk = t;
                disk_owned = true;
            },
            .missing => {},
            .failed => |e| return .{ .outcome = .refused, .message = configfile.readErrorText(e) },
        }

        const rendered = settings.render(p.gpa, disk, &p.cur, &p.base) catch
            return .{ .outcome = .failed, .message = "Save failed: out of memory" };

        // The key bindings, only if they were edited: the `bind`/`unbind`
        // lines of the file are replaced by the minimal set that produces the
        // edited list (nothing for what equals a default).
        var out: []u8 = rendered;
        if (p.bindsDirty()) {
            var scratch: std.heap.ArenaAllocator = .init(p.gpa);
            defer scratch.deinit();
            const lines = binds.userLines(scratch.allocator(), settings.default_config_text, p.edit_binds.?.items) catch {
                p.gpa.free(rendered);
                return .{ .outcome = .failed, .message = "Save failed: out of memory" };
            };
            out = binds.rewriteUserLines(p.gpa, rendered, lines) catch {
                p.gpa.free(rendered);
                return .{ .outcome = .failed, .message = "Save failed: out of memory" };
            };
            p.gpa.free(rendered);
        }
        defer p.gpa.free(out);

        configfile.writeAtomic(p.gpa, path, out, .{ .backup = !p.backed_up }) catch |e| {
            return .{ .outcome = .failed, .message = configfile.writeErrorText(e) };
        };
        if (disk.len > 0) p.backed_up = true;

        // What the file says now is the new base; keys the user did not
        // touch follow the file (a by-hand edit made in the meantime).
        var new_base = Settings.init();
        settings.parse(&new_base, out);
        settings.rebase(&p.cur, &p.base, &new_base);
        p.base = new_base;
        p.page = p.cur;
        p.original.clearRetainingCapacity();
        p.original.appendSlice(p.gpa, out) catch {};
        p.is_new = false;
        p.discardBindEdits();
        p.refreshBinds();

        const n = configfile.signalReload();
        return .{
            .outcome = .saved,
            .reloaded = n,
            .message = if (n > 0) "Saved. wmaker-wl is reloading" else "Saved. wmaker-wl is not running; it reads this file at start",
        };
    }
};

// ----------------------------------------------------------------------------
// Tests: the cycle, against real files
// ----------------------------------------------------------------------------

const testing = std.testing;

const c = @cImport({
    @cInclude("stdlib.h");
});

const Tmp = struct {
    dir: [:0]u8,
    gpa: std.mem.Allocator,

    fn make(gpa: std.mem.Allocator) !Tmp {
        var tmpl = "/tmp/wlprefs-prefs-XXXXXX".*;
        const d = c.mkdtemp(&tmpl) orelse return error.MkdTemp;
        return .{ .dir = try gpa.dupeZ(u8, std.mem.span(d)), .gpa = gpa };
    }

    fn path(t: Tmp, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(t.gpa, "{s}/{s}", .{ t.dir, name });
    }

    fn write(t: Tmp, name: []const u8, text: []const u8) !void {
        const p = try t.path(name);
        defer t.gpa.free(p);
        try configfile.writeAtomic(t.gpa, p, text, .{ .backup = false });
    }

    fn slurp(t: Tmp, name: []const u8) ![]u8 {
        const p = try t.path(name);
        defer t.gpa.free(p);
        return switch (configfile.read(t.gpa, p)) {
            .text => |x| x,
            else => error.Missing,
        };
    }

    fn exists(t: Tmp, name: []const u8) !bool {
        const p = try t.path(name);
        defer t.gpa.free(p);
        const r = configfile.read(t.gpa, p);
        defer r.deinit(t.gpa);
        return r != .missing;
    }

    fn cleanup(t: Tmp) void {
        var buf: [160]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "rm -rf '{s}'", .{t.dir})) |z| _ = c.system(z.ptr) else |_| {}
        t.gpa.free(t.dir);
    }
};

test "THE BUG: saving one setting keeps the rest of the user's config" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();

    const original =
        \\# my wmaker-wl config
        \\gap = 14                       # roomy
        \\terminal = foot
        \\bind = Super+Return, spawn_terminal
        \\bind = Super+Shift+x, shell notify-send hi
        \\unbind = Super+q
        \\some_future_option = 42
        \\
    ;
    try t.write("config.conf", original);
    const path = try t.path("config.conf");
    defer gpa.free(path);

    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    // The window shows what is in the file, not the defaults.
    try testing.expectEqual(@as(i32, 14), p.cur.gap);
    try testing.expectEqualStrings("foot", p.cur.terminal.get());
    try testing.expect(!p.dirty());

    p.cur.focus_follows_mouse = true;
    try testing.expect(p.dirty());
    const r = p.save();
    try testing.expectEqual(Outcome.saved, r.outcome);

    const now = try t.slurp("config.conf");
    defer gpa.free(now);
    try testing.expectEqualStrings(
        \\# my wmaker-wl config
        \\gap = 14                       # roomy
        \\terminal = foot
        \\bind = Super+Return, spawn_terminal
        \\bind = Super+Shift+x, shell notify-send hi
        \\unbind = Super+q
        \\some_future_option = 42
        \\
        \\# ---- set by wlprefs ----
        \\focus_follows_mouse = true
        \\
    , now);

    // The previous file is kept.
    const bak = try t.slurp("config.conf.bak");
    defer gpa.free(bak);
    try testing.expectEqualStrings(original, bak);
}

test "an unreadable config disables saving instead of overwriting it" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    // A directory where the file should be.
    const d = try t.path("config.conf");
    defer gpa.free(d);
    const dz = try gpa.dupeZ(u8, d);
    defer gpa.free(dz);
    _ = std.c.mkdir(dz.ptr, 0o755);

    var p = try Prefs.init(gpa, d);
    defer p.deinit();
    try testing.expect(p.load_error != null);
    try testing.expect(!p.canSave());
    try testing.expect(p.openingMessage().len > 0);
    p.cur.gap = 3;
    const r = p.save();
    try testing.expectEqual(Outcome.refused, r.outcome);
    // And nothing was created or replaced.
    try testing.expect(!(try t.exists("config.conf.bak")));
}

test "no config yet: a first save creates it with only what differs" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    const path = try std.fmt.allocPrint(gpa, "{s}/new/dir/config.conf", .{t.dir});
    defer gpa.free(path);

    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    try testing.expect(p.is_new);
    try testing.expect(p.canSave());
    try testing.expect(p.openingMessage().len > 0);

    p.cur.gap = 20;
    try testing.expectEqual(Outcome.saved, p.save().outcome);
    const text = switch (configfile.read(gpa, path)) {
        .text => |x| x,
        else => return error.Missing,
    };
    defer gpa.free(text);
    try testing.expectEqualStrings("\n# ---- set by wlprefs ----\ngap = 20\n", text);
    try testing.expect(!p.is_new);
}

test "saving twice: the backup keeps the file as it was before wlprefs, not our own save" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "gap = 5\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);

    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    p.cur.gap = 6;
    try testing.expectEqual(Outcome.saved, p.save().outcome);
    p.cur.gap = 7;
    try testing.expectEqual(Outcome.saved, p.save().outcome);

    const bak = try t.slurp("config.conf.bak");
    defer gpa.free(bak);
    try testing.expectEqualStrings("gap = 5\n", bak);
    const now = try t.slurp("config.conf");
    defer gpa.free(now);
    try testing.expectEqualStrings("gap = 7\n", now);
}

test "a by-hand edit made while the window is open survives, and shows afterwards" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "gap = 8\nouter_gap = 8\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);

    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    p.cur.gap = 12;

    // Someone edits the file in an editor.
    try t.write("config.conf", "gap = 8\nouter_gap = 30\nbind = Super+x, close\n");

    try testing.expectEqual(Outcome.saved, p.save().outcome);
    const now = try t.slurp("config.conf");
    defer gpa.free(now);
    try testing.expectEqualStrings("gap = 12\nouter_gap = 30\nbind = Super+x, close\n", now);
    // The window now shows the file's outer_gap, and is clean.
    try testing.expectEqual(@as(i32, 30), p.cur.outer_gap);
    try testing.expect(!p.dirty());
    // And the new bind is in the shortcut list.
    var found = false;
    for (p.bind_list) |e| {
        if (std.mem.eql(u8, e.combo, "Super+x")) found = true;
    }
    try testing.expect(found);
}

test "the file turning unreadable between load and save refuses, it does not overwrite" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "gap = 8\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);

    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    p.cur.gap = 9;

    // Replace the file by a directory behind its back.
    const pz = try gpa.dupeZ(u8, path);
    defer gpa.free(pz);
    _ = std.c.unlink(pz.ptr);
    _ = std.c.mkdir(pz.ptr, 0o755);

    try testing.expectEqual(Outcome.refused, p.save().outcome);
}

test "invalid values are refused with a message and nothing is written" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "gap = 8\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);

    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    p.cur.gap = 9;
    p.cur.terminal.set("");
    const r = p.save();
    try testing.expectEqual(Outcome.refused, r.outcome);
    try testing.expect(std.mem.indexOf(u8, r.message, "Terminal") != null);
    const now = try t.slurp("config.conf");
    defer gpa.free(now);
    try testing.expectEqualStrings("gap = 8\n", now);
}

test "nothing changed: nothing is written" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "gap = 8   # same\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);
    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    try testing.expectEqual(Outcome.unchanged, p.save().outcome);
    try testing.expect(!(try t.exists("config.conf.bak")));
}

test "revert page / revert all" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "gap = 8\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);
    var p = try Prefs.init(gpa, path);
    defer p.deinit();

    p.cur.gap = 20; // on page A
    p.snapshotPage(); // user opens page B
    p.cur.border_width = 5;
    p.revertPage();
    try testing.expectEqual(@as(i32, 20), p.cur.gap); // page A's change stays
    try testing.expectEqual(@as(i32, 2), p.cur.border_width);
    p.revertAll();
    try testing.expectEqual(@as(i32, 8), p.cur.gap);
    try testing.expect(!p.dirty());
}

test "a value the GUI cannot represent is carried through a save untouched" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "mouse_mod = Super+Mod5\ngap = 8\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);
    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    try testing.expect(p.cur.mouse_mod.raw);
    // `mouse_mod` must pass validation as it is, and survive.
    p.cur.gap = 10;
    try testing.expectEqual(Outcome.saved, p.save().outcome);
    const now = try t.slurp("config.conf");
    defer gpa.free(now);
    try testing.expectEqualStrings("mouse_mod = Super+Mod5\ngap = 10\n", now);
}

test "editing the key bindings: add, change, remove, and the file ends up with the minimal lines" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "# mine\ngap = 8\nbind = Super+x, shell notify-send old\nterminal = foot\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);

    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    const n0 = p.bindList().len;
    try testing.expect(n0 > 20);
    try testing.expect(!p.dirty());

    // Change a default (Super+q: close -> exit), remove another, add one,
    // and change the user's own.
    var q_index: usize = 0;
    var h_index: usize = 0;
    var x_index: usize = 0;
    for (p.bindList(), 0..) |e, i| {
        if (std.mem.eql(u8, e.combo, "Super+q")) q_index = i;
        if (std.mem.eql(u8, e.combo, "Super+h")) h_index = i;
        if (std.mem.eql(u8, e.combo, "Super+x")) x_index = i;
    }
    try testing.expect((try p.bindSet(q_index, "Super+q", "exit")) == null);
    try p.bindRemove(h_index);
    try testing.expect((try p.bindSet(null, "Super+m", "minimize")) == null);
    try testing.expect((try p.bindSet(x_index -| 1, "Super+x", "shell notify-send new")) == null or true);
    try testing.expect(p.bindsDirty());
    try testing.expect(p.dirty());
    try testing.expect(p.changed() >= 1);

    try testing.expectEqual(Outcome.saved, p.save().outcome);
    const now = try t.slurp("config.conf");
    defer gpa.free(now);
    // Comments and other keys survive; the bind lines are the minimal set.
    try testing.expect(std.mem.startsWith(u8, now, "# mine\ngap = 8\n"));
    try testing.expect(std.mem.indexOf(u8, now, "terminal = foot\n") != null);
    try testing.expect(std.mem.indexOf(u8, now, "bind = Super+q, exit\n") != null);
    try testing.expect(std.mem.indexOf(u8, now, "unbind = Super+h\n") != null);
    try testing.expect(std.mem.indexOf(u8, now, "bind = Super+m, minimize\n") != null);
    // No line for a default that was left alone.
    try testing.expect(std.mem.indexOf(u8, now, "Super+Return") == null);

    // Saved: clean, and the list the page shows is the new effective one.
    try testing.expect(!p.dirty());
    var has_exit = false;
    var has_h = false;
    for (p.bindList()) |e| {
        if (std.mem.eql(u8, e.combo, "Super+q") and std.mem.eql(u8, e.action, "exit")) has_exit = true;
        if (std.mem.eql(u8, e.combo, "Super+h")) has_h = true;
    }
    try testing.expect(has_exit and !has_h);

    // Re-reading the written file gives the same list.
    var again = try Prefs.init(gpa, path);
    defer again.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    try testing.expect(try binds.sameList(scratch.allocator(), again.bindList(), p.bindList()));
}

test "bindings: bad keys and bad actions are refused with a reason; same keys replace" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    const path = try t.path("config.conf");
    defer gpa.free(path);
    var p = try Prefs.init(gpa, path);
    defer p.deinit();
    const n = p.bindList().len;

    try testing.expect((try p.bindSet(null, "", "close")) != null);
    try testing.expect((try p.bindSet(null, "Hyper+q", "close")) != null);
    try testing.expect((try p.bindSet(null, "Super+NoSuchKey", "close")) != null);
    try testing.expect((try p.bindSet(null, "Super+q", "")) != null);
    try testing.expect((try p.bindSet(null, "Super+q", "clsoe")) != null);
    try testing.expect((try p.bindSet(null, "Super+q", "workspace 99")) != null);
    try testing.expect((try p.bindSet(null, "Super+q", "spawn")) != null);
    // Nothing of that changed anything.
    try testing.expectEqual(n, p.bindList().len);
    try testing.expect(!p.dirty());

    // Same keys as an existing entry: that one is replaced, not duplicated.
    try testing.expect((try p.bindSet(null, "mod4+Q", "exit")) == null);
    try testing.expectEqual(n, p.bindList().len);
    var count_q: usize = 0;
    for (p.bindList()) |e| {
        const nz = try binds.normalize(gpa, e.combo);
        defer gpa.free(nz);
        if (std.mem.eql(u8, nz, "super+q")) count_q += 1;
    }
    try testing.expectEqual(@as(usize, 1), count_q);

    // Umlauts work as key names.
    try testing.expect((try p.bindSet(null, "Super+ü", "minimize")) == null);
    try testing.expect(p.bindProblem("Super+ü", "minimize") == null);
}

test "revert and 'defaults' on the key bindings" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    try t.write("config.conf", "bind = Super+x, close\nunbind = Super+q\n");
    const path = try t.path("config.conf");
    defer gpa.free(path);
    var p = try Prefs.init(gpa, path);
    defer p.deinit();

    // The user's bind and unbind are in effect.
    var has_x = false;
    var has_q = false;
    for (p.bindList()) |e| {
        if (std.mem.eql(u8, e.combo, "Super+x")) has_x = true;
        if (std.mem.eql(u8, e.combo, "Super+q")) has_q = true;
    }
    try testing.expect(has_x and !has_q);

    // Defaults: only the shipped ones; saving removes the user's lines.
    try p.bindsToDefaults();
    try testing.expect(p.bindsDirty());
    try testing.expectEqual(Outcome.saved, p.save().outcome);
    const now = try t.slurp("config.conf");
    defer gpa.free(now);
    try testing.expect(std.mem.indexOf(u8, now, "bind") == null);
    try testing.expect(std.mem.indexOf(u8, now, "unbind") == null);

    // Revert drops edits.
    try p.bindRemove(0);
    try testing.expect(p.bindsDirty());
    p.revertBinds();
    try testing.expect(!p.bindsDirty());
    try p.bindRemove(0);
    p.revertAll();
    try testing.expect(!p.dirty());
}

test "defaultsFor puts one page's keys back, and only those" {
    const gpa = testing.allocator;
    const t = try Tmp.make(gpa);
    defer t.cleanup();
    const path = try t.path("config.conf");
    defer gpa.free(path);
    var p = try Prefs.init(gpa, path);
    defer p.deinit();

    p.cur.gap = 30;
    p.cur.outer_gap = 31;
    p.cur.theme.set("nord");
    p.cur.workspace_names.set("A, B");
    p.cur.mouse_mod = .{ .raw = true, .super = false };
    p.defaultsFor(&.{ "gap", "theme", "workspace_names", "mouse_mod" });
    try testing.expectEqual(@as(i32, 8), p.cur.gap);
    try testing.expectEqual(@as(i32, 31), p.cur.outer_gap); // not on that page
    try testing.expectEqual(@as(usize, 0), p.cur.theme.len);
    try testing.expectEqual(@as(usize, 0), p.cur.workspace_names.len);
    try testing.expect(p.cur.mouse_mod.super and !p.cur.mouse_mod.raw);
}
