// SPDX-License-Identifier: 0BSD
//
// SKELETT, KEINE FERTIGE IMPLEMENTIERUNG. Siehe docs/WPREFS.md, Abschnitt 6,
// Punkt 2, für den Gesamtplan, in den dieses Modul passt.
//
// Zweck: eine GUI-freie Lese-/Schreib-Schicht über genau die Dateien, die
// wmaker-wl selbst schon parst (config.conf, attributes.conf,
// dockapps.conf). Eine künftige "wmaker-wl-prefs"-GUI (eigenständiges
// Projekt, analog zu examples/wmaker-dockapp-clock, das dieses Repo per
// root.zig als Bibliothek importiert) soll NICHT selbst Parser/Serializer
// pflegen, sondern:
//
//   1. Model.load() aufrufen (liest dieselben Dateien wie config.load(),
//      wm_attr.parse(), dockapp.parseOwn() -- keine zweite Parser-Kopie),
//   2. Felder im entstehenden Model bearbeiten (reine Datenstrukturen,
//      keine WM-Logik, kein Zeiger auf einen laufenden Compositor),
//   3. Model.save() aufrufen (schreibt config.conf/attributes.conf/
//      dockapps.conf zurück),
//   4. den laufenden wmaker-wl-Prozess per SIGHUP zum Neuladen anstoßen
//      (docs/TODO.md, "Live-Config-Reload" -- bereits vorhandener
//      Mechanismus, hier nicht neu zu erfinden).
//
// Explizit NICHT Aufgabe dieses Moduls:
//   - keine Kommunikation mit einem laufenden wmaker-wl-Prozess (kein IPC,
//     kein Socket) -- SIGHUP + Datei-Neuladen reicht, siehe oben.
//   - keine GUI-Widgets, kein Rendering -- das ist Aufgabe des künftigen
//     wmaker-wl-prefs-Projekts, das dieses Modul importiert.
//   - kein neues Dateiformat -- Model.save() schreibt exakt die Syntax,
//     die config.zig/wm_attr.zig/dockapp.zig auch lesen.
//
// Aktueller Stand: nur Typen und Funktionssignaturen mit Kommentaren, was
// jede Funktion tun muss. Keine der load()/save()-Funktionen ist
// implementiert (siehe TODO-Marker unten) -- absichtlich, damit dieses
// Grundgerüst review-bar bleibt, bevor die eigentliche (deutlich größere)
// Implementierungsarbeit beginnt.

const std = @import("std");
const config = @import("config.zig");
const wm_attr = @import("wm_attr.zig");
const dockapp = @import("dockapp.zig");

// ----------------------------------------------------------------------------
// Das Gesamtmodell: alles, was eine Prefs-GUI in einer Sitzung anzeigen und
// bearbeiten könnte, an einem Ort. Getrennt von config.Config, weil
// config.Config bewusst schreibgeschützte, bereits aufgelöste Werte hält
// (z.B. `binds: []const Bind` nach dem Parsen) -- ein GUI-Modell braucht
// stattdessen animierbare, GUI-freundliche Container (ArrayList statt
// fester Slice) und muss zusätzlich Dinge mitführen, die config.Config gar
// nicht kennt (z.B. Kommentare/Originalzeilen, um sie beim Zurückschreiben
// nach Möglichkeit zu erhalten -- siehe save()'s Doc-Kommentar unten).
// ----------------------------------------------------------------------------

pub const Model = struct {
    arena: std.heap.ArenaAllocator,

    // ---- Quelle jeder Sektion, für Fehlermeldungen in der GUI -------------
    // Genau wie config.zig's config_file: "wo kam dieser Wert her", damit
    // eine GUI z.B. "diese Regel kommt aus ~/GNUstep/Defaults/WMState,
    // nicht aus deiner eigenen dockapps.conf" anzeigen kann, statt beim
    // Speichern eine fremde Datei überraschend zu überschreiben.
    config_path: ?[]const u8 = null,
    attributes_path: ?[]const u8 = null,
    dockapps_path: ?[]const u8 = null,

    // ---- Allgemein / Layout / Look -----------------------------------------
    // 1:1 die Felder aus config.Config, siehe dort für Bedeutung und
    // Defaults. Hier ABSICHTLICH keine erneute Dokumentation jedes Felds --
    // config.zig bleibt die eine Quelle der Wahrheit für Bedeutung/Defaults,
    // dieses Modell übernimmt nur Kopien zur Bearbeitung.
    general: GeneralSection = .{},

    // ---- Tastenkürzel -------------------------------------------------------
    // ArrayList statt config.Config's fester []const Bind: eine GUI muss
    // Einträge hinzufügen/entfernen können, während die Sitzung läuft, ohne
    // jedes Mal neu zu allokieren.
    binds: std.ArrayList(BindEntry) = .empty,

    // ---- Fensterregeln (attributes.conf) -----------------------------------
    // Eine Zeile pro app_id. wm_attr.Attributes hat bereits exakt die
    // richtige Form (alle ?bool/?WorkspaceRef-Felder) für eine tabellarische
    // GUI -- ein Attribut ist "nicht gesetzt" (null), "an" oder "aus", genau
    // wie eine dreiwertige Checkbox das darstellen würde.
    window_rules: std.ArrayList(WindowRule) = .empty,

    // ---- DockApps (dockapps.conf) --------------------------------------------
    // dockapp.DockApp ist bereits GUI-tauglich (siehe dockapp.zig); hier nur
    // als veränderliche Liste statt fixem Slice.
    dockapps: std.ArrayList(dockapp.DockApp) = .empty,

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
    }
};

