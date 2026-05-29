{
  description = "Nix Packaging Standard — shared flake-parts modules + canonical CI/update tooling for the Daaboulex *-nix fleet";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # The shared contract consumed by every packaging repo via
      #   imports = [ inputs.std.flakeModules.base ];
      # `base` is the proven, fleet-wide surface. Archetype modules
      # (python/kernel/module-eval/multi-component) are added here as each
      # archetype's first repo is converted — never speculatively.
      flake.flakeModules.base = ./flake-modules/base.nix;

      perSystem =
        { pkgs, ... }:
        {
          formatter = pkgs.nixfmt-rfc-style;
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nil
              nixfmt-rfc-style
              jq
              shellcheck
              check-jsonschema
            ];
          };
        };
    };
}
