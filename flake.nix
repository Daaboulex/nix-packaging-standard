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

          # patchAssertions is a shell string, so nothing type-checks it: this
          # exercises every primitive both ways. A helper that cannot fail is
          # exactly the defect it exists to prevent.
          checks.std-patch-assertions =
            pkgs.runCommand "std-patch-assertions"
              {
                prelude = (import ./lib.nix).patchAssertions;
              }
              ''
                printf 'alpha\nbeta\nalpha\n' > f
                probe() { # probe <want-exit> <label> <body>
                  local rc=0
                  set +e
                  bash -c "set -e; cd $PWD; $prelude"$'\n'"$3" > out 2>&1
                  rc=$?
                  set -e
                  if [ "$rc" = "$1" ]; then
                    echo "  ok   $2"
                  else
                    echo "  FAIL $2 (exit $rc, want $1)"
                    sed 's/^/         /' out
                    bad=1
                  fi
                }
                bad=0
                probe 0 "landed finds what an edit produced"        "landed f beta l"
                probe 1 "landed fails when the edit did not apply"  "landed f zulu l"
                probe 0 "gone passes when the text is absent"       "gone f zulu l"
                probe 1 "gone fails while the text remains"         "gone f beta l"
                probe 0 "present passes on a live precondition"     "present f beta l"
                probe 1 "present fails on an obsolete patch"        "present f zulu l"
                probe 0 "exactly_one accepts a single match"        "exactly_one f '^beta$' l"
                probe 1 "exactly_one rejects two matches"           "exactly_one f '^alpha$' l"
                probe 1 "exactly_one rejects zero matches"          "exactly_one f '^zulu$' l"
                probe 0 "landed_soft warns but never fails"         "landed_soft f zulu l"
                [ "$bad" = 0 ] || { echo "std-patch-assertions: a primitive does not behave"; exit 1; }
                echo "std-patch-assertions: 10 cases, all as specified"
                touch "$out"
              '';

          # Each pattern must match its own fail-open example and NOT the
          # correct one. Built from the same list the gate uses, so a pattern
          # that stops discriminating cannot go unnoticed.
          checks.std-fail-open-patterns =
            let
              inherit (import ./lib.nix) failOpenPatterns;
              case = p: ''
                printf '%s\n' ${pkgs.lib.escapeShellArg p.bad} > bad.txt
                printf '%s\n' ${pkgs.lib.escapeShellArg p.good} > good.txt
                if grep -qE -- ${pkgs.lib.escapeShellArg p.ere} bad.txt; then
                  echo "  ok   ${p.name}: catches the fail-open form"
                else
                  echo "  FAIL ${p.name}: does not match its own bad example"
                  bad=1
                fi
                if grep -qE -- ${pkgs.lib.escapeShellArg p.ere} good.txt; then
                  echo "  FAIL ${p.name}: also flags the correct form"
                  bad=1
                else
                  echo "  ok   ${p.name}: leaves the correct form alone"
                fi
              '';
            in
            pkgs.runCommand "std-fail-open-patterns" { } ''
              bad=0
              ${pkgs.lib.concatMapStringsSep "\n" case failOpenPatterns}
              [ "$bad" = 0 ] || { echo "a fail-open pattern no longer discriminates"; exit 1; }
              echo "std-fail-open-patterns: ${toString (builtins.length failOpenPatterns)} patterns, each matching only the bad form"
              touch "$out"
            '';

          checks.std-fleet-roll-build-is-bounded =
            pkgs.runCommand "std-fleet-roll-build-is-bounded" { roll = ./scripts/fleet-roll.sh; }
              ''
                invocation=$(awk '/nix-fast-build --/,/flake "\.#checks/' "$roll")

                grep -q -- '-j "\$FAST_BUILD_JOBS"' <<< "$invocation" \
                  || { echo "fleet-roll invokes nix-fast-build without an explicit -j. Its -j DEFAULTS to nix's max-jobs, so on a max-jobs=0 host it starts zero build workers and then waits forever on a queue nothing drains: a silent hang, not an error"; exit 1; }

                jobs=$(sed -n 's/^FAST_BUILD_JOBS=\''${FAST_BUILD_JOBS:-\([0-9]*\)}.*/\1/p' "$roll")
                [ -n "$jobs" ] && [ "$jobs" -gt 0 ] \
                  || { echo "FAST_BUILD_JOBS must default to a positive number; 0 is the hang"; exit 1; }

                if ! grep -q 'stat -c %s "\$buildlog"' "$roll"; then
                  echo "the per-repo build is not bounded on SILENCE. A wall-clock bound cannot separate a heavy build from a hang: both occupy the same duration, so raising it kills healthy work and lowering it still misses stalls. Bound on absence of output"
                  exit 1
                fi

                if grep -q 'timeout "\$BUILD_TIMEOUT"' "$roll"; then
                  echo "the build is bounded on elapsed time again. That killed three healthy builds, one of which had already succeeded and was copying its result back"
                  exit 1
                fi

                stall=$(sed -n 's/^STALL_TIMEOUT=\''${STALL_TIMEOUT:-\([0-9]*\)}.*/\1/p' "$roll")
                if [ -z "$stall" ] || [ "$stall" -le 0 ]; then
                  echo "STALL_TIMEOUT must default to a positive number of seconds; absent or 0 means the stall is never reported"
                  exit 1
                fi

                grep -q 'brc" -eq 124' "$roll" \
                  || { echo "a timeout exit is not classified, so it would be reported as an ordinary build failure"; exit 1; }

                touch "$out"
              '';

          checks.std-fleet-roll-verifies-hooks =
            pkgs.runCommand "std-fleet-roll-verifies-hooks"
              {
                roll = ./scripts/fleet-roll.sh;
                audit = ./scripts/fleet-audit.sh;
              }
              ''
                if ! grep -q 'ensure_hook "\$dir"' "$roll"; then
                  echo "fleet-roll commits without checking the repo's pre-commit hook. A MISSING hook lets the commit succeed with the repo's own gate never running -- success reported for work nothing verified. A dangling one (its store path garbage-collected) fails the commit with an unreadable error"
                  exit 1
                fi

                if ! grep -q 'e "\$p"' "$roll"; then
                  echo "the hook check does not test that the recorded store path still EXISTS, so a hook garbage-collected out from under the clone still reads as present"
                  exit 1
                fi

                if ! grep -q 'hook_absent' "$audit"; then
                  echo "fleet-audit does not report a clone with NO pre-commit hook, so the silent half of this failure never announces itself"
                  exit 1
                fi

                touch "$out"
              '';

          checks.std-fleet-roll-restores-on-abort =
            pkgs.runCommand "std-fleet-roll-restores-on-abort" { roll = ./scripts/fleet-roll.sh; }
              ''
                if ! grep -qE '^trap on_abort .*INT.*TERM' "$roll"; then
                  echo "fleet-roll does not trap interruption. A Ctrl-C, SIGTERM, usage limit or crash then leaves the repo it was mid-edit dirty, and the NEXT roll refuses that repo with 'working tree is not clean'. That stranding has cost two runs"
                  exit 1
                fi

                if ! grep -q 'restore "\$IN_FLIGHT"' "$roll"; then
                  echo "the abort trap does not restore the in-flight repo, so it reports the interruption while still stranding the tree"
                  exit 1
                fi

                if ! grep -q '^  IN_FLIGHT="\$dir"' "$roll"; then
                  echo "no repo is ever marked in-flight, so the abort trap has nothing to restore and silently does nothing"
                  exit 1
                fi

                touch "$out"
              '';

          checks.std-update-retire-guard =
            pkgs.runCommand "std-update-retire-guard" { canonical = ./update.yml; }
              ''
                guarded() {
                  local step
                  step=$(awk '
                    /^      - name: Retire attempt branches/ { inStep = 1 }
                    inStep && /^        uses:/ { exit }
                    inStep { print }
                  ' "$1")
                  grep -q 'github\.event\.repository\.default_branch' <<< "$step"
                }

                if guarded "$canonical"; then
                  echo "  ok   the retire step only runs on the default branch"
                else
                  echo "  FAIL update.yml retires attempt branches from any ref."
                  echo "       Dispatched on an update/* branch, the job deletes the ref that same"
                  echo "       run just pushed its successful update to."
                  exit 1
                fi

                sed '/github\.event\.repository\.default_branch/d' "$canonical" > ungated.yml
                if guarded ungated.yml; then
                  echo "  FAIL this check passes a file with the gate removed, so it proves nothing"
                  exit 1
                fi
                echo "  ok   the check rejects the ungated form"
                touch "$out"
              '';

          # The one composition rule custom shells got wrong: the pins must run
          # BEFORE the hook install, or pre-commit writes ~/.cache/pre-commit
          # before PRE_COMMIT_HOME exists and std-home-proof refuses the push.
          checks.std-devshell-pins-before-hooks =
            pkgs.runCommand "std-devshell-pins-before-hooks"
              {
                hook = ((import ./lib.nix).mkDevShell { inherit pkgs config; } { }).shellHook;
              }
              ''
                printf '%s' "$hook" >hook.sh
                pins=$(grep -n 'PRE_COMMIT_HOME=' hook.sh | head -1 | cut -d: -f1)
                install=$(grep -n 'pre-commit install' hook.sh | head -1 | cut -d: -f1)
                if [ -z "$pins" ]; then
                  echo "mkDevShell composed a hook that never pins PRE_COMMIT_HOME, so every tool it starts writes the real home"
                  exit 1
                fi
                if [ -z "$install" ]; then
                  echo "mkDevShell composed a hook that never installs the git hooks, so the repo's own gate would never run"
                  exit 1
                fi
                if [ "$pins" -ge "$install" ]; then
                  echo "mkDevShell puts the hook install at line $install ahead of the pins at line $pins, so pre-commit writes ~/.cache/pre-commit before PRE_COMMIT_HOME exists"
                  exit 1
                fi

                touch "$out"
              '';

          # The roll reported every failed push as a permissions problem, so a
          # pre-push hook refusing it (std-home-proof finding real home
          # pollution) read as a GitHub problem and sent the reader to the
          # wrong place entirely.
          checks.std-fleet-roll-names-the-push-failure =
            pkgs.runCommand "std-fleet-roll-names-the-push-failure" { roll = ./scripts/fleet-roll.sh; }
              ''
                if grep -q 'archived or no write access' "$roll"; then
                  echo "the roll still guesses at a failed push instead of reading the error git gave it"
                  exit 1
                fi

                if ! grep -q 'pre-push' "$roll"; then
                  echo "the roll cannot tell a local hook refusal from a remote one, so the two read alike"
                  exit 1
                fi

                if grep -q 'Eval: local-fast-build' "$roll"; then
                  echo "the adoption commit still writes the retired Eval: trailer instead of a plain Test: line"
                  exit 1
                fi

                touch "$out"
              '';

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

          # This repo runs what it ships: its own maintenance workflow must be
          # the canonical (GitHub reads no symlinked workflow, so it is a copy),
          # and the two scripts that workflow calls are symlinks to the
          # canonicals. Nothing else compares the copy with the shipped file.
          checks.std-own-copies-match-shipped =
            pkgs.runCommand "std-own-copies-match-shipped" { src = ./.; }
              ''
                cd "$src"
                bad=0
                if cmp -s maintenance.yml .github/workflows/maintenance.yml; then
                  echo "  ok   .github/workflows/maintenance.yml is the shipped canonical"
                else
                  echo "  FAIL .github/workflows/maintenance.yml differs from the maintenance.yml this repo ships; copy the canonical over it"
                  diff -u maintenance.yml .github/workflows/maintenance.yml | head -40
                  bad=1
                fi
                for s in heal-overlays.sh classify-build-failure.sh; do
                  if [ "$(readlink "scripts/$s")" = "../$s" ]; then
                    echo "  ok   scripts/$s is a link to the canonical"
                  else
                    echo "  FAIL scripts/$s is not a symlink to ../$s; a copy would drift the way the workflow did"
                    bad=1
                  fi
                done
                [ "$bad" = 0 ] || exit 1
                touch "$out"
              '';

          # The README is the contract a consumer reads. Every check base
          # provides, every lib helper and every synced file must be named in
          # it, and the pin in the consumption example must be the newest
          # version the History section records, or the page reads as current
          # while it is not.
          checks.std-readme-names-every-surface =
            pkgs.runCommand "std-readme-names-every-surface"
              {
                readme = ./README.md;
                base = ./flake-modules/base.nix;
                hooks = ./flake-modules/hooks.nix;
                libNames = builtins.attrNames (import ./lib.nix);
                syncedPaths = builtins.attrNames (lib.importJSON ./synced-files.json);
              }
              ''
                bad=0
                want() {
                  if grep -qE -- "\`(inputs\.)?(std\.lib\.)?$1(\`| |\{)" "$readme"; then
                    echo "  ok   README names $1"
                  else
                    echo "  FAIL README does not name $1 ($2)"
                    bad=1
                  fi
                }
                for n in $(grep -ohE '(^|[[:space:]])std-[a-z0-9-]+ =' "$base" "$hooks" | tr -d ' =' | sort -u); do
                  want "$n" "a check or hook this standard provides"
                done
                for n in $libNames; do
                  want "$n" "a std.lib helper"
                done
                for p in $syncedPaths; do
                  want "$p" "a synced file"
                done
                newest=$(grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+ \(' "$readme" | tail -1 | tr -d ' (')
                pin=$(grep -oE 'nix-packaging-standard\?ref=v[0-9]+\.[0-9]+\.[0-9]+' "$readme" | head -1 | cut -d= -f2)
                if [ -z "$newest" ] || [ -z "$pin" ]; then
                  echo "  FAIL could not read the newest History version ('$newest') or the example pin ('$pin')"
                  bad=1
                elif [ "$newest" != "$pin" ]; then
                  echo "  FAIL the consumption example pins $pin while History's newest entry is $newest"
                  bad=1
                else
                  echo "  ok   the example pins the newest version, $pin"
                fi
                [ "$bad" = 0 ] || exit 1
                touch "$out"
              '';

          formatter = pkgs.writeShellScriptBin "treefmt" ''
            exec ${pkgs.nixfmt-tree}/bin/treefmt --no-cache "$@"
          '';
          packages.std-home-proof = import ./flake-modules/home-proof.nix { inherit pkgs; };
          devShells.default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                nil
                nixfmt
                jq
                shellcheck
                check-jsonschema
                config.pre-commit.settings.package
              ]
              ++ config.pre-commit.settings.enabledPackages;
            shellHook = (import ./lib.nix).devStateHook + config.pre-commit.installationScript;
          };
        };
    };
}
