# WPrefs für wmaker-wl: Bestandsaufnahme & Plan

Dieses Dokument beschreibt, was X11 Window Makers `WPrefs.app` konfiguriert, was davon in
wmaker-wl (dieses Projekt) schon über `config.conf`/`attributes.conf`/`dockapps.conf` abgedeckt
ist, und was für ein modernes Äquivalent noch fehlt. Ziel ist **kein** 1:1-Klon von WPrefs'
GTK/WINGs-Oberfläche, sondern derselbe Funktionsumfang, zeitgemäß umgesetzt: eine
GUI-Konfigurationsschicht über denselben `config.conf`/`attributes.conf`-Dateien, die auch von
Hand editierbar bleiben -- die GUI ist ein Komfort-Layer, keine neue Quelle der Wahrheit.

Kontext: `docs/TODO.md` listet "Phase 6: Themes, `~/GNUstep/Defaults/WindowMaker`-Schlüssel" noch
als offen, und `compatibility.zig`s `loadTheme()` ist ein reiner `TODO`-Stub. Eine WPrefs-artige
GUI setzt auf genau dieser Schicht auf und kann realistischerweise erst sinnvoll entstehen, wenn
Phase 5 (Dock/Clip) und Phase 6 (Themes) zumindest im Datenmodell stehen -- eine GUI, die Optionen
anzeigt, die der Compositor noch gar nicht auswertet, wäre irreführend.

## Stand: `wlprefs` (Version 0.2)

`wlprefs/` ist das GUI-Projekt aus §5, ein eigenständiges Programm (`zig build` im Root baut es mit,
`cd wlprefs && zig build` allein auch). Es bildet WPrefs.app geometrisch nach (gleiches Fenster, gleiche
16 Abschnitts-Icons) und bearbeitet genau die Datei, die wmaker-wl liest.

**Echte Seiten** (jede Einstellung ist ein `config.conf`-Schlüssel):

| Abschnitt | Schlüssel |
|---|---|
| Window Focus | `focus_follows_mouse`, `center_focused_column` |
| Window Handling | `new_window`, `gap`, `outer_gap`, `min_window_size` |
| Workspace | `workspace_count`, `workspace_names`, `default_column_width`, `width_step`, `width_presets` |
| Appearance | `border_width`, `border_focused`, `border_unfocused`, `border_floating`, `theme` |
| Mouse | `mouse_mod` (beliebige Kombination), `drag_threshold`, `floating_size` |
| Ergonomic (Standardprogramme) | `terminal`, `launcher`, `browser` |
| Docks | `dock_enabled`, `dock_edge`, `dock_offset`, `dock_on_top`, `dock_reserve_space`, `clip_enabled`, `clip_corner`, `clip_on_top`, `clip_collapsed` |
| Other Configurations | `enable_dockapps`, `enable_autostart`, `enable_wmaker_compat` |
| Keyboard Shortcuts | die wirksamen Kürzel (Standard + eigene, `*` = aus der eigenen Datei) **bearbeiten**: Add / Edit / Remove, „Record“ nimmt die Tastenkombination auf; geprüft werden Taste (gegen xkbcommon) und Aktion (Liste in `wlprefs/src/actions.zig`, im Compositor-Test gegen `types.Command` abgeglichen). Dazu `bind_layout` (welches Tastaturlayout die Kürzel übersetzt). Geschrieben wird die kleinste Menge `bind`/`unbind`-Zeilen, die aus den Standardwerten die Liste macht; Gleiches bleibt ungeschrieben, der Rest der Datei unberührt |

Menu Preferences zeigt das WPrefs-Bild, ist aber ausdrücklich „nur Anzeige“ (wmaker-wl hat diese
Optionen nicht). Icons, Paths, Menu, Hot Corners, Fonts und Expert haben keine Entsprechung und sagen
auf ihrer Seite, warum und was man stattdessen tut.

**Speichern verändert nie mehr als nötig** (`settings.render`, `prefs.save`, `configfile.writeAtomic`):

