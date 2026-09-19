# Fehlerbericht: Compositor-Absturz / Layer-Surface-Dismissal bei Wayland-Layer-Shell Clients

## 1. Problembeschreibung & Symptome
Beim Aufrufen von Wayland-Programmen, die das `zwlr_layer_shell_v1`-Protokoll nutzen (wie z. B. der Application Launcher `fuzzel`), schlägt das Rendering fehl. Der Client beendet sich unerwartet oder schließt sofort wieder.

**Symptome im Protokoll-Trace:**
* Der Client stellt eine Verbindung zum Ausgabegerät her (z. B. `wl_output#18` / `eDP-1`).
* Der Client ruft `zwlr_layer_shell_v1.get_layer_surface` auf (z. B. mit `layer=3` / `OVERLAY`) und fordert eine Größe an.
* Direkt nach dem ersten `wl_surface.commit()` sendet der Compositor `zwlr_layer_surface_v1.closed()`.
* **Ergebnis:** Das Fenster der Anwendung wird vom Compositor sofort wieder verworfen und schließt sich ohne sichtbare Ausgabe.

---

## 2. Ursachenanalyse im Quellcode
Das Protokoll `zwlr_layer_shell_v1` verlangt eine spezifische Handhabung seitens des Compositors (`waylandmaker`). 

**Festgestellte Ursache:**
1. **Fehlender Lifecycle-Handshake:** Der Compositor empfängt das Event für eine neue Layer-Surface, verarbeitet den Lebenszyklus jedoch nicht korrekt.
2. **Fehlendes Configure-Event:** Anstatt der Surface über `wlr_layer_surface_v1_configure()` ihre Geometrie zuzuweisen und das Rendern freizugeben, schließt der Compositor die Surface umgehend (`wlr_layer_surface_v1_destroy` bzw. `closed()`).
3. **Eingeschränkte Layer-Shell-Abdeckung:** Das Projekt befindet sich im Aufbau und verfügt derzeit über keine vollständige Implementierung für Unmanaged-/Layer-Surfaces (wie Overlay-, Panel- oder Dock-Layer).

---

## 3. Lösungsansätze

### Ansatz A: Behebung im Compositor (Entwickler-Lösung)
Wenn `waylandmaker` erweitert werden soll, um Layer-Shell-Clients (wie `fuzzel`, `waybar` oder `mako`) nativ zu unterstützen, muss die Handhabung in der C/Zig-C-Anbindung implementiert werden:

1. **Event-Listener einrichten:** Auf das `new_surface`-Signal der `wlr_layer_shell_v1` lauschen.
2. **Surface-Mapping:** Die angeforderte Surface in die interne Render-Struktur des passenden Layers (z. B. Background, Top, Overlay) einsortieren.
3. **Configure senden:** Dem Client die finale Größe mitteilen:
   ```c
   wlr_layer_surface_v1_configure(layer_surface, width, height);