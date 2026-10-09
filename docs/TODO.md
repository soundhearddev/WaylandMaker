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
- [x] **wlprefs** (`wlprefs/`, siehe `docs/WMPREFS.md` „Stand“): lädt `config.conf` jetzt wirklich (der
      erste Entwurf las die Datei nie und ersetzte sie beim ersten Speichern durch die paar Zeilen, die
      von den Standardwerten abwichen), speichert nur geänderte Schlüssel in der Datei selbst,
      atomar mit Backup, sperrt sich bei unlesbarer Datei, deckt alle Dock-/Clip-/Workspace-Namen-/
      Preset-/Maus-Modifier-Schlüssel ab, zeigt die wirksamen Tastenkürzel, hat einen Bild-Fallback statt
      selbstgemalter Icons (`docs/WLPREFS-ICONS.md`) und eine `poll`-Schleife, die SIGTERM sauber
      beendet (libwayland wiederholt `poll` bei EINTR, ein blockierendes `dispatch()` hätte nie
      zurückgekehrt).
      Danach nachgerüstet: **Tastenkürzel bearbeiten** (Auswahl, Add/Edit/Remove, Aufnahme per Tastendruck
      mit Prüfung von Taste *und* Aktion; geschrieben wird die kleinste Menge `bind`/`unbind`-Zeilen, die
      aus den Standardwerten die bearbeitete Liste macht), `bind_layout` und `theme` als Felder,
      **Defaults**-Knopf je Seite, Cursor-Bearbeitung (Pfeile, Pos1/Ende, Entf, Klick setzt den Cursor),
      Tab/Shift+Tab zwischen Feldern, Status unter den Knöpfen statt über ihnen.
      *Noch offen in wlprefs:*
      - Tastenkürzel **bearbeiten** (Tabelle mit Aufnahme per Tastendruck; die Anzeige gibt es);
      - Fensterregeln (`attributes.conf`) und DockApp-Editor (`dockapps.conf`) als eigene Seiten;
      - Root-Menü-Editor (`RootMenu`);
      - die 6 Dock-/Clip-Icons (`docs/WLPREFS-ICONS.md`), bis dahin Platzhalter;
      - Schriftseite (hängt an Titelleisten); Theme-Auswahl aus der Liste statt Textfeld;
      - HiDPI/Skalierung (das Fenster ist fest 520×390 wie WPrefs);
      - Live-Vorschau der Änderungen (heute: Speichern → SIGHUP);
      - Mehrfachauswahl und Verschieben von Zeilen in der Kürzelliste; Aufnahme von Kürzeln mit Zeichen
        aus höheren Ebenen (AltGr) ist ungetestet;
      - ein gleichzeitig von Hand geänderter `bind`-Block wird beim Speichern der Kürzel ersetzt (alles
        andere bleibt, siehe `settings.render`);
      - die Menü-Seite wird erst echt, wenn wmaker-wl diese Optionen hat.
- [x] **Phase 5**: Dock und Clip (`dock.zig`, `ui.zig`; `WMState`, 64-px-Kacheln, `app_id`-Zuordnung).
      *Dock:* Spalte aus 64-px-Kacheln am linken/rechten Rand (`dock_edge`, `dock_offset`), erste Kachel
      ist die „WM“-Logo-Kachel, danach die Einträge mit `place = dock`. Linksklick startet das Programm
      oder fokussiert es, wenn schon ein Fenster davon läuft (Vergleich über `DockApp.matches`:
      expliziter `app_id`, `dockapp:<name>`, Teile von `instance.Class`, `--class dockapp:…` im Befehl,
      Programmname); Mittelklick startet immer eine neue Instanz; Rechtsklick öffnet ein Menü (Launch,
      „Lower Dock“/„Keep Dock on Top“). Anzeige „läuft nicht“ siehe Dock-Überarbeitung unten. PNG-Icons per
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
      *XPM-Icons* (`xpm.zig`): Window Makers eigenes Icon-Format wird gelesen (1-4 Zeichen je Pixel,
      `None`, `#RGB`…`#RRRRGGGGBBBB`, `grayNN`, übliche X11-Namen; unbekannte Farbe = Magenta, damit ein
      falsches Icon auffällt). Größen werden vor jeder Allokation geprüft; kaputte Dateien lassen das Dock
      nie scheitern (die Kachel zeigt dann den Buchstaben).
      *Noch offen:* SVG-Icons; Drawers; „Settings…“-Dialog und „Rename Workspace“ (brauchen eigene
      Texteingabe); Attract-Icons des Clips; Mehr-Monitor (Dock/Clip sitzen auf der ersten Ausgabe);
      Verzögerung für Autocollapse/Auto raise (es gibt keine Timer).
