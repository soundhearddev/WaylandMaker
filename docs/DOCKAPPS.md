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

- **Roher Wayland-Client** (wie [`wmaker-dockapp-clock`](../examples/wmaker-dockapp-clock/),
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
wmaker-dockapp-clock &
nm-applet &
```

Kein neues Format, keine zusätzliche Datei -- exakt der Weg, den es unter X11 auch schon gab.

## Optionale Zusatzschicht: `dockapps.conf` für Metadaten

Nur relevant, wenn zusätzlich zum reinen Start auch **Metadaten** hinterlegt werden sollen, die
das Programm selbst nicht über seine `app_id` transportieren kann -- ein Icon-Pfad, eine feste
Grid-Position für eine künftige Dock-UI (siehe „Was noch fehlt" unten), oder eine bestehende
Window-Maker-`WMState`-Datei mit vorhandenen Dock-Einträgen übernehmen. Für alles andere ist
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
| `icon` | Pfad/Name eines Icons | nein |
| `position` | Grid-Position `x,y` (Kachel-Koordinaten, nicht Pixel) | nein, Default `0,0` |
| `autolaunch` | beim Sessionstart einmal automatisch starten | nein, Default `no` |
| `lowered` | Kachel liegt unter statt über normalen Fenstern | nein, Default `no` |

Wichtig: **`command` ist die einzige Pflichtangabe.** Ein Eintrag ohne `command` wird beim Parsen
stillschweigend übersprungen -- kein Fehler, kein Absturz. Unbekannte Schlüssel werden ebenfalls
stillschweigend ignoriert, nicht gemeldet (das Format darf wachsen, ohne ältere Dateien zu
brechen) -- ein Tippfehler in einem Schlüsselnamen fällt also nicht auf. `command` wird ohne
Shell in Argumente zerlegt (`" "`-getrennt, `"Anführungszeichen"` für Argumente mit
Leerzeichen); für Pipes/Umleitungen explizit `/bin/sh -c "..."` verwenden. `#` leitet einen
Kommentar ein wie in `config.conf`.

### 2. Window Makers eigenes Format: `~/GNUstep/Defaults/WMState`

Nur wenn `enable_wmaker_compat = true` gesetzt ist **und** keine eigene `dockapps.conf`
existiert. Liest den `Dock`- (ersatzweise `Clip`-)Abschnitt einer bestehenden
Window-Maker-`WMState`-Datei unverändert:

```
{ Dock = { Applications = ( { Command = xterm; Name = "xterm.XTerm"; AutoLaunch = No; }, ... ); }; }
```

Gedacht, um ein bestehendes Window-Maker-Dock-Setup weiterzuverwenden, nicht um neue Einträge von
Hand zu schreiben.

### Autostart-Verhalten dieser Liste

`enable_dockapps = true` (Default) lädt diese Liste beim Sessionstart; jede Zeile mit
`autolaunch = yes` (bzw. `AutoLaunch = Yes`) wird einmal gestartet, in Dateireihenfolge, genau
wie das `autostart`-Skript -- und läuft bei einem SIGHUP-Reload bewusst nicht erneut. Eine
kaputte Datei wird übersprungen (mit Warnung), die Session startet trotzdem.

## Referenz-Implementierung: `wmaker-dockapp-clock`

[`examples/wmaker-dockapp-clock/`](../examples/wmaker-dockapp-clock/) ist ein komplett
eigenständiges Beispielprojekt (kein Teil von wmaker-wl, keine Abhängigkeit darauf, eigenes
`build.zig`/`build.zig.zon`, Zig 0.16.0): ein roher Wayland-Client, der nur `app_id =
"dockapp:clock"` setzt und eine feste 64×64-Größe anfragt -- der komplette, empfohlene Weg von
oben, ohne jede Konfigurationsdatei. Siehe dessen eigene
[README](../examples/wmaker-dockapp-clock/README.md) zum Bauen, Ausprobieren und als Vorlage für
eine eigene DockApp.

## Was noch fehlt

Weder Selbst-Erkennung noch `dockapps.conf` zeichnen eine grafische Dock-Kachel-Leiste -- das
ist Phase 5 in `docs/TODO.md`. `river_layer_shell_v1` (`protocol/river-layer-shell-v1.xml`)
erlaubt wmaker-wl außerdem nicht, selbst eine Layer-Shell-Surface zu erzeugen (es lässt den
Fenstermanager nur wissen, wie viel Platz *externe* Layer-Shell-Clients belegen, siehe
`output.zig`s `non_exclusive_area`). Bis dahin ist eine DockApp ein normales, freischwebendes
Fenster mit den oben beschriebenen Attributen -- funktional bereits nützlich (kein Rahmen, kein
Titel, taucht nicht in der Fensterliste auf), aber noch keine feste Kachel-Position im
Bildschirmrand.