- Die Datei wird beim Start gelesen und beim Speichern **noch einmal**. Geändert werden nur die Zeilen
  der Schlüssel, die der Nutzer geändert hat; Kommentare, Leerzeilen, `bind`/`unbind`, unbekannte
  Schlüssel, CRLF und von Hand zwischenzeitlich Geändertes bleiben unberührt.
- Eine Datei, die existiert, aber nicht lesbar ist, **sperrt das Speichern** (statt sie durch den
  GUI-Zustand zu ersetzen). Fehlt sie, wird sie beim ersten Speichern angelegt.
- Schreiben ist atomar (temporäre Datei, `fsync`, `rename`), behält die Rechte, folgt einem Symlink
  (Dotfile-Manager) und legt beim ersten Überschreiben einer Sitzung `config.conf.bak` an.
- Werte, die der Compositor ablehnen oder falsch lesen würde (leeres Terminal, Befehl mit führendem
  Anführungszeichen, Presets außerhalb (0,1], kein Maus-Modifier), werden **nicht geschrieben**, mit
  Meldung. Ein Wert, den das GUI nicht darstellen kann (`mouse_mod = Super+Mod5`), bleibt wie er ist.
- Die Standardwerte stammen aus `src/share/default_config.conf` (zur Bauzeit eingebettet), nicht aus
  einer Kopie. Ein Test im Compositor prüft, dass alles, was wlprefs schreibt, von `config.zig` mit
  demselben Wert gelesen wird (`wlprefs and the compositor agree`).
- Danach bekommt jeder laufende `wmaker-wl` des Nutzers `SIGHUP` (über `/proc`, ohne `pkill`).

Bedienung: `Save` (oder Strg+S), `Revert Page`, `Revert All`, `Defaults` (die Schlüssel der Seite auf
wmaker-wls Standard, nicht gespeichert bis `Save`); `Close` mit ungesicherten Änderungen warnt und
verwirft erst beim zweiten Klick. In Textfeldern: Pfeile, Pos1/Ende, Entf, Klick setzt den Cursor,
Tab/Shift+Tab wechselt das Feld. `wlprefs --config DATEI` bearbeitet eine andere Datei,
`wlprefs --shot ORDNER` schreibt jede Seite als PNG (ohne Wayland-Sitzung).

Icons: `docs/WLPREFS-ICONS.md`. Offenes: `docs/TODO.md`.

Die folgenden Abschnitte sind die ursprüngliche Bestandsaufnahme und Planung; sie bleiben als
Begründung stehen.

## 1. Was WPrefs.app bei X11 Window Maker konfiguriert

WPrefs gliedert sich in Icons/Tabs, jede davon eine eigene `.conf`-Sektion in
`~/GNUstep/Defaults/WindowMaker`. Zur Orientierung, mit Zuordnung zum wmaker-wl-Äquivalent:

| WPrefs-Icon | Beispielhafte Optionen | wmaker-wl-Äquivalent |
|---|---|---|
| **Window Handling** | Fokusmodus (click/sloppy/auto), Auto-Arrange-Icons, Fenster-Platzierung | `focus_follows_mouse`; Rest fehlt (siehe §3.1) |
| **Icon and Image Preferences** | Icon-Größe, Icon-Positionierung, Pixmap-Pfade | fehlt komplett (kein Dateimanager-Icon-Konzept in einem scrollenden Tiling-WM) |
| **Menu Preferences** | Menü-Stil, Scrollen, Transparenz | Root-Menü existiert (`RootMenu`-Datei), Styling teils über `config.conf`-Farben |
| **Workspace Preferences** | Anzahl, Namen, "Advance to new workspace" | `workspace_count`; **Namen fehlen** (§3.2) |
| **Appearance / Themes** | Theme-Paket laden (Texturen, Schriften, Farben je Widget) | fehlt komplett -- Phase 6 (§3.3) |
| **Menu and Icon Fonts** | Schriftfamilie/-größe für Menü, Titelleiste, Icons | fehlt (`gfx.zig` nutzt aktuell feste Pango-Defaults) |
| **Mouse Preferences** | Doppelklick-Geschwindigkeit, Grab-Modifier, Scroll-Aktionen auf Titelleiste | `mouse_mod`, `drag_threshold`; Rest fehlt |
| **Keyboard Shortcuts** | Grafischer Keybind-Editor (genau `bind =`-Zeilen) | `bind =`/`unbind =` existieren textuell; **GUI fehlt** (§2) |
| **Window Focus Preferences** | Focus-follows-mouse-Feinheiten, Auto-Focus neuer Fenster | teilweise (`focus_follows_mouse`) |
| **Miscellaneous Preferences** | Doppelklick auf Titelleiste, Animationsgeschwindigkeit, "Opaque move" | größtenteils irrelevant für ein Scrolling-Tiling-Modell, s. §4 |
| **Expert User Preferences / Advanced Options** | Icon-Slide-Animation, Disable-Dithering, u.v.m. X11-Spezifika | größtenteils **nicht übertragbar** (kein X11-Rendering mehr, s. §4) |
| **Application Preferences** | Pfad zu Standardanwendungen (Terminal, Browser, E-Mail) | `terminal`, `launcher`, `browser` |

