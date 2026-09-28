# wlprefs: Aufbau, Seiten und Einstellungen

Dieses Dokument beschreibt, was `wlprefs` (die Einstellungs-App für `wmaker-wl`) sein soll:
welche Seiten es gibt, was auf jeder Seite steht, woher jeder Wert kommt und was bewusst
fehlt. Es ersetzt und verfeinert `docs/WMPREFS.md`.

**Leitidee:** Aussehen und Bedienung wie Window Makers `WPrefs.app` (NeXTSTEP-Ästhetik,
Icon-Leiste, Fase-Widgets, dieselben Icons), aber der **Inhalt** ist für einen
scrollenden Tiling-Compositor unter Wayland (niri-Stil, auf river aufgesetzt) neu
gedacht. Nichts wird angezeigt, was der Compositor nicht auswertet.

---

## 1. Ausgangslage

| Was | Stand |
|---|---|
| `wlprefs/` | Skelett. Fenster 520×390, Icon-Leiste mit 16 Sektionen, Buttons Revert/Save/Close **nur gezeichnet**. Nur `Menu Preferences` hat ein Demo-Panel (feste Beispielwerte, nichts wird gelesen oder geschrieben). |
| `wmaker-wl` | river-Client. Konfiguration in `config.conf`, `attributes.conf`, `dockapps.conf`, `RootMenu`, `autostart`. Änderungen laden per **SIGHUP** neu (existiert, robust, mit Fallback auf die alte Config). |
| `src/wm_prefs.zig` | Nur Skelett (Typen und Signaturen). Ist die geplante Lese-/Schreibschicht für die GUI. |
| Titelleisten (Phase 3) | Bewusst **ferne Zukunft**. Alles, was davon abhängt, ist in diesem Plan ausgeblendet. |
| Scrolling-Extras (Animationen, Drag-Umsortieren) | **Nicht jetzt.** Keine Platzhalter in der GUI. |

---

## 2. Grundprinzipien

1. **Keine zweite Quelle der Wahrheit.** wlprefs liest und schreibt dieselben Dateien, die
   auch von Hand editierbar bleiben. Unbekannte Zeilen und Kommentare gehen nie verloren.
2. **Jedes Steuerelement hat ein echtes Feld** im Compositor. Neue Option = zuerst
   `config.zig` und Auswirkung im Compositor, dann erst die GUI-Zeile.
3. **Fehlermeldungen kommen vom Parser** (Zeilennummer, Grund), nicht aus einer
   parallelen Validierung in der GUI.
4. **Keine toten Schalter.** Was nicht wirkt, wird nicht gezeigt (kein Ausgrauen als
   Platzhalter).
5. **NeXTSTEP-Optik bleibt.** Farbe `0xaeaeae`, Fasen (raised/sunken/groove), schwarzer
   Text, keine Akzentfarben, Auswahl = eingedrückter Button. Die originalen WPrefs-Icons
   bleiben (siehe §4).

---

## 3. Speichern, Live-Wirkung und Neustart

Das ist die Entscheidung "Änderungen: jein". Umsetzung als **Modus-Option** in der
Kopfzeile bzw. im Fußbereich des Fensters:

| Modus | Verhalten |
|---|---|
| **Live** (Standard) | Jede Änderung wird nach kurzer Verzögerung (ca. 300 ms, gebündelt) in die Datei geschrieben, danach **SIGHUP** an `wmaker-wl`. Der Nutzer sieht Gaps, Farben, Spaltenbreite sofort. |
| **Manuell** | Änderungen bleiben im Speicher, erst **Save** schreibt und sendet SIGHUP. **Revert Page / Revert All** verwerfen. Das ist das klassische WPrefs-Verhalten. |

Die Umschaltung heißt in der Oberfläche z. B. **"Apply changes immediately"** (Schalter,
gespeichert in einer kleinen wlprefs-eigenen Datei, siehe §9).

**Neustart-Bedarf pro Option.** Nicht alles wirkt per SIGHUP. Jede Option trägt eine
Eigenschaft, die bestimmt, wie sie wirkt:

| Wirkung | Bedeutung | Anzeige in der GUI |
|---|---|---|
| `live` | Wirkt nach SIGHUP sofort. | nichts |
| `restart` | Braucht einen neuen Compositor-Start (z. B. Autostart wird bewusst nicht erneut ausgeführt, `enable_dockapps`, später Themes mit Pixmaps). | kleines Symbol + Hinweiszeile "Wirkt nach Neustart" |
| `session` | Wirkt erst bei neu geöffneten Fenstern (z. B. Fensterregeln für schon laufende Fenster). | Hinweiszeile "Gilt für neue Fenster" |

