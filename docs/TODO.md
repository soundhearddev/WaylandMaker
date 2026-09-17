# TODO.md / PLAN.md

## Projektübersicht
Entwicklung eines Wayland-Compositors in Zig auf Basis des **River-Protokolls** (via `river-window-management-v1`, `river_output_v1`, `river_seat_v1`), der Elemente eines klassischen Window Managers (ähnlich Window Maker) mit einem scrollbaren Tiling-Ansatz (inspiriert von `niri`) verbindet.

## Phasen des Projekts

### Phase 1: Minimaler Grundgerüst-Compositor (Erreicht)
- [x] Build-Skript (`build.zig`) für Zig mit Wayland- und River-Client-Abhängigkeiten einrichten.
- [x] Wayland-Display, Event-Loop und Registry-Binding für River-Komponenten initialisieren.
- [x] Verbindung zum `river_window_manager_v1`-Protokoll herstellen.
- [x] XDG-Shell / River-Window-Event-Listener für die Fensterverwaltung integrieren.

### Phase 2: Eingabe und Ausgabegeräte (Outputs & Inputs)
- [x] Ausgabe-Management (`river_output_v1`) zur Erkennung von Bildschirm-Koordinaten und Dimensionen einbinden.
- [x] Eingabegeräte (`river_seat_v1` / `river_xkb_bindings_v1`) für Tastatur- und Maus-Interaktionen einbinden.
- [ ] Fokus- und Event-Weiterleitung für aktive Fenster vervollständigen (`river_seat.focusWindow`).

### Phase 3: Fenster-Layout und Scrollbares Tiling (Core Features)
- [x] Datenstrukturen für Fenster, Columns, Strips und Workspaces aufbauen (`types.zig`).
- [ ] Layout-Engine für scrollbares Tiling (Strip → Column → Window im niri-Stil) verfeinern.
- [ ] Maus-Interaktionen (Verschieben, Resize) und Workspace-Sichtbarkeit implementieren.

### Phase 4: Dekorationen und Polish
- [ ] Fenstertitel und Titelleisten (angelehnt an das klassische Window Maker Look & Feel) integrieren.
- [ ] Konfiguration (ZON- oder strukturiertes Format) für Shortcuts und Layout-Parameter hinzufügen.
- [ ] Stabilitätstests, Speicherbereinigung (GPA) und Performance-Optimierungen in Zig.