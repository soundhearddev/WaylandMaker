# wlprefs icons

wlprefs shows 16 section icons (Window Maker's own WPrefs artwork, see `Category.icon()` in
`wlprefs/src/root.zig`) and, beyond those, **six icons that nobody has drawn yet**: the Dock edge and the
Clip corner pickers on the Dock Preferences page.

**The rule:** wlprefs does not draw its own icons. Every icon below is a PNG that somebody provides. Until
one exists, the spot shows a clearly marked *fallback*: a grey box, crossed out, with the icon's short name in
it. The page works, and it is obvious which icon belongs where. (The code is `wlprefs/src/icons.zig`; the
table below must list the same files and fallback texts as its `spec()`; a test checks that.)

## Icons wanted

All six are **48 × 48 px PNG** with an alpha channel. A file of another size is not scaled: it is drawn
centred in the 48 × 48 box (and cut off if it is bigger), so it should be exactly this size. A file that is
not a PNG, or whose sides are over the limit in `gfx.max_side`, is ignored and the fallback is shown.

| file | fallback text | label under the button | where it appears |
|---|---|---|---|
| `dock-left.png` | `dock L` | left | Dock Preferences > Dock > Edge: the Dock on the left screen edge |
| `dock-right.png` | `dock R` | right | Dock Preferences > Dock > Edge: the Dock on the right screen edge |
| `clip-top-left.png` | `clip TL` | top left | Dock Preferences > Clip > Corner: the Clip in the top left corner |
| `clip-top-right.png` | `clip TR` | top right | Dock Preferences > Clip > Corner: the Clip in the top right corner |
| `clip-bottom-left.png` | `clip BL` | bottom left | Dock Preferences > Clip > Corner: the Clip in the bottom left corner |
| `clip-bottom-right.png` | `clip BR` | bottom right | Dock Preferences > Clip > Corner: the Clip in the bottom right corner |

The label is always drawn under the button: an icon alone is not a label.

What a good icon shows: the screen as a rectangle, and the Dock (a narrow column of tiles) hugging the
named edge, or the Clip (one tile) in the named corner. Keep it readable on both a light and a dark
background; Window Maker's NeXT-style grey is the usual one.

## Where wlprefs looks

First hit wins:

1. `$WLPREFS_ICON_DIR/<file>`
2. `$XDG_DATA_HOME/wlprefs/icons/<file>` (default `~/.local/share/wlprefs/icons/<file>`)
3. `/usr/local/share/wlprefs/icons/<file>`
4. `/usr/share/wlprefs/icons/<file>`
5. compiled into the binary (`embedded()` in `icons.zig`; empty today)
6. the fallback

So a theme or a packager can supply the icons without rebuilding wlprefs, and you can try one at once:

```sh
mkdir -p ~/.local/share/wlprefs/icons
cp dock-left.png ~/.local/share/wlprefs/icons/
wlprefs            # the Dock > Edge picker now shows it
```

## Shipping an icon with the project

1. Put the PNG into `wlprefs/src/assets/icons/`.
2. In `embedded()` in `wlprefs/src/icons.zig`, return `@embedFile("assets/icons/<file>")` for its id
   (instead of `null`).
3. Run `zig build test-wlprefs`.
   (`build.zig.zon` already lists the whole `wlprefs` directory in `.paths`.)

Only draw or contribute icons you have the right to release under the project's licence (GPL-3.0, or
CC0 / CC-BY-SA for artwork). Do not copy icons from other projects without checking their licence.