/// Deckt config.conf's "Allgemein"-Bereiche ab: Layout, Look, Workspaces,
/// Maus, Programme. Bewusst als eigener Typ statt config.Config direkt zu
/// verwenden, damit dieses Modell künftig GUI-spezifische Zusatzfelder
/// bekommen kann (z.B. einen "verändert seit dem Laden"-Marker pro Feld für
/// eine "ungespeicherte Änderungen"-Anzeige), ohne config.Config selbst mit
/// GUI-Belangen zu verschmutzen.
pub const GeneralSection = struct {
    // TODO: 1:1-Kopie der Felder aus config.Config (gap, outer_gap,
    // default_column_width, width_presets, width_step, min_window_size,
    // center_focused_column, new_window, border_width, border_focused,
    // border_unfocused, border_floating, workspace_count, drag_threshold,
    // floating_size, focus_follows_mouse, mouse_mod, terminal, launcher,
    // browser, enable_wmaker_compat, enable_autostart, enable_dockapps).
    //
    // TODO (docs/WPREFS.md §3.2, empfohlener erster Schritt): sobald
    // config.Config ein `workspace_names: []const []const u8`-Feld hat,
    // hier ebenfalls aufnehmen -- als std.ArrayList([]const u8), damit die
    // GUI einzelne Namen bearbeiten kann.
    //
    // TODO (docs/WPREFS.md §3.3): sobald es ein Theme-Datenmodell gibt,
    // hier ein `theme_path: ?[]const u8` ergänzen.
};

/// Eine bearbeitbare Zeile im künftigen Tastenkürzel-Editor. Entspricht
/// config.Bind, aber mit combo/command bereits in GUI-freundliche Teile
/// zerlegt statt als rohe Config-Textzeile -- siehe docs/WPREFS.md §5,
/// Punkt 3 ("Tastenkürzel"): die GUI soll `spawn` (Programm+Argumente) und
/// `shell`/`exec` (freier Shell-Text, siehe action.zig) als zwei klar
/// unterschiedene Eingabemodi anbieten, nicht als eine einzige
/// Freitext-Zeile.
pub const BindEntry = struct {
    // Rohe Zeichenkette wie "Super+Shift+h" -- die Zerlegung in
    // config.Modifiers + Keysym passiert erst beim Speichern/Parsen
    // (config.zig's parseCombo ist bereits die richtige Stelle dafür,
    // nicht hier neu implementieren).
    combo: []const u8,

    // Welche der beiden Eingabemodi diese Zeile gerade benutzt. Eine GUI
    // zeigt je nach Wert ein anderes Eingabefeld (z.B. "Programm:" +
    // "Argumente:" getrennte Felder für .spawn, ein einzelnes
    // "Shell-Befehl:"-Textfeld für .shell) und schreibt beim Speichern das
    // passende Schlüsselwort (`spawn ...` bzw. `shell ...`) zurück.
    kind: union(enum) {
        /// Eines der eingebauten, argumentlosen Kommandos (close,
        /// toggle_floating, workspace_next, ...) oder eines mit festen
        /// Parametern (workspace N). Diese kommen 1:1 aus
        /// action.zig's Command-Union -- siehe TODO in load() unten,
        /// wie das ohne Doppelpflege bleibt.
        builtin: []const u8,
        /// `spawn <argv...>`: Programm direkt, ohne Shell.
        spawn: std.ArrayList([]const u8),
        /// `shell <text>` / Aliase `exec`, `shexec`: roher Shell-Text.
        shell: []const u8,
    },
};

/// Eine Zeile im künftigen Fensterregel-Editor (attributes.conf), ein
/// Eintrag pro app_id. wm_attr.Attributes deckt bereits jedes mögliche
/// Attribut ab (siehe wm_attr.zig) -- hier nur zusammen mit dem app_id
/// gruppiert, wie es die Datei tut ({ "app_id" = { ... }; }).
pub const WindowRule = struct {
    app_id: []const u8,
    attrs: wm_attr.Attributes,
};

// ----------------------------------------------------------------------------
// Laden / Speichern -- noch nicht implementiert.
//
// Warum hier nur Signaturen: load()/save() sind der eigentliche Umfang der
// Arbeit (Parser-Ergebnisse in die GUI-Modelle umkopieren bzw. wieder als
// Text serialisieren, inklusive Fehlerdiagnosen mit Zeilennummer wie
// config.zig sie bereits liefert). Das lohnt eine eigene Review-Runde
// sobald der Rest dieses Modells (siehe oben) steht, statt hier blind
// vorzugreifen.
// ----------------------------------------------------------------------------

