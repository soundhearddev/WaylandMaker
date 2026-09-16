# Rill — Analyse der Scrolling-Tiling-Qualität

**Quelle:** `rill-main/rill/` (Zig, ~2150 Zeilen über 9 Dateien), MIT-artig lizenziert,
implementiert `river-window-management-v1` — dasselbe Protokoll, das du auch benutzt.

## Ist das "richtig gutes" Scrolling-Tiling?

**Ja, uneingeschränkt.** Es ist im Kern eine niri-artige Scrolling-Layout-Engine,
sauber getrennt in vier Verantwortlichkeiten:

| Datei | Aufgabe |
|---|---|
| `layout.zig` | reine Geometrie-Berechnung (wo soll jedes Fenster stehen — *Ziel*-Rechteck) |
| `animation.zig` | interpoliert vom Ist- zum Ziel-Rechteck über die Zeit (easing), setzt tatsächliche Wayland-Calls ab |
| `keybinding.zig` | State-Mutationen (Fokus wechseln, Fenster verschieben, Breite ändern …) |
| `types.zig` | zentrales Datenmodell (`Output → Workspace → Window`, `Config`) |

Diese Trennung ist der wichtigste Qualitätsindikator: **Layout-Berechnung, Rendering/Animation
und Input-Handling sind komplett entkoppelt.** Das ist genau das Muster, das gute
Compositor-seitige Tiling-Logik von Bastel-Code unterscheidet.

## Scrolling-Mechanik im Detail (`layout.zig::scrollingLayout`)

- Es gibt **keinen Scroll-Offset-State** wie in deinem Code (`strip.scroll_x`). Stattdessen wird bei
  jedem Layout-Lauf das fokussierte Fenster an einer festen Position (links, rechts oder zentriert,
  je nach `center_focused_window`-Config) platziert, und alle anderen Fenster werden relativ dazu
  links/rechts aufgereiht (`placement_rect.x += width + gap` nach rechts, symmetrisch nach links).
- **`snapToEdge`** (Zeilen 303–335) ist ein cleverer Kniff: wenn außen Platz frei bliebe (z. B. am
  Rand der Fensterliste), werden alle Fenster gemeinsam so verschoben, dass sie an den Bildschirmrand
  "einschnappen" — verhindert hässliche Lücken am Anfang/Ende der Liste, ohne dass man einen
  expliziten Scroll-Offset klemmen (`clamp`) muss. Das ist eleganter als ein manuell geklemmter
  `scroll_x`, wie du ihn in `Strip.scrollToColumn` benutzt.
- **Kein Column-Konzept mit Stacking** — anders als bei dir (mehrere Fenster pro Column,
  vertikal gestapelt) hat Rill offenbar ein Fenster pro "Slot" in der Scroll-Reihe (aus
  `types.Window` und der Schleifenstruktur in `scrollingLayout` ersichtlich: jedes Element aus
  `workspace.window_list` bekommt seine eigene horizontale Position). D.h. Rill ist reines
  1D-Scrolling ohne vertikales Stapeln — dein Code geht mit `Column.windows` (mehrere Fenster pro
  Column, Höhe wird gleichmäßig aufgeteilt) einen Schritt weiter in Richtung "niri mit Stapel-Spalten".
  Das ist kein Rill-Mangel, sondern ein Feature, das du zusätzlich hast.
- **Proportionale Breiten** (`window.proportion`, änderbar per `adjust_window_width`/`set_window_width`)
  statt fixer Pixelbreite — robust gegenüber Output-Größenänderungen, weil relativ zur `non_exclusive`-
  Breite berechnet.
- **Multi-Output sauber verdrahtet**: jeder Output hat eigene Workspaces, gerichtete Navigation
  (`focus_output_left/right/above/below`) über `getOutputInDirection`, die Adjazenz rein geometrisch
  über Kantenberührung bestimmt (kein Pixel-Gefrickel).

## Animation (`animation.zig`)

- Cubic-ease-out (`1 - (1-progress)^3`), Dauer konfigurierbar (`animation_duration`, Default 200ms).
- Interpoliert alle vier Rechteck-Parameter (x, y, w, h) unabhängig — funktioniert also für
  Größen- *und* Positionsänderungen gleichzeitig, inklusive Scrollen selbst (das "wandernde" Fenster
  bei Fokuswechsel ist reine Konsequenz aus unterschiedlichem `start_rect`/`finish_rect`).
- **Clipping und Hide/Show pro Frame** (`placeWindow`): Fenster, die den Output verlassen (weil sie
  aus dem sichtbaren Scroll-Bereich rausgescrollt wurden), werden per `river_window.hide()` /
  `setClipBox()` unsichtbar geschaltet bzw. am Rand abgeschnitten — technisch sauber, verhindert
  Overdraw/Leaks von Nachbar-Workspaces (die ja bei Rill per `y_offset` als "übereinander" simuliert
  werden, nicht wirklich versteckt).
- Workspace-Wechsel ist selbst eine Animation: `y_offset = (workspace_idx - focused_idx) * output.height`
  — Workspaces liegen konzeptuell übereinander (vertikal gestapelt) und man "scrollt" vertikal
  zwischen ihnen, während innerhalb eines Workspace horizontal gescrollt wird. Cleveres, konsistentes
  Modell (ein Scroll-Mechanismus für beides).

## Kompatibilität mit "wie Wayland/river das erwartet"

- Explizites `useSsd()`/`setTiled()`/`proposeDimensions(0,0)` beim Vorbereiten neuer Fenster
  (verhindert Flackern/CSD-Fensterrahmen).
- Fullscreen sauber über `informFullscreen()`/`informNotFullscreen()`/`fullscreen(output)`
  am Ende der Animation (nicht sofort) — vermeidet Race Conditions zwischen Client-Resize-Bestätigung
  und Compositor-State.
- Border-Farben werden aus Config in echtes premultiplied-alpha `u32`-Format konvertiert
  (`toRiverColor`) — Detail, das oft übersehen wird.

## Bewertung

| Kriterium | Bewertung |
|---|---|
| Scrolling-Korrektheit | Sehr gut — robustes Modell ohne fehleranfälligen manuellen Scroll-Offset |
| Code-Trennung (Layout/Animation/Input) | Vorbildlich |
| Animationen | Sauber, konfigurierbar, technisch korrekt (Clipping, Hide/Show) |
| Multi-Output | Vollständig (Fokus, Move, Send in alle 4 Richtungen) |
| Config-System | Gut: ZON-Datei, Live-Reload, sinnvolle Defaults |
| Fehlt / nicht generisch genug für deinen Zweck | Kein Column/Stack-Konzept, kein Window-Maker-Vokabular (Dock/Clip/Icons) — logisch, ist ja kein WM-Fork |

**Fazit:** Rill ist eine hervorragende Referenzimplementierung für den Scrolling-Tiling-Teil.
Du kannst insbesondere `snapToEdge`, das Animation-Ease-Muster und die Output-Adjazenz-Logik
fast 1:1 als Vorbild für dein eigenes Projekt nehmen — dein Column-Stacking-Konzept ist bereits
eine sinnvolle Erweiterung darüber hinaus.