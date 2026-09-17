# Projekt-Overview: wmaker-wl (River-basiert)

Diese Dokumentation fasst die Architektur, den aktuellen Integrationsstatus und die Modulstruktur des `wmaker-wl`-Compositors zusammen. Das Projekt setzt auf das **River Window Management Protokoll** auf.

---

## 1. Modulstruktur (`src/`)

Der Code ist sauber in Module aufgeteilt:

```text
src/
├── main.zig        # Event-Loop, Registry-Listener, River-WM Event-Dispatcher
├── types.zig       # Datenstrukturen (WindowManager, Output, Workspace, Strip, Column, Window)
├── layout.zig      # Reine Geometrieberechnung (recomputeGeometry)
├── window.zig      # Lifecycle von WindowV1 (create, manage, windowListener)
├── output.zig      # Lifecycle von OutputV1 (position, dimensions, reaps)
└── seat.zig        # Lifecycle von SeatV1, Fokus-Steuerung & Eingabe
