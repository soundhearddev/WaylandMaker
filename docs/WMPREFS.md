# wlprefs

`wlprefs` is the settings window for wmaker-wl. It is modelled on Window Maker's `WPrefs.app`: same window
size, same row of section icons, same page layout where it makes sense. It is a separate program in
`wlprefs/`; `zig build` in the root builds it together with the compositor (it has no build.zig of its own).

It is not a new source of truth. It reads and writes the same `config.lua` that you can edit by hand, and
leaves everything it does not understand alone.

```
wlprefs [--config FILE] [--shot DIR] [--check]
  --config FILE   edit FILE instead of the default config.lua (good for trying it out)
  --shot DIR      draw every page into DIR/NN-name.png and exit; needs no Wayland session
  --check         read the config the way the window does, report problems, write nothing
                  (exit 0: fine, 1: problems)
```

## Sections

Pages that exist, with the `config.lua` keys they edit:

| Section | Keys |
|---|---|
| Window Focus | `focus_follows_mouse`, `center_focused_column` |
| Window Handling | `new_window`, `gap`, `outer_gap`, `min_window_size` |
| Workspace | `workspace_count`, `workspace_names`, `default_column_width`, `width_step`, `width_presets` |
| Appearance | `border_width`, `border_focused`, `border_unfocused`, `border_floating`, `theme` |
| Mouse | `mouse_mod` (any combination), `drag_threshold`, `floating_size` |
| Ergonomic | `terminal`, `launcher`, `browser` |
| Docks | `dock_enabled`, `dock_size`, `dock_edge`, `dock_offset`, `dock_on_top`, `dock_reserve_space`, `dock_single_click`, `dock_save_state`, `clip_enabled`, `clip_corner`, `clip_on_top`, `clip_collapsed`, `clip_auto_collapse`, `clip_auto_raise`, `clip_scroll_workspaces` |
| Other Configurations | `enable_dockapps`, `enable_autostart`, `enable_wmaker_compat` |
| Fonts | `font_menu_title`, `font_menu`, `font_dock` |
| Keyboard Shortcuts | the effective key bindings, with Add / Edit / Remove; see below |

Keyboard Shortcuts lists the defaults plus your own (marked `*` when they come from your file). "Record"
captures a key combination. The key is checked against xkbcommon and the action against the list in
`wlprefs/src/actions.zig`, which a test in the compositor compares with `types.Command`. `bind_layout`
(which keyboard layout translates the bindings) is on the same page. wlprefs writes the smallest set of
`bind` / `unbind` lines that turns the defaults into your list. Anything equal to the default is left
unwritten.

Sections with no real page:

- **Menu Preferences** shows WPrefs' picture but says so on the page: it is display only, because
  wmaker-wl's menu has none of these options. `menu_submenu_align` exists in `config.lua`, but WPrefs'
  two submenu-alignment buttons do not map cleanly onto its `left` / `right` value, so it is not wired up.
- **Icons**, **Paths**, **Hot Corners** and **Expert** have no counterpart. Each page says why and what to
  do instead (icons: windows live in columns, there are no desktop icons; paths: icons come from the
  icon theme directories; hot corners: use a key binding; expert: those are X11 rendering switches).
- The **root menu** (`RootMenu`) and **window rules** (`WMWindowAttributes`) have no editor. Edit the files
  by hand.

## How saving works

The aim is to change as little of your file as possible (`settings.render`, `prefs.save`,
`configfile.writeAtomic`).

- The file is read at start and read again when you save. Only the lines of keys you changed are touched.
  Comments, blank lines, `bind` / `unbind`, unknown keys, CRLF line endings and anything you edited by hand
  in the meantime stay as they are.
- A file that exists but cannot be read blocks saving, instead of being replaced by what the window
  shows. A missing file is created on the first save.
- Writing is atomic (temporary file, `fsync`, `rename`), keeps the file's permissions, follows a symlink
  (for dotfile managers), and makes `config.lua.bak` the first time a session overwrites the file.
- Values the compositor would reject or misread are not written, and a message says so: an empty
  terminal, a command with a leading quote, presets outside (0, 1], no mouse modifier. A value the window
  cannot show (`mouse_mod = Super+Mod5`, say) is left as it is.
- Defaults come from `src/share/default_config.lua`, embedded at build time, not from a copy. A test in the
  compositor checks that everything wlprefs writes is read back by `config.zig` with the same value
  (`wlprefs and the compositor agree`).
- After saving, every running `wmaker-wl` of the user gets `SIGHUP` (found through `/proc`, without
  `pkill`).
- Several statements on one line (`a = 1; b = 2`) are deliberately not touched.

## Using it

`Save` (or Ctrl+S), `Revert Page`, `Revert All`, and `Defaults`, which resets the keys of the current page
to wmaker-wl's defaults but does not save until you press `Save`. `Close` with unsaved changes warns first
and only discards on the second click. In text fields: arrows, Home/End, Delete, a click sets the cursor,
Tab and Shift+Tab move between fields.

## What WPrefs does that wlprefs does not

WPrefs carries a lot that has no use here, and I left it out on purpose instead of showing disabled
checkboxes: icon slide animations, opaque move, dithering, backing store, desktop icon arrangement, and
"advance to new workspace" when dragging past the screen edge.

Open work on wlprefs is in `wlprefs/TODO.md`.