Zusätzlich verwaltet WPrefs die Attribut-Inspector-Funktion (`WMWindowAttributes`, pro App) und den
Dock/Clip-Editor (Drag&Drop von App-Icons in die Kachel-Leiste). Beides sind eigene Fenster
innerhalb von WPrefs, keine Tabs der Haupteinstellungen.

## 2. Was in wmaker-wl bereits vorhanden ist

Die Datenseite ist für einen großen Teil von WPrefs bereits da -- nur ohne grafische Oberfläche:

- **`config.conf`** (`src/config.zig`): Layout, Look (Rahmenfarben), Workspaces (nur Anzahl),
  Maus (`mouse_mod`, `drag_threshold`, `focus_follows_mouse`), Programme (`terminal`, `launcher`,
  `browser`), `bind =`/`unbind =` für Keybinds -- textuelles Äquivalent von "Window Handling",
  "Mouse Preferences", "Keyboard Shortcuts" (nur ohne Editor) und "Application Preferences".
- **`attributes.conf`** (`WMWindowAttributes`, `src/wm_attr.zig`): fast das komplette
  X11-Attribut-Set pro `app_id` (`NoTitlebar`, `Omnipresent`, `StartWorkspace`, `KeepOnTop`, ...) --
  das textuelle Äquivalent von WPrefs' Attribute-Inspector-Fenster.
- **`dockapps.conf`** (`src/dockapp.zig`): Name, Command, Icon-Pfad, Grid-Position, AutoLaunch,
  Lowered -- die Datengrundlage für einen künftigen Dock-Editor, auch wenn noch keine Kachel
  gezeichnet wird (Phase 5).
- **`RootMenu`** (`src/wm_menu.zig`): Menüstruktur textuell, Plist- und Text-Format.

Was komplett fehlt, ist die **GUI-Schicht selbst** -- kein Tool liest/schreibt diese Dateien
interaktiv; alles wird von Hand editiert und per SIGHUP neu geladen.

## 3. Fehlende Grundlagen (Compositor-Seite), bevor eine GUI sinnvoll wird

### 3.1 Window-Handling-Optionen jenseits von `focus_follows_mouse`
X11 Window Maker kennt weitere Fokus-Feinheiten (z.B. "focus new windows automatically",
"raise window when focused"), die es in `types.Command`/`config.zig` noch nicht gibt. Vor einer
GUI-Checkbox braucht jede Option zuerst ihr `config.conf`-Feld und ihre Auswirkung im Compositor.

### 3.2 Workspace-Namen
`workspace_count` existiert, benannte Workspaces (Window Makers `WorkspaceNames`) nicht. Für die
Root-Menü-Anzeige und eine künftige "Workspace Preferences"-GUI-Seite ist das ein kleiner, klar
abgegrenzter erster Schritt (ein `[]const []const u8` in `Config`, ein `workspace_names =
Web, Code, ...`-Schlüssel, Fallback auf "Workspace N").

