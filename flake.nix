{
  description = "Nix Packaging Standard — shared flake-parts modules + canonical CI/update tooling for the *-nix packaging repos";

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
      # `base` is the proven, fleet-wide surface.
      flake.flakeModules.base = ./flake-modules/base.nix;

      # Helper functions consumed as inputs.std.lib.*. Module repos add a
      # module-instantiation check with nixosModuleCheck / homeModuleCheck.
      # Added as repos need them, never speculatively.
      flake.lib = import ./lib.nix;

      imports = [ inputs.git-hooks.flakeModule ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          pre-commit.settings.hooks =
            (import ./flake-modules/hooks.nix {
              inherit pkgs lib;
              ruffConfigArg = " --config ${./ruff.toml}";
            })
            // {
              check-readme-sections.enable = false;
            };

          checks.std-action-pins =
            pkgs.runCommand "std-action-pins"
              {
                shipped = [
                  ./ci.yml
                  ./maintenance.yml
                  ./update.yml
                ];
                own = ./.github/workflows;
              }
              ''
                pins() { grep -ohE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[a-f0-9]{40}' "$@" | sort -u; }
                pins $shipped > shipped.txt
                pins "$own"/*.yml > own.txt

                if awk -F@ '
                  NR == FNR { canon[$1] = $2; next }
                  ($1 in canon) && canon[$1] != $2 {
                    printf "  %s\n    shipped canonical: %s\n    this repo CI:      %s\n", $1, canon[$1], $2
                    bad = 1
                  }
                  END { exit bad ? 1 : 0 }
                ' shipped.txt own.txt; then
                  echo "ok: every action pinned in both places agrees"
                  touch "$out"
                else
                  echo ""
                  echo "An action is pinned to different SHAs in the workflows this repo SHIPS"
                  echo "(ci.yml, maintenance.yml, update.yml at the root) and the ones it RUNS"
                  echo "(.github/workflows). Dependabot only scans .github/workflows, so it bumps"
                  echo "the second and never the first: the fleet keeps the old pin until the"
                  echo "canonical is bumped by hand. Bump the canonical to match, then re-run."
                  exit 1
                fi
              '';

          formatter = pkgs.nixfmt;
          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
            packages = with pkgs; [
              nil
              nixfmt
              jq
              shellcheck
              check-jsonschema
            ];
          };
        };
    };
}
