// SPDX-License-Identifier: 0BSD
//
// XPM3 reader, for Dock and Clip tile icons. Window Maker's own icons and
// nearly every DockApp ship as .xpm, which cairo cannot read.
//
// No cairo and no Wayland in here: text in, ARGB pixels out, so the whole
// thing is testable (and fuzz-resistant: every size is checked before
// anything is allocated, nothing is trusted from the file).
//
// What is understood:
//   * the C-source form (`/* XPM */ static char * x[] = { "..", ... };`),
//     comments included;
//   * 1 to 4 characters per pixel;
//   * colour keys `c` (preferred), `g4`, `g`, `m`; values `None` (transparent),
//     `#RGB`, `#RRGGBB`, `#RRRGGGBBB`, `#RRRRGGGGBBBB`, `grayNN`/`greyNN`, and
//     a table of the common X11 names;
//   * the optional hotspot and XPMEXT in the header (ignored).
//
// An unknown colour name is drawn magenta, so a wrong icon is visibly wrong
// instead of silently transparent.

const std = @import("std");

/// Biggest icon side accepted (a tile icon is 48 px; DockApps use up to 64).
pub const max_side: u32 = 512;
/// Biggest palette. XPM allows more; no icon needs them.
pub const max_colors: u32 = 65536;

pub const Error = error{
    /// Not an XPM, or the header is malformed.
    Invalid,
    /// Valid, but larger than we are willing to load.
    TooBig,
    OutOfMemory,
};

pub const Pixmap = struct {
    width: u32,
    height: u32,
    /// width * height premultiplied ARGB32 (0xAARRGGBB), row by row. Every
    /// pixel is either opaque or fully transparent (0), so premultiplied
    /// and straight alpha are the same thing here.
    pixels: []u32,

    pub fn deinit(p: Pixmap, gpa: std.mem.Allocator) void {
        gpa.free(p.pixels);
    }
};

// ----------------------------------------------------------------------------
// Tokenising: the double-quoted strings of the C source, in order
// ----------------------------------------------------------------------------

const Strings = struct {
    text: []const u8,
    pos: usize = 0,

    /// The next "..." string, without its quotes; null at the end. Skips
    /// /* */ and // comments, and honours \" and \\ inside a string (the
    /// returned slice is the raw text between the quotes: an XPM never
    /// needs escapes in practice, and a pixel code is never a backslash).
    fn next(it: *Strings) ?[]const u8 {
        const t = it.text;
        while (it.pos < t.len) {
            const ch = t[it.pos];
            if (ch == '/' and it.pos + 1 < t.len and t[it.pos + 1] == '*') {
                const end = std.mem.indexOfPos(u8, t, it.pos + 2, "*/") orelse {
                    it.pos = t.len;
                    return null;
                };
                it.pos = end + 2;
            } else if (ch == '/' and it.pos + 1 < t.len and t[it.pos + 1] == '/') {
                it.pos = std.mem.indexOfScalarPos(u8, t, it.pos, '\n') orelse t.len;
            } else if (ch == '"') {
                const start = it.pos + 1;
                var i = start;
                while (i < t.len and t[i] != '"') : (i += 1) {
                    if (t[i] == '\\' and i + 1 < t.len) i += 1;
                }
                if (i >= t.len) {
                    it.pos = t.len;
                    return null; // unterminated
                }
                it.pos = i + 1;
                return t[start..i];
            } else {
                it.pos += 1;
            }
        }
        return null;
    }
};

// ----------------------------------------------------------------------------
// Colours
// ----------------------------------------------------------------------------

const transparent: u32 = 0;
const magenta: u32 = 0xffff00ff;