- [x] **Dock-Überarbeitung nach Window Makers Dock-System** (`dock.zig`, `dockapp.zig`, `ui.zig`,
      `wm_files.zig`): Doppelklick startet (`dock_single_click` für einen Klick); *nicht* laufende Kachel =
      drei Punkte unten links wie `dock_dots`, gerade gestartet = Raster (`launching`), Clip-Einträge auf
      allen Workspaces = Eselsohr; Ziehen sortiert um, entfernt (weit weg loslassen) und verschiebt Dock
      (Logo-Kachel, Rand und Offset) und Clip (Ecke); Menüs wie bei Window Maker (*Dock position*,
      *Clip Options*, *Launch*, *Bring Here*, *Hide*, *Lock*, *Remove Icon*, *Kill*, *Keep Application*);
      Stapelebenen *normal / auto / top* (`dock_level`); Clip *Autocollapse*/*Autoraise*. Zustand in
      eigener Datei `$XDG_STATE_HOME/wmaker-wl/dock.conf`, atomar geschrieben, beim Start vor
      `dockapps.conf` gelesen. Die fehlende `src/share/dockapps.conf` (der Test erwartete sie) ist
      ergänzt. Details und Abweichungen vom Original: `docs/DOCKAPPS.md`.
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
- [x] **Phase 6 (der machbare Teil): Themes und `include`.** `theme = NAME` liest `Themes/NAME.conf`
      (neben der `config.conf`, sonst `/usr/local/share/` und `/usr/share/wmaker-wl/Themes/`), `include = DATEI`
      liest eine beliebige Datei an dieser Stelle (spätere Zeilen überschreiben, Tiefe höchstens 4, relativ zur
      einbindenden Datei, `~/` geht). Ein Theme darf **nur** Farben, `border_width` und Gaps setzen; alles
      andere (Tastenkürzel, Programme, `include`) wird mit Warnung ignoriert, ein heruntergeladenes Theme
      kann also nichts ausführen. Namen sind Dateinamen (kein `/`, kein `..`). Drei Beispiele in
      `src/share/Themes/` (`gruvbox` = das eingebaute Aussehen, `nord`, `next`); `Config.parse_warnings`
      zählt übersprungene Zeilen, die eingebaute Config und die Themes sind darauf getestet.
      *Noch offen:* Schriften in Themes (hängt an Titelleisten); Window-Maker-Themes (`.themed`-Archive,
      `~/GNUstep/Defaults/WindowMaker`) lesen; Theme-Liste/Auswahl in wlprefs (heute ein Textfeld); wlprefs
      zeigt Werte, die nur ein `include`/`theme` setzt, nicht an (es schreibt aber nie darüber).
- [x] **Phase 7 (Teil): Minimieren und Verstecken.** `minimize`, `restore` (zuletzt minimiertes),
      `show_all`, `hide_others`, `hide_app` als Tastenkürzel (Standard: `Super+n`, `Super+Shift+n`,
      `Super+Ctrl+n`, `Super+o`) und als Menüpunkte `HIDE_OTHERS`/`SHOW_ALL`. Ein minimiertes Fenster
      verlässt den Streifen (`workspace == null`, wird dadurch von der Render-Runde versteckt), merkt sich
      Spalte, Breite bzw. Rechteck und kommt auf den **aktuellen** Workspace zurück. Im Fenster-Menü steht es
      als `(Titel)`; Auswählen oder ein Klick auf seine Dock-/Clip-Kachel holt es zurück. DockApps werden nie
      versteckt. Workspace-Namen: `workspace_names` / `WMState`, im Clip und im Workspace-Menü.
      *Noch offen:* Shade (braucht Titelleisten); Session speichern (siehe unten); Miniwindows als Icons.
- [x] **Menüpunkte `SHUTDOWN`, `INFO_PANEL`, `LEGAL_PANEL`, `OPEN_MENU`** (`fsmenu.zig`, `ui.zig`):
      SHUTDOWN bittet alle Fenster zu schließen und beendet wmaker-wl; Info/Legal sind Untermenüs mit
      Text (Version, Config-Pfad, 0BSD). `OPEN_MENU` macht aus einem **Verzeichnis** ein Menü (Ordner zuerst,
      Dateien öffnen mit `WITH Programm` oder `xdg-open`, Pfade korrekt gequotet, Tiefe 3, höchstens
      200 Einträge je Ordner und 1000 insgesamt, Dotfiles ausgelassen) oder bindet eine **Menüdatei** ein;
      aufgebaut beim Öffnen, nie veraltet. `OPEN_MENU | befehl` wird bewusst nicht ausgeführt (ein
      langsames Programm würde beim Menüöffnen den ganzen Desktop anhalten) und erscheint ausgegraut.
      *Noch offen:* `RESTART` und `SAVE_SESSION` (siehe `--restart` oben).
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
- [x] Menüs, die höher als der Output sind, **scrollen**: sie werden auf das gekürzt, was passt (Pfeile
      oben/unten zeigen, wo es weitergeht), Mausrad/Touchpad scrollt drei Zeilen je Raste, die Pfeiltasten
      holen die Auswahl in den sichtbaren Bereich.
- [x] Fenster, die während offenem Menü geschlossen werden, entfernen ihre Zeile korrekt (`forgetWindow`)
      und das Menü redrawt sich noch in derselben manage-Sequenz (`window_mod.reap()` läuft vor `u.sync()`
      in `onManage()`, mit Reihenfolge-Regressionstest abgesichert). War bereits so, nur nicht verifiziert.

### Sonstiges
- [x] Mehrere Outputs: `focus_output_next/prev` (Standard `Super+Alt+←/→`) wechselt den Monitor, auf dem
      gearbeitet wird -- auch auf einen **leeren** (`wm.active_output`); `move_to_output_next/prev`
      (`Super+Alt+Shift+←/→`) nimmt das fokussierte Fenster mit. Wo neue Fenster aufgehen und was
      „aktueller Output“ ist, entscheidet jetzt eine Stelle (`types.workingOutput`). Das Clip wirkt auf den
      Output, auf dem es sitzt. *Noch offen:* Dock/Clip nur auf dem ersten Output; Fenster per Maus über die
      Monitorkante ziehen ist getestet nur im Modell.
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
- [x] **Tastaturlayout (de)**: Tasten lassen sich als Zeichen schreiben (`bind = Super+ü, ...`, `Super+ß`),
      und `bind_layout = 0..3` legt alle Kürzel auf ein Layout der Tastatur fest
      (`river_xkb_binding_v1.set_layout_override`), damit `Super+q` nach dem Umschalten us ↔ de dieselbe
      Taste bleibt; `current` (Standard) folgt dem aktiven Layout. In wlprefs unter Keyboard Shortcuts.
- [x] config keybind exec shell / apps custom (`shell`/`exec`/`shexec` in `action.zig`, siehe
      `process.spawnShell`)


### Ideen, noch nicht begonnen (nach Nutzen sortiert)
- [ ] **Titelleisten** (Phase 3): braucht `river_decoration_v1`-Flächen pro Fenster, eine reservierte Höhe im
      Layout (`layout.zig` rechnet heute mit der ganzen Zelle) und Eingabe auf den Dekorationsflächen --
      lässt sich ohne laufendes river nicht verlässlich prüfen. Reihenfolge: Zeichnen als reine Funktion
      (testbar, wie `dock.zig`), dann Layout-Höhe, dann Eingabe. Danach: Shade, Schriften in Themes.
- [ ] **Session speichern** (`SAVE_SESSION`, Fenster + Workspaces + Spalten): nur sinnvoll, wenn Programme
      wiedererkannt und gestartet werden; erst `app_id` → Startbefehl-Zuordnung (hat `dockapps.conf` schon).
- [ ] **Mehrere Seats**: Menü und Dock gehören heute dem ersten Seat.
- [ ] **Dock/Clip mit der Maus verschieben, Drag & Drop von Einträgen**: ohne Zurückschreiben nutzlos
      (wmaker-wl schreibt nie in Nutzerdateien); denkbar über wlprefs.
- [ ] **Dock/Clip auf jedem Output** (oder pro Output wählbar).
- [ ] **`--check` für wlprefs/wmaker-wl**: Config laden, `parse_warnings` und unlesbare Dateien melden, mit
      Exit-Code (für Dotfile-Pipelines).
- [ ] **Fuzzing** der Parser (`plist`, `xpm`, `wm_menu`, `config`): die Schleifen sind begrenzt und getestet,
      ein Fuzz-Lauf fehlt.
- [ ] **Animationen** beim Scrollen und Drag-Reordering von Spalten (optional).

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