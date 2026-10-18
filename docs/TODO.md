- [ ] waylandmaker cli options
- [ ] **`wmaker-wl --restart`/Root-Menü-Eintrag `RESTART`**:
      Prozess-Neustart (`execve` auf sich selbst) würde die bestehende `river_window_manager_v1`-Verbindung
      kappen; ob/wie river danach einen neuen WM-Client akzeptiert, ohne dass alle verwalteten Fenster
      unverwaltet zurückbleiben, ist ungeklärt. SIGHUP-Reload deckt den eigentlichen
      Bedarf ("neue Config ohne Sitzung neu zu starten") ab.
- [ ] **Phase 6 (Teil): Minimieren und Verstecken.** `minimize`, `restore` (zuletzt minimiertes),
      `show_all`, `hide_others`, `hide_app` als Tastenkürzel (Standard: `Super+n`, `Super+Shift+n`,
      `Super+Ctrl+n`, `Super+o`) und als Menüpunkte `HIDE_OTHERS`/`SHOW_ALL`. Ein minimiertes Fenster
      verlässt den Streifen (`workspace == null`, wird dadurch von der Render-Runde versteckt), merkt sich
      Spalte, Breite bzw. Rechteck und kommt auf den **aktuellen** Workspace zurück. Im Fenster-Menü steht es
      als `(Titel)`; Auswählen oder ein Klick auf seine Dock-/Clip-Kachel holt es zurück. DockApps werden nie
      versteckt. Jedes minimierte Fenster bekommt eine eigene temporäre Kachel im Dock (`dockhost.syncModel`,
      `Model.attachWindow`; nie gespeichert, kein Menü, ein Klick holt genau dieses Fenster zurück, ein kleiner
      „Minimieren“-Balken unten links unterscheidet sie von Programm-Kacheln). Das Icon ist das System-Icon des
      Programms (`appicon.zig`: Icon-Theme, `Icon=` der `.desktop`-Datei, sonst der Platzhalter des Themes; nur
      PNG/XPM, nichts Selbstgezeichnetes; nur ohne jedes Theme der Anfangsbuchstabe). `mini_dock` und der Befehl
      `toggle_mini_dock` (Standard: `Super+Shift+m`) schalten das ein/aus. Ist das Dock voll oder
      `dock_enabled = false`, gibt es keine Kachel (Fenstermenü / `restore` gehen weiter). Workspace-Namen: `workspace_names` / `WMState`, im Clip und im Workspace-Menü.
- [ ] Menü läuft ausschließlich über den ersten gebundenen `wl_seat`; bei mehreren Seats bekommen weitere
      keinen Zeiger/keine Tastatur fürs Menü.
- [ ] **Perf (Messen)**: Es fehlt ein Benchmark im Repo (`zig build bench`); die Zahlen oben stammen aus einem
      lokalen Wegwerf-Test.
- [ ] `compatibility.zig`: Stubs (`libwmaker` per `dlopen`, WMakerrc-Parser, Zwischenablage). `registerHook` speichert
      jetzt wirklich (Test), `loadAttributes` liest höchstens 1 MiB und gibt bei Fehlern keinen Speicher mehr verloren.
- [ ] Drag-Reordering von Spalten
- [ ] Animationen beim Scrollen
- [ ] Modular Workspaces
- [ ] Docks Platz belegung fix und überlappung fix
- [ ] Fenster fokus bei maximierung beibehalten
- [ ] **Session speichern** (`SAVE_SESSION`, Fenster + Workspaces + Spalten): nur sinnvoll, wenn Programme
      wiedererkannt und gestartet werden; erst `app_id` → Startbefehl-Zuordnung (hat `dockapps.conf` schon).
- [ ] **Mehrere Seats**: Menü und Dock gehören zurzeit dem ersten Seat.
- [ ] **Dock/Clip auf jedem Output** (oder pro Output wählbar).
- [ ] **`--check` für wlprefs/wmaker-wl**: Config laden, `parse_warnings` und unlesbare Dateien melden, mit
      Exit-Code (für Dotfile-Pipelines).
- [ ] **Fuzzing** der Parser (`plist`, `xpm`, `wm_menu`, `config`): die Schleifen sind begrenzt und getestet,
      ein Fuzz-Lauf fehlt.
- [ ] **Animationen** beim Scrollen und Drag-Reordering von Spalten (optional).