Wenn mindestens eine `restart`-Option geändert wurde, erscheint unten eine Statuszeile
**"Neustart erforderlich"**. Ein Button **"Neustart"** startet `wmaker-wl` neu, sobald
das gefahrlos möglich ist. Bis dahin (siehe `docs/TODO.md`, `RESTART` ist bewusst noch
nicht umgesetzt, weil ein `execve` die `river_window_manager_v1`-Verbindung kappt) zeigt
die Zeile nur den Hinweis und der Button ist ausgeblendet. So ist die Option "man sollte
immer neu starten können" vorbereitet, ohne etwas zu versprechen, das der Compositor
noch nicht kann.

**Sicherheitsnetz beim Speichern (beide Modi):**
- vor dem ersten Überschreiben einer Datei pro Sitzung eine Kopie `*.bak`
- bei Parser-Fehlern (Diagnose vom Compositor-Parser) **nicht** schreiben, sondern
  Fehler mit Zeilennummer anzeigen
- nach dem Schreiben Rückmeldung, ob der Compositor lief (SIGHUP zustellbar) oder nicht

---

## 4. Fenster und Navigation

Behalten wird die WPrefs-Anordnung: **oben eine Icon-Leiste, darunter der Inhaltsbereich,
unten die Befehlsleiste.** Das ist NeXTSTEP-typisch und passt zu den vorhandenen Icons.

- Die Leiste hat nur noch **9 Seiten** statt 16. 9 × 64 px = 576 px, das passt in
  ~580 px Fensterbreite, **das horizontale Scrollen der Leiste entfällt**.
- Fensterbreite steigt dafür von 520 auf ca. **600 px**, Höhe bleibt ca. 390 bis 420.
- Icons: nur die vorhandenen 48×48-PNGs aus `wlprefs/src/assets/icons/`. Keine neuen
  Icons nötig (Zuordnung in §5).
- Ein Klick auf ein Icon setzt den Fenstertitel auf den Seitennamen (wie im Original).
- Balloon-Help ("Tooltips") bleibt als abschaltbare Option, gespeichert in der
  wlprefs-eigenen Datei.

**Größe unter einem Tiling-WM.** `wmaker-wl` kachelt wlprefs wie jedes andere Fenster.
Ein festes Fenster wirkt in einer Spalte falsch. Deshalb:

- Mindestgröße = Sollgröße (ca. 600 × 400).
- Ist mehr Platz da, wächst der **Inhaltsbereich**, die Leiste bleibt oben zentriert.
- Der Fenstertyp soll per `attributes.conf`-Vorgabe als **Floating** startbar sein
  (`app_id = wlprefs`), damit es wie ein Dialog erscheint statt eine Spalte zu belegen.
  Diese Regel liefert wmaker-wl als Standard mit.

---

## 5. Die Seiten

Reihenfolge der Icon-Leiste, links nach rechts. Die Icon-Dateien sind bereits im Projekt.

| # | Seitenname | Icon-Datei | Ersetzt im Original |
|---|---|---|---|
| 1 | **Layout** | `whandling.png` | Window Handling |
| 2 | **Focus & Mouse** | `windowfocus.png` | Window Focus, Mouse |
| 3 | **Appearance** | `appearance.png` | Appearance, Fonts |
| 4 | **Workspaces** | `workspace.png` | Workspace |
| 5 | **Keyboard Shortcuts** | `keyshortcuts.png` | Keyboard Shortcuts |
| 6 | **Programs & Startup** | `configs.png` | Search Path (teilw.), Other |
| 7 | **Window Rules** | `expert.png` | Attribute-Inspector |
| 8 | **Dock** | `dockclipdrawersection.png` | Dock |
| 9 | **Applications Menu** | `menus.png` | Applications Menu Definition, Menu Prefs |

Ungenutzte Icons (`iconprefs`, `ergonomic`, `paths`, `hotcorners`, `menuprefs`,
`mousesettings`, `fonts`) bleiben im Repo; einige werden später gebraucht (siehe §7).

Legende der Spalte **Quelle** in den Tabellen unten:
- **ist** = Feld existiert heute in `config.zig` und wirkt
- **neu** = Feld muss zuerst im Compositor entstehen
- **river** = braucht ein river-Protokoll, das `wmaker-wl` noch nicht bindet
- **Wirkung** = `live` / `session` / `restart` (siehe §3)

---

### Seite 1: Layout  (`whandling.png`)

