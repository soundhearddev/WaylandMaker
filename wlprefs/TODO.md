- [ ] `menu_submenu_align` – Seite Menu: bleibt offen. Die Menü-Seite ist bewusst „nur Anzeige“, ein echter
      Schalter braucht Klick-Behandlung in `window.zig` und `panel_menu.zig`. **Offene Frage:** Window Makers
      Seite hat zwei Knöpfe zur Submenü-Ausrichtung (`AlignSubmenus`: aus/an, dort geht es um die vertikale
      Ausrichtung am Eltern-Eintrag). Unsere Option ist eine Seite (`left`/`right`). Die zwei Knöpfe passen
      nicht 1:1; wie sollen sie auf `left`/`right` abgebildet werden?
- [ ] **Fensterregeln-Editor** (`WMWindowAttributes` / `attributes.conf`): Tabelle, eine Zeile pro `app_id`.
- [ ] **DockApps-Editor** (`dockapps.conf`): Name, Command, Icon, Position, AutoLaunch.
- [ ] **Root-Menü-Editor** (`RootMenu`).
- [ ] **Live-Vorschau**: "Apply" lädt den Compositor neu, ohne die Datei zu schreiben.
      Heute: Speichern, dann SIGHUP.
- [ ] **HiDPI**: Das Fenster ist fest 520×390 (wie WPrefs).
- [ ] **Die 6 Dock-/Clip-Icons**: noch Platzhalter, siehe `docs/WLPREFS-ICONS.md`.
- [ ] Mehrfachauswahl.
- [ ] Zeilen verschieben.
- [ ] Aufnahme von Tasten aus höheren Ebenen (AltGr) testen: bisher ungetestet.
- [ ] **Mehrere Anweisungen in einer Zeile** (`a = 1; b = 2`) werden bewusst nicht angefasst.