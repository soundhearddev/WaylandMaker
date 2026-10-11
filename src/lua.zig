// SPDX-License-Identifier: 0BSD
//
// The few entries of the Lua 5.3 / 5.4 C API that config.zig needs, declared
// by hand: no @cImport and no header on the include path. Link with the
// system Lua (`-Dlua=lua5.4` if pkg-config calls it that, see build.zig).
//
// Rules for the callers (config.zig):
//   * Everything that reads a table uses the raw_* functions, so a script's
//     metatables can never run code (or raise an error) outside a pcall.
//   * Strings are only read from values that really ARE strings (toSlice
//     checks), because lua_tolstring would convert a number in place and
//     confuse a running lua_next.

const std = @import("std");

pub const State = opaque {};
const Debug = opaque {};

pub const CFunction = *const fn (L: *State) callconv(.c) c_int;
const Hook = *const fn (L: *State, ar: *Debug) callconv(.c) void;

pub const OK: c_int = 0;

pub const T_NIL: c_int = 0;
pub const T_BOOLEAN: c_int = 1;
pub const T_NUMBER: c_int = 3;
pub const T_STRING: c_int = 4;
pub const T_TABLE: c_int = 5;

/// LUA_REGISTRYINDEX = -LUAI_MAXSTACK - 1000 (same value in 5.3 and 5.4).
const REGISTRYINDEX: c_int = -1001000;
/// registry[LUA_RIDX_GLOBALS] is the global table.
const RIDX_GLOBALS: i64 = 2;
const MASKCOUNT: c_int = 1 << 3;

const c = struct {
    extern fn luaL_newstate() ?*State;
    extern fn lua_close(L: *State) void;
    extern fn luaL_openlibs(L: *State) void;
    extern fn luaL_loadbufferx(L: *State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
    extern fn lua_pcallk(L: *State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) c_int;
    extern fn lua_settop(L: *State, idx: c_int) void;
    extern fn lua_type(L: *State, idx: c_int) c_int;
    extern fn lua_typename(L: *State, tp: c_int) [*:0]const u8;
    extern fn lua_toboolean(L: *State, idx: c_int) c_int;
    extern fn lua_tolstring(L: *State, idx: c_int, len: ?*usize) ?[*:0]const u8;
    extern fn lua_tonumberx(L: *State, idx: c_int, isnum: ?*c_int) f64;
    extern fn lua_tointegerx(L: *State, idx: c_int, isnum: ?*c_int) i64;
    extern fn lua_rawlen(L: *State, idx: c_int) usize;
    extern fn lua_rawgeti(L: *State, idx: c_int, n: i64) c_int;
    extern fn lua_rawget(L: *State, idx: c_int) c_int;
    extern fn lua_rawset(L: *State, idx: c_int) void;
    extern fn lua_next(L: *State, idx: c_int) c_int;
    extern fn lua_pushnil(L: *State) void;
    extern fn lua_pushvalue(L: *State, idx: c_int) void;
    extern fn lua_pushlstring(L: *State, s: [*]const u8, len: usize) [*:0]const u8;
    extern fn lua_pushcclosure(L: *State, f: CFunction, n: c_int) void;
    extern fn lua_setglobal(L: *State, name: [*:0]const u8) void;
    extern fn lua_createtable(L: *State, narr: c_int, nrec: c_int) void;
    extern fn lua_setupvalue(L: *State, funcindex: c_int, n: c_int) ?[*:0]const u8;
    extern fn lua_sethook(L: *State, f: ?Hook, mask: c_int, count: c_int) void;
    extern fn luaL_where(L: *State, lvl: c_int) void;
    extern fn luaL_error(L: *State, fmt: [*:0]const u8, ...) c_int;
};

// ---- state -----------------------------------------------------------------

/// null: out of memory.
pub fn newState() ?*State {
    return c.luaL_newstate();
}

pub fn close(L: *State) void {
    c.lua_close(L);
}

/// base, table, string, math, os, io, ... (the user's own script is trusted,
/// like an awesome or neovim config; themes never get this, see config.zig).
pub fn openLibs(L: *State) void {
    c.luaL_openlibs(L);
}

fn instructionLimit(L: *State, _: *Debug) callconv(.c) void {
    _ = c.luaL_error(L, "script ran for far too long (endless loop?)");
}

/// A normal config needs well under a million VM instructions. After this
/// many the script is aborted with an error instead of hanging the session.
pub fn limitInstructions(L: *State, count: c_int) void {
    c.lua_sethook(L, instructionLimit, MASKCOUNT, count);
}

// ---- running code ----------------------------------------------------------

/// Compile `text` (source only, never bytecode) as a function on the stack.
/// On failure the error message is on the stack instead.
pub fn load(L: *State, text: []const u8, chunk_name: [*:0]const u8) bool {
    return c.luaL_loadbufferx(L, text.ptr, text.len, chunk_name, "t") == OK;
}

/// Call the function on top of the stack. On failure the error message is
/// on the stack instead of the (no) results.
pub fn call(L: *State) bool {
    return c.lua_pcallk(L, 0, 0, 0, 0, null) == OK;
}

pub fn register(L: *State, name: [*:0]const u8, f: CFunction) void {
    c.lua_pushcclosure(L, f, 0);
    c.lua_setglobal(L, name);
}

/// Make the table on top of the stack the `_ENV` of the function below it.
/// Stack: [func, table] -> [func]. false: the function has no upvalue.
pub fn setEnv(L: *State, func_idx: c_int) bool {
    return c.lua_setupvalue(L, func_idx, 1) != null;
}

// ---- stack -----------------------------------------------------------------

pub fn pop(L: *State, n: c_int) void {
    c.lua_settop(L, -n - 1);
}

pub fn typeOf(L: *State, idx: c_int) c_int {
    return c.lua_type(L, idx);
}

pub fn typeName(L: *State, idx: c_int) []const u8 {
    return std.mem.span(c.lua_typename(L, c.lua_type(L, idx)));
}

pub fn newTable(L: *State) void {
    c.lua_createtable(L, 0, 8);
}

pub fn pushValue(L: *State, idx: c_int) void {
    c.lua_pushvalue(L, idx);
}

pub fn pushNil(L: *State) void {
    c.lua_pushnil(L);
}

pub fn pushString(L: *State, s: []const u8) void {
    _ = c.lua_pushlstring(L, s.ptr, s.len);
}

/// Push the global table.
pub fn pushGlobals(L: *State) void {
    _ = c.lua_rawgeti(L, REGISTRYINDEX, RIDX_GLOBALS);
}

// ---- reading values --------------------------------------------------------

/// The bytes of a STRING value (not of a number: those are not converted).
/// Valid while the value stays on the stack / in its table: copy to keep.
pub fn toSlice(L: *State, idx: c_int) ?[]const u8 {
    if (c.lua_type(L, idx) != T_STRING) return null;
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len];
}

