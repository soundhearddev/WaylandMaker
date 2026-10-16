## TODO
- [ ] **`wmaker-wl --restart`/Root-Menü-Eintrag `RESTART`**:
      Prozess-Neustart (`execve` auf sich selbst) würde die bestehende `river_window_manager_v1`-Verbindung
      kappen; ob/wie river danach einen neuen WM-Client akzeptiert, ohne dass alle verwalteten Fenster
      unverwaltet zurückbleiben, ist ungeklärt. SIGHUP-Reload deckt den eigentlichen
      Bedarf ("neue Config ohne Sitzung neu zu starten") ab.
- [ ] **Phase 4** Minimieren und Verstecken.
### Sonstiges
- [ ] Drag-Reordering von Spalten
- [ ] **Session speichern** (`SAVE_SESSION`, Fenster + Workspaces + Spalten): nur sinnvoll, wenn Programme
      wiedererkannt und gestartet werden; erst `app_id` → Startbefehl-Zuordnung (hat `dockapps.conf` schon).
- [ ] **Mehrere Seats**: Menü und Dock gehören zurzeit dem ersten Seat.
- [ ] **Dock/Clip auf jedem Output** (oder pro Output wählbar).
- [ ] **`--check` für wlprefs/wmaker-wl**: Config laden, `parse_warnings` und unlesbare Dateien melden, mit
      Exit-Code (für Dotfile-Pipelines).
- [ ] **Fuzzing** der Parser (`plist`, `xpm`, `wm_menu`, `config`): die Schleifen sind begrenzt und getestet,
      ein Fuzz-Lauf fehlt.
- [ ] **Animationen** beim Scrollen und Drag-Reordering von Spalten (optional).
- [ ] More Niri esc config options
- [ ] Multi Monitor Support
- [ ] Follow window Maxamize