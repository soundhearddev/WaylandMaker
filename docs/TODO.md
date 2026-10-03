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
- [x] **Phase 5**: Dock und Clip (`dock.zig`, `ui.zig`; `WMState`, 64-px-Kacheln, `app_id`-Zuordnung).
      *Dock:* Spalte aus 64-px-Kacheln am linken/rechten Rand (`dock_edge`, `dock_offset`), erste Kachel
      ist die „WM“-Logo-Kachel, danach die Einträge mit `place = dock`. Linksklick startet das Programm
      oder fokussiert es, wenn schon ein Fenster davon läuft (Vergleich über `DockApp.matches`:
      expliziter `app_id`, `dockapp:<name>`, Teile von `instance.Class`, `--class dockapp:…` im Befehl,
      Programmname); Mittelklick startet immer eine neue Instanz; Rechtsklick öffnet ein Menü (Launch,
      „Lower Dock“/„Keep Dock on Top“). Läuft-Anzeige als kleines Dreieck unten links. PNG-Icons per
      cairo (Pfad oder Name in `hicolor`/`pixmaps`), sonst der erste Buchstabe des Namens.
      Feste 64×64-DockApp-Fenster (`dockapp:<name>`, z. B. `examples/wl-clock`) werden direkt **in ihre
      Kachel gesetzt** (`ui.placeDocked`, über dem Dock gestapelt) und sind `omnipresent`.
      Der Arbeitsbereich schrumpft um das Dock (`Output.reserved`), außer es ist „lowered“ oder
      `dock_reserve_space = false`.
      *Clip:* Kachel mit Workspace-Nummer und -Name, Pfeil oben rechts = nächster, unten links =
      vorheriger Workspace (wie in Window Maker), Mausrad schaltet ebenfalls; daneben in einer Reihe die
      Einträge mit `place = clip`, pro Workspace (`workspace = N`) oder für alle. Rechtsklick: Clip-Menü
      (Collapse/Expand, Lower/Keep on Top, Workspaces), Mittelklick: Workspace-Menü. Ecke über
      `clip_corner`; Workspace-Namen über `workspace_names` oder aus `WMState` (`Workspaces[i].Name`).
      `WMState`: `Dock.Applications` (Logo-Eintrag `Command = "-"` wird nur als Anker gelesen),
      `Clip.Applications` und `Workspaces[i].Clip.Applications`.
      Außerdem behoben: `onRender` stapelt jetzt erst die Fenster und dann Dock/Menüs (`applyRender` hob
      das fokussierte Fenster sonst über ein offenes Menü), und `skip_window_list` blendet Fenster nun
      wirklich aus der Fensterliste aus; der Root-`build.zig` baut wieder `wmaker-wl` (er baute nur
      `wlprefs`).
      *Beispiel-DockApp* `examples/wl-clock` (neu geschrieben): zeichnet die komplette 64×64-Kachel im
      Look der Dock-Kacheln mit eingelassenem LCD, lokale Zeit statt UTC, `--name`/`--tz`/`--label`/
      `--12h`/`--no-seconds`, Klick schaltet 12/24 h, ein Pool mit zwei Buffern statt einem neuen pro
      Sekunde, `poll`-Schleife ohne Leerlauf-CPU, `--snapshot` ohne Compositor. Passend dazu ignoriert
      `action.requestFocus` unfokussierbare Fenster (Hover/Klick auf eine DockApp verschiebt weder Fokus
      noch Streifen).
      *Noch offen:* XPM-Icons; Dock/Clip per Maus verschieben (Position kommt nur aus der Config);
      Einträge per Drag & Drop hinzufügen/entfernen und Zustand zurückschreiben (wmaker-wl schreibt nie
      in Nutzerdateien); „Collapse“ für das Dock; Attract-Icons des Clips; Mehr-Monitor (Dock/Clip
      sitzen auf der ersten Ausgabe).
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
- [x] **DockApp-Erkennung & -Format** (`dockapp.zig`): zwei unabhängige Wege.
      **Primär, ohne jede Konfigurationsdatei:** ein Fenster mit `app_id` `dockapp:<name>` oder
      `dockapp-<name>` wird automatisch erkannt (`isSelfDeclared`, eingehängt in `window.zig`s
      `app_id`-Event und `placeNew`) und bekommt `NoTitlebar`/`NoBorder`/`Floating`/
      `SkipWindowList` als Default-Attribute (`defaultAttrs`) -- eine `attributes.conf`-Regel für
      denselben `app_id` gewinnt weiterhin pro Option. Das ist die Wayland-Entsprechung von X11
      Window Makers `WM_CLASS`/`WM_HINTS`-Selbstdeklaration. **Optional, für Metadaten** (Icon,
      Grid-Position) und Autostart-Listen: gemeinsamer `DockApp`-Typ (Name, Command als argv,
      Icon, Grid-Position, `AutoLaunch`, `Lowered`), zwei Parser auf dieselbe Liste -- Window
      Makers `WMState`-Format (`Dock.Applications`/`Clip.Applications`, GNUstep-Plist) für
      bestehende Setups, und ein eigenes `[name]`-Block-Format (`~/.config/wmaker-wl/dockapps.conf`)
      im Stil von `attributes.conf`. In `wm_files.zig`/`main.zig` eingehängt (analog zu
      `loadMenu`/`findAutostart`): `enable_dockapps` (Default an) lädt die Liste beim
      Sessionstart, `runAutoLaunch()` spawnt `autolaunch = yes`-Einträge einmalig, genau wie der
      bestehende Autostart-Mechanismus (der für den Normalfall "beim Start starten" ohnehin
      bereits ausreicht, siehe `docs/DOCKAPPS.md`), und läuft bei einem SIGHUP-Reload bewusst
      nicht erneut. Zeichnet noch keine Kacheln (das ist weiterhin Phase 5, siehe unten) --
      liefert aber die Datenbasis, die Phase 5 direkt übernehmen kann.

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
- [x] Attribute mit später eintreffender `app_id`/Größen-Hint/Parent: `floating`/`Omnipresent` werden jetzt
      bei jedem dieser Events neu geprüft (`window.zig`s `recheckFloating`), nicht mehr nur beim allerersten
      Platzieren -- genau der Fall, der eine DockApp sonst dauerhaft gekachelt mit vollem Rahmen stehen
      lässt, wenn ihr `app_id`/fixe Größe erst nach `manage_start` eintrifft. `StartWorkspace` bleibt bewusst
      eine reine Erstplatzierungs-Entscheidung -- ein bereits gekacheltes Fenster nachträglich auf einen
      anderen Workspace zu verschieben ist ein größerer, selteneren Eingriff, als eine späte
      DockApp-Deklaration braucht.
- [ ] Optional: Drag-Reordering von Spalten
- [ ] Optional: Animationen beim Scrollen
- [ ] Lauf gegen ein echtes river ist weiterhin unbestätigt für die UI-Schicht (`ui.zig`, `shm.zig`,
      `gfx.zig`); nur `zig build`/`zig build test` sind bisher verifiziert.
- [ ] de layout integration!!
- [x] config keybind exec shell / apps custom (`shell`/`exec`/`shexec` in `action.zig`, siehe
      `process.spawnShell`)
- [ ] **WPrefs-Äquivalent**: Plan und Bestandsaufnahme in `docs/WPREFS.md`. Grundgerüst
      `src/wm_prefs.zig` liegt als reines Skelett (Typen + Signaturen, keine Implementierung)
      vor Phase 5/6, weil eine GUI erst sinnvoll wird, sobald Dock/Clip (Phase 5) und Themes
      (Phase 6) zumindest im Datenmodell existieren.

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