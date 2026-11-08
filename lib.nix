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
rec {
  releaseUrl = "github:Daaboulex/nix-packaging-standard/release";

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
      pkgs.runCommand name { }
        ''echo "skipped: ${name} not available on ${pkgs.stdenv.hostPlatform.system}" > "$out"''
    else
      pkgs.runCommand name {
        ok = builtins.seq drv.drvPath "evaluated";
      } ''echo "$ok" > "$out"'';

  # Byte-equality gate for prebuilt binaries that read themselves at runtime
  # (embedded resource maps, appended payloads, .NET single-file bundles).
  # patchelf/strip on such a binary shifts its embedded offsets and breaks it
  # at runtime while the build stays green -- install the file pristine, launch
  # it through the host loader (nix-ld on NixOS), supply deps via wrapper env,
  # and let this check prove the installed bytes equal the fetched source.
  pristineBinaryCheck =
    {
      pkgs,
      package,
      binaryPath,
      name ? "${package.pname or package.name}-binary-pristine",
    }:
    pkgs.runCommand name { } ''
      cmp ${package.src} "${package}/${binaryPath}"
      touch "$out"
    '';

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

  # One top-level import package per python application: site-packages is a
  # global namespace shared by every package in a merged environment (a Nix
  # profile's buildEnv, a venv). A flat top-level module (cli.py, utils.py)
  # collides there with any other application shipping the same generic name
  # and the whole profile fails to build on the conflict -- corecycler's flat
  # cli.py vs hermes-agent's flat cli.py broke a home profile (2026-07-20).
  # Inspects the BUILT output (the ground truth a profile merges), not the
  # pyproject declaration: everything must live under the one declared package.
  pythonSitePackagesCheck =
    {
      pkgs,
      drv,
      package, # the single allowed top-level import package name
      name ? "python-site-packages",
    }:
    pkgs.runCommand name { } ''
      shopt -s nullglob dotglob
      spdirs=("${drv}"/lib/python*/site-packages)
      if [ "''${#spdirs[@]}" -ne 1 ]; then
        echo "expected exactly one site-packages under ${drv}/lib, found ''${#spdirs[@]}"
        exit 1
      fi
      sp="''${spdirs[0]}"
      if [ ! -d "$sp/${package}" ]; then
        echo "declared package '${package}' missing from site-packages"
        exit 1
      fi
      bad=0
      for entry in "$sp"/*; do
        base="''${entry##*/}"
        case "$base" in
        "${package}" | *.dist-info) ;;
        *)
          echo "flat top-level entry in site-packages: $base"
          bad=1
          ;;
        esac
      done
      if [ "$bad" -ne 0 ]; then
        echo "every module must live under the '${package}' package"
        exit 1
      fi
      echo "ok: single top-level package '${package}'" > "$out"
    '';

  # Shell shapes that report success while doing nothing. Consumed by
  # flakeModules.base as the std-no-fail-open gate and tested against fixtures
  # from the same list, so the gate cannot silently stop matching. A line
  # carrying `std:fail-open-ok: <reason>` is exempt: a tolerance that is
  # declared is not the same defect as one nobody noticed.
  failOpenScan =
    { lib, src }:
    p: ''
      rc=0
      matches=$(grep -rnE --include='*.nix' --include='*.sh' --include='*.yml' \
        -- ${lib.escapeShellArg p.ere} ${src}) || rc=$?
      if [ "$rc" -gt 1 ]; then
        echo "::error::grep could not read the source tree (exit $rc)"
        exit 1
      fi
      hits=$(grep -v 'std:fail-open-ok' <<<"$matches") || hits=
      if [ -n "$hits" ]; then
        printf '%s\n' "$hits"
        echo "::error::${p.name} -- ${p.fix}"
        bad=1
      fi
    '';

  failOpenPatterns = [
    {
      name = "grep -c piped into || echo";
      ere = "grep -c[A-Za-z]* .*\\|\\| *echo";
      bad = "n=$(grep -c foo f || echo 0)";
      good = "n=$(grep -c foo f) || n=0";
      fix = "grep -c prints 0 AND exits 1 when nothing matches, so || echo appends a SECOND value and the variable becomes \"0\\\\n0\" -- every numeric test after it errors and falls through. Assign, then default on failure.";
    }
    {
      name = "substituteInPlace --replace";
      ere = "--replace([[:space:]]|$)";
      bad = "substituteInPlace f --replace a b";
      good = "substituteInPlace f --replace-fail a b";
      fix = "bare --replace is deprecated and tolerant: a pattern upstream moved silently rewrites nothing. Use --replace-fail.";
    }
    {
      name = "substituteInPlace --replace-warn";
      ere = "--replace-warn";
      bad = "substituteInPlace f --replace-warn a b";
      good = "substituteInPlace f --replace-fail a b";
      fix = "--replace-warn ships the package with the substitution missing and only a warning in a log nobody reads. Use --replace-fail, or mark the line std:fail-open-ok with the reason it must stay tolerant.";
    }
    {
      name = "nix eval swallowed";
      ere = "\\$\\(nix eval[^)]*\\|\\| *true\\)";
      bad = "declared=$(nix eval .#checks.x86_64-linux 2>/dev/null || true)";
      good = "declared=$(nix eval .#checks.x86_64-linux)";
      fix = "an evaluation error becomes an empty value, and the empty value reads as 'nothing declared', so a flake that no longer evaluates is skipped as green. Let the assignment fail.";
    }
  ];

  # Assertions for a postPatch that rewrites upstream source. A bare `sed -i`,
  # `awk` or hand-rolled substitution reports nothing: when upstream renames
  # what it matched, the edit applies to nothing, the package builds green, and
  # the change it was meant to make is simply absent. Found live in three repos
  # at once -- a kernel CPUID anchor that had gained an argument, a printk
  # rewrite upstream had already made unnecessary, and a getuid() guard that no
  # longer existed -- plus two more that were no-ops by construction. nixpkgs'
  # substituteInPlace --replace-fail is the same idea; this is it for the edits
  # substituteInPlace cannot express. Prepend to postPatch, assert after every
  # edit, and see the README for a worked example.
  #
  # landed FILE FIXED LABEL       what the edit produces is now present
  # gone FILE FIXED LABEL         what the edit replaced is now absent
  # present FILE FIXED LABEL      precondition; pair it with `gone`, whose
  #                               postcondition passes just as happily against
  #                               a source that never held the text
  # exactly_one FILE ERE LABEL    an insertion anchor matches once, so an edit
  #                               cannot land twice (a duplicate C label, say)
  # landed_soft FILE FIXED LABEL  a deliberately optional edit; warns, never fails
  patchAssertions = ''
    _patch_assert_die() {
      echo "[FAIL] $1"
      exit 1
    }
    present() {
      grep -qF -- "$2" "$1" || _patch_assert_die "$3 -- the text this edit rewrites is absent from $1 (looked for: $2). The patch is obsolete: drop it or re-aim it."
    }
    landed() {
      grep -qF -- "$2" "$1" || _patch_assert_die "$3 -- the edit did not apply to $1 (expected to find: $2). The upstream anchor moved; re-aim this edit."
      echo "[OK] $3"
    }
    gone() {
      if grep -qF -- "$2" "$1"; then
        _patch_assert_die "$3 -- the edit did not replace it in $1 (still present: $2). The upstream anchor moved; re-aim this edit."
      fi
      echo "[OK] $3"
    }
    landed_soft() {
      if grep -qF -- "$2" "$1"; then
        echo "[OK] $3"
      else
        echo "[WARN] $3 -- optional edit did not apply to $1"
      fi
    }
    exactly_one() {
      local n
      n=$(grep -cE -- "$2" "$1") || n=0
      [ "$n" = 1 ] || _patch_assert_die "$3 -- expected exactly 1 match of /$2/ in $1, found $n. Re-aim this anchor before it edits the wrong place."
    }
  '';

  # Self-contained dev state (the fleet rule: a project dev shell never writes
  # $HOME, and per-project build/cache dirs stay out of the tree): export each
  # tool's cache/home/build dir into the project's gitignored .devshell/. base
  # wires this into the default dev shell; a repo with custom shells sets
  # inputs.std.lib.mkDevShell, which composes it in the one correct order.
  # Setting shellHook alone is NOT enough beside inputsFrom = [
  # config.pre-commit.devShell ]: that shell's hook installs pre-commit first
  # and writes ~/.cache/pre-commit before PRE_COMMIT_HOME exists. nix-direnv
  # (.envrc `use flake`) captures the exports for every in-project entry
  # point, not just `nix develop`. Deliberately NOT pinned here: CARGO_HOME
  # and HF_HOME (shared registry/model caches belong to the machine config,
  # an explicit owner choice). Extend per tool from the same seam.
  devStateHook = ''
    export DEVSHELL_STATE="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.devshell"
    mkdir -p "$DEVSHELL_STATE"
    export NIX_CACHE_HOME="''${NIX_CACHE_HOME:-''${XDG_CACHE_HOME:-$HOME/.cache}/nix}"
    export XDG_CACHE_HOME="$DEVSHELL_STATE/cache"
    export PRE_COMMIT_HOME="$DEVSHELL_STATE/pre-commit"
    export RUFF_CACHE_DIR="$DEVSHELL_STATE/ruff"
    export MYPY_CACHE_DIR="$DEVSHELL_STATE/mypy"
    export PYTHONPYCACHEPREFIX="$DEVSHELL_STATE/pycache"
    export PIP_CACHE_DIR="$DEVSHELL_STATE/pip"
    export CARGO_TARGET_DIR="$DEVSHELL_STATE/cargo-target"
    export npm_config_cache="$DEVSHELL_STATE/npm-cache"
    export npm_config_devdir="$DEVSHELL_STATE/node-gyp"
    export COREPACK_HOME="$DEVSHELL_STATE/corepack"
    export YARN_CACHE_FOLDER="$DEVSHELL_STATE/yarn-cache"
    export NODE_REPL_HISTORY="$DEVSHELL_STATE/node-repl-history"
    export NO_UPDATE_NOTIFIER=1
    export CCACHE_DIR="$DEVSHELL_STATE/ccache"
    export CCACHE_TEMPDIR="$DEVSHELL_STATE/ccache/tmp"
  '';

  # mkDevShell — a custom dev shell that cannot get the order wrong. The hook
  # tools arrive as packages instead of through
  # inputsFrom = [ config.pre-commit.devShell ], whose own shellHook runs first
  # and installs pre-commit before the pins exist, writing ~/.cache/pre-commit.
  # Here devStateHook runs, then the installation script, then the caller's own
  # hook.
  mkDevShell =
    { pkgs, config }:
    args:
    pkgs.mkShell (
      builtins.removeAttrs args [
        "packages"
        "shellHook"
      ]
      // {
        packages =
          (args.packages or [ ])
          ++ [ config.pre-commit.settings.package ]
          ++ config.pre-commit.settings.enabledPackages;
        shellHook = devStateHook + config.pre-commit.installationScript + (args.shellHook or "");
      }
    );

  steamCompatTool =
    spec:
    let
      build =
        pkgs:
        {
          attribute,
          brand,
          homepage,
          description,
          license,
          sources,
          majorPattern,
          buildOf,
          assetUrl,
          variantsOf,
          tokens,
          fetch ? ({ url, hash, ... }: pkgs.fetchzip { inherit url hash; }),
        }:
        let
          inherit (pkgs) lib;
          hostSystem = pkgs.stdenv.hostPlatform.system;
          archOf = system: lib.head (lib.splitString "-" system);
          majorOf =
            tag:
            let
              m = builtins.match majorPattern tag;
            in
            if m == null then
              throw "${attribute}: '${tag}' does not match majorPattern '${majorPattern}'"
            else
              lib.head m;
          releases = {
            ${sources.version} = sources;
          }
          // sources.pins;
          majorChannel = tag: "v${lib.head (lib.splitString "." (majorOf tag))}";
          hasToken = token: tag: variantsOf releases.${tag} ? ${token};
          qualifiers =
            token: tag: channel:
            lib.optional (tokens.${token}.qualifier != null) tokens.${token}.qualifier
            ++ [ (buildOf tag) ]
            ++ lib.optional (channel == "latest") "latest";
          display =
            token: tag: channel:
            "${brand} ${majorOf tag} (${lib.concatStringsSep ", " (qualifiers token tag channel)})";
          key = token: channel: "${attribute}${tokens.${token}.suffix}-${channel}";
          tool =
            token: tag: channel:
            let
              t = tokens.${token};
              foreign = t.system != hostSystem;
            in
            pkgs.stdenvNoCC.mkDerivation {
              pname = "${attribute}${lib.optionalString foreign "-${archOf t.system}"}${t.suffix}";
              version = tag;
              src = fetch {
                inherit tag token;
                url = assetUrl tag token;
                hash = (variantsOf releases.${tag}).${token};
              };
              dontUnpack = true;
              dontConfigure = true;
              dontBuild = true;
              outputs = [
                "out"
                "steamcompattool"
              ];
              passthru = {
                inherit tag token channel;
                key = key token channel;
                display = display token tag channel;
              };
              installPhase = ''
                runHook preInstall
                test -e "$src/proton" || {
                  echo "${attribute}: ${tag} (${token}) has no proton entry point" >&2
                  exit 1
                }
                test -f "$src/toolmanifest.vdf" || {
                  echo "${attribute}: ${tag} (${token}) has no toolmanifest.vdf" >&2
                  exit 1
                }
                echo "${attribute} is a Steam compatibility tool; consume its steamcompattool output through programs.steam.extraCompatPackages" > "$out"
                mkdir "$steamcompattool"
                ln -s "$src"/* "$steamcompattool"
                rm -f "$steamcompattool/compatibilitytool.vdf"
                cat > "$steamcompattool/compatibilitytool.vdf" <<'VDF'
                "compatibilitytools"
                {
                  "compat_tools"
                  {
                    "${key token channel}"
                    {
                      "install_path" "."
                      "display_name" "${display token tag channel}"
                      "from_oslist" "windows"
                      "to_oslist" "linux"
                    }
                  }
                }
                VDF
                runHook postInstall
              '';
              meta = {
                inherit homepage description license;
                platforms = [ t.system ] ++ lib.optional foreign hostSystem;
                sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
              };
            };
          channels =
            token:
            let
              pinned = lib.filter (hasToken token) (lib.attrNames sources.pins);
              names = map majorChannel pinned;
              rolling = majorChannel sources.version;
            in
            if lib.elem rolling names then
              throw "${attribute}: a pin shares the rolling release's major (${rolling}); the rollover pins that line when upstream closes it"
            else if lib.length (lib.unique names) != lib.length names then
              throw "${attribute}: two pins share one major among ${lib.concatStringsSep ", " names}; one pin per major"
            else
              lib.listToAttrs (
                map (tag: lib.nameValuePair (majorChannel tag) (tool token tag (majorChannel tag))) pinned
              )
              // {
                latest = tool token sources.version "latest";
                ${rolling} = tool token sources.version rolling;
              };
          withChannels =
            token:
            let
              c = channels token;
            in
            c.latest.overrideAttrs (old: {
              passthru = old.passthru // c;
            });
          offered = lib.filterAttrs (token: _: hasToken token sources.version) tokens;
          native = lib.filterAttrs (_: t: t.system == hostSystem) offered;
          x86 = lib.filterAttrs (_: t: t.system == "x86_64-linux") offered;
          tools =
            lib.mapAttrs' (token: t: lib.nameValuePair "${attribute}${t.suffix}" (withChannels token)) native
            // lib.mapAttrs' (
              token: t: lib.nameValuePair "${attribute}-x86_64${t.suffix}" (withChannels token)
            ) x86;
          every = lib.unique (
            lib.concatMap (token: lib.attrValues (channels token)) (lib.attrNames (native // x86))
          );
          qualifierWords = lib.unique (
            lib.filter (q: q != null) (lib.mapAttrsToList (_: t: t.qualifier) tokens)
          );
          displayFormat =
            "^${brand} [0-9]+(\\.[0-9]+)? \\(("
            + lib.concatMapStringsSep "|" (q: "${q}, ") qualifierWords
            + ")?[0-9A-Za-z-]+(, latest)?\\)$";
          shape = pkgs.runCommand "${attribute}-compat-tool-shape" { } (
            ''
              refuse() {
                echo "$1"
                exit 1
              }
              shopt -s nullglob
            ''
            + lib.concatMapStringsSep "\n" (d: ''
              dir=${d.steamcompattool}
              test -e "$dir/proton" || refuse "${d.name}: no proton entry point"
              test -f "$dir/toolmanifest.vdf" || refuse "${d.name}: no toolmanifest.vdf"
              test -f "$dir/compatibilitytool.vdf" || refuse "${d.name}: no compatibilitytool.vdf"
              key=$(sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' "$dir/compatibilitytool.vdf" | sed -n 3p)
              shown=$(sed -nE 's/^[[:space:]]*"display_name"[[:space:]]+"(.*)"[[:space:]]*$/\1/p' "$dir/compatibilitytool.vdf")
              [ "$key" = ${lib.escapeShellArg d.passthru.key} ] || refuse "${d.name}: the vdf key is '$key', wanted '${d.passthru.key}'"
              grep -qE '^[a-z0-9-]+$' <<<"$key" || refuse "${d.name}: the key '$key' is not lowercase letters, digits and hyphens"
              [ "$shown" = ${lib.escapeShellArg d.passthru.display} ] || refuse "${d.name}: the display name is '$shown', wanted '${d.passthru.display}'"
              grep -qE ${lib.escapeShellArg displayFormat} <<<"$shown" || refuse "${d.name}: '$shown' is not <Brand> <major> (<qualifiers>)"
              if grep -qiE 'arm64|aarch64|x86_64|slr' <<<"$key $shown"; then
                refuse "${d.name}: an arch or build-type word leaked into '$key' or '$shown'"
              fi
              ${lib.optionalString (d.passthru.channel != "latest") ''
                case "$shown" in
                *latest*) refuse "${d.name}: a pinned channel shows 'latest'" ;;
                esac
              ''}
              echo "$key" >> "keys.${tokens.${d.passthru.token}.system}"
            '') every
            + ''
              for f in keys.*; do
                dup=$(sort "$f" | uniq -d)
                [ -z "$dup" ] || refuse "one key names two tools a ''${f#keys.} client would both list: $dup"
              done
              echo "${attribute}: ${toString (lib.length every)} tools, every vdf in shape" > "$out"
            ''
          );
          drvPaths =
            set:
            lib.mapAttrs (
              _: tool:
              [ tool.drvPath ]
              ++ lib.mapAttrsToList (_: channel: channel.drvPath) (
                lib.filterAttrs (_: lib.isDerivation) tool.passthru
              )
            ) set;
          wanted = drvPaths tools;
          throughOverlay = drvPaths (lib.getAttrs (lib.attrNames tools) (pkgs.extend overlay));
          differing = lib.filter (name: throughOverlay.${name} != wanted.${name}) (lib.attrNames tools);
          overlayApplies = pkgs.runCommand "${attribute}-overlay-applies" { } (
            if differing == [ ] then
              ''echo "${attribute}: the overlay yields the ${toString (lib.length (lib.attrNames tools))} tool attributes of this host, each with its channels" > "$out"''
            else
              ''
                echo "${attribute}: through the overlay, ${lib.concatStringsSep ", " differing} differ from the flake's own packages"
                exit 1
              ''
          );
        in
        {
          inherit tools shape overlayApplies;
        };
      overlay = _final: prev: (build prev (spec prev)).tools;
    in
    {
      inherit overlay;
      forPkgs =
        pkgs:
        let
          host = build pkgs (spec pkgs);
        in
        {
          inherit (host) tools;
          checks = {
            compat-tool-shape = host.shape;
            overlay-applies = host.overlayApplies;
          };
        };
    };
}
