# Dein Code (`main.zig`, ~888 Zeilen) — Status-Check

## Was funktioniert schon nachweislich (laut deiner Beschreibung + Code-Lesart)

- **Verbindung zu river** über `river_window_manager_v1` (Version 4) + `river_xkb_bindings_v1` — korrekt gebunden, Roundtrip vor Nutzung.
- **PDEATHSIG fehlt** (siehe unten unter "Kleinere Lücken") — Rill hat das, dein Code nicht.
- **Strip → Column → Window Modell** ist real implementiert, nicht nur Kommentar:
  - `Strip.addWindow` erstellt für jedes neue Fenster eine eigene Column am Strip-Ende.
  - `Column.windowHeight` teilt die Outputhöhe gleichmäßig auf alle Fenster der Column auf (vertikales Stapeln in einer Spalte funktioniert rechnerisch).
  - `Strip.scrollToColumn` scrollt die aktive Column ins Bild (analog zu Rills `y_offset`-Prinzip, nur horizontal und mit explizitem State statt Neuberechnung).
  - Das erklärt, warum "mehrere Fenster öffnen wie Scrolling nebeneinander" bei dir schon funktioniert — das ist genau `layout()` in `WindowManager`, das für jede Column `col_screen_x = output.x + column.strip_x - strip.scroll_x` berechnet.
- **Pointer move/resize** ist implementiert (`Seat.op`, `pointerMove`/`pointerResize`, Delta-Tracking, `render()` setzt Live-Position während der Operation).
- **Workspace-Grundgerüst** (`workspace_count = 4`, `Output.workspaces` als Array, `switchWorkspace`) — Struktur da, aber siehe unten: Umsetzung unvollständig.

## Wichtige Lücken / Risiken (bevor du weiterbaust, solltest du das wissen)

1. **Kein Scroll-Offset-Clamping am rechten/unteren Rand geprüft** — `scrollToColumn` klemmt nur `scroll_x < 0`, aber nicht nach oben (kein `max scroll`). Bei wenigen/schmalen Columns kann das bei dir zu Leerraum rechts führen; Rills `snapToEdge`-Ansatz vermeidet das strukturell. Empfehlung: das Snap-Prinzip aus Rill übernehmen statt reines Clamping.

2. **`switchWorkspace` versteckt nichts wirklich** — der Kommentar sagt es selbst ("Actual hide/show calls happen during Window.manage()"), aber ich sehe in `Window.manage()` (Zeilen 406–421) keinen Code, der das tatsächlich umsetzt (kein `hide()`/`show()`-Aufruf, keine Prüfung "ist meine Column auf dem aktiven Workspace"). Das ist aktuell eine **Lücke, kein Bug** — Workspace-Wechsel ist strukturell vorbereitet, aber noch nicht verdrahtet. Das ist wahrscheinlich der Hauptgrund, falls Workspace-Wechsel bei dir noch nicht getestet wurde.

3. **`assignToStrip` nimmt immer `wm.outputs.first()`** statt den Output unter dem fokussierten Seat — bei Multi-Monitor landen neue Fenster immer auf demselben Output. Als PoC okay, aber im TODO-Kommentar selbst schon richtig benannt.

4. **Kein `river_seat.focusWindow(...)`-Aufruf sichtbar** in dem Ausschnitt, den ich gesehen habe (anders als Rill, das in `layout.apply` explizit `river_seat.focusWindow(window.river_window)` für das fokussierte Fenster setzt). Ohne das bekommt möglicherweise kein Fenster Keyboard-Fokus vom Compositor zugewiesen — das würde erklären, warum du Tasteneingabe noch nicht getestet hast: es könnte sein, dass noch kein Fenster tatsächlich Fokus bekommt, unabhängig von den Bindings selbst. **Das würde ich als Erstes prüfen, bevor ich Tastatur-Input debugge.**

5. **Keine Border/Farbe-Logik** — kein Problem fürs Funktionieren, aber du hast (noch) keine visuelle Fokus-Anzeige wie Rill's `setBorders` mit fokussiert/unfokussiert-Farben.

6. **Kein Config-Loading** (ZON o.ä.) — alles ist `Config`-Struct mit `comptime`-Konstanten. Für eine PoC in Ordnung, aber falls du Window-Maker-Konfigierbarkeit willst (z. B. `.wmconfig`-ähnliche Dateien), fehlt das komplett noch.

7. **Keine Animation** — logisch, das war nicht dein Anspruch für die eigene main.zig (Rill diente nur als Vergleichsbeispiel).

## Architektonische Einschätzung

Dein Grundmodell (**Output → Workspace → Strip → Column → Window**) ist eine sinnvolle Erweiterung
von Rills flacherem Modell (**Output → Workspace → Window-Liste**), weil es dir erlaubt, Window-Maker-
artiges Verhalten (mehrere Fenster "gruppiert" in einer Spalte, ähnlich wie eine App-Gruppe) UND
Scrolling gleichzeitig zu haben. Das ist strukturell näher an niri selbst als Rill es ist (niri hat
exakt dieses Columns-mit-Stack-Modell). Die Grundentscheidung ist also gut.

Was fehlt, ist eher "Verdrahtung zwischen den Teilen" (Fokus tatsächlich an river melden,
Workspace-Sichtbarkeit tatsächlich durchsetzen) als "grundlegendes Konzept korrigieren".