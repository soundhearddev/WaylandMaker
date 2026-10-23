# Dock, Clip and DockApps

This follows Window Maker (`dock.c`, `appicon.c`) in three ways: there is one file format, there is no
list of DockApps to maintain, and DockApps are not treated as windows.

The Dock and the Clip are drawn on the primary monitor only. One tile is `dock_size` pixels (64 by
default, 16 to 256 allowed).

## Writing a DockApp

A DockApp is an ordinary Wayland program with one convention: its `app_id` is `dockapp:<name>` (or
`dockapp-<name>`). Start it however you like: from `autostart`, the root menu, a terminal, or a `WMState`
entry with `AutoLaunch = Yes`. It should:

1. set that `app_id`,
2. ask for a window size (at most one tile),
3. draw into it.

Everything else is up to the window manager. `examples/wl-clock` and `examples/wl-battery` are complete
small examples; neither needs a toolkit or layer-shell, they are plain `xdg_shell` clients drawing into
`wl_shm` buffers.

## How DockApps are handled (`dockhost.zig`)

When the tag shows up, whenever that is, the window is adopted once: `Window.role = .dockapp`, and it
moves from `wm.windows` to `wm.dock_windows`. After that, layout, workspaces, focus, focus cycling, close,
hide, minimize, kill, the window list and window menus never see it, because they only iterate
`wm.windows`. No flag has to be checked in each of them.

What the compositor then decides, all in `dockhost.apply`:

| Topic | Behaviour |
|---|---|
| Size | what the DockApp asked for, at most one tile; a whole tile if it gave no hint |
| Position | centred in the tile of its name, above the Dock, on all workspaces |
| Decoration | none |
| Focus, keyboard | never; `Super+q` and other window actions do not reach it |
| Events | only size, name and close count; move, resize and fullscreen are ignored |
| Mouse | goes straight to the DockApp, because its window sits on the tile |
| Tile | if an entry with the same name exists, the window sits there; otherwise it gets a temporary tile at the end of the Dock for as long as it runs (never saved) |
| *Keep Icon* | makes the tile permanent. Its command is `<name>`, so name the program like the `app_id` (`dockapp:wl-clock`) |
| *Kill* in the tile menu | ends the program (the only way to do it from the compositor) |
| Click on the tile | does not start a second instance while the DockApp runs |

If two DockApps have the same `app_id`, only the oldest is shown in the tile; the second stays invisible
until the first ends.

## Sizes (`scale.zig`)

Window Maker never scales a finished picture: the tile is `IconSize` pixels, and whatever is inside is
drawn at that size, or centred if it is smaller. `scale.zig` does the same for any `dock_size`.

- Everything is designed on a 64×64 tile ("design units"). `scale.Metrics` turns those into whole pixels
  of the real tile. `edge(v)` rounds an edge (0 stays 0, 64 is always the tile side), `len(at, size)` is
  the distance between two rounded edges (neighbours neither overlap nor leave a gap), `stroke(v)` is never
  thinner than 1 px, `whole(v)` is an integer magnification (for pixel fonts), `f(v)` is the exact size
  for antialiased polygons, and `fontDesc` scales a Pango font.
- The host (`dock.zig`) draws tile frames, bevels, the "not running" dots, arrows, fonts and the icon
  margin through `dock.metrics`. PNG icons are placed on whole pixels. At 64 px the result is
  pixel-identical to the unscaled drawing.
- A DockApp without a size hint gets a whole tile (`scale.proposedSide`) and should draw at that size,
  as the two examples do. An image that cannot be redrawn can be adjusted with `scale.centre` (as Window
  Maker does) or `scale.resize` (bilinear or box). That is a fallback, not the intended way.
- `scale.zig` is copied unchanged into each example. Check with
  `diff src/scale.zig examples/*/src/scale.zig`.

## Ordinary programs

*Keep Application* in the Dock or Clip menu creates a launcher for a running program. A click starts the
program or focuses its window. A launcher with no window shows three dots ("not running"). By default a
double click launches, like Window Maker; `dock_single_click = true` makes it one click. A second click
within 1.5 s on a tile that was just launched starts nothing; a middle click and *Launch* in the menu always
start a new instance.

## `WMState`

Dock and Clip are stored in Window Maker's own property list:

