{
  description = "The purely functional package manager";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  inputs.zig-flake.url = "github:zix-os/zig-flake";

  outputs =
    {
      self,
      nixpkgs,
      zig-flake,
    }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "riscv64-linux"
      ];
    in
    {
      packages = eachSystem (
        system:
        with (nixpkgs.legacyPackages.${system}.appendOverlays [
          zig-flake.overlays.default
        ]); {
          zix = callPackage ./default.nix {
            inherit self;
          };
          default = self.packages.${system}.zix;
        }
      );
      devShells = eachSystem (
        system:
        with (nixpkgs.legacyPackages.${system}.appendOverlays [
          zig-flake.overlays.default
        ]); {
          default = mkShell {
            nativeBuildInputs = [
              zig
              zls
            ];
          };
        }
      );
    };
}
