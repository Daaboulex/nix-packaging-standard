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

  # Eval-only gate for a PACKAGE whose closure is not on cache.nixos.org and
  # cannot build on a free CI runner (CUDA/ROCm toolchains, very large builds).
  # Same idiom as the module checks: force the derivation's full build graph to
  # EVALUATE (catching dep/version/accelerator breakage) via `builtins.seq
  # drv.drvPath`, while storing only a context-free string — so CI never depends
  # on or realizes the heavy closure. Pair it with exposing the package via
  # `flake.packages.<system>` (NOT `perSystem.packages`, which `base` auto-builds)
  # so CI eval-gates it instead of building; the real build happens off-CI against
  # a project cache. See the README "declared == built" exception.
  drvEvalCheck =
    {
      pkgs,
      name ? "drv-eval",
      drv,
    }:
    # Honor the drv's own meta.platforms. On a system the package declares it does
    # NOT support, forcing drv.drvPath throws "Refusing to evaluate ... not
    # available on the requested hostPlatform" (e.g. an x86_64-only off-CI package
    # eval-gated in a repo that ALSO builds aarch64-linux). Skip with a trivial
    # pass there -- the same per-package `declared == built` honesty flakeModules.base
    # applies to perSystem.packages, extended to the off-CI eval gate.
    if !(pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform drv) then
      pkgs.runCommand name { } ''echo "skipped: ${name} not available on ${pkgs.stdenv.hostPlatform.system}" > "$out"''
    else
      pkgs.runCommand name {
        ok = builtins.seq drv.drvPath "evaluated";
      } ''echo "$ok" > "$out"'';

  # requirements.txt coverage gate for env+source python apps: an app shipped
  # as python.withPackages + upstream source has no wheel metadata, so
  # pythonRuntimeDepsCheckHook never runs -- a new upstream requirement ships
  # silently and fails only at the user's runtime import. Compares the
  # PEP503-normalized requirement names in the source's requirements file
  # against the distributions actually present in the built env and fails
  # naming every missing one. Version pins are deliberately ignored (the env
  # ships nixpkgs' versions); extras and environment markers are stripped.
  # Pair with update.json pythonRequirements (update.sh auto-adds resolvable
  # new requirements at the '# std:requirements-auto-add' marker).
  requirementsCoveredCheck =
    {
      pkgs,
      env, # the python.withPackages env
      src, # upstream source containing the requirements file
      file ? "requirements.txt",
      ignore ? [ ], # requirement names knowingly not shipped (PEP503-normalized)
    }:
    pkgs.runCommand "requirements-covered"
      {
        nativeBuildInputs = [ env ];
        ignored = builtins.concatStringsSep " " ignore;
      }
      ''
        python - "$ignored" <<'PY'
        import re
        import sys
        from importlib import metadata

        def norm(name):
            return re.sub(r"[-_.]+", "-", name).lower()

        ignored = {norm(n) for n in sys.argv[1].split()}
        have = {norm(d.metadata["Name"]) for d in metadata.distributions()}
        missing = []
        for line in open("${src}/${file}"):
            line = line.split("#")[0].split(";")[0].strip()
            if not line:
                continue
            req = re.split(r"[\[<>=!~ ]", line)[0].strip()
            if req and norm(req) not in have and norm(req) not in ignored:
                missing.append(req)
        if missing:
            print("requirements not present in the env:", ", ".join(missing))
            print("add each to the withPackages list (or the check's ignore list)")
            sys.exit(1)
        print("ok: every requirement is present in the env")
        PY
        touch "$out"
      '';

  # Self-contained dev state (the fleet rule: a project dev shell never writes
  # $HOME, and per-project build/cache dirs stay out of the tree): export each
  # tool's cache/home/build dir into the project's gitignored .devshell/. base
  # wires this into the default dev shell; a repo with custom shells sets
  # `shellHook = inputs.std.lib.devStateHook;` (or appends it). nix-direnv
  # (.envrc `use flake`) captures the exports for every in-project entry
  # point, not just `nix develop`. Deliberately NOT pinned here: CARGO_HOME
  # and HF_HOME (shared registry/model caches belong to the machine config,
  # an explicit owner choice). Extend per tool from the same seam.
  devStateHook = ''
    export DEVSHELL_STATE="$PWD/.devshell"
    mkdir -p "$DEVSHELL_STATE"
    export PRE_COMMIT_HOME="$DEVSHELL_STATE/pre-commit"
    export RUFF_CACHE_DIR="$DEVSHELL_STATE/ruff"
    export MYPY_CACHE_DIR="$DEVSHELL_STATE/mypy"
    export PYTHONPYCACHEPREFIX="$DEVSHELL_STATE/pycache"
    export PIP_CACHE_DIR="$DEVSHELL_STATE/pip"
    export CARGO_TARGET_DIR="$DEVSHELL_STATE/cargo-target"
    export npm_config_cache="$DEVSHELL_STATE/npm-cache"
  '';
}
