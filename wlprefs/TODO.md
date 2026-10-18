# wlprefs: was noch fehlt

Stand: nach der Lua-Umstellung und der Runde mit `--check`, Theme-Liste, Hinweisen und Typprüfung. Was
unten mit `[x]` steht, ist umgesetzt und durch Tests abgedeckt (`zig build test-wlprefs`: 92, `zig build test`: 301).
Die Offenen sind **noch nicht gemacht**.
Sortiert nach: großer Nutzen, kleiner Aufwand zuerst.

---

## 1. Fehlende Einstellungen (zuerst, am einfachsten)

Der Compositor kennt diese Optionen, wlprefs zeigt sie nicht an. Jede braucht dasselbe:
einen Eintrag in `keys` und ein Feld in `Settings` (`wlprefs/src/settings.zig`), ein Widget auf der
passenden Seite (`wlprefs/src/panels.zig`) und die Standardwerte stehen schon in `default_config.lua`.
Der vorhandene Test "every key has a text form" und der Abgleichstest in `src/model_test.zig`
decken neue Schlüssel automatisch mit ab.

- [x] `focus_new_windows` – Seite Window Focus (Checkbox)
- [x] `workspace_wrap` – Seite Workspace (Checkbox)
- [x] `clip_scroll_workspaces` – Seite Other Configurations (Checkbox)
- [x] `dock_auto_raise` – Seite Other Configurations (Checkbox)
- [x] `dock_single_click` – Seite Other Configurations (Checkbox)
- [x] `dock_save_state` – Seite Other Configurations (Checkbox)
- [x] `clip_auto_collapse` – Seite Other Configurations (Checkbox)
- [x] `clip_auto_raise` – Seite Other Configurations (Checkbox)
- [x] `font_menu_title`, `font_menu`, `font_dock` – Seite Fonts (drei Textfelder, Prüfung mit `validFont`)
- [ ] `menu_submenu_align` – Seite Menu: bleibt offen. Die Menü-Seite ist bewusst „nur Anzeige“, ein echter
      Schalter braucht Klick-Behandlung in `window.zig` und `panel_menu.zig`. **Offene Frage:** Window Makers
      Seite hat zwei Knöpfe zur Submenü-Ausrichtung (`AlignSubmenus`: aus/an, dort geht es um die vertikale
      Ausrichtung am Eltern-Eintrag). Unsere Option ist eine Seite (`left`/`right`). Die zwei Knöpfe passen
      nicht 1:1; wie sollen sie auf `left`/`right` abgebildet werden?

Danach `docs/WMPREFS.md` (Tabelle "Echte Seiten") ergänzen.

---

## 2. Kleine, nützliche Dinge

- [x] **`wlprefs --check`** (`check.zig`, `main.zig`): lädt die Config wie das Fenster, meldet unlesbare
      Datei, Werte der falschen Art und nicht speicherbare Werte mit Exit-Code 1; berechnete Werte und
      Schleifen-Binds sind Hinweise (Exit-Code 0).
- [x] **Theme-Liste statt Textfeld** (`themes.zig`, `panels.zig`, Seite Appearance): `Themes/*.lua` neben der
      Config und in `/usr/local/share/wmaker-wl/Themes` und `/usr/share/wmaker-wl/Themes` (wie der Compositor,
      gleiche Namen früherer Verzeichnisse verdecken spätere), Auswahl per Klick, die drei Rahmenfarben als
      Vorschau, „(none)“, ein nicht installiertes Theme bleibt sichtbar. *Noch offen:* Mausrad auf der Liste.
- [x] **Hinweis bei berechneten Werten**: `Settings.odd` merkt sich pro Schlüssel „berechnet“ oder „falsche Art“;
      die Statuszeile der Seite sagt es („gap (computed): shown with the default; changing it here replaces
      the line“). Ohne Änderung des Schlüssels bleibt die Zeile Byte für Byte erhalten; ändert der Nutzer ihn,
      ersetzt der gewählte Wert die Zeile (wie schon vorher getestet).
- [x] **Hinweis bei Binds aus Schleifen**: `binds.computedBindLines` zählt Zeilen, die Binds auf eine Art
      machen, die die Liste nicht lesen kann; die Seite sagt „N lines in config.lua make more binds …“.
- [x] **Strengere Typprüfung**: `parse` prüft Art des Literals gegen die Art des Schlüssels (Zahl, Bool,
      String, Tabelle); `gap = "12"` ist „falsche Art“ und wird nicht als 12 gezeigt.

---

## 3. Größere Vorhaben

- [ ] **Fensterregeln-Editor** (`WMWindowAttributes` / `attributes.conf`): Tabelle, eine Zeile pro `app_id`.
- [ ] **DockApps-Editor** (`dockapps.conf`): Name, Command, Icon, Position, AutoLaunch.
- [ ] **Root-Menü-Editor** (`RootMenu`).
- [ ] **Live-Vorschau**: "Apply" lädt den Compositor neu, ohne die Datei zu schreiben.
      Heute: Speichern, dann SIGHUP.
- [ ] **HiDPI**: Das Fenster ist fest 520×390 (wie WPrefs).
- [ ] **Die 6 Dock-/Clip-Icons**: noch Platzhalter, siehe `docs/WLPREFS-ICONS.md`.

---

## 4. Kürzelliste verbessern

- [ ] Mehrfachauswahl.
- [ ] Zeilen verschieben.
- [ ] Aufnahme von Tasten aus höheren Ebenen (AltGr) testen: bisher ungetestet.
- [x] Speichern fasst nur die wirklich geänderten `bind`-/`unbind`-Zeilen an (`binds.rewriteUserLines`):
      eine Zeile, die noch gewollt ist (gleiche Taste, gleiche Aktion), bleibt mit Schreibweise und Kommentar
      an ihrer Stelle; fehlende kommen hinter die letzte stehengebliebene Bind-Zeile.

---

## 5. Schwächen der Lua-Umstellung

- [x] **Mehrzeilige Strings und Block-Kommentare** (`[[ ... ]]`, `[==[ ... ]==]`, `--[[ ... ]]` über mehrere
      Zeilen, beliebiger Level): der Zeilenparser folgt ihnen von Zeile zu Zeile (`lualine.Lexer`), Zeilen darin
      sind Text und werden weder gelesen noch umgeschrieben.
- [ ] **Mehrere Anweisungen in einer Zeile** (`a = 1; b = 2`) werden bewusst nicht angefasst.
- [x] **Test mit echter Config** (`src/model_test.zig`): eine Config mit `theme(...)`, `include(...)` und
      `gap = gap + 2` läuft durch den echten Lua-Parser und durch wlprefs; nach dem Bearbeiten einer anderen
      Option liest der Compositor sie unverändert plus die Änderung.
- [x] **Speicherlimit für Config-Skripte** (`src/lua.zig`): ein zählender Allocator begrenzt jeden Lua-State auf
      64 MiB; `string.rep` mit Hunderten MiB und ein endlos wachsendes Table enden als Skriptfehler.

---

## Reihenfolge-Vorschlag

1. `menu_submenu_align` (wartet auf die Frage oben).
2. Fensterregeln-Editor (`WMWindowAttributes`, nach dem Vorbild des Window-Inspector-Panels von Window Maker).
3. DockApps-Editor, Root-Menü-Editor.