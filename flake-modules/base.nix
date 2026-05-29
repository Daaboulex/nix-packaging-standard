# flakeModules.base — the shared surface every packaging repo imports.
#
# Consumed by a repo with:
#   imports = [ inputs.std.flakeModules.base ];
#
# Provides, in the consumer's own module fixpoint (so each repo stays
# self-contained and reproducible against its own lock):
#   - the git-hooks lint/format gate (nixfmt-rfc-style, typos, rumdl,
#     check-readme-sections), the formatter, and a dev shell;
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

      # consumer path -> canonical shipped in this standard
      synced = {
        ".github/workflows/ci.yml" = ../ci.yml;
        ".github/workflows/maintenance.yml" = ../maintenance.yml;
        ".github/workflows/update.yml" = ../update.yml;
        "scripts/update.sh" = ../update.sh;
      };
    in
    {
      pre-commit.settings.hooks = {
        nixfmt-rfc-style.enable = true;
        typos.enable = true;
        rumdl.enable = true;
        check-readme-sections = {
          enable = true;
          name = "check-readme-sections";
          entry = "bash scripts/check-readme-sections.sh";
          files = "README\\.md$";
          language = "system";
        };
      };

      formatter = pkgs.nixfmt-rfc-style;

      devShells.default = pkgs.mkShell {
        inputsFrom = [ config.pre-commit.devShell ];
        packages = [ pkgs.nil ];
      };

      checks = (lib.mapAttrs' (n: v: lib.nameValuePair "package-${n}" v) config.packages) // {
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
