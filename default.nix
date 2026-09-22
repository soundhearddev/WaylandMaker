{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    zig
    pkg-config

    wayland
    wayland-scanner
    wayland-protocols
    libxkbcommon

    cairo
    pango
    glib

    river
  ];

  shellHook = ''
    echo "wmaker-wl development shell"
    echo "Zig: $(zig version)"
  '';
}