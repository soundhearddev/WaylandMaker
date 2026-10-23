# Window Maker integration

The goal is a window manager that behaves like Window Maker where that makes sense on Wayland: the root
menu, the Dock and Clip, DockApps, per-application attributes, and the familiar files. This page says what
is taken over, what is implemented, and what is not.


## Files

| File | Module | Notes |
|---|---|---|
| any property list | `plist.zig` | Window Maker / GNUstep format: comments, escapes, data, line numbers in errors |
| `RootMenu` / `WMRootMenu` | `wm_menu.zig` | property-list and text (`menu`) format, nested menus, `SHORTCUT` |
| `WMWindowAttributes` | `wm_attr.zig` | all 30 attributes are parsed; resolution follows Window Maker |
| `WMState` | `dockapp.zig` | Dock, Clip, Drawers, workspace names; see [DOCKAPPS.md](DOCKAPPS.md) |
| `autostart` | `main.zig` | one shell script, run once at session start |

Search order and the broken-file behaviour are in `wm_files.zig`: `~/.config/wmaker-wl/` first, then
`~/GNUstep` (or `$WMAKER_USER_ROOT`) when `enable_wmaker_compat = true`. wmaker-wl never writes to
`~/GNUstep`; it saves its own `WMState` under `$XDG_STATE_HOME`. A broken file is skipped with a message
that includes the line number; the session still starts.

## Root menu

A right click on the empty desktop opens the root menu, a middle click opens the window list. Submenus
cascade, rows highlight under the pointer, and the keyboard works (arrows, Enter or Right to open or run,
Left to close one level, Esc to close all). `SHORTCUT` text is shown right-aligned.

To catch clicks on the empty desktop, there is one transparent, output-sized shell surface per output.
Windows are stacked above it and keep their own clicks. A left click on it closes an open menu.

Entries that work: `EXEC`, `SHEXEC` (through `/bin/sh -c`), `OPEN_MENU`, `WORKSPACE_MENU`,
`WINDOWS_MENU` (both built from the live model), `EXIT`, `REFRESH`, `SHOW_ALL`, `HIDE_OTHERS`,
workspace next/previous, `SHUTDOWN`, `INFO_PANEL`, `LEGAL_PANEL`.

Shown disabled because there is nothing behind them yet: `RESTART`, `SAVE_SESSION`, `CLEAR_SESSION`,
`ARRANGE_ICONS`.

## Window attributes

Only some attributes have an effect. The others are parsed and ignored.

| Attribute | Effect |
|---|---|
| `StartWorkspace` | the window opens on this workspace (1-based number) |
| `Omnipresent` | floating, follows the user to every workspace |
| `KeepOnTop` | floating |
| `StartMaximized` | the new column fills the work area |
| `NoBorder` | no border; the slot is all content |
| `Unfocusable` | never takes keyboard focus |
| `Floating` | wmaker-wl's own addition: `Yes` floats the window, `No` tiles it |

Everything about title bars (`NoTitlebar`, `NoResizebar`, `NoCloseButton`, `NoMiniaturizeButton`) and
application icons (`Icon`, `NoAppIcon`, ...) has no effect, because there are no title bars and Dock
tiles are not made from arbitrary windows.

## What river provides

The protocol files are in `protocol/`.

- `river_decoration_v1`: `window.get_decoration_above` / `get_decoration_below` with `set_offset`. This is
  what title bars would be drawn on. Not used yet.
- `river_shell_surface_v1`: `get_shell_surface(wl_surface)` gives a surface with its own node, plus
  `focus_shell_surface` and `shell_surface_interaction`. The root menu, window list, Dock and Clip are all
  shell surfaces, so no layer-shell client is needed for them.
- Clicks on a shell surface arrive as ordinary `wl_pointer` events in this process.

Besides river's protocols the program binds `wl_compositor`, `wl_shm`, `wl_seat`, `wl_output`, and
`wp_cursor_shape_manager_v1` if the compositor has it (without it the pointer keeps whatever shape the
last window set). Drawing is cairo and pango.

## Differences that stay

Some Window Maker ideas do not carry over:

- `WM_CLASS`, dragging a window's app icon onto the Dock, and X11 DockApps. Docking works through
  `app_id` instead, and DockApps are Wayland clients that tag themselves (see [DOCKAPPS.md](DOCKAPPS.md)).
  wlmaker's own DockApps (`wlmclock`, `wlmbattery`) would need a separate interface.
- Desktop icons and the icon yard, since windows live in columns.
- Most of WPrefs' X11-specific options (dithering, backing store, opaque move).

## Not done

- **Title bars** (22 px high in wlmaker's defaults, minimize left, close right, resize bar at the bottom),
  and with them the attributes above. Minimize, hide and show-all exist already, without a title bar.
- **Themes** in a wlmaker-style file, and Window Maker's `~/GNUstep/Defaults/WindowMaker` keys
  (`FTitleBack`, `UTitleBack`, `MenuTitleBack`, ...). What exists now are `theme("NAME")` files that set
  colours, border width and gaps.
- **Sessions** (`SAVE_SESSION`).