Das Herzstück. Alles hier gibt es bereits in `config.conf`. Oben eine **Live-Vorschau**:
ein kleines Schema des Bildschirms mit drei Spalten, das Gap, Außenabstand,
Spaltenbreite und Zentrierung sofort widerspiegelt.

**Gruppe "Spacing"**

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Gap between windows | `gap` | Zahl 0 bis 64 px | ist | live |
| Gap to screen edge | `outer_gap` | Zahl 0 bis 64 px | ist | live |
| Border width | `border_width` | Zahl 0 bis 16 px | ist | live |

**Gruppe "Columns"**

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Default column width | `default_column_width` | Schieber 0.1 bis 1.0 | ist | live |
| Width presets | `width_presets` | Liste, Werte 0.1 bis 1.0, hinzufügen/löschen | ist | live |
| Width step (grow/shrink) | `width_step` | Schieber 0.02 bis 0.3 | ist | live |
| Minimum window size | `min_window_size` | Zahl px | ist | live |

**Gruppe "Behavior"**

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Center focused column | `center_focused_column` | Auswahl: On overflow / Always / Never | ist | live |
| New windows open in | `new_window` | Auswahl: New column / Stack in column | ist | live |

**Gruppe "Floating"**

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Default floating size | `floating_size` | Schieber 0.2 bis 1.0 | ist | live |
| Drag distance before a tiled window floats | `drag_threshold` | Zahl px | ist | live |

**Aus niri übernehmenswert, aber noch nicht im Compositor** (erst bauen, dann anzeigen):

| Idee (niri) | Schlüssel-Vorschlag | Quelle |
|---|---|---|
| Einzelne Spalte immer zentrieren (`always-center-single-column`) | `center_single_column` | neu |
| Rahmenfarbe des Fokus abschaltbar (`focus-ring off`) | `border_focused` leer/`none` | neu |

Bewusst **nicht** übernommen: Tab-Anzeige pro Spalte (`default-column-display tabbed`),
Preset-Fensterhöhen, Struts. Das sind Scrolling-Extras, die jetzt nicht dran sind.

---

### Seite 2: Focus & Mouse  (`windowfocus.png`)

Fasst die WPrefs-Seiten *Window Focus Preferences* und *Mouse Preferences* zusammen, soweit
sie unter Wayland/river sinnvoll sind. Zwei Abschnitte, getrennt durch eine Groove-Linie.

**Abschnitt "Focus"**

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Focus follows mouse | `focus_follows_mouse` | Schalter | ist | live |
| Focus new windows automatically | `focus_new_windows` | Schalter | neu | live |
| Scroll view to keep focused column visible | (heute fest an) | Schalter | neu | live |

Die zwei "neu"-Zeilen bleiben unsichtbar, bis der Compositor sie liest.

**Abschnitt "Mouse (window actions)"**

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Grab modifier | `mouse_mod` | Auswahl: Super / Alt / Ctrl / Shift | ist | live |
| Hinweistext | -- | "Modifier + left drag moves, modifier + right drag resizes" | -- | -- |

**Abschnitt "Pointer & keyboard hardware"** (nur wenn river-Protokolle gebunden sind)

Diesen Abschnitt gibt es heute nicht: `config.zig` verweist bei `mouse_sensitivity` auf
"pointer speed is a river/libinput setting". river bietet dafür aber
`river-libinput-config-v1` (Beschleunigungsprofil, Geschwindigkeit −1 bis 1,
natürliches Scrollen, Tap-to-click, Linkshänder-Modus) und `river-xkb-config-v1`
(Tastaturlayout). Wenn `wmaker-wl` diese Protokolle bindet und Werte aus `config.conf`
anwendet, kommen hier hinzu:

| Steuerelement | Schlüssel-Vorschlag | Typ | Quelle |
|---|---|---|---|
| Pointer speed | `pointer_speed` | Schieber −1.0 bis 1.0 | river |
| Acceleration profile | `pointer_accel_profile` | Auswahl: Adaptive / Flat | river |
| Natural scrolling | `natural_scroll` | Schalter | river |
| Tap to click (Touchpad) | `tap_to_click` | Schalter | river |
| Left-handed | `left_handed` | Schalter | river |
| Keyboard layout / variant | `xkb_layout`, `xkb_variant` | Textfeld/Auswahl | river |

Bewusst weggelassen: Doppelklick-Zeit und Titelleisten-Scrollaktionen (hängen an Phase 3),
Mod+Wheel-Fenstergröße, Colormap-Fokus, Auto-Raise-Delay (X11-Konzepte).

---

