# Development shell for wmaker-wl.
#
#   nix-shell        this file, with <nixpkgs>
#   nix develop      flake.nix, which uses this file (so the lists below exist once)
#
# Then: `zig build` (wmaker-wl + wlprefs), `zig build test`, `zig build run`.
# The Lua of config.lua is built from source by the `zlua` dependency, so
# there is no Lua package here; Zig compiles that C itself.
{ pkgs ? import <nixpkgs> { } }:

let
  # build.zig.zon needs Zig 0.16.0: take a 0.16 package when nixpkgs has one.
  zig = pkgs.zig_0_16 or pkgs.zig;

  # What build.zig links (see linkGraphics there). harfbuzz is only a header
  # path for pango.
  libs = with pkgs; [
    wayland
    libxkbcommon
    cairo
    pango
    glib
    harfbuzz
  ];
in
pkgs.mkShell {
  packages = [ zig ] ++ libs ++ (with pkgs; [
    pkg-config
    wayland-scanner
    wayland-protocols
  ])
  # wmaker-wl runs inside river (river_window_management_v1: river 0.4 or
  # newer). Skipped if this nixpkgs has no `river` attribute.
  ++ pkgs.lib.optional (pkgs ? river) pkgs.river;

  # Zig does not go through Nix's compiler wrapper: let the freshly built
  # wmaker-wl and wlprefs find the shared libraries anyway.
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;

  shellHook = ''
    echo "wmaker-wl development shell (Zig $(zig version))"
    if ! printf '%s\n%s\n' 0.16.0 "$(zig version)" | sort -V -C; then
      echo "warning: build.zig.zon needs Zig 0.16.0 or newer" >&2
    fi
    echo "  zig build          build wmaker-wl and wlprefs"
    echo "  zig build test     run the tests (test-wlprefs: wlprefs only)"
    echo "  river -c ./zig-out/bin/wmaker-wl"
  '';
}
