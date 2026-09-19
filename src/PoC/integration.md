# WaylandMaker Refactor: WindowMaker Compatibility Integration Guide

## Overview

This refactor improves code quality and adds a **WindowMaker Compatibility Layer** (WMaker) that allows you to:
- Use real WindowMaker C code without major changes
- Load WindowMaker themes and configuration
- Support DockApps and window attributes
- Map WindowMaker concepts to Wayland/River

## Project Structure

```
src/
├── main.zig                 # Entry point (refactored)
├── config.zig               # Configuration system (NEW)
├── input.zig                # Keyboard/mouse handling (NEW)
├── wmaker_compat.zig        # WMaker FFI layer (NEW)
├── types.zig                # Core data structures (enhanced)
├── action.zig               # Keybinding actions
├── layout.zig               # Tiling layout (unchanged)
├── window.zig               # Window management
├── output.zig               # Output/display handling
└── seat.zig                 # Input seat handling

config/
└── config.zon               # Example user configuration
```

## Key Improvements

### 1. Configuration System (`config.zig`)

**What changed:**
- Removed hard-coded config from `types.zig`
- Loads from `~/.config/wmaker-wl/config.zon`
- Supports keyboard layouts: QWERTY, QWERTZ, AZERTY
- Extensible for WMaker settings

**Usage:**
```zig
const cfg = try config.load(allocator);
const layout = cfg.keyboard_layout; // Access layout
```

### 2. Input Handling (`input.zig`)

**What changed:**
- Separated from main event loop
- New mouse support with drag/resize
- Better keybinding action dispatch
- Layout-aware key mapping

**Features:**
- Mouse button press/release
- Window drag-to-move
- Window drag-to-resize
- Vim-keybind support (h/j/k/l - layout independent)

### 3. WindowMaker Compatibility (`wmaker_compat.zig`)

**Integration points for C code:**

```zig
pub struct WMakerContext {
    enabled: bool,
    docksapp_dir: ?[]const u8,
    wmaker_handle: ?*anyopaque,    // C library handle
    theme_handle: ?*anyopaque,
    prefs_handle: ?*anyopaque,
}
```

**How to integrate real WMaker C code:**

1. **Theme Loading:**
   ```zig
   try wmaker.loadTheme(ctx, "/path/to/theme");
   ```

2. **Window Attributes:**
   ```zig
   const attrs = wmaker.WindowAttributes{
       .skip_taskbar = true,
       .keep_on_top = false,
   };
   try wmaker.applyWindowAttributes(ctx, window_id, attrs);
   ```

3. **DockApp Support:**
   ```zig
   const app = wmaker.DockAppInfo{
       .name = "xclock",
       .icon_path = "/path/to/icon",
       .x = 0, .y = 0,
   };
   try wmaker.createDockApp(ctx, app);
   ```

4. **Hook System (for C callbacks):**
   ```zig
   try wmaker.registerHook(my_c_function, "onWindowMapped");
   ```

## Mapping WindowMaker → Wayland

| WMaker Feature | Wayland Mapping |
|---|---|
| Window Decorations | River `setBorders` |
| Docks/Clips | Layer shell surfaces |
| AppIcons | XDG Toplevel hints |
| Themes | CSS-like surface styling |
| Window Attributes | Layer shell / protocol properties |
| Workspace switching | River active workspace |

## Building with WindowMaker Support

### Option A: Minimal (current state)
```bash
zig build
```
Works without any WindowMaker C code. WMaker layer is scaffolded.

### Option B: With WMaker FFI (future)
```bash
# Requires WindowMaker dev headers
# libwmaker-dev or equivalent installed

# Edit build.zig to add:
exe_module.linkSystemLibrary("wmaker", .{});
exe_module.linkSystemLibrary("X11", .{});  # For theme compatibility

zig build
```

## Next Steps for WMaker Integration

### Phase 1: Basic structure (current)
- ✅ Config system with QWERTZ support
- ✅ Input handling refactor
- ✅ WMaker compat scaffolding
- ⏳ TODO: Mouse features fully tested

### Phase 2: C FFI (medium effort)
- Load real `libwmaker.so`
- Map theme system
- DockApp spawning
- Window attribute handling

### Phase 3: Full compatibility (high effort)
- Complete X11 → Wayland shim
- Menu system integration
- Preference dialog support
- Workspace/Viewport semantics

## Configuration Format (ZON)

```zon
.{
    .keyboard_layout = "qwertz",
    .enable_mouse_support = true,
    .enable_floating_windows = false,
    .enable_wmaker_compat = false,
    .border_focused = 0xd8a657,
    // ... more settings
}
```

See `wmaker_refactor_example_config.zon` for full example.

## Known Limitations

1. **Floating windows**: Scaffolded but not implemented
2. **Fuzzel spawn**: Config ready, needs keyboard integration
3. **WMaker C code**: Not linked yet (pending C FFI setup)
4. **Mouse via config**: Simple button mapping, no chord support yet

## Testing Configuration

Place `config.zon` at:
```bash
mkdir -p ~/.config/wmaker-wl
cp wmaker_refactor_example_config.zon ~/.config/wmaker-wl/config.zon
```

## Migration Path from Original

### Files to merge:
1. **types.zig**: Merge enhanced version (adds config, wmaker_ctx fields)
2. **main.zig**: Merge new entry point (config loading, WMaker init)
3. **action.zig**: Minor updates for input refactoring
4. **seat.zig**: Add mouse_state field to Seat

## References

- River protocol: `protocol/river-window-management-v1.xml`
- Wayland: https://wayland.freedesktop.org/
- WindowMaker: https://www.windowmaker.org/