{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    zig
    llvmPackages.clang

    wayland
    libxkbcommon

    river
    pkg-config
  ];

  shellHook = ''
    echo "wmaker-wl development shell"
    echo "Zig: $(zig version)"
  '';
}