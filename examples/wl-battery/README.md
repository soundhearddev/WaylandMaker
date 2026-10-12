# wl-battery

Kleiner 64x64 Batterie-Monitor als DockApp für wmaker-wl (Zig 0.16.0), gebaut auf wl-clock.

```
[Symbol] [Stecker]  12W    Status-Symbol, Stecker (am Netz), Leistung
        8 7 %              Ladestand, Sieben-Segment
[Uhr] 1:23                 Restzeit bis leer / bis voll
[#######---]               10 Segmente
```

Status-Symbole: Blitz = lädt, Pfeil runter = entlädt, Haken = voll, Pause = lädt nicht,
? = unbekannt, Kreuz = kein Akku.

Farbe: grün, ab 20 % gelb, ab 10 % rot (nicht beim Laden). Klick = sofort neu lesen.

## Update / Performance

- Der Kernel meldet Änderungen an Akku und Netzteil per uevent (netlink, ohne root):
  Stecker rein/raus und Prozentwechsel erscheinen sofort. Zusätzlich liest ein Timer
  spätestens alle `-i` Sekunden (Leistung/Restzeit ändern sich ohne Event).
- Verzeichnis wird nur einmal gescannt; die Dateien bleiben offen, ein Lesen sind ~10 `pread()`.
- Neu gezeichnet wird nur, wenn sich ein Wert ändert; Kachel + LCD werden einmal gebaut und nur kopiert.
- Ohne Akku liest der Timer nur noch alle 60 s. Single-threaded, im Release gestrippt.
- Am kleinsten/schnellsten: `zig build -Doptimize=ReleaseSmall`.

## Build

    zig build -Doptimize=ReleaseSafe
    zig build test
    ./zig-out/bin/wl-battery --snapshot /tmp/bat.ppm   # ohne Compositor

Autostart: `wl-battery &` in `~/.config/wmaker-wl/autostart`.

## Optionen

    -n, --name NAME      app_id-Suffix (Default: wl-battery)
    -b, --battery NAME   Akku, z.B. BAT1 (Default: erster Akku)
    -i, --interval SEC   spätestens alle SEC Sekunden lesen, 1..3600 (Default: 5)
    -v, --verbose        jeden Redraw auf stderr ausgeben
        --snapshot FILE  ein Frame als PPM, dann Ende

Quelle: `/sys/class/power_supply`. Energie (µWh) oder Ladung (µAh) werden erkannt;
Leistung aus `power_now` oder `current_now * voltage_now`. AC = irgendeine
Nicht-Akku-Quelle mit `online=1`. Peripherie-Akkus (scope Device) werden übersprungen.