fn rgb(r: u32, g: u32, b: u32) u32 {
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

const NamedColor = struct { name: []const u8, value: u32 };

/// The X11 names that icons actually use. Lower case; spaces removed
/// before lookup ("light gray" == "lightgray").
const named_colors = [_]NamedColor{
    .{ .name = "black", .value = 0xff000000 },
    .{ .name = "white", .value = 0xffffffff },
    .{ .name = "red", .value = 0xffff0000 },
    .{ .name = "green", .value = 0xff00ff00 },
    .{ .name = "blue", .value = 0xff0000ff },
    .{ .name = "yellow", .value = 0xffffff00 },
    .{ .name = "cyan", .value = 0xff00ffff },
    .{ .name = "magenta", .value = 0xffff00ff },
    .{ .name = "gray", .value = 0xffbebebe },
    .{ .name = "grey", .value = 0xffbebebe },
    .{ .name = "lightgray", .value = 0xffd3d3d3 },
    .{ .name = "lightgrey", .value = 0xffd3d3d3 },
    .{ .name = "darkgray", .value = 0xffa9a9a9 },
    .{ .name = "darkgrey", .value = 0xffa9a9a9 },
    .{ .name = "dimgray", .value = 0xff696969 },
    .{ .name = "dimgrey", .value = 0xff696969 },
    .{ .name = "orange", .value = 0xffffa500 },
    .{ .name = "brown", .value = 0xffa52a2a },
    .{ .name = "pink", .value = 0xffffc0cb },
    .{ .name = "purple", .value = 0xffa020f0 },
    .{ .name = "gold", .value = 0xffffd700 },
    .{ .name = "navy", .value = 0xff000080 },
    .{ .name = "navyblue", .value = 0xff000080 },
    .{ .name = "darkgreen", .value = 0xff006400 },
    .{ .name = "darkblue", .value = 0xff00008b },
    .{ .name = "darkred", .value = 0xff8b0000 },
    .{ .name = "lightblue", .value = 0xffadd8e6 },
    .{ .name = "lightgreen", .value = 0xff90ee90 },
    .{ .name = "skyblue", .value = 0xff87ceeb },
    .{ .name = "steelblue", .value = 0xff4682b4 },
    .{ .name = "royalblue", .value = 0xff4169e1 },
    .{ .name = "forestgreen", .value = 0xff228b22 },
    .{ .name = "limegreen", .value = 0xff32cd32 },
    .{ .name = "firebrick", .value = 0xffb22222 },
    .{ .name = "tomato", .value = 0xffff6347 },
    .{ .name = "salmon", .value = 0xfffa8072 },
    .{ .name = "khaki", .value = 0xfff0e68c },
    .{ .name = "beige", .value = 0xfff5f5dc },
    .{ .name = "tan", .value = 0xffd2b48c },
    .{ .name = "wheat", .value = 0xfff5deb3 },
    .{ .name = "ivory", .value = 0xfffffff0 },
    .{ .name = "silver", .value = 0xffc0c0c0 },
    .{ .name = "maroon", .value = 0xffb03060 },
    .{ .name = "violet", .value = 0xffee82ee },
    .{ .name = "turquoise", .value = 0xff40e0d0 },
};

/// A hex digit run of 1..4 digits per channel, scaled to 8 bits.
fn hexChannel(digits: []const u8) ?u32 {
    if (digits.len == 0 or digits.len > 4) return null;
    const v = std.fmt.parseInt(u32, digits, 16) catch return null;
    // 1 digit: 0xF -> 0xFF; 2: as is; 3: top 8 of 12 bits; 4: top 8 of 16.
    return switch (digits.len) {
        1 => v * 17,
        2 => v,
        3 => v >> 4,
        4 => v >> 8,
        else => null,
    };
}

/// A colour value as it appears after a key: "None", "#rrggbb", "gray50",
/// "light gray", ... Always returns something: unknown -> magenta.
pub fn parseColor(value: []const u8) u32 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len == 0) return magenta;

    if (std.ascii.eqlIgnoreCase(v, "none") or std.ascii.eqlIgnoreCase(v, "background")) return transparent;

    if (v[0] == '#') {
        const hex = v[1..];
        if (hex.len == 0 or hex.len % 3 != 0 or hex.len > 12) return magenta;
        const per = hex.len / 3;
        const r = hexChannel(hex[0..per]) orelse return magenta;
        const g = hexChannel(hex[per .. 2 * per]) orelse return magenta;
        const b = hexChannel(hex[2 * per ..]) orelse return magenta;
        return rgb(r, g, b);
    }

    // Lower-cased, spaces dropped.
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (v) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (n == buf.len) return magenta;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    const name = buf[0..n];

    // grayNN / greyNN: NN percent.
    inline for (.{ "gray", "grey" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) {
            if (std.fmt.parseInt(u32, name[prefix.len..], 10)) |pct| {
                if (pct > 100) return magenta;
                const lvl = (pct * 255 + 50) / 100;
                return rgb(lvl, lvl, lvl);
            } else |_| {}
        }
    }

    for (named_colors) |nc| {
        if (std.mem.eql(u8, nc.name, name)) return nc.value;
    }
    return magenta;
}

