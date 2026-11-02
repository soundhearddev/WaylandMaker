# wlprefs TODO

- [ ] `menu_submenu_align` (Menu page): stays open. The Menu page is deliberately display only; a real switch
      needs click handling in `window.zig` and `panel_menu.zig`. **Open question:** Window Maker's page has two
      buttons for submenu alignment (`AlignSubmenus`: off/on, which is about the vertical alignment with the
      parent entry). Our option is one setting (`left`/`right`). The two buttons do not map 1:1; how should
      they be mapped onto `left`/`right`?
- [ ] **Window rules editor** (`WMWindowAttributes` / `attributes.conf`): a table, one row per `app_id`.
- [ ] **DockApps editor** (`dockapps.conf`): name, command, icon, position, AutoLaunch.
- [ ] **Root menu editor** (`RootMenu`).
- [ ] **Live preview**: "Apply" reloads the compositor without writing the file.
      Today: save, then SIGHUP.
- [ ] **HiDPI**: the window is a fixed 520×390 (like WPrefs).
- [ ] **The 6 Dock/Clip icons**: still placeholders, see [`docs/WLPREFS-ICONS.md`](../docs/WLPREFS-ICONS.md).
- [ ] Multiple selection.
- [ ] Moving rows.
- [ ] Test capturing keys from higher levels (AltGr): untested so far.
- [ ] **Several statements on one line** (`a = 1; b = 2`) are deliberately left alone.
