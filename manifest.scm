;; Development environment for wmaker-wl on Guix.
;;
;;   guix shell -m manifest.scm
;;   zig build            ; wmaker-wl and wlprefs
;;   zig build test
;;   zig build run        ; nested in the current session
;;   ./zig-out/bin/wmaker-wl   ; from a TTY
;;
;; build.zig.zon needs Zig 0.16.0 or newer: check `zig version` (an older
;; Guix zig cannot build this). The Lua of config.lua is built from source by
;; the `zlua` dependency, so there is no Lua package here. wmaker-wl is a
;; compositor on wlroots 0.20: check that the Guix wlroots is that version.
;; harfbuzz is only a header path for pango (build.zig adds it).
(specifications->manifest
 '("zig"
   "pkg-config"
   "wayland"
   "wayland-protocols"
   "libxkbcommon"
   "wlroots"
   "pixman"
   "cairo"
   "pango"
   "glib"
   "harfbuzz"))