# wlprefs: was noch fehlt

Stand: nach der Lua-Umstellung. Alles hier ist **noch nicht gemacht und nicht getestet**.
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
      Schalter braucht Klick-Behandlung in `window.zig` und `panel_menu.zig`.

Danach `docs/WMPREFS.md` (Tabelle "Echte Seiten") ergänzen.

---

## 2. Kleine, nützliche Dinge

- [ ] **`wlprefs --check`**: Config laden, Warnungen und unlesbare Dateien melden, Exit-Code ungleich 0
      bei Problemen. Hilft bei Skripten und beim Testen. (`wlprefs/src/main.zig`)
- [ ] **Theme-Liste statt Textfeld**: `Themes/*.lua` neben der Config und in `/usr/share/wmaker-wl/Themes`
      auflisten, Auswahl per Klick, Farben als kleine Vorschau. (`panels.zig`, Seite Appearance)
- [ ] **Hinweis bei berechneten Werten**: steht in der Config `gap = base * 2`, zeigt wlprefs den
      Standardwert. Ein Symbol oder Tooltip "wird im Skript berechnet, wird nicht überschrieben" wäre ehrlicher.
- [ ] **Hinweis bei Binds aus Schleifen**: Binds aus `for ... do bind(...) end` fehlen in der Kürzelliste.
      Eine Zeile "N Binds kommen aus berechnetem Code" unter der Liste.
- [ ] **Strengere Typprüfung**: `gap = "12"` (String) zeigt wlprefs als 12, der Compositor lehnt es ab.
      In `plainValue` (`settings.zig`) Typen prüfen.

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
- [ ] Wurden die `bind`-Zeilen zwischendurch von Hand geändert, ersetzt Speichern den ganzen Block.
      Besser: nur die wirklich geänderten Zeilen anfassen.

---

## 5. Schwächen der Lua-Umstellung

- [ ] **Mehrzeilige Strings** (`[[ ... ]]` über mehrere Zeilen) erkennt der Zeilenparser nicht
      (`wlprefs/src/lualine.zig`). Solche Zeilen bleiben unberührt, wlprefs sieht sie aber auch nicht.
- [ ] **Mehrere Anweisungen in einer Zeile** (`a = 1; b = 2`) werden bewusst nicht angefasst.
- [ ] **Test mit echter Config**: ein Test, der eine Config mit `include(...)` und `theme(...)` mit dem
      echten Lua-Parser lädt und mit wlprefs vergleicht. Heute decken die Abgleichstests in
      `src/model_test.zig` die Schlüssel ab, nicht die Sonderfälle.
- [ ] **Speicherlimit für Config-Skripte** (Compositor, `src/lua.zig`): Es gibt ein Zeitlimit, aber ein Skript
      kann viel Speicher anfordern (`string.rep`). Dafür bräuchte es einen begrenzten Allocator.

---

## Reihenfolge-Vorschlag

1. Abschnitt 1 (die zehn fehlenden Einstellungen).
2. `--check`.
3. Theme-Liste.
4. Hinweise bei berechneten Werten und Schleifen-Binds.
5. Fensterregeln-Editor.