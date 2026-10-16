## Offen

### Window-Maker-Integration
- [x] **Phase 2**: Zeichen-Infrastruktur (`wl_shm` mit überprüfter, überlaufsicherer Größe in `shm.zig`,
      cairo/pango in `gfx.zig`, `wl_seat`-Bindung in `ui.zig`). Läuft weiterhin über `display.dispatch()`,
      kein `poll()`-Umbau nötig gewesen.
- [x] **Phase 3**: Root-Menü wird angezeigt (rechte Taste auf dem leeren Desktop öffnet es, mittlere Taste
      die Fensterliste), kaskadierende Untermenüs, Tastatur (Pfeile/Enter/Esc/Links schließt eine Ebene),
      `SHORTCUT`-Anzeige. Zeiger-Cursor wechselt über Menü/Desktop korrekt zum Pfeil
      (`wp_cursor_shape_manager_v1`), und ein durch Hovern geschlossenes Untermenü verschwindet sofort statt
      erst im nächsten Zyklus (`reapGraveyard()`-Reihenfolge in `sync()` korrigiert).
- [x] **wlprefs** (`wlprefs/`, siehe `docs/WMPREFS.md` „Stand“; liest/schreibt `config.lua`, dieselbe Datei wie der Compositor): lädt `config.lua` jetzt wirklich (der
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
- [x] **Phase 4**: Dock und Clip (`dock.zig`, `ui.zig`; `WMState`, 64-px-Kacheln, `app_id`-Zuordnung).
      *Dock:* Spalte aus Kacheln (`dock_size`, Standard 64 px) am linken/rechten Rand (`dock_edge`, `dock_offset`), erste Kachel
      ist die „WM“-Logo-Kachel, danach die Einträge mit `place = dock`. Linksklick startet das Programm
      oder fokussiert es, wenn schon ein Fenster davon läuft (Vergleich über `DockApp.matches`:
      expliziter `app_id`, `dockapp:<name>`, Teile von `instance.Class`, `--class dockapp:…` im Befehl,
      Programmname); Mittelklick startet immer eine neue Instanz; Rechtsklick öffnet ein Menü (Launch,
      „Lower Dock“/„Keep Dock on Top“). Anzeige „läuft nicht“ siehe Dock-Überarbeitung unten. PNG-Icons per
      cairo (Pfad oder Name in `hicolor`/`pixmaps`), sonst der erste Buchstabe des Namens.
      DockApp-Fenster (`dockapp:<name>`, z. B. `examples/wl-clock`, skaliert auf `dock_size`) werden direkt **in ihre
      Kachel gesetzt** (`ui.placeDocked`, über dem Dock gestapelt) und sind `omnipresent`.
      Der Arbeitsbereich schrumpft um das Dock (`Output.reserved`), egal auf welcher Ebene es liegt,
      außer `dock_reserve_space = false`. Getilte Fenster werden per `set_clip_box` an der Kante des
      Arbeitsbereichs abgeschnitten (gescrollte Spalten rutschen nicht unter das Dock), Floating-Fenster
      behalten ihre Greifzone im Arbeitsbereich. Im echten Vollbild liegt das Dock hinter dem Fenster,
      der Platz bleibt reserviert.
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
      Verzögerung für *Auto raise* (Autocollapse hat sie seit der Dock-Härtung unten).
- [ ] **`wmaker-wl --restart`/Root-Menü-Eintrag `RESTART`**:
      Prozess-Neustart (`execve` auf sich selbst) würde die bestehende `river_window_manager_v1`-Verbindung
      kappen; ob/wie river danach einen neuen WM-Client akzeptiert, ohne dass alle verwalteten Fenster
      unverwaltet zurückbleiben, ist ungeklärt. SIGHUP-Reload deckt den eigentlichen
      Bedarf ("neue Config ohne Sitzung neu zu starten") ab.
- [x] **Phase 5 (der machbare Teil): Themes und `include`.** `theme("NAME")` liest `Themes/NAME.lua`
      (neben der `config.lua`, sonst `/usr/local/share/` und `/usr/share/wmaker-wl/Themes/`), `include("DATEI")`
      liest eine beliebige Datei an dieser Stelle (spätere Zeilen überschreiben, Tiefe höchstens 4, relativ zur
      einbindenden Datei, `~/` geht). Ein Theme darf **nur** Farben, `border_width` und Gaps setzen; alles
      andere (Tastenkürzel, Programme, `include`) wird mit Warnung ignoriert, ein heruntergeladenes Theme
      kann also nichts ausführen. Namen sind Dateinamen (kein `/`, kein `..`). Drei Beispiele in
      `src/share/Themes/` (`gruvbox` = das eingebaute Aussehen, `nord`, `next`); `Config.parse_warnings`
      zählt übersprungene Zeilen, die eingebaute Config und die Themes sind darauf getestet.
      *Noch offen:* Schriften in Themes (hängt an Titelleisten); Window-Maker-Themes (`.themed`-Archive,
      `~/GNUstep/Defaults/WindowMaker`) lesen; Theme-Liste/Auswahl in wlprefs (heute ein Textfeld); wlprefs
      zeigt Werte, die nur ein `include`/`theme` setzt, nicht an (es schreibt aber nie darüber).
- [ ] **Phase 6 (Teil): Minimieren und Verstecken.** `minimize`, `restore` (zuletzt minimiertes),
      `show_all`, `hide_others`, `hide_app` als Tastenkürzel (Standard: `Super+n`, `Super+Shift+n`,
      `Super+Ctrl+n`, `Super+o`) und als Menüpunkte `HIDE_OTHERS`/`SHOW_ALL`. Ein minimiertes Fenster
      verlässt den Streifen (`workspace == null`, wird dadurch von der Render-Runde versteckt), merkt sich
      Spalte, Breite bzw. Rechteck und kommt auf den **aktuellen** Workspace zurück. Im Fenster-Menü steht es
      als `(Titel)`; Auswählen oder ein Klick auf seine Dock-/Clip-Kachel holt es zurück. DockApps werden nie
      versteckt. Jedes minimierte Fenster bekommt eine eigene temporäre Kachel am Ende der Dock-Spalte, unter
      der letzten Kachel (`dockhost.syncModel`, `Model.attachWindow`; das Log meldet `dockhost: Dock tile for the
      minimized window ...`, bei vollem Dock eine Warnung; nie gespeichert, kein Menü, ein Klick holt genau dieses Fenster zurück, ein kleiner
      „Minimieren“-Balken unten links unterscheidet sie von Programm-Kacheln). Beim Minimieren fliegt der Fensterrahmen zur Kachel, beim Wiederherstellen von der Kachel zurück
      (`anim.zig`, Original: `actions.c` `animateResize*`; Option `iconify_style` = zoom / twist (Standard) /
      flip / none / random; das Fenster erscheint erst nach der Animation). Das Icon ist das System-Icon des
      Programms (`appicon.zig`: Icon-Theme, `Icon=` der `.desktop`-Datei, sonst der Platzhalter des Themes; nur
      PNG/XPM, nichts Selbstgezeichnetes; nur ohne jedes Theme der Anfangsbuchstabe). `mini_dock` und der Befehl
      `toggle_mini_dock` (Standard: `Super+Shift+m`) schalten das ein/aus. Ist das Dock voll oder
      `dock_enabled = false`, gibt es keine Kachel (Fenstermenü / `restore` gehen weiter). Workspace-Namen: `workspace_names` / `WMState`, im Clip und im Workspace-Menü.

- [x] **Menüpunkte `SHUTDOWN`, `INFO_PANEL`, `LEGAL_PANEL`, `OPEN_MENU`** (`fsmenu.zig`, `ui.zig`):
      SHUTDOWN bittet alle Fenster zu schließen und beendet wmaker-wl; Info/Legal sind Untermenüs mit
      Text (Version, Config-Pfad, 0BSD). `OPEN_MENU` macht aus einem **Verzeichnis** ein Menü (Ordner zuerst,
      Dateien öffnen mit `WITH Programm` oder `xdg-open`, Pfade korrekt gequotet, Tiefe 3, höchstens
      200 Einträge je Ordner und 1000 insgesamt, Dotfiles ausgelassen) oder bindet eine **Menüdatei** ein;
      aufgebaut beim Öffnen, nie veraltet. `OPEN_MENU | befehl` wird bewusst nicht ausgeführt (ein
      langsames Programm würde beim Menüöffnen den ganzen Desktop anhalten) und erscheint ausgegraut.
      *Noch offen:* `RESTART` und `SAVE_SESSION` (siehe `--restart` oben).
- [ ] Menü läuft ausschließlich über den ersten gebundenen `wl_seat`; bei mehreren Seats bekommen weitere
      keinen Zeiger/keine Tastatur fürs Menü.
- [x] Menüs, die höher als der Output sind, **scrollen**: sie werden auf das gekürzt, was passt (Pfeile
      oben/unten zeigen, wo es weitergeht), Mausrad/Touchpad scrollt drei Zeilen je Raste, die Pfeiltasten
      holen die Auswahl in den sichtbaren Bereich.
- [x] Fenster, die während offenem Menü geschlossen werden, entfernen ihre Zeile korrekt (`forgetWindow`)
      und das Menü redrawt sich noch in derselben manage-Sequenz (`window_mod.reap()` läuft vor `u.sync()`
      in `onManage()`, mit Reihenfolge-Regressionstest abgesichert). War bereits so, nur nicht verifiziert.

### Sonstiges
- [ ] Drag-Reordering von Spalten
- [ ] Animationen beim Scrollen
- [ ] Docks Platz belegung fix und überlappung fix
- [x] config keybind exec shell / apps custom (`shell`/`exec`/`shexec` in `action.zig`, siehe
      `process.spawnShell`)
- [ ] **Session speichern** (`SAVE_SESSION`, Fenster + Workspaces + Spalten): nur sinnvoll, wenn Programme
      wiedererkannt und gestartet werden; erst `app_id` → Startbefehl-Zuordnung (hat `dockapps.conf` schon).
- [ ] **Mehrere Seats**: Menü und Dock gehören zurzeit dem ersten Seat.
- [ ] **Dock/Clip auf jedem Output** (oder pro Output wählbar).
- [ ] **`--check` für wlprefs/wmaker-wl**: Config laden, `parse_warnings` und unlesbare Dateien melden, mit
      Exit-Code (für Dotfile-Pipelines).
- [ ] **Fuzzing** der Parser (`plist`, `xpm`, `wm_menu`, `config`): die Schleifen sind begrenzt und getestet,
      ein Fuzz-Lauf fehlt.
- [ ] **Animationen** beim Scrollen und Drag-Reordering von Spalten (optional).
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
- [x] **Zeiger-Cursor über Root-Menü/Desktop**: wechselt via `wp_cursor_shape_manager_v1` zur normalen
      Pfeilform, statt das zuletzt von einem Fenster gesetzte Bild zu behalten
- [x] Rewrite des config handling für lua. lua anstatt .conf (`config.zig`/`lua.zig`; `config.lua` gewinnt bei
      Dock-/Clip-Schaltern gegenüber dem gespeicherten `WMState`, `Config.explicit`; ein übrig gebliebenes
      `config.conf` wird beim Start mit einer Warnung gemeldet)
- [x] **wlprefs auf Lua umgestellt**: `wlprefs/src/configfile.zig` und die Hilfstexte nutzen `config.lua` statt `config.conf`
      (das Parsen/Schreiben von `key = wert` und `bind("..", "..")` war schon Lua).
- [ ] Config allow own variables