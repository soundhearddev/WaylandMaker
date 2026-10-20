# TODO
- [ ] **`wmaker-wl --restart` / Root-Menü-Eintrag `RESTART`**: Prozess-Neustart (`execve` auf sich selbst) würde die
      bestehende `river_window_manager_v1`-Verbindung kappen; ob/wie river danach einen neuen WM-Client akzeptiert,
      ohne dass alle verwalteten Fenster unverwaltet zurückbleiben, ist ungeklärt. Der SIGHUP-Reload
      (`pkill -HUP wmaker-wl`) deckt den eigentlichen Bedarf ("neue Config ohne Sitzung neu zu starten") ab.
- [ ] **Docks: Platzbelegung und Überlappung**: Symptom noch genauer eingrenzen (welche Kante, wie viele Outputs,
      welche Kacheln überlappen), dann beheben.
- [ ] **Mehrere Seats**: Menü und Dock gehören zurzeit dem ersten gebundenen `wl_seat`; weitere Seats bekommen
      keinen Zeiger und keine Tastatur fürs Menü.
- [ ] **Dock/Clip auf jedem Output** (oder pro Output wählbar).
- [ ] **Session speichern** (`SAVE_SESSION`, Fenster + Workspaces + Spalten): nur sinnvoll, wenn Programme
      wiedererkannt und gestartet werden; erst `app_id` → Startbefehl-Zuordnung (hat `dockapps.conf` schon).
- [ ] **Modular Workspaces**.
- [ ] **Animationen** beim Scrollen und Drag-Reordering von Spalten (optional).
- [ ] **Drag-Reordering von Spalten**.
- [ ] **Perf (Messen)**: Es fehlt ein Benchmark im Repo (`zig build bench`); die Zahlen stammen aus einem lokalen
      Wegwerf-Test.
- [ ] **`compatibility.zig`**: Stubs (`libwmaker` per `dlopen`, WMakerrc-Parser, Zwischenablage). `registerHook`
      speichert jetzt wirklich (Test), `loadAttributes` liest höchstens 1 MiB und gibt bei Fehlern keinen Speicher
      mehr verloren.
- [ ] **Icons aus `~/.local/share/icons` und `~/.icons`** (bisher nur `/usr/share/icons` und `/usr/share/pixmaps`).
