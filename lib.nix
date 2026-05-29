# std.lib — helpers consumed as inputs.std.lib.*
#
# Module instantiation checks: force FULL evaluation of a module (options +
# assertions + every mkIf path) against a minimal config, WITHOUT building the
# system/home closure. A cheap activation-error gate for module repos — plain
# `nix flake check` only proves a module evaluates as a *definition*, not that
# it instantiates against a real configuration. The check forces the
# instantiated drvPath via `builtins.seq` (so options + assertions evaluate and
# throw on failure) but stores only a context-free string — it never depends on
# or realizes the closure, so the check is eval-only and cheap, even in CI.
{
  nixosModuleCheck =
    {
      nixpkgs,
      system,
      module,
      config ? { },
      overlays ? [ ], # apply the repo's overlay if the module refs overlay-only pkgs
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      sys = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          module
          config
          (
            { lib, ... }:
            {
              nixpkgs.overlays = overlays;
              boot.isContainer = true; # skip bootloader/fileSystem requirements
              networking.useHostResolvConf = lib.mkForce false; # let systemd-resolved modules eval
              system.stateVersion = lib.trivial.release;
            }
          )
        ];
      };
    in
    pkgs.runCommand "module-eval" {
      ok = builtins.seq sys.config.system.build.toplevel.drvPath "instantiated";
    } ''echo "$ok" > "$out"'';

  homeModuleCheck =
    {
      nixpkgs,
      home-manager,
      system,
      module,
      config ? { },
      overlays ? [ ], # apply the repo's overlay if the module refs overlay-only pkgs
    }:
    let
      pkgs = import nixpkgs {
        inherit system overlays;
        config.allowUnfree = true;
      };
      hm = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          module
          config
          {
            home.username = "ci";
            home.homeDirectory = "/home/ci";
            home.stateVersion = "24.05";
          }
        ];
      };
    in
    pkgs.runCommand "module-eval" {
      ok = builtins.seq hm.activationPackage.drvPath "instantiated";
    } ''echo "$ok" > "$out"'';
}
