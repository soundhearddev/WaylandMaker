(use-modules (guix profiles)
             (gnu packages)
             (gnu packages freedesktop)
             (gnu packages gtk)
             (gnu packages pkg-config)
             (gnu packages xdisorg)
             (gnu packages zig))

(packages->manifest
  (list
    (specification->package "zig")
    (specification->package "pkg-config")
    (specification->package "wayland")
    (specification->package "wayland-protocols")
    (specification->package "libxkbcommon")
    (specification->package "cairo")
    (specification->package "pango")
    (specification->package "glib")
    (specification->package "river")))