### Seite 3: Appearance  (`appearance.png`)

Heute nur Farben. Die Seite ist so gebaut, dass Themes (Phase 6) später **auf derselben
Seite** ergänzt werden, ohne Umbau.

**Gruppe "Window borders"**

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Focused | `border_focused` | Farbfeld (Hex) | ist | live |
| Unfocused | `border_unfocused` | Farbfeld (Hex) | ist | live |
| Floating | `border_floating` | Farbfeld (Hex) | ist | live |

Rechts daneben eine **Vorschau**: drei kleine Fensterkarten (fokussiert, unfokussiert,
floating) mit den gewählten Rändern und der aktuellen `border_width`. Farbwahl per
Hex-Eingabe plus kleiner Farbfläche mit Klick-Picker (RGB-Regler im NeXT-Stil, kein
Fremd-Widget).

**Gruppe "Theme"** (erst ab Phase 6, vorher nicht sichtbar)

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Theme file | `theme` | Dateiauswahl | neu | restart |
| Menu font | `font_menu` | Schriftauswahl | neu | live |
| Menu title font | `font_menu_title` | Schriftauswahl | neu | live |

Volle Pixmap-Themes sind ein eigenes, späteres Vorhaben und stehen hier nicht.

---

### Seite 4: Workspaces  (`workspace.png`)

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Number of workspaces | `workspace_count` | Zahl 1 bis 16 | ist | live |
| Workspace names | `workspace_names` | Liste, eine Zeile pro Workspace, Fallback "Workspace N" | neu | live |
| Wrap around (last → first) | `workspace_wrap` | Schalter | neu | live |

**Empfohlener erster Compositor-Schritt** (kleinster, wie in `docs/WMPREFS.md` §3.2
beschrieben): `workspace_names`. Die Namen-Liste passt sich automatisch der Anzahl an
(zu wenige Namen → Fallback, zu viele → ignoriert, mit Hinweis).

Workspaces sind hier **feste, nummerierte** Arbeitsflächen (Window-Maker-Stil), nicht
niris dynamisch wachsende Liste. Das ist eine Compositor-Entscheidung, nicht Sache der GUI.

Weggelassen: "Drag window to next workspace at edge" und "create workspace by dragging"
(passen nicht zum spaltenbasierten Scrollen).

---

### Seite 5: Keyboard Shortcuts  (`keyshortcuts.png`)

Der wichtigste Editor. Datenbasis: die `bind =`- und `unbind =`-Zeilen. Die Seite
ist zweigeteilt.

**Links: Tabelle aller Kürzel**

| Spalte | Inhalt |
|---|---|
| Action | Klartextname der Aktion (aus einer festen Liste, siehe unten) |
| Shortcut | z. B. `Super+Shift+h`, angezeigt lesbar |
| Argument | z. B. `2` bei `workspace 2`, oder Befehl bei `spawn`/`shell` |

Darüber ein **Suchfeld** und ein **Filter** nach Gruppe. Doppelte Tastenkombinationen
werden rot markiert (Konflikt).

**Rechts / unten: Bearbeiten**

| Steuerelement | Funktion |
|---|---|
| **Capture** | Klick, dann gewünschte Tastenkombination drücken (wie im Original). Fängt Modifier + Taste als xkb-Keysym. |
| **Action** | Auswahl, gruppiert (siehe unten) |
| **Argument** | Eingabefeld, passend zur Aktion (Zahl, X/Y-Paar, Text) |
| **Add / Delete** | neue Zeile / Zeile entfernen (Delete erzeugt bei Standard-Kürzeln ein `unbind`) |
| **Restore defaults** | pro Zeile und für alle; entfernt eigene `bind`/`unbind`-Zeilen |

**Aktionen, gruppiert wie in `default_config.conf`** (alle heute im Compositor vorhanden):

| Gruppe | Aktionen |
|---|---|
| Programs | `spawn_terminal`, `spawn_launcher`, `spawn_browser` |
| Custom command | `spawn <Programm + Argumente>` **oder** `shell <Shell-Befehl>` |
| Session / window | `close`, `exit`, `toggle_floating`, `toggle_fullscreen`, `maximize_column` |
| Focus | `focus_left/right/up/down`, `focus_first_column`, `focus_last_column`, `focus_previous`, `focus_toggle_floating` |
| Move | `move_column_left/right`, `move_column_first/last`, `move_window_up/down`, `consume_left`, `expel_right` |
| Scrolling | `scroll_left`, `scroll_right`, `center_column` |
| Column width | `cycle_column_width`, `widen_column`, `narrow_column` |
| Floating | `float_move X Y`, `float_resize X Y` |
| Workspaces | `workspace N`, `move_to_workspace N`, `workspace_next`, `workspace_prev` |

