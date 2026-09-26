## Offen

### Window-Maker-Integration
- [x] **Phase 2**: Zeichen-Infrastruktur (`wl_shm` mit überprüfter, überlaufsicherer Größe in `shm.zig`,
      cairo/pango in `gfx.zig`, `wl_seat`-Bindung in `ui.zig`). Läuft weiterhin über `display.dispatch()`,
      kein `poll()`-Umbau nötig gewesen.
- [ ] **Phase 3**: Titelleisten im NeXTSTEP-Look (`river_decoration_v1`), `NoTitlebar` & Co. wirksam
- [x] **Phase 4**: Root-Menü wird angezeigt (rechte Taste auf dem leeren Desktop öffnet es, mittlere Taste
      die Fensterliste), kaskadierende Untermenüs, Tastatur (Pfeile/Enter/Esc/Links schließt eine Ebene),
      `SHORTCUT`-Anzeige. Zeiger-Cursor wechselt über Menü/Desktop korrekt zum Pfeil
      (`wp_cursor_shape_manager_v1`), und ein durch Hovern geschlossenes Untermenü verschwindet sofort statt
      erst im nächsten Zyklus (`reapGraveyard()`-Reihenfolge in `sync()` korrigiert).
- [ ] **Phase 5**: Dock und Clip (`WMState`/wlmaker-State, 64-px-Kacheln, `app_id`-Zuordnung)
- [x] **Live-Config-Reload (SIGHUP)**: `kill -HUP <pid>` liest `config.conf`, `RootMenu` und
      `WMWindowAttributes` neu ein und ersetzt alle Tastenkürzel im laufenden Betrieb, ohne Fenster oder
      Layout anzufassen (Autostart läuft bewusst nicht erneut). Signalhandler setzt nur ein Flag
      (async-signal-sicher); die eigentliche Arbeit (Bindings zerstören/neu erzeugen) läuft in der nächsten
      manage-Sequenz, dorthin geweckt durch `EINTR` in `display.dispatch()`. `main()` und der Reload-Pfad
      laden `wm.commands`/`wm.root_menu`/`wm.attrs` über dieselbe Funktion (`loadFromConfigImpl`), weil alle
      drei aus derselben Config-Arena stammen — sonst würde eines davon nach dem Reload auf freigegebenen
      Speicher zeigen. Bereits gequeute Tastenkürzel-Befehle (`wm.pending`) werden vor dem Freigeben der
      alten Arena noch abgearbeitet, da `.spawn`-Befehle Zeiger in diese Arena halten. Ein fehlerhaftes
      Reload (kaputte Datei, OOM) fällt sauber auf die vorherige Config zurück. Ein offenes Root-Menü ist
      von alldem unberührt: es kopiert seine Daten beim Öffnen bereits in eine eigene Arena.
- [ ] **`wmaker-wl --restart`/Root-Menü-Eintrag `RESTART`**: bewusst noch nicht umgesetzt. Ein echter
      Prozess-Neustart (`execve` auf sich selbst) würde die bestehende `river_window_manager_v1`-Verbindung
      kappen; ob/wie river danach einen neuen WM-Client akzeptiert, ohne dass alle verwalteten Fenster
      unverwaltet zurückbleiben, ist ungeklärt (siehe Phase 7 unten) — SIGHUP-Reload deckt den eigentlichen
      Bedarf ("neue Config ohne Sitzung neu zu starten") inzwischen ab.
- [ ] **Phase 6**: Themes, `~/GNUstep/Defaults/WindowMaker`-Schlüssel
- [ ] **Phase 7**: Minimieren/Shade/Verstecken, Session speichern, Workspace-Namen
- [ ] Menüpunkte ohne Funktion: `RESTART`, `SHUTDOWN`, `INFO_PANEL`, `LEGAL_PANEL`, `OPEN_MENU`
- [ ] Dock apps framework und integration. am besten einen standart für alle kommenden dock apps

### Root-Menü: bekannte Lücken
- [ ] Menü läuft ausschließlich über den ersten gebundenen `wl_seat`; bei mehreren Seats bekommen weitere
      keinen Zeiger/keine Tastatur fürs Menü.
