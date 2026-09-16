# Empfehlung: Projektstruktur + Window-Maker-kompatible Befehle

## 1. Datei-Aufteilung (wie Rill es macht, für dein Column-Modell angepasst)

Dein eigener Kommentar in `main.zig` sagt bereits, dass eine Aufteilung geplant ist. Konkreter
Vorschlag, orientiert an Rill:

```
src/
  main.zig        -- nur: Registry, Globals, Event-Loop, main()
  types.zig        -- WindowManager, Output, Workspace, Strip, Column, Window structs + Config
  layout.zig        -- reine Geometrie: recomputeGeometry, scrollToColumn, windowHeight, snapToEdge
  window.zig        -- Window.create/manage/maybeDestroy, listener
  output.zig        -- Output.create/listener, Workspace-Array-Handling
  seat.zig          -- Seat, pointer move/resize, Fokus-Tracking
  keybinding.zig      -- XkbBinding, Action-Switch (State-Mutation, kein Layout-Code!)
  animation.zig       -- optional, später: gleiche Idee wie bei Rill (start_rect/finish_rect interpolieren)
  config.zig         -- optional, später: ZON-Laden für Wmaker-Style-Config
```

**Wichtigster Rill-Grundsatz, den du übernehmen solltest:** `layout.zig` darf *nur* Rechtecke
berechnen, keine Wayland-Calls absetzen. Das trennt "wo soll das Fenster hin" von "wie wird das
tatsächlich gesetzt" — macht Animation später trivial nachrüstbar (wie bei Rill: `layout.apply`
setzt nur `finish_rect`, `animation.apply` macht daraus echte `proposeDimensions`/`setPosition`-Calls).

## 2. Was aus Rill du fast 1:1 übernehmen kannst

- **`snapToEdge`-Prinzip** statt hartem `scroll_x`-Clamping → weniger Kanten-/Lücken-Bugs.
- **Border-Farbe fokussiert/unfokussiert** (`setBorders`) — trivial nachzurüsten, großer visueller Gewinn.
- **`river_seat.focusWindow(...)` bei jedem Layout-Lauf explizit setzen** — das solltest du so oder so
  ergänzen (siehe Analyse-Punkt 4 in Datei 02), unabhängig vom Rill-Vergleich.
- **Explizites `hide()`/`hide-via-clipbox`-Muster** für Fenster außerhalb des sichtbaren Bereichs
  (auch für nicht-aktive Workspaces) — löst deine offene Baustelle "Workspace-Wechsel versteckt
  nichts wirklich" strukturell.
- **`useSsd()` + `proposeDimensions(0,0)` + `hide()`** beim Vorbereiten neuer Fenster, bevor sie
  einsortiert werden — verhindert Flackern beim ersten Sichtbarwerden.

## 3. Window-Maker-kompatible Befehle/Konzepte (für deinen Fork-Teil)

Das ist der Teil, wo du "möglichst wenig anpassen" willst. Klassisches Window Maker (der X11-WM)
kennt folgende Kern-Vokabeln, die sich 1:1 auf dein `Output/Workspace/Strip/Column/Window`-Modell
mappen lassen:

| Window-Maker-Konzept | Entspricht in deinem Modell | Umsetzungsaufwand |
|---|---|---|
| **Workspaces** (Ctrl+→/←, benannt, beliebig viele) | `Output.workspaces[]`, `switchWorkspace` | Grundgerüst da, Sichtbarkeit muss noch verdrahtet werden |
| **Window Attributes** (Omnipresent, No-Titlebar, Keep-on-top) | Flags auf `Window`-Struct | Leicht, nur neue bool-Felder + Respektierung in `layout()` |
| **Icon Yard / Miniwindows** (minimierte Fenster als Icons) | von dir selbst als TODO markiert (`minimize_requested`) | Mittel — braucht eigene Icon-Darstellung, in river evtl. via Layer-Shell-artige Surface oder eigene minimal gerenderte Node |
| **The Dock** (vertikale App-Leiste am Bildschirmrand) | Kein Äquivalent aktuell | Mittel-Hoch — eigenständige Struktur, eher orthogonal zum Scrolling-Layout, würde wie Rills `layer_shell`-Integration behandelt (feste Position außerhalb des scrollbaren Bereichs) |
| **The Clip** (Workspace-übergreifende Mini-Dock-Erweiterung) | Kein Äquivalent | Niedrige Priorität, baut auf Dock auf |
| **Window Menu (Rechtsklick auf Titlebar)** | Kein Äquivalent | Braucht eigenes Kontextmenü-Rendering — aufwändigster Punkt, weil UI statt nur Layout |
| **Appearance/Theme-Datei (`WindowMaker`-Style-Configs)** | `Config`-Struct + `config.zig` | Rill zeigt exakt das richtige Pattern (ZON statt Wmaker's proprietärem Format, aber gleiche Idee: Live-Reload via Keybinding) |
| **Alt-Tab / Switch Panel** | Kein Äquivalent | Niedrig-Mittel, reine UI-Overlay-Frage |

**Priorisierungsvorschlag** (aufsteigender Aufwand, absteigender "Kern-WM-Gefühl"-Impact):
1. Workspace-Sichtbarkeit fertigstellen (ist eh offene Baustelle)
2. Window-Attribute-Flags (Omnipresent etc.) — billig, viel Wmaker-Charakter
3. Fokus-Border-Farben (aus Rill übernehmbar)
4. Dock (eigenständiges Feature, aber Kern-Wmaker-Identität)
5. Icon Yard/Miniwindows
6. Window-Menu, Clip, Alt-Tab (Politur, nicht Kern)

## 4. Zusammenfassend: nächste konkrete Schritte

1. `river_seat.focusWindow()` ergänzen (behebt vermutlich auch Input-Testbarkeit).
2. Workspace-Sichtbarkeit (`hide()`/`show()` je nach `active_workspace`) verdrahten.
3. Code wie oben in 6–8 Dateien aufteilen, `layout.zig` von Wayland-Calls befreien.
4. Danach: Animation nach Rill-Vorbild nachrüsten (separates Modul, `start_rect`/`finish_rect`).
5. Danach erst: Window-Maker-Vokabular (Attribute-Flags, Dock, Icons) draufsetzen.