/// Which of the keys on a colour line is best: c, then g4, g, m, s.
fn keyRank(key: []const u8) ?u8 {
    if (std.mem.eql(u8, key, "c")) return 0;
    if (std.mem.eql(u8, key, "g4")) return 1;
    if (std.mem.eql(u8, key, "g")) return 2;
    if (std.mem.eql(u8, key, "m")) return 3;
    return null;
}

fn isKey(tok: []const u8) bool {
    return keyRank(tok) != null or std.mem.eql(u8, tok, "s");
}

/// The colour of a colour line's `rest` (everything after the pixel code):
/// "c #ff0000 m black s name" -> the `c` value.
fn lineColor(rest: []const u8) u32 {
    var best: ?u32 = null;
    var best_rank: u8 = 255;

    var it = std.mem.tokenizeAny(u8, rest, " \t");
    var key: ?[]const u8 = null;
    var value: [64]u8 = undefined;
    var vlen: usize = 0;

    const Flush = struct {
        fn run(k: ?[]const u8, v: []const u8, b: *?u32, br: *u8) void {
            const kk = k orelse return;
            const r = keyRank(kk) orelse return; // `s` (symbolic name): ignored
            if (r < br.*) {
                b.* = parseColor(v);
                br.* = r;
            }
        }
    };

    while (it.next()) |tok| {
        if (isKey(tok)) {
            Flush.run(key, value[0..vlen], &best, &best_rank);
            key = tok;
            vlen = 0;
        } else if (key != null) {
            // A colour name may be several words ("light gray").
            if (vlen > 0 and vlen < value.len) {
                value[vlen] = ' ';
                vlen += 1;
            }
            const n = @min(tok.len, value.len - vlen);
            @memcpy(value[vlen..][0..n], tok[0..n]);
            vlen += n;
        }
    }
    Flush.run(key, value[0..vlen], &best, &best_rank);
    return best orelse magenta;
}

// ----------------------------------------------------------------------------
// Parsing
// ----------------------------------------------------------------------------

fn parseUint(tok: []const u8) ?u32 {
    return std.fmt.parseInt(u32, tok, 10) catch null;
}

/// Parse XPM3 source text.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) Error!Pixmap {
    var it: Strings = .{ .text = text };

    // The header: "width height ncolors chars_per_pixel [x_hot y_hot] [XPMEXT]"
    const header = it.next() orelse return error.Invalid;
    var ht = std.mem.tokenizeAny(u8, header, " \t");
    const width = parseUint(ht.next() orelse return error.Invalid) orelse return error.Invalid;
    const height = parseUint(ht.next() orelse return error.Invalid) orelse return error.Invalid;
    const ncolors = parseUint(ht.next() orelse return error.Invalid) orelse return error.Invalid;
    const cpp = parseUint(ht.next() orelse return error.Invalid) orelse return error.Invalid;

    if (width == 0 or height == 0 or ncolors == 0) return error.Invalid;
    if (cpp == 0 or cpp > 4) return error.Invalid;
    if (width > max_side or height > max_side or ncolors > max_colors) return error.TooBig;

    // Palette: pixel code (up to 4 bytes, packed) -> colour.
    var palette: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer palette.deinit(gpa);
    palette.ensureTotalCapacity(gpa, ncolors) catch return error.OutOfMemory;

    var i: u32 = 0;
    while (i < ncolors) : (i += 1) {
        const line = it.next() orelse return error.Invalid;
        if (line.len < cpp) return error.Invalid;
        const code = pack(line[0..cpp]);
        palette.putAssumeCapacity(code, lineColor(line[cpp..]));
    }

    const count: usize = @as(usize, width) * @as(usize, height);
    const pixels = gpa.alloc(u32, count) catch return error.OutOfMemory;
    errdefer gpa.free(pixels);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = it.next() orelse return error.Invalid;
        if (row.len < @as(usize, width) * cpp) return error.Invalid;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const code = pack(row[x * cpp ..][0..cpp]);
            // A code that is not in the palette is a broken file: magenta.
            pixels[y * width + x] = palette.get(code) orelse magenta;
        }
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn pack(code: []const u8) u32 {
    var v: u32 = 0;
    for (code) |ch| v = (v << 8) | ch;
    return v;
}

