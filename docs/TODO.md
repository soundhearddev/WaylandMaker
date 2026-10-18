## Erledigt (diese Runde)

- [x] **Kamera bei Maximierung**: `maximize_follow` (Standard an) hält den Viewport auf der aktiven maximierten
      Spalte, in jedem Layout-Durchlauf (Scroll-Befehle, Dock, Fenster in anderen Spalten). `maximize_keep_focus`
      lässt neue Tiled-Fenster im Hintergrund öffnen. Dazu der Bug-Fix: Klick-/Hover-Fokus ruft jetzt
      `workspace.activate` auf, **bevor** das Layout läuft (`strip.active` blieb vorher veraltet, die Kamera
      sprang zur alten Spalte zurück).
- [x] **Modulare Workspaces**: `workspace_add`, `workspace_remove_last`, `workspace_last`,
      `move_to_workspace_next/prev`; `workspace N` legt fehlende Workspaces an (bis 16);
      `dynamic_workspaces` (niri-Stil); `workspace_back_and_forth`; ein Reload übernimmt eine geänderte
      `workspace_count`. Nur das Ende des Arrays wächst/schrumpft, Workspace-Adressen bleiben stabil.
- [x] **Config neu laden per Taste**: `reload_config` (Standard `Super+Shift+r`), im selben Manage-Durchlauf
      nach der Aktions-Queue.
- [x] **niri-Optionen**: `strut_*`, `center_single_column`, `focus_follows_mouse_scroll`, `warp_mouse_to_focus`,
      `prefer_no_csd`, `spawn_at_startup`, `environment`; Befehle `set_column_width`,
      `focus_window_or_workspace_up/down`, `focus_column_or_output_left/right`.
- [x] `focus_up`/`focus_down` bei Floating-Fenstern: wechseln jetzt in stabiler Öffnungsreihenfolge (vorher
      pendelten sie wegen des Hochholens nur zwischen den obersten zwei Fenstern).
- [x] Schließt ein Hintergrundfenster, springt der Fokus nicht mehr; `focus_previous` und Menü-Fokus nehmen
      omnipräsente Fenster mit; `move_to_workspace` behält die Spaltenbreite.

## Offen


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
