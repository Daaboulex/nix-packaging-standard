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
          system,
          ...
        }:
        let
          actionlintIgnore = ''property "workflow_(repository|sha)" is not defined in object type'';
          baseOn =
            fixture: systems:
            (inputs.flake-parts.lib.mkFlake
              {
                inputs = inputs // {
                  self = {
                    outPath = fixture;
                    inherit inputs;
                  };
                };
              }
              {
                inherit systems;
                imports = [ ./flake-modules/base.nix ];
              }
            ).checks;
        in
        {
          pre-commit.settings.hooks =
            (import ./flake-modules/hooks.nix {
              inherit pkgs lib;
              ruffConfigArg = " --config ${./ruff.toml}";
            })
            // {
              check-readme-sections.enable = false;
              shellcheck = {
                enable = true;
                files = "\\.sh$";
              };
              actionlint = {
                enable = true;
                files = "^(\\.github/workflows|callers)/";
                entry = lib.mkForce "${pkgs.actionlint}/bin/actionlint -ignore ${lib.escapeShellArg actionlintIgnore}";
              };
            };

          checks.std-actionlint-ignore-still-needed =
            pkgs.runCommand "std-actionlint-ignore-still-needed"
              {
                nativeBuildInputs = [ pkgs.actionlint ];
                probe = ./.github/workflows/package-ci.yml;
              }
              ''
                if actionlint "$probe" >lint.txt 2>&1; then
                  echo "actionlint ${pkgs.actionlint.version} accepts job.workflow_repository and job.workflow_sha; delete actionlintIgnore and its -ignore from flake.nix"
                  exit 1
                fi
                if ! grep -q 'property "workflow_sha" is not defined' lint.txt; then
                  cat lint.txt
                  echo "actionlint rejects the probe for a reason other than the one the ignore covers"
                  exit 1
                fi
                if ! actionlint -ignore ${lib.escapeShellArg actionlintIgnore} "$probe"; then
                  echo "the ignore no longer silences the job.workflow_* finding; its message changed"
                  exit 1
                fi
                touch "$out"
              '';

          checks.std-every-job-has-a-timeout =
            pkgs.runCommand "std-every-job-has-a-timeout"
              {
                nativeBuildInputs = [ pkgs.yq-go ];
                workflows = [
                  ./.github/workflows/package-ci.yml
                  ./.github/workflows/package-update.yml
                  ./.github/workflows/package-maintenance.yml
                ];
              }
              ''
                unbounded() { yq -r '.jobs | to_entries | map(select(.value["timeout-minutes"] == null)) | .[].key' "$1"; }
                bad=0
                for w in $workflows; do
                  missing=$(unbounded "$w")
                  if [ -n "$missing" ]; then
                    echo "  FAIL ''${w#*-}: job(s) with no timeout-minutes, so a hung step runs for six hours: $missing"
                    bad=1
                  fi
                done
                printf 'jobs:\n  bounded:\n    timeout-minutes: 5\n  open:\n    runs-on: x\n' > twin.yml
                if [ "$(unbounded twin.yml)" != open ]; then
                  echo "  FAIL the check does not name the unbounded job of its twin, so it proves nothing"
                  bad=1
                fi
                [ "$bad" = 0 ] || exit 1
                touch "$out"
              '';

          checks.std-base-fixtures =
            let
              current = (baseOn ./tests/fixtures/consumer-current [ system ]).${system};
              stale = (baseOn ./tests/fixtures/consumer-stale [ system ]).${system};
              custom = (baseOn ./tests/fixtures/consumer-custom [ system ]).${system};
              both = baseOn ./tests/fixtures/consumer-current [
                "x86_64-linux"
                "aarch64-linux"
              ];
              armOnly = baseOn ./tests/fixtures/consumer-current [ "aarch64-linux" ];
              expect =
                what: got: want:
                if got == want then null else "${what}: got ${builtins.toJSON got}, want ${builtins.toJSON want}";
              failures = lib.filter (x: x != null) [
                (expect "a consumer on the release branch is declared as one" current.std-follows-release.declared
                  (import ./lib.nix).releaseUrl
                )
                (expect "a consumer pinned to a tag is declared as that tag" stale.std-follows-release.declared
                  "github:Daaboulex/nix-packaging-standard?ref=v2.42.0"
                )
                (expect "a consumer carrying no retired copy has none" current.std-no-retired-copies.present [ ])
                (expect "a consumer carrying retired copies has each one named" stale.std-no-retired-copies.present
                  [
                    "scripts/heal-overlays.sh"
                    "scripts/update.sh"
                  ]
                )
                (expect "a custom updater's own scripts/update.sh is not a retired copy"
                  custom.std-no-retired-copies.present
                  [ ]
                )
                (expect "a consumer declaring both systems lints on x86_64-linux" (
                  both.x86_64-linux ? pre-commit
                ) true)
                (expect "and does not lint again on aarch64-linux" (both.aarch64-linux ? pre-commit) false)
                (expect "a consumer declaring only aarch64-linux lints there" (
                  armOnly.aarch64-linux ? pre-commit
                ) true)
              ];
            in
            pkgs.runCommand "std-base-fixtures" { } (
              if failures == [ ] then
                ''touch "$out"''
              else
                lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg f}") failures + "\nexit 1\n"
            );

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

          checks.std-no-fail-open-scan =
            let
              inherit (import ./lib.nix) failOpenPatterns failOpenScan;
              swallowed = builtins.head (builtins.filter (p: p.name == "nix eval swallowed") failOpenPatterns);
              fixture = pkgs.runCommand "fail-open-fixture" { } ''
                mkdir -p "$out/.github/workflows"
                printf '%s\n' ${pkgs.lib.escapeShellArg swallowed.bad} > "$out/.github/workflows/ci.yml"
                printf '%s\n' ${pkgs.lib.escapeShellArg swallowed.bad} > "$out/notes.txt"
              '';
            in
            pkgs.runCommand "std-no-fail-open-scan" { } ''
              bad=0
              {
                ${failOpenScan {
                  inherit (pkgs) lib;
                  src = fixture;
                } swallowed}
              } > report.txt
              cat report.txt
              if [ "$bad" != 1 ]; then
                echo "the consumer scan missed a swallowed nix eval in a workflow file"
                exit 1
              fi
              if grep -q notes.txt report.txt; then
                echo "the consumer scan read a file outside its --include set"
                exit 1
              fi
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

                if ! grep -q 'REMOTELESS=1' "$roll"; then
                  echo "fleet-roll has no path for a consumer with no remote: it fails at the fetch, so an unpushed WIP can never adopt a tag and sits on an old one while the audit reds its drift"
                  exit 1
                fi

                if ! grep -q '^  if ! refresh_hook "\$dir"; then' "$roll"; then
                  echo "the roll does not regenerate the hook set after the pin bump, so the adoption commit and push run the OLD tag's gate: a proof from the old tag that needs a native dev shell refuses the push of a flake the host cannot build"
                  exit 1
                fi

                if ! grep -q 'e "\$1/.pre-commit-config.yaml"' "$roll"; then
                  echo "the hook check does not test that the config link still resolves; the hook binary can survive a collection that took the config, and the commit then fails on a missing config"
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

                if ! grep -q '^  if ! git -C "\$dir" add -A; then' "$roll"; then
                  echo "fleet-roll builds and commits without staging what sync.sh wrote, so a newly synced file is invisible to the flake build and never committed"
                  exit 1
                fi

                if ! grep -q 'reset --quiet --hard HEAD' "$roll"; then
                  echo "restore does not reset the index, so a staged adoption survives a failed roll and strands the repo"
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

          checks.std-declared-runners =
            pkgs.runCommand "std-declared-runners"
              {
                script = ./declared-runners.sh;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                mkdir bin
                cat > bin/nix <<'STUB'
                #!${pkgs.runtimeShell}
                if [ -n "$STUB_FAIL" ]; then
                  echo "error: stub evaluation failure" >&2
                  exit 1
                fi
                printf '%s' "$STUB_DECLARED"
                STUB
                chmod +x bin/nix
                export PATH="$PWD/bin:$PATH" STUB_FAIL=
                bad=0
                expect() {
                  local got
                  if got=$(STUB_DECLARED="$2" bash "$script" $3); then
                    if [ "$got" = "$4" ]; then
                      echo "  ok   $1"
                    else
                      echo "  FAIL $1: printed $got, expected $4"
                      bad=1
                    fi
                  else
                    echo "  FAIL $1: exited non-zero"
                    bad=1
                  fi
                }
                refuse() {
                  if STUB_DECLARED="$2" STUB_FAIL="$3" bash "$script" >/dev/null 2>&1; then
                    echo "  FAIL $1: passed, so a flake nothing verifies would read as green"
                    bad=1
                  else
                    echo "  ok   $1"
                  fi
                }
                expect "both systems name both runners" '["aarch64-linux","x86_64-linux"]' "" '["ubuntu-24.04-arm","ubuntu-latest"]'
                expect "the system already built is left out" '["aarch64-linux","x86_64-linux"]' x86_64-linux '["ubuntu-24.04-arm"]'
                expect "nothing left to build is an empty list" '["x86_64-linux"]' x86_64-linux '[]'
                refuse "a system no runner builds is refused" '["riscv64-linux"]' ""
                refuse "a flake with checks on no system is refused" '[]' ""
                refuse "an evaluation error is refused" '["x86_64-linux"]' 1
                [ "$bad" = 0 ] || exit 1
                touch "$out"
              '';

          checks.std-update-retire-guard =
            pkgs.runCommand "std-update-retire-guard" { canonical = ./.github/workflows/package-update.yml; }
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

          # A consumer with no output for the rolling host cannot be built there.
          # The roll must still verify it (every declared system evaluates) and
          # still run its gate (the hook set built for the host), and never
          # push it silently unverified.
          checks.std-fleet-roll-verifies-a-foreign-flake =
            pkgs.runCommand "std-fleet-roll-verifies-a-foreign-flake" { roll = ./scripts/fleet-roll.sh; }
              ''
                grep -q 'foreign_flake "\$dir" "\$sys"' "$roll" \
                  || { echo "fleet-roll never asks whether the host has an output for the flake, so a foreign flake either fails the roll or, worse, is pushed on a skipped build"; exit 1; }
                grep -q -- '--no-build --all-systems' "$roll" \
                  || { echo "a foreign flake is not verified by evaluating every system it declares"; exit 1; }
                grep -q 'host-hooks.nix' "$roll" \
                  || { echo "ensure_hook has no fallback for a flake with no dev shell on this host, so the commit would run no gate"; exit 1; }
                grep -q 'the build is CI' "$roll" \
                  || { echo "the adoption commit of a foreign flake does not say that the build is left to CI"; exit 1; }
                touch "$out"
              '';

          checks.std-own-copies-match-shipped =
            pkgs.runCommand "std-own-copies-match-shipped"
              {
                own = ./.github/workflows/maintenance.yml;
                shipped = ./callers/maintenance.yml;
              }
              ''
                sed 's#uses: Daaboulex/nix-packaging-standard/\(.*\)@release#uses: ./\1#' "$shipped" >local.yml
                if cmp -s "$shipped" local.yml; then
                  echo "  FAIL callers/maintenance.yml no longer calls package-maintenance.yml@release, so this check compares nothing"
                  exit 1
                fi
                if ! diff -u local.yml "$own"; then
                  echo "  FAIL .github/workflows/maintenance.yml is not the consumers' caller pointed at this commit's own package-maintenance.yml"
                  exit 1
                fi
                touch "$out"
              '';

          # A verdict this repo's own CI reads must come from this flake's lock,
          # never from whatever the runner image happens to ship. A bare
          # `shellcheck` ran the image's older build and failed on findings the
          # pinned one does not report, so the step was red on code that is
          # clean locally and nothing in the log said why.
          checks.std-own-ci-pins-its-tools =
            pkgs.runCommand "std-own-ci-pins-its-tools" { own = ./.github/workflows; }
              ''
                # Every tool whose OUTPUT is a verdict. `bash script.sh` runs
                # one of our own scripts and is not one; `bash -n` judges it,
                # so it is.
                tools="shellcheck actionlint check-jsonschema pipx nixfmt shfmt statix deadnix typos rumdl"
                bad=0
                report() {
                  echo "  FAIL a step runs '$1' from the runner image, not from this flake:"
                  echo "       $2"
                  bad=1
                }
                # Any line that names one of them must carry the pin on that
                # same line. A step name and a comment name a tool without
                # running it; nothing else does.
                judge() { # judge <label> <ere>
                  local hits hit
                  hits=$(grep -rhE -- "$2" "$own"/*.yml | grep -vE '^ *#|name:' || true)
                  while IFS= read -r hit; do
                    [ -n "$hit" ] || continue
                    case "$hit" in
                    *"nix run --inputs-from ."* | *"nix shell --inputs-from ."* | *"nix develop"*) continue ;;
                    esac
                    report "$1" "$hit"
                  done <<< "$hits"
                }
                for t in $tools; do judge "$t" "\\b$t\\b"; done
                judge "bash -n" '\bbash +-n\b'
                [ "$bad" = 0 ] || {
                  echo "put it behind 'nix run --inputs-from . nixpkgs#<tool> --' so the local run and the runner read the same version"
                  exit 1
                }
                echo "ok: every verdict-bearing tool in this repo's own CI comes from its lock"
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
                if grep -qF '"${(import ./lib.nix).releaseUrl}"' "$readme"; then
                  echo "  ok   the consumption example follows the release branch"
                else
                  echo "  FAIL the README shows no std input set to \"${(import ./lib.nix).releaseUrl}\", the only url std-follows-release accepts"
                  bad=1
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