**Wichtig bei "Custom command":** zwei klar getrennte Eingabemodi (Radiobuttons),
weil `spawn` und `shell` sich grundlegend verhalten:

- **Run program** = `spawn`, kein Shell, keine `$VARS`, keine Pipes
- **Run shell command** = `shell`, läuft über `/bin/sh -c`, Pipes/`&&`/`~` funktionieren

Dazu eine Fehlermeldung direkt am Feld, wenn der Parser die Zeile ablehnt (Diagnose
kommt aus `config.zig`, nicht aus wlprefs).

---

### Seite 6: Programs & Startup  (`configs.png`)

| Steuerelement | Schlüssel | Typ | Quelle | Wirkung |
|---|---|---|---|---|
| Terminal | `terminal` | Textfeld (Programm + Argumente) | ist | live |
| Launcher | `launcher` | Textfeld | ist | live |
| Browser | `browser` | Textfeld | ist | live |
| Run autostart script at login | `enable_autostart` | Schalter | ist | restart |
| Autostart script | Datei `autostart` | mehrzeiliges Textfeld | ist | restart |
| Load dock apps at login | `enable_dockapps` | Schalter | ist | restart |
| Read Window Maker files (~/GNUstep) | `enable_wmaker_compat` | Schalter, mit Hinweis welche Dateien dann zusätzlich gelesen werden | ist | restart |

Hinweiszeile beim Autostart: "Wird nur einmal beim Start ausgeführt, nicht bei einem
Reload." (das ist Absicht im Compositor, siehe `docs/TODO.md`.)

Die Terminal/Launcher/Browser-Felder haben rechts einen kleinen Knopf **"Test"**, der
das Programm einmal startet, damit man einen Tippfehler sofort sieht.

---

### Seite 7: Window Rules  (`expert.png`)

Ersatz für den Attribut-Inspector von Window Maker. Datenbasis: `attributes.conf`
(`WMWindowAttributes`, `wm_attr.zig`). Layout: **Liste links, Details rechts.**

**Links: Regelliste**
- eine Zeile pro `app_id` (oder Fenstertitel-Muster, soweit `wm_attr.zig` das kennt)
- Knöpfe: **New**, **Delete**, **Pick window…**

**"Pick window…"** ist ein Komfortgewinn, den WPrefs nie hatte: zeigt eine Liste der
gerade offenen Fenster (mit `app_id`) und übernimmt die Auswahl als neue Regel. Braucht
eine Abfrage der Fensterliste vom Compositor; bis dahin bleibt es ein manuelles Textfeld.

**Rechts: Attribute**, jedes **dreiwertig** (*Default / Yes / No*, passend zu den `?bool`-Feldern):

*Nur diese sind heute wirksam und werden standardmäßig angezeigt:*

| Attribut | Bedeutung |
|---|---|
| `StartWorkspace` | öffnet auf Workspace N (Zahl oder Name) |
| `Omnipresent` | floating, folgt auf jeden Workspace |
| `KeepOnTop` | floating |
| `StartMaximized` | neue Spalte füllt den Arbeitsbereich |
| `NoBorder` | kein Rand |
| `Unfocusable` | nimmt nie Tastaturfokus |
| `Floating` | erzwingt floating (Yes) oder getilt (No) |

*Übrige Attribute* (`NoTitlebar`, `NoResizebar`, `NoCloseButton`, `NoMiniaturizeButton`,
`Icon`, `NoAppIcon`, `SkipWindowList`, `KeepOnBottom`, `KeepInsideScreen` usw.) sind im
Parser vorhanden, aber ohne Wirkung. Sie liegen hinter einem Schalter **"Show attributes
that have no effect yet"** und tragen ein Kennzeichen "wirkt ab Phase 3/5/7". So bleibt
der Regelfile vollständig editierbar, ohne dass die Standardansicht irreführt.

Wirkung: `session`. Hinweiszeile "Gilt für neu geöffnete Fenster". Ausnahme laut
`docs/TODO.md`: `floating`/`Omnipresent` werden bei späten `app_id`-Ereignissen neu
geprüft, `StartWorkspace` nur bei der Erstplatzierung.

---

### Seite 8: Dock  (`dockclipdrawersection.png`)

Ehrlich in zwei Stufen. Solange Phase 5 (Dock/Clip zeichnen) fehlt, ist diese Seite
ein **reiner Listeneditor** ohne Live-Vorschau.

