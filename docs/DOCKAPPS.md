# DockApps

Dieses Dokument beschreibt, wie ein Programm sich wmaker-wl gegenüber als DockApp zu erkennen
gibt, und die optionale Zusatzschicht für Autostart-Listen. Es gibt zwei unabhängige Dinge, die
oft verwechselt werden:

1. **„Ist dieses Fenster eine DockApp?"** -- beantwortet das Programm selbst, ganz ohne
   Konfigurationsdatei (siehe unten). Das ist der normale, empfohlene Weg.
2. **„Welche Programme sollen beim Sessionstart automatisch laufen?"** -- dafür reicht in den
   allermeisten Fällen das ohnehin vorhandene `autostart`-Skript (siehe „Autostart" unten), exakt
   wie bei X11 Window Maker. Eine eigene `dockapps.conf` ist nur nötig, wenn zusätzliche
   Dock-Metadaten (Icon, Grid-Position) außerhalb des Programms selbst hinterlegt werden sollen.

## Der empfohlene Weg: das Programm erkennt sich selbst

wmaker-wl braucht **keine Liste, keine Konfigurationsdatei**, um ein Fenster als DockApp zu
behandeln. Ein Programm muss dafür nur zwei Dinge selbst tun:

1. Seine Wayland-`app_id` auf `dockapp:<name>` oder `dockapp-<name>` setzen (z. B.
   `dockapp:clock`). Genau das ist die Wayland-Entsprechung dessen, was X11-Window-Maker-DockApps
   schon immer über `WM_CLASS`/`WM_HINTS` gemacht haben -- das Programm deklariert sich selbst,
   der Fenstermanager muss es nicht in einer Datei nachschlagen.
2. Optional eine feste Fenstergröße anfragen (gleiche Minimal- und Maximalgröße, klassisch
   64×64 px) -- wmaker-wl behandelt jedes Fenster mit fester Größe ohnehin automatisch als
   freischwebende Kachel statt es in die Tiling-Spalten einzureihen (siehe `window.zig`,
   `wantsFloating`).

Sobald wmaker-wl eine `app_id` mit einem der beiden Präfixe sieht (`src/dockapp.zig`,
`isSelfDeclared`), bekommt das Fenster automatisch:

| Attribut | Wert | Bedeutung |
|---|---|---|
| `NoTitlebar` | an | keine Titelleiste -- eine Kachel, kein normales Fenster |
| `NoBorder` | an | kein Rahmen |
| `Floating` | an | schwimmt frei, reiht sich nie in die Tiling-Spalten ein |
| `SkipWindowList` | an | taucht nicht in der Fensterliste auf |

Keine Datei anlegen, keinen Eintrag pflegen -- das Programm bringt seine Absicht selbst mit.

### Eigene Attribute trotzdem übersteuern

Diese vier Defaults sind genau das: Defaults. Eine ganz normale `attributes.conf`-Regel für den
jeweiligen `app_id` gewinnt pro Option, exakt wie bei jeder anderen Anwendung auch:

```
{ "dockapp:clock" = { NoBorder = No; StartWorkspace = 2; }; }
```

`NoBorder` bekommt hier explizit `No`, alles andere (`NoTitlebar`, `Floating`,
`SkipWindowList`) bleibt bei den DockApp-Defaults, weil die Datei dazu nichts sagt.

### Wie man eine `app_id` setzt

Wie genau, hängt vom Toolkit ab:

- **Roher Wayland-Client** (wie [`wl-clock`](../examples/wl-clock/),
  siehe unten): `xdg_toplevel`s `set_app_id`-Request mit dem gewünschten String.
- **GTK**: `Gio.Application`'s `application-id`, oder `gtk_window_set_wmclass`/
  `g_set_prgname`, je nach GTK-Version.
- **Qt**: `QGuiApplication::setDesktopFileName("dockapp:clock")`.
- **Ein Terminal-Programm** (kein eigenes Wayland-Fenster): der Terminal-Emulator setzt seine
  `app_id`, nicht das Programm darin. Mit `--class`/`--app-id` (je nach Emulator) lässt sich das
  von außen erzwingen, z. B. `alacritty --class dockapp:clock -e mein-programm`.

## Autostart: wie in X11 Window Maker

Für „dieses Programm soll beim Sessionstart laufen" gibt es bereits den identischen Mechanismus
wie bei X11 Window Maker: ein einziges Shell-Skript, `~/.config/wmaker-wl/autostart`
(`enable_autostart = true`, Default an), läuft einmal beim Start, komplett unabhängig von
DockApps. Für die allermeisten Fälle reicht das:

```sh
#!/bin/sh
wl-clock &
nm-applet &
```

Kein neues Format, keine zusätzliche Datei -- exakt der Weg, den es unter X11 auch schon gab.

## Optionale Zusatzschicht: `dockapps.conf` für Metadaten

Nur relevant, wenn zusätzlich zum reinen Start auch **Metadaten** hinterlegt werden sollen, die
das Programm selbst nicht über seine `app_id` transportieren kann -- ein Icon-Pfad, eine feste
Grid-Position im Dock, ein Eintrag für den Clip, oder eine bestehende Window-Maker-`WMState`-Datei
mit vorhandenen Dock-Einträgen übernehmen. Diese Datei bestimmt außerdem, **was im Dock und im
Clip steht** (siehe „Dock und Clip" unten). Für alles andere ist
diese Datei **nicht nötig** -- Selbst-Erkennung plus Autostart deckt den Normalfall vollständig
ab.

`src/dockapp.zig` liest dafür zwei Formate, die erste existierende Datei gewinnt:

### 1. Eigenes Format: `~/.config/wmaker-wl/dockapps.conf`

```ini
[htop]
command = alacritty --class dockapp:htop -e htop
icon = /usr/share/icons/hicolor/48x48/apps/utilities-system-monitor.png
position = 0,1
autolaunch = yes
```

| Feld | Bedeutung | Pflicht |
|---|---|---|
| `command` | Befehlszeile, die beim Start ausgeführt wird | ja |
| `icon` | PNG- oder **XPM**-Pfad, oder ein Name, der in `/usr/share/icons/hicolor/*/apps` und `/usr/share/pixmaps` (erst `.png`, dann `.xpm`) gesucht wird (Default: Programmname) | nein |
| `position` | Grid-Position `x,y` (Kachel-Koordinaten, nicht Pixel); im Dock zählt nur `y`, im Clip `x`, dann `y` | nein, Default `0,0` |
| `place` | `dock` oder `clip` | nein, Default `dock` |
| `workspace` | nur Clip: 1-basierter Workspace, oder `all` | nein, Default `all` |
| `app_id` | `app_id` der Fenster, die dieser Eintrag startet, falls sie sich nicht aus Name/Befehl ergibt | nein |
| `autolaunch` | beim Sessionstart einmal automatisch starten | nein, Default `no` |
| `lowered` | von Window Maker übernommen, gespeichert; ohne Wirkung (stattdessen `dock_on_top`/`clip_on_top` in `config.conf`) | nein, Default `no` |

Wichtig: **`command` ist die einzige Pflichtangabe.** Ein Eintrag ohne `command` wird beim Parsen
stillschweigend übersprungen -- kein Fehler, kein Absturz. Unbekannte Schlüssel werden ebenfalls
stillschweigend ignoriert, nicht gemeldet (das Format darf wachsen, ohne ältere Dateien zu
brechen) -- ein Tippfehler in einem Schlüsselnamen fällt also nicht auf. `command` wird ohne
Shell in Argumente zerlegt (`" "`-getrennt, `"Anführungszeichen"` für Argumente mit
Leerzeichen); für Pipes/Umleitungen explizit `/bin/sh -c "..."` verwenden. `#` leitet einen
Kommentar ein wie in `config.conf`.

### 2. Window Makers eigenes Format: `~/GNUstep/Defaults/WMState`

Nur wenn `enable_wmaker_compat = true` gesetzt ist **und** keine eigene `dockapps.conf`
existiert. Liest eine bestehende Window-Maker-`WMState`-Datei unverändert: `Dock.Applications`
(der Logo-Eintrag mit `Command = "-"` ist keine Anwendung, seine `Position` ist nur der Anker der
Spalte), den Clip (`Clip.Applications` für alle Workspaces, `Workspaces[i].Clip.Applications` nur für
Workspace `i`) und die Workspace-Namen (`Workspaces[i].Name`):

```
{ Dock = { Applications = ( { Command = xterm; Name = "xterm.XTerm"; AutoLaunch = No; }, ... ); };
  Workspaces = ( { Name = Main; Clip = { Applications = ( ... ); }; }, ... ); }
```

Gedacht, um ein bestehendes Window-Maker-Dock-Setup weiterzuverwenden, nicht um neue Einträge von
Hand zu schreiben.

### Autostart-Verhalten dieser Liste

`enable_dockapps = true` (Default) lädt diese Liste beim Sessionstart; jede Zeile mit
`autolaunch = yes` (bzw. `AutoLaunch = Yes`) wird einmal gestartet, in Dateireihenfolge, genau
wie das `autostart`-Skript -- und läuft bei einem SIGHUP-Reload bewusst nicht erneut. Eine
kaputte Datei wird übersprungen (mit Warnung), die Session startet trotzdem.

## Referenz-Implementierung: `wl-clock`

[`examples/wl-clock/`](../examples/wl-clock/) ist ein komplett eigenständiges Beispielprojekt (kein
Teil von wmaker-wl, keine Abhängigkeit darauf, eigenes `build.zig`/`build.zig.zon`, Zig 0.16.0): ein
roher Wayland-Client, der nur `app_id = "dockapp:<name>"` setzt und eine feste 64×64-Größe anfragt --
der komplette, empfohlene Weg von oben, ohne jede Konfigurationsdatei.

Er zeichnet seine ganze Kachel selbst, im Look der Dock-Kacheln (abgeschrägter Rahmen mit Verlauf,
darin ein eingelassenes LCD mit Datum, Sieben-Segment-Zeit, Monat und Sekundenbalken), wie es Window-
Maker-DockApps tun. Docked sieht man deshalb keinen Unterschied zu den Kacheln daneben. Ein Klick
schaltet 12/24 Stunden um. Mit `--name`, `--tz` und `--label` laufen mehrere Uhren nebeneinander
(Weltzeit), jede mit eigenem Eintrag:

```ini
[tokyo]
command = wl-clock --name tokyo --tz Asia/Tokyo --label tokyo
position = 0,2
autolaunch = yes
```

**Der Name verbindet beides:** der Eintragsname (`[tokyo]`) muss `wl-clock`s `--name` entsprechen,
denn das Fenster hat `app_id = dockapp:tokyo`. Siehe dessen
[README](../examples/wl-clock/README.md) zum Bauen, Ausprobieren und als Vorlage für eine eigene
DockApp.

## Dock und Clip

`ui.zig`/`dock.zig` zeichnen beides als 64-px-Kacheln im NeXT-/Window-Maker-Look.

**Dock** (`dock_enabled`, `dock_edge = left|right`, `dock_offset`, `dock_on_top`,
`dock_reserve_space`): eine Spalte am Bildschirmrand der ersten Ausgabe. Oben die „WM“-Logo-Kachel,
darunter die Einträge mit `place = dock`, nach `y` sortiert und lückenlos gestapelt (`y = 0` kommt
direkt hinter das Logo, ein negatives `y` davor).

| Aktion | Wirkung |
|---|---|
| Linksklick auf eine Kachel | Programm starten, oder das laufende Fenster fokussieren |
| Mittelklick | immer eine neue Instanz starten |
| Rechtsklick | Menü: *Launch*, *Lower Dock* / *Keep Dock on Top* |
| kleines Dreieck unten links | ein Fenster dieses Eintrags ist offen |

Ein Fenster gehört zu einem Eintrag, wenn (in dieser Reihenfolge) der explizite `app_id` passt;
sonst wenn `dockapp:<name>`/`dockapp-<name>` den Namen trifft, ein Teil eines Window-Maker-Namens
`instance.Class` die `app_id` ist, ein Argument des Befehls selbst eine solche `dockapp:…`-Kennung
trägt (`alacritty --class dockapp:htop` — dann zählt *nur* die), oder der Dateiname des Programms.
Groß-/Kleinschreibung egal.

**DockApp-Fenster in der Kachel:** ein Fenster mit `app_id = dockapp:<name>`, dessen Größe *fest*
(Min = Max) und höchstens 64×64 ist (der Beispielclient `wl-clock`), wird mittig in die Kachel des
gleichnamigen Eintrags gesetzt, über das Dock gestapelt und ist auf allen Workspaces sichtbar. Alles
andere (ein Terminal mit `--class dockapp:htop`) bleibt ein normales schwebendes Fenster; seine
Kachel startet/fokussiert es nur.

**Clip** (`clip_enabled`, `clip_corner`, `clip_on_top`, `clip_collapsed`, `workspace_names`):

| Aktion | Wirkung |
|---|---|
| Pfeil oben rechts / unten links | nächster / vorheriger Workspace |
| Mausrad über dem Clip | dito |
| Rechtsklick auf die Workspace-Kachel | Menü: *Collapse/Expand*, *Lower/Keep on Top*, Workspace vor/zurück, *Workspaces* |
| Mittelklick | Workspace-Menü |
| Kacheln daneben | Einträge mit `place = clip` des aktuellen Workspaces; Klick wie im Dock |

Liegt der Clip auf der Dock-Seite und überdeckt es, rückt er neben das Dock.

## Was noch fehlt

Dock und Clip lassen sich nicht mit der Maus verschieben, und Einträge nicht per Drag & Drop
hinzufügen oder entfernen: Position und Inhalt kommen aus `config.conf` und `dockapps.conf` /
`WMState`, und wmaker-wl schreibt nie in Nutzerdateien. Icons sind nur PNG (kein XPM, kein SVG). Das
Dock hat kein „Collapse“, und beide hängen an der ersten Ausgabe. Siehe `docs/TODO.md`.