// ----------------------------------------------------------------------------
// Files
// ----------------------------------------------------------------------------

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

/// No icon is anywhere near this; a bigger file is not one.
pub const max_file: usize = 1 << 20;

/// Read `path` completely (at most `max_file` bytes). null if it is missing,
/// unreadable, or too big. Caller frees.
pub fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n > 0) {
            if (list.items.len + n > max_file) {
                list.deinit(gpa);
                return null;
            }
            list.appendSlice(gpa, buf[0..n]) catch {
                list.deinit(gpa);
                return null;
            };
        }
        if (n < buf.len) break;
    }
    if (c.ferror(f) != 0) {
        list.deinit(gpa);
        return null;
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// Load and parse an .xpm file. null on any problem (a bad icon must never
/// stop the Dock from coming up).
pub fn load(gpa: std.mem.Allocator, path: [:0]const u8) ?Pixmap {
    const text = readFile(gpa, path) orelse return null;
    defer gpa.free(text);
    return parse(gpa, text) catch null;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\/* XPM */
    \\static char * sample_xpm[] = {
    \\"4 3 4 1 0 0",
    \\"  c None",
    \\". c #ff0000",
    \\"# c #00ff00 m black",
    \\"o c light gray",
    \\" .#o",
    \\"o#. ",
    \\"....",
    \\};
;

test "parse: a small icon, transparent pixels, hex and named colours" {
    const p = try parse(testing.allocator, sample);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), p.width);
    try testing.expectEqual(@as(u32, 3), p.height);
    try testing.expectEqual(@as(u32, 0), p.pixels[0]); // " " = None
    try testing.expectEqual(@as(u32, 0xffff0000), p.pixels[1]);
    try testing.expectEqual(@as(u32, 0xff00ff00), p.pixels[2]); // `c` wins over `m`
    try testing.expectEqual(@as(u32, 0xffd3d3d3), p.pixels[3]); // "light gray"
    try testing.expectEqual(@as(u32, 0xffd3d3d3), p.pixels[4]);
    try testing.expectEqual(@as(u32, 0xffff0000), p.pixels[6]);
    try testing.expectEqual(@as(u32, 0), p.pixels[7]); // the trailing " " of row 1
    try testing.expectEqual(@as(u32, 0xffff0000), p.pixels[11]);
}

test "parse: two characters per pixel" {
    const p = try parse(testing.allocator,
        \\"2 1 2 2",
        \\"aa c #000000",
        \\"bb c white",
        \\"aabb"
    );
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xff000000), p.pixels[0]);
    try testing.expectEqual(@as(u32, 0xffffffff), p.pixels[1]);
}

test "parse: comments, a hotspot and an extension in the header are fine" {
    const p = try parse(testing.allocator,
        \\/* XPM */ // x
        \\static char *a[] = { /* "not a string" */
        \\"1 1 1 1 3 4 XPMEXT",
        \\"x c #123456", // trailing
        \\"x"
        \\};
    );
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xff123456), p.pixels[0]);
}

test "parse: colour spellings" {
    try testing.expectEqual(@as(u32, 0xffffffff), parseColor("#fff"));
    try testing.expectEqual(@as(u32, 0xff112233), parseColor("#112233"));
    try testing.expectEqual(@as(u32, 0xff112233), parseColor("#111222333"));
    try testing.expectEqual(@as(u32, 0xff112233), parseColor("#111122223333"));
    try testing.expectEqual(@as(u32, 0), parseColor("None"));
    try testing.expectEqual(@as(u32, 0), parseColor("none"));
    try testing.expectEqual(@as(u32, 0), parseColor("Background"));
    try testing.expectEqual(@as(u32, 0xff808080), parseColor("gray50"));
    try testing.expectEqual(@as(u32, 0xffffffff), parseColor("Grey100"));
    try testing.expectEqual(@as(u32, 0xff000000), parseColor("gray0"));
    try testing.expectEqual(@as(u32, 0xffd3d3d3), parseColor("Light Gray"));
    try testing.expectEqual(@as(u32, 0xffff0000), parseColor("RED"));
    // Unknown or broken: magenta, so it shows.
    try testing.expectEqual(magenta, parseColor("nonsense"));
    try testing.expectEqual(magenta, parseColor("#12"));
    try testing.expectEqual(magenta, parseColor("#zzzzzz"));
    try testing.expectEqual(magenta, parseColor("gray101"));
    try testing.expectEqual(magenta, parseColor(""));
    try testing.expectEqual(magenta, parseColor("x" ** 100));
}

