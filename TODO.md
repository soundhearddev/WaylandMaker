# PLAN.md

## Projektübersicht
Entwicklung eines Wayland-Compositors in Zig auf Basis von `wlroots` (Version 0.21+), der Elemente eines klassischen Window Managers (ähnlich Window Maker) mit einem scrollbaren Tiling-Ansatz (inspiriert von `niri`) verbindet.

## Phasen des Projekts

### Phase 1: Minimaler Grundgerüst-Compositor (Aktueller Stand)
- [x] Build-Skript (`build.zig`) für Zig mit lokalen wlroots- und Systemabhängigkeiten einrichten.
- [x] Wayland-Display, Event-Loop und wlroots-Backend (`wlr_backend_autocreate`) initialisieren.
- [x] Renderer und Basis-Compositor (`wlr_compositor`) starten.
- [x] XDG-Shell für Fensterverwaltung integrieren und grundlegende Signal-Listener registrieren.

### Phase 2: Eingabe und Ausgabegeräte (Outputs & Inputs)
- [ ] Ausgabe-Management (`wlr_output`) implementieren, um Monitore und Modi zu erkennen und Frames zu rendern.
- [ ] Eingabegeräte (`wlr_seat`, Tastatur und Maus/Touchpad) über libinput einbinden.
- [ ] Grundlegende Fokus- und Event-Weiterleitung für Tastatur und Zeigegeräte einrichten.

### Phase 3: Fenster-Layout und Scrollbares Tiling (Core Features)
- [ ] Datenstrukturen für Fenster (Views/Surfaces) aufbauen.
- [ ] Layout-Engine für scrollbares Tiling (Spalten- und Zeilen-Struktur à la niri) entwerfen.
- [ ] Maus-Interaktionen (Verschieben, Resize, Floating-Fenster im Stil von Window Maker) implementieren.

### Phase 4: Dekorationen und Polish
- [ ] Fenstertitel und Titelleisten (angelehnt an das klassische Window Maker Look & Feel) rendern.
- [ ] Konfigurationsdatei (z.B. im TOML- oder JSON-Format) für Shortcuts und Einstellungen hinzufügen.
- [ ] Stabilitätstests, Speicherbereinigung und Performance-Optimierungen in Zig.