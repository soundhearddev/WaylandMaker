# DockApps: eigene Einträge anlegen

Dieses Dokument beschreibt das DockApp-Format von wmaker-wl (`src/dockapp.zig`): was eine
DockApp ist, wie man eine eigene definiert, und worauf man dabei achten muss. Es richtet sich
an Nutzer, die `~/.config/wmaker-wl/dockapps.conf` von Hand schreiben, nicht an eine grafische
Oberfläche -- die gibt es noch nicht (siehe „Was noch fehlt" unten).

## Was eine DockApp ist

Window Maker kennt DockApps als kleine, eigenständige Programme mit genau einer 64×64-px-Kachel
im Dock oder im Clip: ein Icon, ein Klick startet den zugehörigen Befehl. wmaker-wl übernimmt
diese Idee als reines Datenformat -- ein `DockApp`-Eintrag ist:

| Feld | Bedeutung | Pflicht |
|---|---|---|
| Name | Anzeigename | ja |
| Command | Befehlszeile, die beim Start ausgeführt wird | ja |
| Icon | Pfad/Name eines Icons | nein |
| Position | Grid-Position (Kachel-Koordinaten, nicht Pixel) | nein, Default `0,0` |
| AutoLaunch | beim Sessionstart einmal automatisch starten | nein, Default `No` |
| Lowered | Kachel liegt unter statt über normalen Fenstern | nein, Default `No` |

Wichtig: **`Command` ist die einzige Pflichtangabe.** Ein Eintrag ohne `Command` wird beim
Parsen stillschweigend übersprungen -- kein Fehler, kein Absturz, er taucht einfach nicht in
der geladenen Liste auf. Das ist Absicht (siehe „Fehlerverhalten" unten), aber leicht zu
übersehen, wenn man sich fragt, warum eine DockApp nicht startet.

## Zwei Wege, eine DockApp zu definieren

wmaker-wl liest **eine** der beiden folgenden Dateien -- die erste, die existiert und sich
parsen lässt, gewinnt. Es werden nicht beide gemischt.

### 1. Eigenes Format: `~/.config/wmaker-wl/dockapps.conf`

Der empfohlene Weg, wenn kein bestehendes Window-Maker-Setup übernommen werden soll. Syntax wie
`attributes.conf`: ein `[name]`-Block pro DockApp, darin `key = value`-Zeilen.

```ini
# ~/.config/wmaker-wl/dockapps.conf

[htop]
command = alacritty -e htop
icon = /usr/share/icons/hicolor/48x48/apps/utilities-system-monitor.png
position = 0,1
autolaunch = yes

[nm-applet]
command = nm-applet
autolaunch = yes

[galculator]
command = "galculator"
autolaunch = no
lowered = true
```

Regeln für dieses Format:

- Ein `[name]`-Header **beendet** den vorherigen Block und startet einen neuen. Alles davor, was
  nicht in einem Block steht, wird ignoriert.
- `#` leitet einen Kommentar ein, wenn es am Zeilenanfang steht oder auf Leerraum folgt -- exakt
  wie in `config.conf`/`attributes.conf`.
- `command = ...` wird wie eine normale Befehlszeile in Argumente zerlegt (`" "`-getrennt, mit
  Unterstützung für `"doppelte Anführungszeichen"` bei Argumenten mit Leerzeichen). Es gibt
  **keine Shell** dazwischen -- `command = foo | bar` startet ein Programm namens `foo` mit den
  Argumenten `|` und `bar`, keine Pipe. Braucht ein Befehl tatsächlich eine Shell (Pipes,
  Umleitungen, Variablen), muss man das explizit machen: `command = /bin/sh -c "foo | bar"`.
- Unbekannte Schlüssel innerhalb eines Blocks werden ignoriert, nicht als Fehler gemeldet -- das
  Format darf wachsen, ohne ältere Dateien zu brechen. Ein Tippfehler in einem Schlüssel (z. B.
  `autolauch` statt `autolaunch`) führt also **nicht** zu einer Warnung, sondern einfach dazu,
  dass die Option ihren Default behält. Bei Problemen: Schlüsselnamen genau mit der Tabelle oben
  vergleichen.
- `position = x,y` sind vorzeichenbehaftete Ganzzahlen (auch negativ, z. B. `position = -1,0`),
  keine Pixel -- siehe „Was Position bedeutet" unten.
- `autolaunch` und `lowered` akzeptieren `yes`/`no`, `true`/`false`, `on`/`off`, `1`/`0`.

### 2. Window Makers eigenes Format: `~/GNUstep/Defaults/WMState`

Nur relevant, wenn `enable_wmaker_compat = true` gesetzt ist (Default: aus) **und** keine eigene
`dockapps.conf` existiert. Liest den `Dock`- (oder ersatzweise `Clip`-)Abschnitt einer
bestehenden Window-Maker-`WMState`-Datei, ohne dass man dafür irgendetwas umschreiben muss:

```
{
  Dock = {
    Applications = (
      { Command = xterm; Name = "xterm.XTerm"; AutoLaunch = No; Position = "0,1"; },
      { Command = "nm-applet"; Name = nm-applet; AutoLaunch = Yes; Position = "0,2"; }
    );
    Position = "-64,0";
    Lowered = No;
  };
}
```

Das ist eine GNUstep-Property-List (dieselbe Syntax wie `WMRootMenu`/`WMWindowAttributes`,
siehe `plist.zig`). Dieser Weg ist gedacht, um ein bestehendes Window-Maker-Dock-Setup
weiterzuverwenden, nicht um neue Einträge von Hand zu schreiben -- dafür ist Format 1 einfacher.

## Wie eine DockApp geladen wird

Die Kandidaten-Reihenfolge (implementiert in `wm_files.zig`, `candidates(.dockapps, ...)`):

1. `~/.config/wmaker-wl/dockapps.conf` (bzw. `$XDG_CONFIG_HOME/wmaker-wl/dockapps.conf`)
2. `~/GNUstep/Defaults/WMState` (bzw. `$WMAKER_USER_ROOT/Defaults/WMState`), nur wenn
   `enable_wmaker_compat = true`

Die **erste Datei, die existiert UND sich fehlerfrei parsen lässt**, gewinnt. Eine
existierende, aber kaputte Datei wird mit einer Warnung übersprungen, der nächste Kandidat wird
versucht -- die Session startet immer, auch mit einer fehlerhaften `dockapps.conf`.

`enable_dockapps = true` (Default) steuert, ob überhaupt geladen wird -- siehe
`src/share/default_config.conf`. `enable_dockapps = false` deaktiviert das komplett, unabhängig
davon, welche Dateien existieren.

## Autostart-Verhalten

Jede DockApp mit `autolaunch = yes` wird **einmal** beim Sessionstart gestartet, genau wie das
bestehende `autostart`-Skript (`dockapp.runAutoLaunch()`, aufgerufen aus `main()`). Wichtig:

- Die Reihenfolge im Dokument wird eingehalten -- Einträge werden in der Reihenfolge gestartet,
  in der sie in der Datei stehen.
- Ein **SIGHUP-Reload** (`kill -HUP <pid>`, siehe `docs/TODO.md`) startet DockApps **nicht**
  erneut -- genau wie das Autostart-Skript auch nicht erneut läuft. Nur Tastenkürzel, Root-Menü
  und Fenster-Attribute werden neu geladen.
- Ein Prozess wird detached gestartet (kein Elternprozess-Zombie, `SIGCHLD` wird ignoriert) --
  siehe `process.zig`.
- Scheitert `spawn` (z. B. Befehl nicht gefunden), wird das geloggt, die übrigen DockApps in der
  Liste starten trotzdem weiter.

## Was Position bedeutet

`x`/`y` sind Window Makers **Grid-Koordinaten** (Kachel-Einheiten relativ zur Dock-Ecke), keine
Pixel. Eine künftige Dock-UI entscheidet die tatsächliche Kachelgröße (Window Makers Standard
ist 64 px). Bis es eine solche UI gibt (siehe unten), hat `position` **keine sichtbare
Wirkung** -- der Wert wird nur mitgeladen und steht bereit.

## Fehlerverhalten -- worauf achten

- **Kein `Command`/`command` → Eintrag wird stillschweigend übersprungen.** Kein Log, kein
  Fehler. Wenn eine erwartete DockApp fehlt, zuerst prüfen, ob `command` tatsächlich gesetzt ist.
- **Unbekannte Schlüssel werden ignoriert, nicht gemeldet.** Ein Tippfehler in einem Schlüssel
  fällt nicht auf, weil er weder einen Fehler noch eine Warnung erzeugt -- die Option bleibt
  einfach beim Default.
- **Eine kaputte Datei blockiert nicht die Session**, aber auch nicht automatisch den nächsten
  Kandidaten, wenn die kaputte Datei die einzige mit höherer Priorität ist, die existiert: Ist
  z. B. `dockapps.conf` vorhanden, aber mit einem Syntaxfehler (nur bei der WMState-Variante
  überhaupt als „Syntax" erkennbar, das eigene Format hat keinen harten Fehlzustand), wird das
  geloggt und `~/GNUstep/Defaults/WMState` als nächster Kandidat versucht.
- **`command` ohne Shell:** siehe oben -- Pipes, Umleitungen, Globbing (`*`) funktionieren nicht
  ohne ein explizites `/bin/sh -c "..."`.
- **`enable_wmaker_compat = false` (Default) blendet `WMState` komplett aus.** Wer eine
  bestehende Window-Maker-Dock-Konfiguration übernehmen will, muss `enable_wmaker_compat = true`
  in `config.conf` setzen.

## Was noch fehlt (bewusst nicht Teil dieses Frameworks)

Dieses Format lädt und startet DockApps -- es **zeichnet noch keine Dock-Kacheln**. Das ist
Phase 5 in `docs/TODO.md` und braucht mehr als dieses Dokument abdeckt:

- Eine tatsächliche 64-px-Kachel-UI (`wl_shm`/cairo, wie beim Root-Menü in `ui.zig`/`gfx.zig`).
- Eine wichtige Einschränkung dabei: `river_layer_shell_v1`
  (`protocol/river-layer-shell-v1.xml`) erlaubt wmaker-wl **nicht**, selbst eine
  Layer-Shell-Surface zu erzeugen -- das Protokoll lässt den Fenstermanager nur erfahren, wie
  viel Platz *externe* Layer-Shell-Clients (Bars, Docks) reserviert haben
  (`non_exclusive_area`, siehe `output.zig`). Eine echte Dock-Kachel-Leiste ist deshalb entweder
  (a) eigenes Zeichnen über die vorhandene `wl_shm`/cairo-Infrastruktur, genau wie das
  Root-Menü, oder (b) ein separater Client-Prozess, den wmaker-wl startet.
- „Läuft"-Anzeige über `app_id`-Vergleich, Rechtsklick-Menü, Icon-Laden (insbesondere klassische
  XPM-Icons brauchen einen eigenen Lader, siehe `docs/INTEGRATION.md`).

Bis dahin ist der Nutzen dieses Formats: ein einheitlicher, geprüfter Weg, DockApp-Definitionen
zu laden und `autolaunch`-Einträge beim Sessionstart zu starten -- unabhängig davon, ob sie aus
einer neuen `dockapps.conf` oder einer bestehenden Window-Maker-`WMState` kommen.