- [ ] Kein Scrollen bei einem Menü, das höher als der Output ist (wird an den oberen Rand geklemmt, der
      untere Teil ragt ggf. heraus).
- [x] Fenster, die während offenem Menü geschlossen werden, entfernen ihre Zeile korrekt (`forgetWindow`)
      und das Menü redrawt sich noch in derselben manage-Sequenz (`window_mod.reap()` läuft vor `u.sync()`
      in `onManage()`, mit Reihenfolge-Regressionstest abgesichert). War bereits so, nur nicht verifiziert.

### Sonstiges
- [ ] Mehrere Outputs: Fokus zwischen Monitoren, Fenster verschieben
- [ ] Attribute mit später eintreffender `app_id`: Ort (Workspace, floating) wird nur beim ersten Platzieren entschieden
- [ ] Optional: Drag-Reordering von Spalten
- [ ] Optional: Animationen beim Scrollen
- [ ] Lauf gegen ein echtes river ist weiterhin unbestätigt für die UI-Schicht (`ui.zig`, `shm.zig`,
      `gfx.zig`); nur `zig build`/`zig build test` sind bisher verifiziert.

## Erledigt

- [x] Ein Modus pro Fenster; Tiling/Floating/Fullscreen ohne leere Spalten
- [x] Neue Fenster werden sofort platziert (kein Warten auf `dimensions`)
- [x] Scrollen folgt dem Fokus und bleibt im gültigen Bereich
- [x] Maus-Operation als Zustandsmaschine mit kumulativem `op_delta`
- [x] Config wirkt (Gaps, Borders, Farben, Keybinds); alte Optionsnamen als Aliase
- [x] Layer-Shell-Arbeitsbereich für Leisten
- [x] **Window-Maker-Formate**: Plist-Parser, Root-Menü (Plist- und Text-Format), `WMWindowAttributes`
- [x] **Config-Handling**: `~/GNUstep` bzw. `$WMAKER_USER_ROOT` und `~/.config/wmaker-wl`, Zeilennummern in Fehlern
- [x] **Autostart**: `~/.config/wmaker-wl/autostart` bzw. `~/GNUstep/Library/WindowMaker/autostart`, einmalig und
      entkoppelt beim Sessionstart über `/bin/sh` ausgeführt (`enable_autostart`, Standard an)
- [x] **Attribute wirksam**: `StartWorkspace`, `Omnipresent`, `KeepOnTop`, `StartMaximized`, `NoBorder`, `Unfocusable`, `Floating`
- [x] **Root-Menü sichtbar**: `ui.zig` zeichnet mit cairo/pango in `wl_shm`-Buffer, ein transparentes
      Desktop-Catcher-Surface pro Output fängt Rechts-/Mittelklick auf dem freien Desktop ab, Menüs laufen
      über `river_shell_surface_v1`-Nodes
- [x] **Robustheit der Menü-/Zeichen-Schicht**: geprüfte, überlaufsichere `wl_shm`-Puffergröße
      (`shm.checkedSize`, Obergrenze 16384 px/Seite bzw. 256 MiB), Zeilenlimit pro Menü (`max_rows`),
      UTF-8-sichere Label-Kürzung ohne eingebettetes NUL (`clipUtf8`), Tiefen-/Item-/Warnungslimits beim
      Parsen von `RootMenu` (`MAX_MENU_DEPTH`, `MAX_ITEMS_PER_MENU`, `MAX_WARNINGS`) gegen kaputte oder
      böswillige Menüdateien
- [x] **Zeiger-Cursor über Root-Menü/Desktop**: wechselt via `wp_cursor_shape_manager_v1` zur normalen
      Pfeilform, statt das zuletzt von einem Fenster gesetzte Bild zu behalten
- [x] **Menü-Overlap beim Hovern behoben**: ein durch Hovern geschlossenes Untermenü wird noch in derselben
      Sequenz zerstört (`reapGraveyard()` läuft am Ende von `sync()`), statt bis zum nächsten Zyklus mit dem
      letzten Frame sichtbar zu bleiben