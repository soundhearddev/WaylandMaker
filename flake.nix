{
  description = "Development environment for wmaker-wl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f {
            pkgs = import nixpkgs {
              inherit system;
            };
          });
    in
    {
      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
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
        };
      });
    };
}