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

Ein Klick schaltet zwischen 24 und 12 Stunden um.

Kein Code aus wmaker-wl, kein Toolkit, kein Layer-Shell: ein gewöhnlicher `xdg_shell`-Client, der in
`wl_shm`-Buffer zeichnet. Er schläft in `poll(2)` bis zur nächsten Sekunde (bzw. Minute) und zeichnet
nur, wenn sich etwas ändert; es gibt genau einen Buffer-Pool mit zwei Buffern für die ganze Laufzeit.

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
Der Eintrag in `~/.config/wmaker-wl/dockapps.conf` (siehe `dockapps.conf.example`):

```ini
[clock]
command = wl-clock
position = 0,1
autolaunch = yes
```

`[clock]` und `wl-clock`s `--name` (Standard: `clock`) müssen übereinstimmen. Bis die Uhr da ist,
zeigt die Kachel ihren Buchstaben; läuft sie, deckt das Fenster die Kachel genau ab.

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
| `--12h` / `--24h` | Startmodus (Klick schaltet um) |
| `--no-seconds` | kein Sekundenbalken, Doppelpunkt blinkt nicht, eine Aktualisierung pro Minute |
| `--snapshot DATEI` | ein Bild schreiben und beenden |
| `-h`, `--help` | Hilfe |

## Als Vorlage für eine eigene DockApp

* `src/face.zig` ist reine Zeichenlogik ohne Wayland und ohne libc: Kachelrahmen, antialiasierte
  Segmente, 3×5-Pixelschrift. Ersetze `render()`, der Rest bleibt.
* `src/main.zig` enthält alles, was Wayland betrifft: Registry, ein Pool mit zwei Buffern,
  `release`-Behandlung, `poll`-Schleife, Zeiger (Klick, Cursorform), sauberes Beenden bei
  `SIGINT`/`SIGTERM`.
* `src/options.zig` ist die Kommandozeile.

Eine DockApp zeichnet ihre **ganze** 64×64-Kachel selbst, Rahmen eingeschlossen (so ist es bei
Window Maker auch). Die Farben des Rahmens stammen aus `src/dock.zig` von wmaker-wl; wer ein anderes
Theme will, ändert sie an beiden Stellen.

## Projektstruktur

```
wl-clock/
├── build.zig              # Bauen, Testen, Protokoll-Bindings
├── build.zig.zon          # Paket-Metadaten, zig-wayland
├── src/main.zig           # Wayland-Client, Ereignisschleife
├── src/face.zig           # Kachel zeichnen (rein, getestet)
├── src/options.zig        # Kommandozeile (rein, getestet)
├── dockapps.conf.example  # Einträge für wmaker-wl
└── README.md
```