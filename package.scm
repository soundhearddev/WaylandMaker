(use-modules (guix profiles)
             (gnu packages))

(specifications->manifest
  '(
    "river"
    "zig"
    "wayland"
    "wayland:bin"       
    "wayland-protocols"
    "libxkbcommon"
    "pkg-config"
    "libevdev"
    "pixman"
   ))