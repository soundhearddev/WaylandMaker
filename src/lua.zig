// SPDX-License-Identifier: 0BSD
//
// What config.zig needs of Lua, on top of ziglua (the `zlua` package, see
// build.zig.zon): Lua 5.4 is compiled from source and linked statically, no
// system Lua is needed.
//
// This file is a thin layer so that config.zig reads like plain stack code.
// Rules for the callers (config.zig):
//   * Everything that reads a table is raw (rawGet*, rawLen, next, rawSet),
//     so a script's metatables can never run code (or raise an error)
//     outside a protected call.
//   * Strings are only read from values that really ARE strings (toSlice
//     checks), because lua_tolstring would convert a number in place and
//     confuse a running next().
//   * Functions the script can call (`register`) never raise a Lua error
//     (that would longjmp across Zig frames): they report and return.

const std = @import("std");
const zlua = @import("zlua");

pub const State = zlua.Lua;

pub const T_NIL = zlua.LuaType.nil;
pub const T_TABLE = zlua.LuaType.table;

// ---- state -----------------------------------------------------------------

/// null: out of memory. Lua allocates from the C allocator, not from the
/// config's arena: a whole interpreter's memory must not pile up in it.
pub fn newState() ?*State {
    return zlua.Lua.init(std.heap.c_allocator) catch null;
}

pub fn close(L: *State) void {
    L.deinit();
}

/// base, table, string, math, os, io, ... (the user's own script is trusted,
/// like an awesome or neovim config; themes never get this, see config.zig).
pub fn openLibs(L: *State) void {
    L.openLibs();
}

fn instructionLimit(L: *State, _: zlua.Event, _: *zlua.DebugInfo) void {
    L.raiseErrorStr("script ran for far too long (endless loop?)", .{});
}

/// A normal config needs well under a million VM instructions. After this
/// many the script is aborted with an error instead of hanging the session.
pub fn limitInstructions(L: *State, count: i32) void {
    L.setHook(zlua.wrap(instructionLimit), .{ .count = true }, count);
}

// ---- running code ----------------------------------------------------------

/// Compile `text` (source only, never bytecode) as a function on the stack.
/// On failure the error message is on the stack instead.
pub fn load(L: *State, text: []const u8, chunk_name: [:0]const u8) bool {
    L.loadBuffer(text, chunk_name, .text) catch return false;
    return true;
}

/// Call the function on top of the stack. On failure the error message is
/// on the stack instead of the (no) results.
pub fn call(L: *State) bool {
    L.protectedCall(.{}) catch return false;
    return true;
}

/// Make `f` callable from scripts as the global `name`.
pub fn register(L: *State, name: [:0]const u8, comptime f: fn (*State) i32) void {
    L.pushFunction(zlua.wrap(f));
    L.setGlobal(name);
}

/// Make the table on top of the stack the `_ENV` of the function below it.
/// Stack: [func, table] -> [func]. false: the function has no upvalue.
pub fn setEnv(L: *State, func_idx: i32) bool {
    _ = L.setUpvalue(func_idx, 1) catch return false;
    return true;
}

// ---- stack -----------------------------------------------------------------

pub fn pop(L: *State, n: i32) void {
    L.pop(n);
}

pub fn typeOf(L: *State, idx: i32) zlua.LuaType {
    return L.typeOf(idx);
}

pub fn typeName(L: *State, idx: i32) []const u8 {
    return L.typeNameIndex(idx);
}

pub fn newTable(L: *State) void {
    L.createTable(0, 8);
}

pub fn pushValue(L: *State, idx: i32) void {
    L.pushValue(idx);
}

pub fn pushNil(L: *State) void {
    L.pushNil();
}

/// Push the global table.
pub fn pushGlobals(L: *State) void {
    L.pushGlobalTable();
}

// ---- reading values --------------------------------------------------------

/// The bytes of a STRING value (not of a number: those are not converted).
/// Valid while the value stays on the stack / in its table: copy to keep.
pub fn toSlice(L: *State, idx: i32) ?[]const u8 {
    if (L.typeOf(idx) != .string) return null;
    return L.toString(idx) catch null;
}

/// An integer, or a float with an integral value. Strings are not converted.
pub fn toInteger(L: *State, idx: i32) ?i64 {
    if (L.typeOf(idx) != .number) return null;
    const v = L.toInteger(idx) catch return null;
    return @intCast(v);
}

pub fn toNumber(L: *State, idx: i32) ?f64 {
    if (L.typeOf(idx) != .number) return null;
    const v = L.toNumber(idx) catch return null;
    return @floatCast(v);
}

/// A real boolean; 0, "" and nil are not "false" here.
pub fn toBool(L: *State, idx: i32) ?bool {
    if (L.typeOf(idx) != .boolean) return null;
    return L.toBoolean(idx);
}

// ---- tables (raw: no metamethods) -------------------------------------------

pub fn rawLen(L: *State, idx: i32) usize {
    return L.lenRaw(idx);
}

/// Push t[n]. `idx` is where the table is NOW (before the push).
pub fn rawGetI(L: *State, idx: i32, n: i64) void {
    _ = L.getIndexRaw(idx, @intCast(n));
}

/// Pop a key and a value, do t[key] = value.
pub fn rawSet(L: *State, idx: i32) void {
    L.setTableRaw(idx);
}

/// Table iteration: pushNil(), then `while (next(L, t)) { key at -2, value
/// at -1; pop(L, 1) (the value) at the end of the body }`.
pub fn next(L: *State, idx: i32) bool {
    return L.next(idx);
}

/// Push "chunk:line: " of the Lua code that called the running Zig function
/// (or an empty string), and return it. Pop it with pop(L, 1).
pub fn where(L: *State) []const u8 {
    L.where(1);
    return toSlice(L, -1) orelse "";
}
