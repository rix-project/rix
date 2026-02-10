{
  description = "The purely functional package manager";

  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  inputs.wild-linker = {
    url = "github:davidlattimore/wild";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      wild-linker,
    }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "riscv64-linux"
      ];
      mkPkgs =
        system:
        import nixpkgs {
          # TODO: fetchurl/boot.nix doesn't accept nativeBuildInputs?!
          # localSystem = {
          #  inherit system;
          #  useLLVM = true;
          #  linker = "lld";
          # };
          localSystem.system = system;
          overlays = [
            (import wild-linker)
          ];
        };
    in
    {
      packages = eachSystem (
        system: with mkPkgs system; {
          rix = callPackage ./default.nix {
            inherit self;
          };
          default = self.packages.${system}.rix;
        }
      );
      devShells = eachSystem (
        system:
        let
          pkgs = mkPkgs system;
          devShell = pkgs.mkShell.override {
            stdenv =
              if pkgs.stdenv.hostPlatform.isLinux then
                pkgs.stdenvAdapters.useWildLinker pkgs.stdenv
              else
                pkgs.stdenv;
          };
        in
        with pkgs;
        {
          default = devShell {
            packages = [
              nixfmt
              nil
              rustc
              cargo
              rustfmt
              clippy
              rust-analyzer
              wild
              rust-cbindgen
            ];
          };
        }
      );
    };
}
