# flakeModules.base — the shared surface every packaging repo imports.
#
# Consumed by a repo with:
#   imports = [ inputs.std.flakeModules.base ];
#
# Provides, in the consumer's own module fixpoint (so each repo stays
# self-contained and reproducible against its own lock):
#   - the git-hooks lint/format gate (nixfmt-rfc-style, typos, rumdl with its
#     config, and the standard's own check-readme-sections script), the
#     formatter, and a dev shell — so repos carry no .rumdl.toml or linter scripts;
#   - every declared package aliased into `checks` (so `nix flake check` /
#     nix-fast-build actually BUILD the package — nix#13470);
#   - `std-conformance`: a hermetic check that the synced workflow/script
#     files byte-match this standard's canonicals (replaces the old
#     curl-based drift-check.yml — no network, no raw.githubusercontent);
#   - `std-update-json`: validates .github/update.json against the schema.
{ inputs, lib, ... }:
{
  imports = [ inputs.git-hooks.flakeModule ];

  perSystem =
    { config, pkgs, ... }:
    let
      src = inputs.self;

      # custom-updater repos ship a bespoke scripts/update.sh — exclude it from
      # the byte-conformance check (it is intentionally not the canonical).
      updateJson =
        if builtins.pathExists (src + "/.github/update.json") then
          builtins.fromJSON (builtins.readFile (src + "/.github/update.json"))
        else
          { };
      isCustom = (updateJson.upstream.type or "") == "custom";

      # consumer path -> canonical shipped in this standard
      syncedAll = {
        ".github/workflows/ci.yml" = ../ci.yml;
        ".github/workflows/maintenance.yml" = ../maintenance.yml;
        ".github/workflows/update.yml" = ../update.yml;
        "scripts/update.sh" = ../update.sh;
        "scripts/heal-overlays.sh" = ../heal-overlays.sh;
      };
      synced = if isCustom then builtins.removeAttrs syncedAll [ "scripts/update.sh" ] else syncedAll;

      # Only alias a package into `checks` on systems it actually supports (its
      # own meta.platforms / badPlatforms). Without this, an x86_64-only package
      # in a repo that ALSO declares aarch64-linux aborts the aarch64 build with
      # "Refusing to evaluate ... not available on the requested hostPlatform".
      # True package-level `declared == built`: each package builds only where
      # its meta allows, so a repo may mix arch-portable and x86-only packages.
      buildable = lib.filterAttrs (_: p: lib.meta.availableOn pkgs.stdenv.hostPlatform p) config.packages;
    in
    {
      pre-commit.settings.hooks = {
        # Use pkgs.nixfmt directly: pkgs.nixfmt-rfc-style is now an alias of it
        # and emits a deprecation warning on every eval. Same formatter, no noise.
        nixfmt-rfc-style = {
          enable = true;
          package = pkgs.nixfmt;
        };
        typos.enable = true;
        # rumdl config lives HERE, not in a per-repo .rumdl.toml: MD013
        # (line length) is impractical for prose, links, and tables.
        rumdl = {
          enable = true;
          settings.configuration = {
            MD013.enabled = false;
          };
        };
        # The README-section linter is the standard's own script (no per-repo
        # scripts/check-readme-sections.sh to copy and let drift).
        check-readme-sections = {
          enable = true;
          name = "check-readme-sections";
          entry = "bash ${../scripts/check-readme-sections.sh}";
          files = "README\\.md$";
          language = "system";
        };
      };

      formatter = pkgs.nixfmt;

      devShells.default = pkgs.mkShell {
        inputsFrom = [ config.pre-commit.devShell ];
        packages = [ pkgs.nil ];
      };

      checks = (lib.mapAttrs' (n: v: lib.nameValuePair "package-${n}" v) buildable) // {
        std-conformance = pkgs.runCommand "std-conformance" { } (
          (lib.concatStringsSep "\n" (
            lib.mapAttrsToList (dst: canon: ''
              if ! diff -u ${canon} ${src + "/${dst}"}; then
                echo "::error::${dst} drifted from the canonical nix-packaging-standard"
                exit 1
              fi
              echo "ok  ${dst}"
            '') synced
          ))
          + "\ntouch \"$out\"\n"
        );

        std-update-json =
          pkgs.runCommand "std-update-json" { nativeBuildInputs = [ pkgs.check-jsonschema ]; }
            ''
              check-jsonschema --schemafile ${../update.schema.json} ${src + "/.github/update.json"}
              touch "$out"
            '';
      };
    };
}