/// An integer, or a float with an integral value. Strings are not converted.
pub fn toInteger(L: *State, idx: c_int) ?i64 {
    if (c.lua_type(L, idx) != T_NUMBER) return null;
    var ok: c_int = 0;
    const v = c.lua_tointegerx(L, idx, &ok);
    return if (ok != 0) v else null;
}

pub fn toNumber(L: *State, idx: c_int) ?f64 {
    if (c.lua_type(L, idx) != T_NUMBER) return null;
    var ok: c_int = 0;
    const v = c.lua_tonumberx(L, idx, &ok);
    return if (ok != 0) v else null;
}

/// A real boolean; 0, "" and nil are not "false" here.
pub fn toBool(L: *State, idx: c_int) ?bool {
    if (c.lua_type(L, idx) != T_BOOLEAN) return null;
    return c.lua_toboolean(L, idx) != 0;
}

// ---- tables (raw: no metamethods) -------------------------------------------

pub fn rawLen(L: *State, idx: c_int) usize {
    return c.lua_rawlen(L, idx);
}

/// Push t[n]. `idx` is where the table is NOW (before the push).
pub fn rawGetI(L: *State, idx: c_int, n: i64) void {
    _ = c.lua_rawgeti(L, idx, n);
}

/// Pop a key, push t[key].
pub fn rawGet(L: *State, idx: c_int) void {
    _ = c.lua_rawget(L, idx);
}

/// Pop a value and a key, do t[key] = value.
pub fn rawSet(L: *State, idx: c_int) void {
    c.lua_rawset(L, idx);
}

/// Table iteration: push nil, then `while (next(L, t) )` { key at -2, value
/// at -1; pop 1 (the value) at the end of the body }.
pub fn next(L: *State, idx: c_int) bool {
    return c.lua_next(L, idx) != 0;
}

/// Push "chunk:line: " of the Lua code that called the running C function
/// (or an empty string), and return it. Pop it with pop(L, 1).
pub fn where(L: *State) []const u8 {
    c.luaL_where(L, 1);
    return toSlice(L, -1) orelse "";
}
