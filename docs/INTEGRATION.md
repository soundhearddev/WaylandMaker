# Window-Maker-Integration: Stand und Plan

Ziel: wmaker-wl soll sich wie Window Maker anfühlen: Root-Menü, Dock, Titelleisten
im NeXTSTEP-Look, Fenster-Attribute, die bekannten Konfigurationsdateien.

## 1. Was wlmaker ist und was daraus übertragbar ist

[wlmaker](https://github.com/phkaeser/wlmaker) ist ein **eigener Compositor** (wlroots-Szenengraph, C,
Apache-2.0). wmaker-wl ist dagegen ein **Client von river**. Deshalb lässt sich vom Zeichencode nichts
direkt übernehmen; übernommen wird, was Format und Verhalten betrifft:

| Aus wlmaker übernommen | Wo |
|---|---|
| Menü-Bezeichnungen (`Execute`, `ShellExecute`, `Quit`, `WorkspaceNext` …) | `wm_menu.zig` |
| Theme-Format (`Window.TitleBar`, `Tile`, `Menu` …, Farben `argb32:ff777777`) | Phase 6 |
| Maße der Titelleiste, des Docks und der Menüs (aus `Default.plist`) | Phasen 3–5 |
| State-Format des Docks (`Edge`, `Anchor`, `Launchers`) | Phase 5 |


## 2. Stand

Fertig, mit Unit-Tests (78) und Echtlauf gegen Beispieldateien:

| Datei | Inhalt |
|---|---|
| `plist.zig` | Parser für das Window-Maker-/GNUstep-Plist-Format (Kommentare, Escapes, Data, Zeilennummern in Fehlern) |
| `wm_menu.zig` | Root-Menü: Plist-Format **und** Text-Format (`menu`), verschachtelt, `SHORTCUT`, wlmaker-Namen |
| `wm_attr.zig` | `WMWindowAttributes`: alle 30 Window-Maker-Optionen gelesen, Auflösung wie Window Maker |
| `wm_files.zig` | Suchpfade `~/GNUstep` bzw. `$WMAKER_USER_ROOT` und `~/.config/wmaker-wl`, Ausweichen bei kaputten Dateien |



| Attribut | Wirkung |
|---|---|
| `StartWorkspace` | Fenster öffnet auf diesem Workspace (Nummer, 1-basiert) |
| `Omnipresent` | floating, folgt dem Nutzer auf jeden Workspace |
| `KeepOnTop` | floating |
| `StartMaximized` | neue Spalte füllt den Arbeitsbereich |
| `NoBorder` | kein Rand, der Slot ist reiner Inhalt |
| `Unfocusable` | nimmt nie Tastaturfokus |
| `Floating` | Erweiterung von wmaker-wl: `Yes` = floating, `No` = getilt |

Brauchen Titelleisten oder Dock: `NoTitlebar`, `NoResizebar`,
`NoCloseButton`, `NoMiniaturizeButton`, `Icon`, `NoAppIcon`, alle übrigen.

Das Root-Menü ist **geladen und sichtbar** (Phase 4, siehe unten): rechte Taste auf dem leeren Desktop
öffnet es, mittlere Taste die Fensterliste. Zwei kleine Korrekturen (Cursor-Form über dem Menü, ein
Überlapp-Fehler beim Hovern zwischen Untermenüs) sind als Patch bereit, aber noch nicht in `main` gemerged
— siehe `docs/TODO.md`.

## 3. Was river bietet, und was noch fehlt

river-Protokoll (im Repo unter `protocol/`), geprüft:

* **`river_decoration_v1`**: `window.get_decoration_above/below(wl_surface)` mit `set_offset`. Genau dafür
  gedacht, Titelleisten zu zeichnen. Die Fläche zeichnen wir selbst.
* **`river_shell_surface_v1`**: `get_shell_surface(wl_surface)` mit eigenem Node, `focus_shell_surface` und
  `shell_surface_interaction`. Dafür gedacht: Statusleisten, Hintergrundbild, **Desktop-Menü**. Damit
  brauchen Dock und Menüs **keinen** Layer-Shell-Client.
* Klicks auf eine Shell-Surface kommen als normale `wl_pointer`-Events direkt bei unserem Prozess an.

Dafür gebraucht und seit Phase 2/4 gebunden: `wl_compositor`, `wl_shm`, `wl_seat` (Zeiger, Tastatur), cairo +
pangocairo als Zeichenbibliothek (wie wlmaker; getestet mit cairo 1.18, pango 1.52). Optional zusätzlich
gebunden (Patch bereit, siehe `docs/TODO.md`): `wp_cursor_shape_manager_v1`, damit der Zeiger über
Menü/Desktop zum normalen Pfeil wechselt statt das zuletzt von einem Fenster gesetzte Bild zu behalten.

## 4. Phasen

Reihenfolge nach deinen Prioritäten (Root-Menü und Dock zuerst), mit Abhängigkeiten:

**Phase 2: Zeichen-Infrastruktur** — erledigt
* `gfx.zig`: `wl_shm`-Puffer (memfd, über `shm.zig` mit geprüfter, überlaufsicherer Größe), cairo-Kontext,
  Text mit Pango (`wm_text.c`/`.h` als schmaler C-Helfer um die Pango-Font-Description-Makros), Bevel
  (Kante hell/dunkel), Verläufe.
