# Icons für wlprefs

**Regel:** wlprefs zeichnet keine eigenen Icons. Was nicht als PNG vorliegt, zeigt ein klar markierter
**Platzhalter** (graue Box, durchgestrichen, mit dem Kurznamen darin), damit die Oberfläche trotzdem
funktioniert und man sofort sieht, welches Icon an welche Stelle gehört. Die Logik dahinter steht in
`wlprefs/src/icons.zig`.

## Vorhanden

Die 16 Abschnitts-Icons der Leiste (48×48) sind Window Makers eigene WPrefs-Grafiken
(`WPrefs.app/xpm/*.xpm`, 1:1 nach PNG umgewandelt, `wlprefs/src/assets/icons/`), dazu die Bilder der
Menü-Seite (`assets/menu/`: `speed0..4(s)`, `menualign1/2`). Sie werden zur Bauzeit eingebettet.

## Noch gebraucht (zeigen derzeit den Platzhalter)

Alle sind PNG, **48×48**, mit Alpha, im NeXT-/Window-Maker-Stil der übrigen Icons. Sie erscheinen als
Bildschaltflächen (wie die Submenu-Ausrichtung in WPrefs' Menü-Seite); der Text darunter steht immer
dabei, ein Icon allein ist keine Beschriftung.

| Datei | Wo | Zeigt |
|---|---|---|
| `dock-left.png` | Dock Preferences › Dock › Rand | das Dock am linken Bildschirmrand |
| `dock-right.png` | Dock Preferences › Dock › Rand | das Dock am rechten Bildschirmrand |
| `clip-top-left.png` | Dock Preferences › Clip › Ecke | der Clip oben links |
| `clip-top-right.png` | Dock Preferences › Clip › Ecke | der Clip oben rechts |
| `clip-bottom-left.png` | Dock Preferences › Clip › Ecke | der Clip unten links |
| `clip-bottom-right.png` | Dock Preferences › Clip › Ecke | der Clip unten rechts |

Der Platzhalter trägt jeweils den Kurznamen (`dock L`, `clip TR`, …).

## Wie man ein Icon liefert

Reihenfolge der Suche, der erste Treffer gewinnt:

1. `$WLPREFS_ICON_DIR/<datei>`
2. `$XDG_DATA_HOME/wlprefs/icons/<datei>` (Standard `~/.local/share/wlprefs/icons/`)
3. `/usr/local/share/wlprefs/icons/<datei>`
4. `/usr/share/wlprefs/icons/<datei>`
5. in die Binärdatei eingebettet
6. der Platzhalter

Ein Theme oder Paket kann Icons also ohne Neubau mitbringen. Ein Icon, das zum Projekt gehört: die PNG
in `wlprefs/src/assets/icons/` ablegen und in `embedded()` (`wlprefs/src/icons.zig`) eine Zeile mit
`@embedFile` für die Id ergänzen -- der Test `embedded icons, if any, decode at their documented size`
prüft dann die Größe.

Ein neues Icon aufnehmen: eine Id in `icons.Id`, einen Eintrag in `spec()` (Datei, Kurzname,
Beschriftung, Größe, Verwendung) -- der Test `every icon has a unique png file name…` verlangt alle
Angaben. Danach diese Tabelle ergänzen.

Wer sehen will, wie die Seiten aussehen, ohne Wayland-Sitzung: `wlprefs --shot ordner/` schreibt jede
Seite als PNG.