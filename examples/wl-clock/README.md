# wl-clock

Eine Uhr als **DockApp** für [wmaker-wl](https://github.com/soundhearddev/WaylandMaker) -- und
zugleich die Vorlage, wie man eine eigene schreibt. Sie zeichnet eine 64×64-Kachel im Look der
Dock-Kacheln von wmaker-wl (hell abgeschrägter Rahmen mit Verlauf, wie bei Window Maker) mit einem
eingelassenen LCD darin:

```
 SAT 03        Wochentag und Tag
 08:20         Zeit in Sieben-Segment-Anzeige, der Doppelpunkt blinkt
 OCT      PM   Monat (oder --label), AM/PM im 12-Stunden-Modus
 ######        Balken, der sich über die Minute füllt
```

Die Kachel gehört dem **Dock**: Die Uhr nimmt keine Mausklicks an, sie fallen durch das Fenster auf die
Dock-Kachel darunter (Menü, Ziehen, Sperren, Entfernen, siehe [Zusammenspiel mit dem
Dock](#zusammenspiel-mit-dem-dock)). Zwischen 24 und 12 Stunden schaltet man mit `--12h`/`--24h`, im Betrieb
mit `pkill -USR1 wl-clock`, oder mit `--click` per Linksklick.

Kein Code aus wmaker-wl, kein Toolkit, kein Layer-Shell: ein gewöhnlicher `xdg_shell`-Client, der in
`wl_shm`-Buffer zeichnet. Er schläft in `poll(2)` bis zur nächsten Sekunde (bzw. Minute) und zeichnet
nur, wenn sich etwas ändert; es gibt genau einen Buffer-Pool mit zwei Buffern für die ganze Laufzeit.
Ohne `--click` bindet er nicht einmal einen Zeiger.

## Bauen

Braucht Zig **0.16.0**, `libwayland-dev` und `wayland-protocols`.

```sh
zig build                # zig-out/bin/wl-clock
zig build test           # Unit-Tests, kein Compositor nötig
zig build --prefix ~/.local install    # nach ~/.local/bin, damit es im PATH steht
```

Vorschau ohne Compositor (schreibt ein Bild im PPM-Format):

```sh
zig-out/bin/wl-clock --snapshot uhr.ppm
```

## In wmaker-wl einbinden

Zwei Dinge machen ein Programm zur DockApp, und beide stecken in `src/main.zig`:

1. `app_id` = `dockapp:<name>`
2. feste Fenstergröße (Min = Max), höchstens 64×64

Dann setzt wmaker-wl das Fenster **in die Kachel** des Dock-Eintrags mit demselben Namen: mittig,
über dem Dock, auf allen Workspaces, ohne Rahmen und Titelleiste, und nicht in der Fensterliste.
Der Eintrag in `~/.config/wmaker-wl/dockapps.conf` (fertig zum Kopieren: `dockapps.conf.example`):

```ini
[clock]
command = wl-clock
position = 0,1
autolaunch = yes
```

`[clock]` und `wl-clock`s `--name` (Standard: `clock`) müssen übereinstimmen. Bis die Uhr da ist,
zeigt die Kachel ihren Buchstaben; läuft sie, deckt das Fenster die Kachel genau ab.

### Zusammenspiel mit dem Dock

Das Dock von wmaker-wl verhält sich wie das von Window Maker (Details: `docs/DOCKAPPS.md`). Für die Uhr
heißt das:

| Du tust | Es passiert |
|---|---|
| Rechtsklick auf die Uhr | Kachel-Menü des Docks: *Launch*, *Lock*/*Unlock*, *Remove Icon*, *Kill* (beendet die Uhr). *Bring Here* und *Hide* sind ausgegraut: eine DockApp ist auf allen Workspaces und wird nie versteckt |
| Uhr-Kachel ziehen | auf einen anderen Platz = umsortieren, die Uhr zieht mit um; weit vom Dock weg loslassen = entfernen |
| Dock am Logo ziehen | das ganze Dock samt Uhr wandert an einen anderen Rand |
| *Remove Icon* / Kachel wegziehen | die Kachel verschwindet **und die Uhr wird beendet** (`xdg_toplevel.close`); ohne ihre Kachel wäre sie nur ein verlorenes 64×64-Fenster |
| Uhr läuft nicht (noch nicht gestartet, beendet) | die Kachel zeigt drei Punkte unten links; ein Doppelklick startet sie |
| Uhr wird gerade gestartet | die Kachel ist mit einem feinen Raster belegt, bis das Fenster da ist |

Was man so ändert, merkt sich wmaker-wl in `$XDG_STATE_HOME/wmaker-wl/dock.conf` und liest es beim
nächsten Start **statt** deiner `dockapps.conf`. Lösch die Datei, um wieder bei den Einträgen aus
`dockapps.conf` anzufangen.

Zwei Beschränkungen, beide gewollt: Ist die Uhr gestartet, aber ihre Kachel fehlt (Eintrag nicht in der
Liste, anderer Name), bleibt sie ein gewöhnliches kleines schwebendes Fenster. Und mit `--click` gehört die
Maus wieder der Uhr: Menü und Ziehen der Kachel gehen dann nicht mehr, solange die Uhr läuft.

### Mehrere Uhren

Jede Uhr braucht einen eigenen Namen und einen eigenen Eintrag:

```ini
[tokyo]
command = wl-clock --name tokyo --tz Asia/Tokyo --label tokyo
position = 0,2
autolaunch = yes
```

## Optionen

| Option | Bedeutung |
|---|---|
| `-n`, `--name NAME` | `app_id`-Suffix = Name des Eintrags (Standard `clock`; Buchstaben, Ziffern, `_`, `-`) |
| `-z`, `--tz ZONE` | Zeitzone, z. B. `Europe/Berlin` (Standard: lokale Zeit) |
| `-l`, `--label TEXT` | statt des Monatsnamens, bis 8 Zeichen |
| `--12h` / `--24h` | Startmodus. Im Betrieb schaltet `pkill -USR1 wl-clock` um (z. B. auf eine Taste in wmaker-wl legen: `bind = Super+T, pkill -USR1 wl-clock`) |
| `--click` | die Uhr behält die Maus: Linksklick schaltet 12/24 Stunden um, das Dock bekommt auf dieser Kachel keine Klicks mehr |
| `--no-seconds` | kein Sekundenbalken, Doppelpunkt blinkt nicht, eine Aktualisierung pro Minute |
| `--snapshot DATEI` | ein Bild schreiben und beenden |
| `-h`, `--help` | Hilfe |

## Als Vorlage für eine eigene DockApp

* `src/face.zig` ist reine Zeichenlogik ohne Wayland und ohne libc: Kachelrahmen, antialiasierte
  Segmente, 3×5-Pixelschrift. Ersetze `render()`, der Rest bleibt.
* `src/main.zig` enthält alles, was Wayland betrifft: Registry, ein Pool mit zwei Buffern,
  `release`-Behandlung, `poll`-Schleife, die **leere Eingaberegion** (`wl_surface.set_input_region`, damit
  das Dock die Klicks bekommt), Zeiger nur mit `--click`, sauberes Beenden bei `SIGINT`/`SIGTERM` und
  Umschalten per `SIGUSR1`.
* `src/options.zig` ist die Kommandozeile.

Eine DockApp zeichnet ihre **ganze** 64×64-Kachel selbst, Rahmen eingeschlossen (so ist es bei
Window Maker auch). Die Farben des Rahmens stammen aus `src/dock.zig` von wmaker-wl; wer ein anderes
Theme will, ändert sie an beiden Stellen.

Eine eigene DockApp sollte **die Maus dem Dock überlassen**, außer sie braucht sie wirklich: leere
Eingaberegion setzen (vor dem ersten `commit`), und alles aus dem Kachel-Menü, Ziehen und Entfernen
funktioniert ohne weiteren Code. Das Dock schließt die DockApp beim Entfernen der Kachel selbst; ein
sauberes Beenden bei `xdg_toplevel.close` genügt.

## Projektstruktur

```
wl-clock/
├── build.zig              # Bauen, Testen, Protokoll-Bindings
├── build.zig.zon          # Paket-Metadaten, zig-wayland
├── src/main.zig           # Wayland-Client, Ereignisschleife, Eingaberegion
├── src/face.zig           # Kachel zeichnen (rein, getestet)
├── src/options.zig        # Kommandozeile (rein, getestet)
├── dockapps.conf.example  # Einträge für wmaker-wl (zum Kopieren)
└── README.md
```