**Tabelle** aus `dockapps.conf` (`dockapp.zig`):

| Spalte | Schlüssel | Heute wirksam |
|---|---|---|
| Name | `[name]` | ja (Bezeichner) |
| Command | `command` | ja |
| Start at login | `autolaunch` | ja |
| Icon | `icon` | erst ab Phase 5 |
| Position (x,y) | `position` | erst ab Phase 5 |
| Docked below windows | `lowered` | erst ab Phase 5 |

Knöpfe: **Add**, **Delete**, **Move up/down**. Die ersten drei Spalten sind sofort
nutzbar; die übrigen erscheinen ausgeblendet mit Hinweis "wirkt ab Phase 5".

Ein Info-Textblock erklärt den Selbstdeklarationsweg (`app_id = dockapp:<n>` wird ohne
jede Datei erkannt, siehe `docs/DOCKAPPS.md`).

**Ab Phase 5** kommen dazu: Dock an/aus, Kantenwahl, Kachelgröße, Clip an/aus,
Verzögerungen. Erst dann, nicht vorher.

---

### Seite 9: Applications Menu  (`menus.png`)

Zwei Bereiche: Struktur des Menüs und Verhalten des Menüs.

**Bereich "Menu contents"** (Datenbasis `RootMenu`, `wm_menu.zig`)

- **Baumansicht** mit Ordnern und Einträgen, wie im echten WPrefs seit Version 0.63.
- Knöpfe: **New entry**, **New submenu**, **Delete**, **Up / Down**.
- Eintragstypen (aus `wm_menu.zig`): `Execute`, `ShellExecute`, Untermenü,
  Workspace-Liste, Fensterliste, sowie Kennzeichen für `SHORTCUT`-Anzeige.
- Ein Eintrag hat: **Titel**, **Typ**, **Befehl**, optional **Shortcut-Anzeige**.
- Bearbeitbar ist nur das **Plist-Format**. Liegt das Menü im Text-Format vor, zeigt die
  Seite es schreibgeschützt an und bietet "In Plist-Format umwandeln" an (genau wie
  das Original, das Text-Menüs nicht editieren konnte).
- Einträge ohne Funktion (`RESTART`, `SHUTDOWN`, `INFO_PANEL`, `LEGAL_PANEL`,
  `OPEN_MENU`) erscheinen in der Typ-Auswahl **nicht**, bis sie implementiert sind.

**Bereich "Menu behavior"** (nur was der Compositor bald lesen kann)

Die Demo-Optionen aus `panel_menu.zig` (Scrollgeschwindigkeit `speed0..4`,
Untermenü-Ausrichtung `menualign1/2`, Wrap, Scroll-on-hover, vi-Tasten) sind der
Rohbau. Sie werden **nicht sofort** verdrahtet, sondern erst angezeigt, wenn `ui.zig`
die zugehörigen Optionen liest:

| Steuerelement | Schlüssel-Vorschlag | Quelle |
|---|---|---|
| Submenu alignment | `menu_align_submenus` | neu |
| Keep submenus on screen | `menu_wrap` | neu |
| Scroll off-screen menus on hover | `menu_scroll_on_hover` | neu (siehe TODO: "Kein Scrollen bei hohem Menü") |
| Vi keys (h/j/k/l) | `menu_vi_keys` | neu |

Bis dahin bleibt das Demo-Panel im Code, ist aber nicht in der Leiste erreichbar.

---

## 6. Was bewusst wegfällt

| WPrefs-Sektion / Option | Grund |
|---|---|
| Icon Preferences (Positionierung, Größe, Miniaturisierungs-Animation, Mini-Previews) | kein Desktop-Icon-Konzept im scrollenden Modell |
| Ergonomic (Größen-/Positionsanzeige beim Ziehen, Appicon-Bouncing, Workspace-Rand) | X11-typisch; Workspace-Rand ist durch `outer_gap` abgedeckt |
| Search Path (Pixmap-Pfade) | Dockapps tragen ihren Icon-Pfad direkt |
| Other / Expert (Opaque Move/Resize, Dithering, Colormap, Smooth Scaling, Icon-Slide, Shade-Animation, Titlebar-Stil, SaveUnder, xset) | reine X11-Rendering-Eigenheiten |
| Window Handling: Platzierungsstil (Random/Manual/Cascade/Smart), Edge Resistance, "Dragging a maximized window", Mod+Wheel | ersetzt durch das Spalten-/Gap-Modell der Seite 1 |
| Workspace: Drag über den Rand, automatisch neuen Workspace anlegen | passt nicht zum spaltenbasierten Scrollen |
| Hot Corners | vertagt; kein Compositor-Feld dafür |
| Titlebar-Stil, Titelleisten-Doppelklick | Phase 3, ferne Zukunft |

