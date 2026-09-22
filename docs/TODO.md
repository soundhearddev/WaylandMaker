## Offen

Plan und Begründung: [`docs/WINDOWMAKER.md`](WINDOWMAKER.md).

### Window-Maker-Integration
- [ ] **Phase 2**: Zeichen-Infrastruktur (`wl_shm`, cairo/pango, Texturen, `wl_seat`, `poll()`-Loop)
- [ ] **Phase 3**: Titelleisten im NeXTSTEP-Look (`river_decoration_v1`), `NoTitlebar` & Co. wirksam
- [ ] **Phase 4**: Root-Menü anzeigen (rechte Taste auf dem Desktop), Fensterliste (mittlere Taste)
- [ ] **Phase 5**: Dock und Clip (`WMState`/wlmaker-State, 64-px-Kacheln, `app_id`-Zuordnung)
- [ ] **Phase 6**: Themes, `~/GNUstep/Defaults/WindowMaker`-Schlüssel
- [ ] **Phase 7**: Minimieren/Shade/Verstecken, Session speichern, Workspace-Namen
- [ ] Menüpunkte ohne Funktion: `RESTART`, `SHUTDOWN`, `INFO_PANEL`, `LEGAL_PANEL`, `OPEN_MENU`

### Sonstiges
- [ ] Mehrere Outputs: Fokus zwischen Monitoren, Fenster verschieben
- [ ] Attribute mit später eintreffender `app_id`: Ort (Workspace, floating) wird nur beim ersten Platzieren entschieden
- [ ] Optional: Drag-Reordering von Spalten
- [ ] Optional: Animationen beim Scrollen

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