```
$XDG_STATE_HOME/wmaker-wl/WMState      (else ~/.local/state/wmaker-wl/WMState)
~/GNUstep/Defaults/WMState             (only with enable_wmaker_compat = true)
```

wmaker-wl writes the first file itself, atomically (temporary file and `rename`), whenever tiles are
moved, added or removed or a switch changes (`dock_save_state = true`). At start it wins over `~/GNUstep`;
an empty saved Dock stays empty. Deleting it goes back to `~/GNUstep` or to the values in `config.lua`.

**Precedence.** The saved switches (`dock_edge`, `dock_offset`, `dock_on_top`, `dock_auto_raise`,
`clip_corner`, `clip_on_top`, `clip_collapsed`, `clip_auto_collapse`, `clip_auto_raise`) only fill in
options that your own `config.lua` does not set. If `config.lua` sets one, the config wins, also after a
restart or `SIGHUP`, and changing that option with the mouse only lasts until then. Delete the line from
`config.lua` to let the mouse decide again. The built-in defaults do not count as "set by you".

What is read and written:

- `Dock`: `Applications`, `Lowered`, `AutoRaiseLower`. The logo tile (`Command = "-"`) anchors the column.
- `Clip`: `Applications` (all workspaces), `Lowered`, `Collapsed`, `AutoCollapse`, `AutoRaiseLower`.
- `Workspaces[i]`: `Name`, and `Clip.Applications` for that workspace only.
- Per entry: `Name`, `Command`, `Position` (`"x,y"`), `AutoLaunch`, `Lock`, `Lowered`.
- wmaker-wl's own keys, which Window Maker ignores: `WMakerWLEdge` and `WMakerWLOffset` in the Dock,
  `WMakerWLCorner` in the Clip, `WMakerWLIcon` and `WMakerWLAppId` per entry, `WMakerWLRow` per drawer.

Order is position: in the Dock `y` counts (the logo tile is 0, entries above it are negative), in the Clip `x`.

A window is matched to an entry through `app_id` instead of `WM_CLASS` (`DockApp.matches`): an explicit
`WMakerWLAppId`, then `dockapp:<name>`, parts of `instance.Class`, the program name, and the last part of a
reverse-DNS `app_id`.

## Grid model (`wm_dock.zig`, from `dock.c`)

Dock, Clip and Drawers share Window Maker's model: every icon has a grid position (`xindex`, `yindex`)
relative to the first tile of its dock.

| Kind | Layout |
|---|---|
| Dock | logo tile and one column (`xindex = 0`); rows may stay empty, also above the logo (`yindex < 0`) |
| Clip | workspace tile in a corner, the applications of the current workspace freely around it, each next to another (`CLIP_ATTACH_VICINITY = 1`); omnipresent tiles follow the workspace |
| Drawer | a tile on the Dock that opens a gapless row towards the middle of the screen; folded (tile only) until the pointer comes (*Autocollapse*) |

As in the original:

- Dragging a tile snaps it with `snapIcon`: first into its own dock, then into the others (Dock, Drawers,
  Clip). Dropped on nothing, it is removed (locked tiles stay).
- New tiles take the first free slot (`findFreeSlot`: a spiral around the Clip tile, along the edge for
  a Clip in a corner).
- A click on a Drawer tile opens or closes it; dragging moves it to another Dock row. *Add a drawer* is in
  the Dock menu; the Drawer menu has *Collapsed*, *Autocollapse* and *Remove drawer*.
- The Dock menu has *Dock position*, *Keep Application*, *Add a drawer* and *Info Panel*.

Dock, Clip and every Drawer are each one surface around their tiles plus a margin where a dragged tile
can still snap in. Only the tiles take pointer input (input region); the rest passes through.

## Robustness

- `Model.layout` moves the Dock only as far as needed to keep every tile and Drawer on screen. When the
  Clip changes corner, its tiles mirror.
- Positions beyond ±4096 tiles (`dockapp.max_grid`) in a state file count as "no position". A Drawer on
  the logo row or on another Drawer's row gets a free row.
- Autocollapse waits 700 ms before folding and 250 ms before unfolding. The timer runs in the `poll` loop
  in `main.zig` (`Ui.nextTimeoutMs`, `Ui.onTimer`).