{
  description = "Declarative, self-hosted Multica (server + CLI) for Nix / NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      allSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];

      forSystems = systems: f:
        lib.genAttrs systems (system: f {
          inherit system;
          pkgs = nixpkgs.legacyPackages.${system};
        });
      forAllSystems = forSystems allSystems;
      forLinux = forSystems linuxSystems;
    in
    {
      # The CLI package, available on all supported systems. The desktop client is an
      # Electron AppImage, so it is Linux-only.
      packages = forAllSystems ({ pkgs, system, ... }: {
        multica-cli = pkgs.callPackage ./pkgs/multica-cli.nix { };
        default = pkgs.callPackage ./pkgs/multica-cli.nix { };
      } // lib.optionalAttrs (builtins.elem system linuxSystems) {
        multica-desktop = pkgs.callPackage ./pkgs/multica-desktop.nix { };
      });

      overlays.default = final: _prev: {
        multica-cli = final.callPackage ./pkgs/multica-cli.nix { };
      } // lib.optionalAttrs final.stdenv.hostPlatform.isLinux {
        multica-desktop = final.callPackage ./pkgs/multica-desktop.nix { };
      };

      # The star of round 1: a NixOS module that stands up a self-hosted Multica server.
      nixosModules.multica = import ./modules/multica.nix;
      nixosModules.default = self.nixosModules.multica;

      # `nix flake check` builds the CLI and runs the integration VM test (Linux only).
      checks = forLinux ({ pkgs, system, ... }: {
        multica-cli = self.packages.${system}.multica-cli;
        integration = import ./tests/integration.nix { inherit pkgs self; };
      });

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          packages = [ pkgs.nixpkgs-fmt pkgs.skopeo pkgs.gnumake pkgs.jq ];
        };
      });

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixpkgs-fmt);
    };
}
