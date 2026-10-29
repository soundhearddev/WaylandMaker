# Debugging and testing

## Looking into a running wmaker-wl

| Tool | How | What you get |
|---|---|---|
| Log filter | `WMAKER_LOG=info,anim=debug` or `--log` | filtered log lines on stderr |
| Invariant check | `WMAKER_CHECKS=1` | after every manage sequence the model invariants (`src/invariants.zig`) are checked; violations are logged as `err(check)` |
| Flight recorder | always on (info and up); `WMAKER_TRACE=1` adds `debug` | the last 256 log lines, in memory, independent of the filter |
| State dump | `pkill -USR1 wmaker-wl` | `$XDG_RUNTIME_DIR/wmaker-wl-state.txt` (else `/tmp`): outputs, monitors, workspaces, columns, windows, seats, rules, invariants, perf table, recent log lines |
| Perf probes | in the dump | for `manage`, `layout`, `render`, `checks`, `monitors`: count, mean, p50/p95/p99, max |
| Stutter warning | automatic | a manage sequence over 8 ms is logged as `warn(perf)`, at most once a second |

`WMAKER_LOG` takes a list of rules separated by commas or blanks. A bare level sets the default for all
scopes, `SCOPE=LEVEL` overrides it for one scope (the last rule for a scope wins). Levels are `off`,
`err`, `warn`, `info`, `debug`. The default is `info`. Every source file logs under its own scope, so a
line reads `info(window): ...`. The scopes are `action`, `anim`, `check`, `compat`, `config`, `dock`,
`dockapp`, `dockhost`, `dump`, `files`, `keyboard`, `boot`, `main`, `output`, `perf`, `process`, `seat`, `sequence`,
`server`, `svg`, `ui` and `window`.

The invariant check costs O(windows) per sequence. It is for hunting a bug, not for leaving on. "invariants:
all hold" in the dump is the quickest answer to "is the model broken or only the picture?".

`wmaker-wl --check` reads the config, key bindings, root menu, window attributes and `WMState` the way a
session would, reports what is wrong, and exits with 0 or 1 without starting anything.

## The keyboard does nothing

Start with `wmaker-wl --log info,keyboard=debug` from a TTY (stderr to a file: `... 2> ~/wl.log`), press a
key, and read the log:

| Log line | Meaning |
|---|---|
| `config ...: N binds` at start | config.lua was read and its binds turned into commands. `0 binds` means the config is empty or broken: run `wmaker-wl --check` |
| `keyboard ...: N layout(s), repeat R/s after D ms, B binds` | a keyboard was found and set up. Without this line libinput gave no keyboard (check the seat: `loginctl seat-status`, group `input`, `seatd`) |
| `err(keyboard): B binds in the config but C commands` | the model was not loaded at start: a bug, not a config problem |
| `warn(keyboard): the keymap from XKB_DEFAULT_* does not compile` | typo in `XKB_DEFAULT_LAYOUT` & co (`environment` in config.lua, or `~/.config/wmaker-wl/env`); the keyboard runs with `us` meanwhile |
| `debug(keyboard): key K mods M: bind I ...` / `no bind, goes to the client` | what a key press did. `M` is the modifier mask (Super is `0x40`, Shift `0x1`, Ctrl `0x4`, Alt `0x8`) |
| `info(keyboard): switching to vt N` | `Ctrl+Alt+F<N>` was pressed; this works whatever the config says |

`wmaker-wl --binds` lists what is bound. `Super+Shift+e` leaves the session, `Ctrl+Alt+F<N>` switches to another
terminal if everything else fails.

## Tests

```
zig build test            # all unit tests: compositor (model, config, monitors, diagnostics) and wlprefs
zig build test-wlprefs    # only wlprefs
zig build test-examples   # only the examples (wl-battery, wl-clock; separate projects)
zig build test-all        # test + test-examples
zig build bench -Doptimize=ReleaseFast                 # benchmark
zig build bench -Doptimize=ReleaseFast -- --check      # with budgets, exit code 1 when exceeded
zig build bench -- --quick | --csv
```

- `src/model_test.zig`: operations on the data model (fixture with dummy Wayland objects).
- `src/diag_test.zig`: the invariant checker (on good models and on deliberately broken ones), the dump,
  monitor rules, windows returning, output order, and a randomized test: 24 seeds × 150 random operations
  (place, float, fullscreen, minimize, move, monitor on/off, monitor gone and back), with
  `invariants.check` after every step. A failure prints the seed and step, so it can be reproduced.
- `src/fuzz_test.zig`: feeds garbage to everything that reads a file or string (property lists, XPM,
  `config.lua`, key-binding commands). It only checks that nothing crashes, hangs or leaks.
- `src/monitors.zig`, `src/perf.zig`, `src/trace.zig`: tests inside the files.
- `src/config.zig`: among others `monitor()` and `monitor_profile()`: tables, typos, wrong values.
- `src/action.zig`: the argument parsers (`workspace`, `set_column_width`, `float_move`, ...), workspace
  stepping, width presets.
- `src/output.zig`: `sanitize` (a work area almost fully taken by a bar is discarded).
- `src/lua.zig`: memory limit of the Lua states, type strictness of the readers, tables, `load` / `call`.

**Adding a file with `test` blocks?** Add one line to the `test { }` block of `src/root.zig`:

```zig
_ = @import("name.zig");
```

That is all. A file that is not listed there never runs its tests, and neither does a
`pub const x = @import(...)` somewhere else. For wlprefs the list is `wlprefs/src/root.zig` (same line,
separate module), for the examples it is their `main.zig`. `zig build test` runs the compositor and wlprefs
lists together. Nothing checks for a forgotten entry, so after adding tests it is worth seeing the new
test names appear once in the output.

## Benchmark (`src/bench.zig`)

Synthetic models with 10, 100 and 1000 windows, no compositor. Each call is timed for: `layout.compute`
(columns and stacks, with and without `follow`), placing all windows, moving all of them to another
workspace, the invariant check, monitor order and primary with 16 monitors, and rule and profile lookup.
p50, p95 and p99 come from a log2 histogram (microseconds) and are rounded up to the bucket's upper bound,
so they are **not** exact. Mean and maximum are exact.

The budgets in `--check` are deliberately loose (roughly ten times what a current laptop needs). They are
meant to catch "layout became quadratic", not a bad day, and they only apply to optimized builds.

A run is checked in as `dump/bench_*.txt`. In that Debug build, with 1000 windows, a layout takes about
0.1 ms, the invariant check about 0.07 ms, and moving all windows to another workspace about 10 ms. The
model scales roughly linearly, so stutter is more likely to come from clients, rendering or the config
than from the model. I have not measured with real clients yet.