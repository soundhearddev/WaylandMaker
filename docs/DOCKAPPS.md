# DockApps, Dock und Clip

wmaker-wl folgt hier Window Maker (`dock.c`, `appicon.c`): **ein** Dateiformat, **kein** Register
von DockApps, und DockApps sind keine Fenster.

## DockApps: starten, fertig

Ein DockApp ist ein ganz normales Programm. Es meldet sich selbst an:

1. Wayland-`app_id` = `dockapp:<name>` (oder `dockapp-<name>`),
2. feste Fenstergröße (gleiche Min-/Max-Größe, klassisch 64×64).

Gestartet wird es, wie man will: `autostart`-Skript, Menü, Terminal oder ein `WMState`-Eintrag mit
`AutoLaunch = Yes`. Eine Konfigurationsdatei gibt es dafür nicht.

Was wmaker-wl daraus macht:

| Situation | Verhalten |
|---|---|
| Eintrag mit passendem Namen existiert | das Fenster sitzt in dessen Kachel |
| kein Eintrag | **temporäre Kachel** am Ende des Docks, solange das Programm läuft (Window Makers Icon, das man ins Dock zieht); sie wird nie gespeichert |
| Kachelmenü → *Keep Icon* | die Kachel wird dauerhaft; Command = `<name>`, also `app_id` nach dem Programm benennen (`dockapp:wl-clock`) |
| Mod+Q / Close-Taste | wirkungslos: ein DockApp ist ein Icon, kein Fenster |
| Kachelmenü → *Kill* | beendet das Programm |
| Klick, Hover, Fokus | gehen an das DockApp selbst, der Fokus bleibt unverändert |

Ein DockApp hat keine Titelleiste, keinen Rahmen, schwebt, ist auf allen Workspaces und taucht in
keiner Fensterliste auf. Einzelne Werte lassen sich mit einer normalen `attributes.conf`-Regel für
seine `app_id` überschreiben.

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