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

Dann behandelt wmaker-wl das Fenster als Icon, nicht als Fenster: Es sitzt **in einer Dock-Kachel**
(mittig, auf allen Workspaces, ohne Rahmen und Titelleiste, nicht in der Fensterliste) und lässt sich
nicht mit der Close-Taste (Mod+Q) schließen. Beenden geht über *Kill* im Kachelmenü.

Konfiguration gibt es keine. Starte die Uhr einfach, z. B. in `~/.config/wmaker-wl/autostart`:

```sh
wl-clock &
```

Ohne eigenen Dock-Eintrag bekommt sie eine **temporäre Kachel** am Ende des Docks, solange sie läuft.
*Keep Icon* im Kachelmenü macht die Kachel dauerhaft; wmaker-wl speichert sie in seiner `WMState` mit
dem Befehl `wl-clock` (deshalb ist `wl-clock` der Standardname). Ab dann kann der Eintrag auch
`AutoLaunch = Yes` haben, und die Uhr startet mit dem Dock.

### Mehrere Uhren

Jede Uhr braucht einen eigenen Namen:

```sh
wl-clock &
wl-clock --name tokyo --tz Asia/Tokyo --label tokyo &
```

Beide bekommen eine temporäre Kachel. Für die zweite speichert *Keep Icon* nur den Befehl `tokyo`;
soll sie dauerhaft sein, trag in der `WMState` einen Eintrag mit `Command = "wl-clock --name tokyo
--tz Asia/Tokyo --label tokyo"` und `Name = "tokyo"` ein.

## Optionen

| Option | Bedeutung |
|---|---|
| `-n`, `--name NAME` | `app_id`-Suffix = Name des Programms (Standard `wl-clock`; Buchstaben, Ziffern, `_`, `-`) |
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
└── README.md
```