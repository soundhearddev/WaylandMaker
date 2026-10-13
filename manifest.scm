;; Development environment for wmaker-wl on Guix.
;;
;;   guix shell -m manifest.scm
;;   zig build            ; wmaker-wl and wlprefs
;;   zig build test
;;   river -c ./zig-out/bin/wmaker-wl
;;
;; build.zig.zon needs Zig 0.16.0 or newer: check `zig version` (an older
;; Guix zig cannot build this). The Lua of config.lua is built from source by
;; the `zlua` dependency, so there is no Lua package here. wmaker-wl runs
;; inside river (river_window_management_v1, river 0.4 or newer).
;; harfbuzz is only a header path for pango (build.zig adds it).
(specifications->manifest
 '("zig"
   "pkg-config"
   "wayland"
   "wayland-protocols"
   "libxkbcommon"
   "cairo"
   "pango"
   "glib"
   "harfbuzz"
   "river"))