test "parse: a colour line with only `g` or `m` still gives a colour; `s` alone does not" {
    const p = try parse(testing.allocator,
        \\"3 1 3 1",
        \\"a g4 gray25",
        \\"b m white",
        \\"c s name_only",
        \\"abc"
    );
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xff404040), p.pixels[0]);
    try testing.expectEqual(@as(u32, 0xffffffff), p.pixels[1]);
    try testing.expectEqual(magenta, p.pixels[2]);
}

test "parse: a pixel code missing from the palette is magenta, not a crash" {
    const p = try parse(testing.allocator,
        \\"2 1 1 1",
        \\"a c black",
        \\"az"
    );
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xff000000), p.pixels[0]);
    try testing.expectEqual(magenta, p.pixels[1]);
}

test "parse: malformed files are rejected without allocating the picture" {
    const gpa = testing.allocator;
    try testing.expectError(error.Invalid, parse(gpa, ""));
    try testing.expectError(error.Invalid, parse(gpa, "not xpm at all"));
    try testing.expectError(error.Invalid, parse(gpa, "\"1 1\""));
    try testing.expectError(error.Invalid, parse(gpa, "\"a b c d\""));
    try testing.expectError(error.Invalid, parse(gpa, "\"0 1 1 1\", \"a c red\", \"a\""));
    try testing.expectError(error.Invalid, parse(gpa, "\"1 1 0 1\", \"a\""));
    try testing.expectError(error.Invalid, parse(gpa, "\"1 1 1 0\", \"a c red\", \"a\""));
    try testing.expectError(error.Invalid, parse(gpa, "\"1 1 1 5\", \"aaaaa c red\", \"aaaaa\""));
    // Fewer colour lines than announced, fewer rows, rows too short.
    try testing.expectError(error.Invalid, parse(gpa, "\"1 1 2 1\", \"a c red\""));
    try testing.expectError(error.Invalid, parse(gpa, "\"1 2 1 1\", \"a c red\", \"a\""));
    try testing.expectError(error.Invalid, parse(gpa, "\"3 1 1 1\", \"a c red\", \"aa\""));
    // Unterminated string.
    try testing.expectError(error.Invalid, parse(gpa, "\"1 1 1 1\", \"a c red\", \"a"));
}

test "parse: absurd sizes are refused before anything is allocated" {
    const gpa = testing.allocator;
    try testing.expectError(error.TooBig, parse(gpa, "\"100000 100000 1 1\""));
    try testing.expectError(error.TooBig, parse(gpa, "\"513 1 1 1\", \"a c red\", \"a\""));
    try testing.expectError(error.TooBig, parse(gpa, "\"1 1 4000000000 1\""));
    // Overflowing numbers are just invalid.
    try testing.expectError(error.Invalid, parse(gpa, "\"99999999999999 1 1 1\""));
}

test "parse: truncation anywhere in a valid file never crashes" {
    const gpa = testing.allocator;
    var cut: usize = 0;
    while (cut < sample.len) : (cut += 1) {
        if (parse(gpa, sample[0..cut])) |p| p.deinit(gpa) else |_| {}
    }
}

test "parse: the full-size palette limit holds" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "\"1 1 65537 4\"");
    try testing.expectError(error.TooBig, parse(gpa, text.items));
}

test "load: missing, directory and valid files" {
    const gpa = testing.allocator;
    try testing.expect(load(gpa, "/nonexistent/wmaker-wl/icon.xpm") == null);
    try testing.expect(load(gpa, "/tmp") == null); // a directory

    var tmpl = "/tmp/wmaker-xpm-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.MkdTemp;
    defer {
        var cmd: [96]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{std.mem.span(dir)})) |z| _ = c.system(z.ptr) else |_| {}
    }
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/icon.xpm", .{std.mem.span(dir)});
    const f = c.fopen(path.ptr, "wb") orelse return error.Open;
    _ = c.fwrite(sample.ptr, 1, sample.len, f);
    _ = c.fclose(f);

    const p = load(gpa, path) orelse return error.LoadFailed;
    defer p.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), p.width);
}
