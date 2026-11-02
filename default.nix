# Development shell for wmaker-wl.
{ pkgs ? import <nixpkgs> { } }:

let
  zig = pkgs.zig_0_16 or pkgs.zig;
  wlroots = pkgs.wlroots_0_20 or pkgs.wlroots;

  libs = with pkgs; [
    wlroots
    wayland
    libxkbcommon
    pixman
    cairo
    pango
    glib
    harfbuzz
  ];
in
pkgs.mkShell {
  packages = [ zig pkgs.stdenv.cc ] ++ libs ++ (with pkgs; [
    pkg-config
    wayland-scanner
    wayland-protocols
  ]);

  NIX_CFLAGS_COMPILE = "-isystem ${pkgs.stdenv.cc.libc.dev}/include";
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;

  shellHook = ''
    echo "wmaker-wl development shell (Zig $(zig version))"
    if ! printf '%s\n%s\n' 0.16.0 "$(zig version)" | sort -V -C; then
      echo "warning: build.zig.zon needs Zig 0.16.0 or newer" >&2
    fi
    echo "  zig build          build wmaker-wl and wlprefs"
    echo "  zig build test     run the tests"
    echo "  zig build run      start nested in the current session"
    echo "  ./zig-out/bin/wmaker-wl   from a TTY"
  '';
}