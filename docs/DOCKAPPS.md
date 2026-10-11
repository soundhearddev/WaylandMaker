# DockApps, Dock und Clip

wmaker-wl folgt hier Window Maker (`dock.c`, `appicon.c`): **ein** Dateiformat, **kein** Register
von DockApps, und DockApps sind keine Fenster.

## DockApps sind Icons, keine Fenster (`dockhost.zig`)

Ein DockApp ist ein normales Programm mit **einem Tag**: sein Wayland-`app_id` ist
`dockapp:<name>` (oder `dockapp-<name>`). Mehr braucht es nicht; gestartet wird es, wie man will:
`autostart`, Menü, Terminal oder ein `WMState`-Eintrag mit `AutoLaunch = Yes`.

Sobald der Tag da ist (egal wie spät), wird das Fenster einmal **adoptiert** (`Window.role = .dockapp`)
und wandert von `wm.windows` nach `wm.dock_windows`. Damit ist es für alles andere unsichtbar, ohne
dass irgendwo ein Flag geprüft werden muss: Layout, Workspaces, Fokus, Fokus-Zyklus, Close, Hide,
Minimize, Kill, Fensterliste und Fenstermenüs iterieren nur über `wm.windows`.

Was der Compositor (nicht der Client) dann festlegt, ausschließlich in `dockhost.apply`:

| Thema | Verhalten |
|---|---|
| Größe | was das DockApp angefragt hat, höchstens eine Kachel (64×64); ohne Hint eine ganze Kachel |
| Position | zentriert in der Kachel seines Namens, über dem Dock, auf allen Workspaces |
| Dekoration | keine (CSD, keine Ränder, keine Titelleiste) |
| Fokus, Tastatur | nie; Mod+Q und andere Fenster-Aktionen erreichen es nicht |
| Events | nur Größe, Name und Schließen zählen; Move, Resize und Fullscreen werden ignoriert |
| Maus | geht direkt ans DockApp (sein Fenster liegt auf der Kachel) |
| Kachel | existiert ein Eintrag mit passendem Namen, sitzt es dort; sonst bekommt es eine **temporäre Kachel** am Dock-Ende, solange es läuft (nie gespeichert) |
| *Keep Icon* | macht die Kachel dauerhaft; Command = `<name>`, also `app_id` nach dem Programm benennen (`dockapp:wl-clock`) |
| *Kill* im Kachelmenü | beendet das Programm (einziger Weg vom Compositor aus) |
| Klick auf die Kachel | startet **keine** zweite Instanz, solange das DockApp läuft |

Das Framework für DockApp-Autoren ist damit: Tag setzen, Fenstergröße angeben, zeichnen. Alles
andere übernimmt der Compositor.

## Normale Programme

*Keep Application* im Dock-/Clip-Menü legt für ein laufendes Programm einen Starter an. Ein Klick
startet das Programm oder fokussiert sein Fenster; ein Starter ohne Fenster zeigt die drei Punkte
("läuft nicht").

## WMState: das einzige Format

Dock und Clip stehen in Window Makers Property-List `WMState`:

```
$XDG_STATE_HOME/wmaker-wl/WMState      (sonst ~/.local/state/wmaker-wl/WMState)
~/GNUstep/Defaults/WMState             (nur bei enable_wmaker_compat = true)
```

wmaker-wl schreibt die erste Datei selbst (atomar, per `rename`), sobald man Kacheln bewegt,
hinzufügt, entfernt oder Schalter ändert (`dock_save_state = true`). Beim Start gewinnt sie vor
`~/GNUstep`; ein leeres gespeichertes Dock bleibt leer. Löschen setzt auf `~/GNUstep` bzw. `config.conf`
zurück.

Gelesen und geschrieben werden:

* `Dock`: `Applications`, `Lowered`, `AutoRaiseLower`; die Logo-Kachel (`Command = "-"`) verankert die Spalte.
* `Clip`: `Applications` (alle Workspaces), `Lowered`, `Collapsed`, `AutoCollapse`, `AutoRaiseLower`.
* `Workspaces[i]`: `Name` und `Clip.Applications` (nur dieser Workspace).
* pro Eintrag: `Name`, `Command`, `Position` ("x,y"), `AutoLaunch`, `Lock`, `Lowered`.
* wmaker-wl-eigen (Window Maker ignoriert sie): `WMakerWLEdge`, `WMakerWLOffset` im Dock,
  `WMakerWLCorner` im Clip, `WMakerWLIcon`, `WMakerWLAppId` pro Eintrag.

Reihenfolge ist die Position: im Dock zählt `y` (die Logo-Kachel ist 0, Einträge darüber negativ), im
Clip `x`.

## Dock-Optionen

`dock_*` / `clip_*` in `config.conf`; Fensterzuordnung über `app_id` statt `WM_CLASS`
(`DockApp.matches`: expliziter `WMakerWLAppId`, `dockapp:<Name>`, Teile von `instance.Class`,
Programmname).

## Das Raster-Modell (`wm_dock.zig`, Port von `dock.c`)

Dock, Clip und Drawers teilen sich Window Makers Modell: jedes Icon hat eine Rasterposition
(`xindex`, `yindex`) relativ zur ersten Kachel seines Docks.

| Typ | Aufbau |
|---|---|
| **Dock** | Logo-Kachel und eine Spalte (`xindex = 0`); Zeilen dürfen leer bleiben, auch oberhalb des Logos (`yindex < 0`) |
| **Clip** | Workspace-Kachel in einer Ecke, Anwendungen des *aktuellen* Workspaces frei darum herum, jede neben einer anderen (`CLIP_ATTACH_VICINITY = 1`); *Omnipresent*-Kacheln wandern mit dem Workspace |
| **Drawer** | Kachel am Dock, öffnet eine lückenlose Reihe zur Bildschirmmitte; eingeklappt (nur die Kachel), bis der Zeiger kommt (*Autocollapse*) |

Verhalten wie im Original:

* Ziehen einer Kachel rastet über `snapIcon` ein: im eigenen Dock, dann in den anderen (Dock,
  Drawers, Clip). Losgelassen ohne Ziel wird sie entfernt (gesperrte Kacheln bleiben).
* Neue Kacheln kommen auf den ersten freien Platz (`findFreeSlot`: Spirale um die Clip-Kachel, am
  Rand entlang bei einer Clip in der Ecke).
* Ein Klick auf die Drawer-Kachel öffnet/schließt, ziehen verschiebt sie auf eine andere Dock-Zeile.
  *Add a drawer* steht im Dock-Menü, das Drawer-Menü hat *Collapsed*, *Autocollapse*, *Remove drawer*.
* Dock-Menü: *Dock position*, *Keep Application*, *Add a drawer*, *Info Panel*.

Gespeichert wird alles in `WMState`: `Dock.Applications` (`Position = "0,y"`),
`Clip`/`Workspaces[i].Clip` (`Position = "x,y"`), `Drawers` (`Name`, `Dock.Applications`,
`Collapsed`, `AutoCollapse`, wmaker-wl-eigen `WMakerWLRow`).

Jede Dock-Fläche (Dock, Clip, jeder Drawer) ist **eine** Layer-Surface um ihre Kacheln plus einen
Rand, auf den eine gezogene Kachel noch einrasten kann. Pointer-Eingaben nehmen nur die Kacheln
an (Input-Region), alles andere geht durch.