Wenn sich später etwas davon lohnt (Hot Corners, Titelleisten), kommt es als
**neue Seite** mit dem bereits vorhandenen Icon (`hotcorners.png`, `iconprefs.png`).

---

## 7. Zuordnung: alle 16 alten Icons

| Original-Sektion | Icon | Verbleib |
|---|---|---|
| Window Focus | `windowfocus.png` | Seite 2 |
| Window Handling | `whandling.png` | Seite 1 |
| Menu Preferences | `menuprefs.png` | Teil von Seite 9 (Bereich "Menu behavior") |
| Icon Preferences | `iconprefs.png` | entfällt |
| Ergonomic | `ergonomic.png` | entfällt |
| Search Path | `paths.png` | entfällt |
| Dock | `dockclipdrawersection.png` | Seite 8 |
| Workspace | `workspace.png` | Seite 4 |
| Other Configurations | `configs.png` | Seite 6 (nur der nutzbare Rest) |
| Applications Menu | `menus.png` | Seite 9 |
| Keyboard Shortcuts | `keyshortcuts.png` | Seite 5 |
| Hot Corners | `hotcorners.png` | vertagt |
| Mouse | `mousesettings.png` | Seite 2 (Icon evtl. hier, s. Hinweis) |
| Appearance | `appearance.png` | Seite 3 |
| Fonts | `fonts.png` | Seite 3 (ab Phase 6) |
| Expert | `expert.png` | Seite 7 (Fensterregeln) |

Hinweis: Für Seite 2 kann statt `windowfocus.png` auch `mousesettings.png` gewählt
werden. Empfehlung `windowfocus.png`, weil der Fokus die Hauptsache ist.

---

## 8. Architektur

Passend zu dem, was `docs/WMPREFS.md` und `src/wm_prefs.zig` schon vorsehen:

1. **`wm_prefs.zig` wird die einzige Datei-Schicht.** Sie lädt `config.conf`,
   `attributes.conf`, `dockapps.conf`, `RootMenu` und `autostart` in ein veränderliches
   Modell und schreibt sie zurück. wlprefs importiert sie als Bibliothek, statt
   Parser zu kopieren. (Heute dupliziert `wlprefs/src/root.zig` sogar `configPath()`
   absichtlich; das soll entfallen, sobald die Bibliothek exportiert wird.)
2. **Kommentarerhaltung beim Schreiben.** Das Modell speichert Originalzeilen und
   Kommentare; geändert wird nur die betroffene Zeile. Neue Schlüssel werden am Ende
   der passenden Sektion (`# ---- layout ----` usw.) eingefügt.