### 3.3 Themes (Phase 6)
Der größte fehlende Baustein. Ein Theme müsste mindestens definieren:
- Titelleisten-/Rahmenfarben und -texturen (aktuell nur drei feste Hex-Farben in `config.conf`)
- Schriftfamilie/-größe für Menü und Titelleiste (aktuell feste Pango-Defaults in `gfx.zig`)
- Menü-Erscheinungsbild (Hintergrund, Hervorhebung)

Ein pragmatischer erster Schritt, der nicht auf volle GNUstep-Theme-Pakete (Pixmap-Texturen,
`.tiff`-Icons) wartet: ein reines Farben+Schriften-"Theme" als eigene kleine Plist-Datei, die
`config.conf`s `border_*`-Schlüssel und eine neue `font_*`-Gruppe zusammenfasst. Volle
Pixmap-Texturen sind ein separates, deutlich größeres Vorhaben (eigener Bildlader, Tiling/Scaling
der Textur in `gfx.zig`) und sollten bewusst später kommen.

### 3.4 Maus- und Fokus-Feinheiten
`drag_threshold` und `mouse_mod` sind da; WPrefs' "Mouse Preferences" hat u.a. auch
Doppelklick-Geschwindigkeit (für Titelleisten-Doppelklick-Aktionen, die es hier mangels
Titelleisten-Interaktion noch nicht gibt -- siehe Phase 3) und konfigurierbare
Scroll-auf-Titelleiste-Aktionen. Beides hängt an Phase 3 (Titelleisten) und ist vor deren
Fertigstellung nicht sinnvoll planbar.

## 4. Was bewusst NICHT übernommen werden sollte

WPrefs trägt viel X11-spezifischen oder für ein scrollendes Tiling-Modell irrelevanten Ballast
mit, den wmaker-wl nicht braucht:

- **Icon-Slide-Animationen, "Opaque Move", Dithering, Backing-Store-Optionen**: reine
  X11-Server-Eigenheiten ohne Wayland-Äquivalent.
- **Auto-Arrange-Icons / Icon-Grid auf dem Desktop**: setzt ein Desktop-Icon-Konzept voraus, das
  ein scrollendes Tiling-Modell (`layout.zig`) grundsätzlich nicht hat -- Fenster liegen in
  Spalten, nicht als freie Icons auf dem Hintergrund.
- **"Advance to new workspace" bei Fenster-Drag über den Bildschirmrand**: passt nicht zum
  spaltenbasierten Scrollen dieses Projekts.
- **Expert/Advanced-Tab-Großteil**: meist Debugging-Schalter für X11-Rendering-Pfade, die es unter
  Wayland/wlroots (bzw. hier: river) schlicht nicht gibt.

Diese Posten sollten in einer künftigen wmaker-wl-Prefs-GUI von vornherein fehlen, statt sie als
wirkungslose, ausgegraute Checkboxen mitzuschleppen.

## 5. Vorgeschlagener Aufbau der künftigen GUI

Kein GTK/WINGs-Klon, sondern konsistent mit dem Rest des Projekts:

1. **Kein eigener Prozess mit eigenem State.** Die GUI liest `config.conf`/`attributes.conf`/
   `dockapps.conf` beim Öffnen, schreibt beim Speichern dieselben Dateien zurück (mit erhaltenen
   Kommentaren, wo möglich -- oder zumindest ohne bestehende, von der GUI nicht verstandene Zeilen
   zu verwerfen) und stößt den laufenden Compositor per SIGHUP zum Neuladen an, exakt der bereits
   vorhandene Live-Reload-Mechanismus (`docs/TODO.md`, "Live-Config-Reload"). Keine zweite
   Config-Quelle, kein IPC-Protokoll, das gepflegt werden müsste.
2. **Eigenständiges Projekt, wie `wl-clock`.** Ein `wmaker-wl-prefs`-Programm, das den
   geparsten Zustand über dieselben Parser aus diesem Repo (`config.zig`, `wm_attr.zig`,
   `dockapp.zig` als kleine, wiederverwendbare Bibliothek exportiert, s. `src/root.zig`) liest.
   Muss also **nicht** in den Compositor-Prozess selbst.
