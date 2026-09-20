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

Das Root-Menü ist **geladen, aber noch nicht sichtbar**: es gibt noch keine Anzeige (Phase 4).

## 3. Was river bietet, und was noch fehlt

river-Protokoll (im Repo unter `protocol/`), geprüft:

* **`river_decoration_v1`**: `window.get_decoration_above/below(wl_surface)` mit `set_offset`. Genau dafür
  gedacht, Titelleisten zu zeichnen. Die Fläche zeichnen wir selbst.
* **`river_shell_surface_v1`**: `get_shell_surface(wl_surface)` mit eigenem Node, `focus_shell_surface` und
  `shell_surface_interaction`. Dafür gedacht: Statusleisten, Hintergrundbild, **Desktop-Menü**. Damit
  brauchen Dock und Menüs **keinen** Layer-Shell-Client.
* Klicks auf eine Shell-Surface kommen als normale `wl_pointer`-Events direkt bei unserem Prozess an.

Was dafür neu gebraucht wird: `wl_compositor`, `wl_shm`, `wl_seat` (Zeiger, Tastatur), eine Zeichenbibliothek
und Schrift. **Empfehlung: cairo + pangocairo**, wie wlmaker. Beides ist installierbar (hier getestet:
cairo 1.18, pango 1.52) und liefert Verläufe, Text, PNG-Icons.

## 4. Phasen

Reihenfolge nach deinen Prioritäten (Root-Menü und Dock zuerst), mit Abhängigkeiten:

**Phase 2: Zeichen-Infrastruktur** (Voraussetzung für alles Sichtbare)
* `gfx.zig`: `wl_shm`-Puffer (memfd), cairo-Kontext, Text mit Pango, Texturen im Window-Maker-Format
  (`solid`, `hgradient`, `vgradient`, `dgradient`), Bevel (Kante hell/dunkel).
* `ui_client.zig`: Bindung von `wl_compositor`/`wl_shm`/`wl_seat`, Zeiger- und Tastaturereignisse,
  Event-Loop von `dispatch()` auf `poll()` umstellen (nötig für Timer und Menü-Tastatur).
* Testbar **ohne Compositor**: in ein cairo-Bild rendern und Pixel prüfen.

**Phase 3: Titelleisten** (`decoration_above`)
* Maße aus wlmaker `Default.plist`: Höhe 22, Fase 1, Minimieren links, Schließen rechts, Titel zentriert;
  Resize-Leiste 7 px unten mit Eckbreite 29. Fokussiert schwarz/weiß, unfokussiert grau.
* Layout: Titelleiste zieht ihre Höhe vom Fenster ab (getilt und floating); Fenster-Attribute
  `NoTitlebar`, `NoResizebar`, `NoCloseButton`, `NoMiniaturizeButton` werden wirksam.
* Klick: Fokus; Ziehen: `op_start_pointer` (läuft schon über die vorhandene Maschine); Schließen: `close`.
* Minimieren/Shade: eigenes Modell nötig (siehe Phase 7).

**Phase 4: Root-Menü** (wichtig)
* Hintergrund als Shell-Surface unten: **rechte Taste** öffnet das Root-Menü, **mittlere** die Fensterliste,
  linke wählt Fenster (das ist die Standardbelegung in Window Maker, im Quelltext geprüft:
  `MouseRightButtonAction = OpenApplicationsMenu`, `MouseMiddleButtonAction = OpenWindowListMenu`).
  Damit entfällt der Umweg über Pointer-Bindings (deren `enable` wäre nur in der Manage-Phase möglich).
* Kaskadierende Untermenüs, Hervorhebung, Tastatur (Pfeile, Enter, Esc), `SHORTCUT`-Anzeige.
* `WORKSPACE_MENU` und `WINDOWS_MENU` werden zur Laufzeit aus dem Modell erzeugt; `EXEC`/`SHEXEC` über
  `process.spawn` (`SHEXEC` mit `/bin/sh -c`).
* Notlösung bis dahin, falls gewünscht: ein Tastenkürzel, das das Menü in `fuzzel --dmenu` zeigt.

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

