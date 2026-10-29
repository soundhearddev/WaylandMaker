# Themes and the look

Window Maker keeps how things *look* apart from how they *behave*: a style is a set of named colours, textures
and fonts you can swap without touching anything else. wmaker-wl does the same.

```text
config.lua ── theme("nord") ── Themes/nord.lua      set the look options
      │
      ▼
config.Config                                       one reload = one set of values
      │   style.apply(cfg)   (boot.loadModel, at start and on every reload)
      ▼
style.palette, gfx.fonts                            what the drawing code reads
      │
      ▼
dock_draw.render  ──▶  tile cache (dropped on reload)  ──▶  scene buffers
```

The drawing code never sees the `Config`. Colours and fonts are copied out of the config arena, so a reload that
frees the old arena cannot leave a dangling pointer.

## What a theme can set

Only look, nothing that acts. A theme runs with an **empty Lua environment** (no `bind`, no `os`) and anything
else in it is a warning.

| Option | What |
|---|---|
| `border_width`, `gap`, `outer_gap` | window frames and spacing |
| `border_focused`, `border_unfocused`, `border_floating` | frame colours |
| `tile_from`, `tile_to` | app, Clip and Drawer tiles: diagonal gradient |
| `tile_hot_from`, `tile_hot_to` | the same under the pointer |
| `logo_from`, `logo_to`, `logo_text` | the Dock's first tile ("WM") and the title bar of a placeholder icon |
| `tile_text` | workspace number and name in the Clip |
| `bevel_light`, `bevel_dark` | the two-line NeXT bevel |
| `arrow`, `arrow_hot` | the Clip's workspace arrows, the Drawers' chevrons |
| `font_menu_title`, `font_menu`, `font_dock`, `font_dock_logo`, `font_dock_number` | Pango font descriptions |

Colours are `"#rrggbb"`, `"rrggbb"`, `"0xrrggbb"` or a number. The defaults are Window Maker's NeXT look,
pixel for pixel what the Dock drew before this was configurable.

## Using one

```lua
-- ~/.config/wmaker-wl/config.lua
theme("graphite")
border_focused = "#ff8800"     -- lines after theme() win over it
```

Then `Super+Shift+r` (or `pkill -HUP wmaker-wl`). Looked up in `~/.config/wmaker-wl/Themes/NAME.lua`, then
`/usr/local/share/wmaker-wl/Themes`, then `/usr/share/wmaker-wl/Themes`. A name is a file name, never a path.

Shipped (`src/share/Themes/`): `next` (the default Dock plus grey frames), `gruvbox`, `nord`, `graphite`.

## Writing one

Copy `next.lua` and change colours. A theme that fails halfway is dropped as a whole, so you never get half a
look. `wmaker-wl --check` reports problems with the line number.

## Not yet

Menus and title bars are not ported to the wlroots build (see `TODO wlroots.md`). When they are, their colours
join `style.Palette`; `font_menu_title` and `font_menu` are already applied to `gfx.fonts` for them.