3. **Tabs, die 1:1 auf bestehende Dateien/Sektionen abbilden**, nicht auf WPrefs' historische
   Icon-Anordnung:
   - **Allgemein**: Layout-Werte, Look (Rahmenfarben, künftig Theme-Auswahl), Workspaces
     (Anzahl + Namen, sobald §3.2 umgesetzt ist).
   - **Tastenkürzel**: Tabelle aller `bind =`-Zeilen, Bearbeiten per Klick+Tastendruck (ein
     Zwei-Klick-Rekorder wie bei den meisten modernen WM-Config-GUIs), inklusive der in diesem
     Repo gerade neu hinzugekommenen `shell`/`exec`-Befehle (freier Text mit Shell-Syntax) und
     `spawn` (Programm + Argumente) als zwei klar unterscheidbare Eingabemodi -- keine Blackbox
     "Befehl", sondern ein Radiobutton "Programm direkt starten" vs. "Shell-Befehl ausführen".
   - **Anwendungen**: `terminal`/`launcher`/`browser`, künftig evtl. weitere Standardprogramme.
   - **Fensterregeln**: tabellarischer Editor für `attributes.conf`, eine Zeile pro `app_id`,
     Spalten = `Attributes`-Felder (bereits vollständig als Struct vorhanden, s. §2).
   - **DockApps**: tabellarischer Editor für `dockapps.conf` (Name, Command, Icon, Position,
     AutoLaunch, Lowered) -- wird erst mit Phase 5 wirklich nützlich, kann aber schon vorher als
     reiner Text-/Tabellen-Editor ohne Live-Vorschau entstehen.
4. **Validierung wiederverwenden statt duplizieren.** Jeder Parser in diesem Repo gibt bei
   Fehlern schon strukturierte Diagnosen zurück (Zeilennummer, Grund -- s. `plist.Diag`,
   `config.zig`s `ParseError`); die GUI zeigt diese Meldungen an, statt eigene Validierungslogik
   parallel zu pflegen, die aus dem Takt geraten könnte.

## 6. Nächste konkrete, unabhängig voneinander sinnvolle Schritte

In empfohlener Reihenfolge, jeder Schritt für sich klein und testbar:

1. Workspace-Namen (`workspace_names` in `config.conf`, §3.2) -- kleinster Einstieg, kein neues
   Konzept, nur ein weiteres `Config`-Feld nach bestehendem Muster.
2. Grundgerüst `src/wm_prefs.zig` in diesem Repo: reine, GUI-freie Lese-/Schreib-Bibliothek
   ("lade Config in ein GUI-freundliches, veränderliches In-Memory-Modell; schreibe es wieder als
   `config.conf`/`attributes.conf`/`dockapps.conf`-Text"). Das ist die Grundlage, auf der sowohl
   eine künftige GUI als auch z.B. ein `wmaker-wl-prefs --set key=value`-CLI-Modus aufbauen können,
   ohne dass die GUI die Parser/Serializer selbst duplizieren muss. **Ein erster Entwurf davon
   liegt bereits in diesem Commit, siehe `src/wm_prefs.zig`** -- bewusst nur Skelett mit
   Kommentaren, keine vollständige Implementierung.
3. Minimales Theme-Datenmodell (§3.3, nur Farben+Schriften, keine Pixmap-Texturen) inklusive
   `config.conf`-Schlüssel `theme = <pfad>` und Fallback auf die eingebauten Defaults.
4. Erst danach: das eigentliche `wmaker-wl-prefs`-GUI-Projekt, aufbauend auf 1--3.

Phase 5 (Dock/Clip) und Phase 3 (Titelleisten) aus `docs/TODO.md` bleiben Voraussetzung für die
DockApps- bzw. jede zukünftige Titelleisten-bezogene GUI-Seite und sind bewusst nicht Teil dieser
Liste -- sie gehören in den Compositor selbst, nicht in die Prefs-Schicht.