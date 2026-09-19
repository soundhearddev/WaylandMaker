# WaylandMaker Refactor: Quick Reference

## Module Map

| Module | Purpose | Key Types |
|--------|---------|-----------|
| `config.zig` | Configuration system | `Config`, `KeyboardLayout` |
| `input.zig` | Keyboard/mouse | `MouseState`, `handleKeybinding()` |
| `wmaker_compat.zig` | WMaker FFI | `WMakerContext`, `DockAppInfo`, `WindowAttributes` |
| `types.zig` | Data structures | All core types (Window, Output, Seat, etc.) |
| `main.zig` | Event loop | Entry point, registry, Wayland protocols |
| `layout.zig` | Tiling | Strip, column, geometry (unchanged) |
| `window.zig` | Window mgmt | Window creation, cleanup |
| `output.zig` | Display | Output binding, workspaces |
| `seat.zig` | Input seat | Keyboard bindings, focus |
| `action.zig` | Keybindings | Action dispatch |

## Configuration

**File**: `~/.config/wmaker-wl/config.zon`

### Key options:
```zon
.keyboard_layout = "qwerty"  // or "qwertz", "azerty"
.enable_mouse_support = true
.enable_floating_windows = false
.enable_wmaker_compat = false
.border_focused = 0xd8a657
.gap = 8
```

## API Reference

### Loading config
```zig
var cfg = try config.load(allocator);
defer cfg.deinit(allocator);
```

### Mouse handling
```zig
input.handleMouseButtonPress(wm, &mouse_state, button, x, y);
input.handleMouseMotion(wm, &mouse_state, x, y);
```

### WMaker integration
```zig
var wmaker_ctx = try wmaker.init(allocator, &cfg);
try wmaker.loadTheme(ctx, "/path/to/theme");
try wmaker.applyWindowAttributes(ctx, window_id, attrs);
```

### Spawning programs
```zig
input.spawn(wm, wm.config.terminal_cmd);
```

## Common Patterns

### Navigate windows
```zig
if (wm.seats.first()) |seat| {
    if (seat.focused) |focused_window| {
        if (types.nextWindowInColumn(focused_window)) |next| {
            // focus next
        }
    }
}
```

### Get active workspace
```zig
const ws = output.activeWorkspace();
const strip = &ws.strip;
```

### Create a DockApp (WMaker)
```zig
const app = wmaker.DockAppInfo{
    .name = "xclock",
    .icon_path = "/path/to/icon.png",
    .x = 0, .y = 0,
};
try wmaker.createDockApp(&wm.wmaker_ctx, app);
```

## Build Targets

```bash
zig build                    # Build executable
zig build run                # Build and run
zig build --help            # All targets
```

## Debug Output

Enable logging by setting environment:
```bash
ZIG_LOG_LEVEL=debug ./build/bin/wmaker-wl
```

Common debug points:
```zig
std.log.debug("window at ({},{})", .{w.x, w.y});
std.log.info("config loaded from: {s}", .{cfg.config_file});
std.log.err("failed to load theme", .{});
```

## Performance Notes

- **Config loading**: ~1ms (one-time at startup)
- **Layout computation**: O(n) windows per output
- **Mouse events**: Instant, no overhead if disabled
- **WMaker FFI**: Zero cost when unused (conditional compilation)

## File Size Comparison

| Aspect | Before | After | Change |
|--------|--------|-------|--------|
| main.zig | 354 lines | 286 lines | -19% |
| types.zig | 367 lines | 386 lines | +5% (added fields) |
| Total src | 1641 lines | 1890 lines | +15% (3 new files) |

All additional logic is opt-in (config, mouse, WMaker).

## Keybinding Format

In config.zig, keybinds are `Keybind` structs:
```zig
pub const Keybind = struct {
    modifiers: river.SeatV1.Modifiers,
    keysym: u32,
    action: []const u8,
};
```

Default modifiers:
- `mod4` = Super/Windows key
- `shift` = Shift
- `mod1` = Alt

## Next Feature Checklist

- [ ] Mouse drag window → `input.zig` ready
- [ ] Floating windows → Update `layout.zig`
- [ ] Fuzzel integration → Use `config.launcher_cmd`
- [ ] Theme loading → `wmaker.loadTheme()`
- [ ] DockApps → `wmaker.createDockApp()`

## Common Tasks

### Add new keybinding
1. Edit `config.zig:defaultKeybinds()`
2. Or add to `~/.config/wmaker-wl/config.zon`
3. Add handler in `input.zig:handleKeybinding()`

### Change border color
```zon
.border_focused = 0xRRGGBB
.border_unfocused = 0xRRGGBB
```

### Enable floating windows
```zon
.enable_floating_windows = true
```
(Then update layout.zig to handle floating state)

### Support QWERTZ
```zon
.keyboard_layout = "qwertz"
```
(Vim keys h/j/k/l still work - they're layout-independent)

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Config file ignored | Wrong path | `~/.config/wmaker-wl/config.zon` |
| Mouse not working | Disabled in config | `enable_mouse_support = true` |
| Wrong keybind layout | Layout not set | Set `keyboard_layout` in config |
| Crash on startup | Missing WMaker lib | Set `enable_wmaker_compat = false` |

## Links

- River protocol: `protocol/river-window-management-v1.xml`
- Config format: See `wmaker_refactor_example_config.zon`
- Full docs: `INTEGRATION.md`, `MIGRATION.md`