// Bewusst kein explizites Error-Set wie `std.Io.Dir.ReadFileAllocError`
// benannt: der Rest des Repos (config.zig, wm_files.zig, compatibility.zig)
// behandelt std.Io.Dir.readFileAlloc()'s Fehler immer per `catch |err|`
// mit Inferenz statt den Fehlertyp beim Namen zu nennen -- vermutlich weil
// der genaue Name in Zig 0.16 nicht stabil/leicht auffindbar ist. Diese
// Funktion folgt demselben Muster: `!Model` statt eines explizit
// ausgeschriebenen Fehler-Sets, damit der Compiler es selbst herleitet.
pub const LoadError = error{OutOfMemory};

/// Lädt config.conf + attributes.conf + dockapps.conf in ein bearbeitbares
/// Model, exakt über dieselben Suchpfade wie config.load() /
/// wm_files.zig (~/.config/wmaker-wl/..., mit enable_wmaker_compat-Fallback
/// auf ~/GNUstep/...). Fehlt eine Datei, ist das -- wie beim Compositor
/// selbst -- kein Fehler, sondern führt zu eingebauten Defaults.
///
/// TODO: config.load() liefert bereits ein fertig geparstes config.Config;
/// dessen Felder müssen nur noch in GeneralSection/binds kopiert werden
/// (Bind.command muss dafür zusätzlich in BindEntry.kind aufgeschlüsselt
/// werden -- am einfachsten durch Wiederverwendung von action.parse()'s
/// Ergebnis-Union, um keine zweite Grammatik für "was ist ein Kommando"
/// zu pflegen).
/// TODO: wm_attr.parse() liefert eine Lookup-Tabelle; hier muss zusätzlich
/// die App-id-Liste selbst erhalten bleiben (Iteration über die Tabelle),
/// was wm_attr.zig aktuell nicht exponiert -- ggf. dort zuerst ergänzen.
/// TODO: dockapp.parseOwn()/parseWMState() liefern bereits dockapp.List;
/// nur noch in eine ArrayList kopieren.
pub fn load(io: std.Io, gpa: std.mem.Allocator) LoadError!Model {
    _ = io;
    return .{ .arena = .init(gpa) };
}

// Siehe LoadError's Kommentar: bewusst kein benannter std.Io.Dir-Fehlertyp.
pub const SaveError = error{OutOfMemory};

/// Schreibt das Model zurück in dieselben drei Dateien.
///
/// Wichtige Design-Entscheidung, noch offen und absichtlich hier notiert
/// statt implizit in der Implementierung vergraben: Window Maker/wmaker-wl-
/// Configs werden häufig von Hand mit Kommentaren gepflegt (siehe
/// share/default_config.conf). Ein naiver Serializer, der die Datei
/// komplett neu aus dem Model generiert, würde jeden Kommentar und jede
/// Formatierung des Users beim ersten GUI-Speichern zerstören. Zwei
/// mögliche Strategien für die künftige Implementierung:
///
///   a) Nur die von der GUI tatsächlich geänderten `key = value`-Zeilen
///      in-place ersetzen (Zeile finden, Wert ersetzen, Rest der Datei
///      byte-identisch lassen), neue Zeilen ans Ende anhängen. Erhält
///      Kommentare vollständig, ist aber komplexer zu implementieren.
///   b) Datei komplett neu generieren, ohne Kommentare. Einfacher, aber
///      zerstört jede Handbearbeitung.
///
/// (a) ist der einzige der beiden Wege, der mit dem Projektstil ("nichts
/// überschreibt heimlich, was der User von Hand geschrieben hat" -- siehe
/// z.B. wie addBind() einen Bind auf derselben Kombination gezielt ersetzt
/// statt die ganze Liste neu zu schreiben) konsistent ist und sollte
/// bevorzugt werden, auch wenn er mehr Implementierungsaufwand bedeutet.
///
/// TODO: Strategie (a) implementieren, sobald load() steht.
pub fn save(model: *const Model) SaveError!void {
    _ = model;
}

// ----------------------------------------------------------------------------
// Rauchtest: nur "kompiliert und läuft", kein Verhalten -- load()/save()
// tun noch nichts. Ersetzt/erweitert werden, sobald load() wirklich
// config.conf/attributes.conf/dockapps.conf parst (siehe die TODOs oben).
// ----------------------------------------------------------------------------

test "load returns an empty, deinit-able Model" {
    var model = try load(std.testing.io, std.testing.allocator);
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 0), model.binds.items.len);
    try std.testing.expectEqual(@as(usize, 0), model.window_rules.items.len);
    try std.testing.expectEqual(@as(usize, 0), model.dockapps.items.len);
}