3. **Nur abweichende Werte schreiben**, wenn ein Wert dem Standard entspricht und vorher
   nicht in der Datei stand (das macht schon das Original: "Only options that have
   different values than the system-wide file are saved").
4. **Option-Metadaten in einer Tabelle**, nicht verstreut im Zeichencode: pro Option
   Schlüssel, Typ, Standard, Wertebereich, Wirkung (`live`/`session`/`restart`), Seite.
   Aus dieser Tabelle entstehen sowohl die Steuerelemente als auch die "Restore
   defaults"-Logik. So lässt sich eine neue Compositor-Option mit einer Zeile in der GUI
   ergänzen.
5. **SIGHUP:** PID von `wmaker-wl` finden (Pidfile in `$XDG_RUNTIME_DIR`, vom Compositor
   zu schreiben, oder Prozesssuche als Rückfall). Läuft er nicht, speichert wlprefs
   trotzdem und zeigt "Compositor not running, changes apply on next start".
6. **Eigene Einstellungen von wlprefs** (nicht die des WMs): kleine Datei
   `~/.config/wmaker-wl/wlprefs.conf` mit "Apply changes immediately" und
   "Balloon help". Diese gehören bewusst nicht in `config.conf`.

---

## 9. Widget-Baukasten (was gebaut werden muss)

Im Skelett gibt es nur `frame`, `switchButton`, `alignButton`, Relief und Text. Für die
Seiten oben braucht es, alles im NeXTSTEP-Look mit `gfx.Canvas`:

| Widget | Gebraucht auf Seite |
|---|---|
| Schalter (Checkbox, existiert als `switchButton`) | alle |
| Radiobutton-Gruppe | 5 (spawn/shell), 1, 2 |
| Zahlenfeld mit Pfeilen | 1, 4 |
| Schieberegler mit Wertanzeige | 1, 2 |
| Auswahl (Popup-Button) | 1, 2, 5 |
| Einzeiliges Textfeld (Cursor, Auswahl, Einfügen) | 5, 6, 7, 8, 9 |
| Mehrzeiliges Textfeld | 6 (autostart) |
| Farbfeld + einfacher Farbwähler | 3 |
| Tabelle/Liste mit Zeilenauswahl und Scrollen | 1 (Presets), 4, 5, 7, 8 |
| Baumansicht (auf-/zuklappbar) | 9 |
| Tastenaufnahme ("Capture") | 5 |
| Vorschau-Zeichnungen (Layout, Ränder) | 1, 3 |
| Statuszeile / Hinweiszeile | alle |

Ohne dieses Fundament ist keine Seite "echt". Es lohnt sich, es **vor** den Seiten zu
bauen und mit der Layout-Seite (nur Schalter, Zahlen, Auswahl, Schieber) zu testen.

---

## 10. Umsetzungsreihenfolge

1. **`wm_prefs.zig` implementieren:** Laden, Kommentare erhalten, Speichern (mit `.bak`),
   Parser-Diagnosen durchreichen, SIGHUP senden. Ohne das ist nichts echt.
2. **Widget-Baukasten** (§9) in Stufen: zuerst Schalter/Zahl/Auswahl/Schieber,
   dann Text/Liste, dann Farbe, Tabelle, Baum, Capture.
3. **Fensterhülle umbauen:** 9 Seiten statt 16, ca. 600 px breit, kein Leisten-Scrollen,
   Live-/Manuell-Schalter, Statuszeile, Revert/Save wirklich verdrahten.
4. **Seite 1 (Layout)** komplett, inklusive Vorschau. Das validiert Hülle, Widgets und
   den Live-Pfad (Änderung → Datei → SIGHUP → sichtbar).
5. **Seite 5 (Keyboard Shortcuts)** und **Seite 6 (Programs & Startup)**.
6. **Seite 3 (Farben)** und **Seite 2 (Fokus, `mouse_mod`)** mit den Feldern, die es gibt.
7. **Compositor: `workspace_names`**, dann **Seite 4**.
8. **Seite 7 (Window Rules)**, dann **Seite 9 (Menu contents)**.
9. **Seite 8 (Dock)** als Listeneditor; voll nutzbar erst nach Phase 5.
10. **Compositor-Erweiterungen**, die Optionen freischalten: `libinput_config` /
    `xkb_config` binden (Seite 2, Hardware), Menü-Verhalten in `ui.zig` (Seite 9),
    `focus_new_windows`, Themes (Seite 3).

Jeder Schritt ist für sich testbar. Das bestehende Muster von `wmaker-wl` (reine
Datenlogik ohne Compositor testbar, siehe `model_test.zig`) gilt auch hier: Parser,
Modell und Speicherlogik von `wm_prefs.zig` bekommen Unit-Tests, ebenso Round-Trip-Tests
("laden → nichts ändern → speichern" darf die Datei nicht verändern).

---

## 11. Offene Entscheidungen

1. **Pidfile für SIGHUP.** Soll `wmaker-wl` beim Start `$XDG_RUNTIME_DIR/wmaker-wl.pid`
   schreiben? Das ist zuverlässiger als eine Prozesssuche.
2. **Neustart-Button.** Aktiv erst, wenn `RESTART` im Compositor gelöst ist (offene
   Frage zur river-Verbindung). Bis dahin nur die Hinweiszeile.
3. **Input-Protokolle binden?** `river-libinput-config-v1` und `river-xkb-config-v1`
   würden Seite 2 deutlich wertvoller machen (Zeigergeschwindigkeit, Natural Scrolling,
   Tastaturlayout), sind aber Compositor-Arbeit. Lohnt sich, sobald das Grundgerüst steht.
4. **Workspaces fest oder dynamisch.** Dieser Plan geht von festen Nummern aus.
5. **Fenstergröße von wlprefs.** Feste Größe als schwebendes Fenster (Regel in der
   Standard-`attributes.conf`) oder skalierbar in einer Spalte. Der Plan empfiehlt beides:
   Mindestgröße plus Floating als Standard.
6. **`wlprefs` als eigener Prozess vs. Teil des Repos.** Aktuell liegt es im
   Repo-Unterordner `wlprefs/` mit eigenem `build.zig`. Das passt, solange es
   `wm_prefs.zig` als Bibliothek importieren darf.