* `ui.zig`: Bindung von `wl_compositor`/`wl_shm`/`wl_seat`, Zeiger- und Tastaturereignisse. Die Event-Loop
  blieb bei `display.dispatch()`; ein Umstieg auf `poll()` war für Menü-Tastatur und -Zeiger nicht nötig.
* Getestet **ohne Compositor**: cairo-Bild rendern und Pixel prüfen (Titelverlauf, Hover-Hervorhebung,
  Bevel, dass Text tatsächlich Pixel setzt), plus Fuzz-/Grenzwerttests für `shm.checkedSize` und
  Menü-Zeilenlimits.

**Phase 3: Titelleisten** (`decoration_above`)
* Maße aus wlmaker `Default.plist`: Höhe 22, Fase 1, Minimieren links, Schließen rechts, Titel zentriert;
  Resize-Leiste 7 px unten mit Eckbreite 29. Fokussiert schwarz/weiß, unfokussiert grau.
* Layout: Titelleiste zieht ihre Höhe vom Fenster ab (getilt und floating); Fenster-Attribute
  `NoTitlebar`, `NoResizebar`, `NoCloseButton`, `NoMiniaturizeButton` werden wirksam.
* Klick: Fokus; Ziehen: `op_start_pointer` (läuft schon über die vorhandene Maschine); Schließen: `close`.
* Minimieren/Shade: eigenes Modell nötig (siehe Phase 7).

**Phase 4: Root-Menü** — erledigt, zwei Korrekturen bereit
* Ein transparentes, output-großes Desktop-Catcher-Shell-Surface pro Output fängt Klicks auf dem freien
  Desktop ab (Fenster liegen darüber, bekommen also weiterhin ihre eigenen Klicks): **rechte Taste** öffnet
  das Root-Menü, **mittlere** die Fensterliste. Linksklick auf dem Desktop schließt ein offenes Menü.
* Kaskadierende Untermenüs, Hervorhebung beim Hovern, Tastatur (Pfeile, Enter/Rechts öffnet oder
  aktiviert, Links schließt eine Ebene, Esc schließt alles), `SHORTCUT`-Anzeige rechtsbündig.
* `WORKSPACE_MENU` und `WINDOWS_MENU` werden zur Laufzeit aus dem Modell erzeugt; `EXEC`/`SHEXEC` über
  `process.spawn` (`SHEXEC` mit `/bin/sh -c`).
* Alle Wayland-Requests laufen ausschließlich aus `Ui.sync()`, aufgerufen aus `main.onManage()`; Zeiger-
  und Tastatur-Callbacks selbst ändern nur reine Daten und rufen `manage_dirty()` — river erlaubt
  `node.set_position`/`place_*` und `focus_shell_surface` sonst nur innerhalb einer Manage-Sequenz.
* Offen, als Patch bereitgestellt (siehe `docs/TODO.md`): der Zeiger-Cursor wechselt über dem Menü/Desktop
  noch nicht zum normalen Pfeil (`wp_cursor_shape_manager_v1` fehlt bisher), und ein durch Hovern
  geschlossenes Untermenü blieb bis zum nächsten Zyklus mit seinem letzten Frame sichtbar
  (`reapGraveyard()`-Reihenfolge in `sync()`).

**Phase 5: Dock und Clip** (wichtig)
* Zustand laden: Window-Maker-`WMState` (`Dock.Applications` mit `Command`, `Name`, `AutoLaunch`,
  `Position`) und das einfachere wlmaker-Format (`Edge`, `Anchor`, `Launchers`).
* 64-px-Kacheln (56 px Inhalt, Fase 2, diagonaler Verlauf), PNG-Icons per cairo. **XPM-Icons**, das
  klassische Window-Maker-Format, brauchen einen eigenen Lader.
* Klick startet den Befehl; „läuft“-Anzeige über `app_id`-Vergleich; Rechtsklick-Menü (Autostart, Entfernen).
* Der Arbeitsbereich schrumpft um das Dock (`Output.usable`), außer `Lowered`.
* Clip: Workspace-Umschalter mit Namen.

**Phase 6: Themes und `WindowMaker`-Defaults**
* Theme im wlmaker-Format (eine Datei, alle Farben, Fonts, Maße). Schlüssel aus `~/GNUstep/Defaults/WindowMaker`
  (`FTitleBack`, `UTitleBack`, `MenuTitleBack` …) werden auf dieselben Werte abgebildet.
* `enable_wmaker_compat` steuert, ob `~/GNUstep` gelesen wird (heute schon wirksam).

**Phase 7: Feinschliff**
* Minimieren (`Icon` → Kachel im Dock/Clip), Shade, Verstecken (`SHOW_ALL`, `HIDE_OTHERS`),
  `SAVE_SESSION`, Workspace-Namen (`StartWorkspace` per Name).
* Mehrere Monitore: Fokus und Verschieben zwischen Ausgaben.


## 5. Grenzen

* Window Makers X11-Konzepte (`WM_CLASS` per Drag auf das Dock, AppIcons, `WPrefs`, DockApps als X-Fenster)
  haben keine direkte Wayland-Entsprechung. Docking erfolgt über `app_id`; DockApps von wlmaker
  (`wlmclock`, `wlmbattery`) brauchen eine eigene Schnittstelle.
* `RESTART`, `SHUTDOWN`, `INFO_PANEL`, `LEGAL_PANEL`, `OPEN_MENU` sind im Menü-Modell vorhanden, aber noch
  ohne Funktion und erscheinen deaktiviert.