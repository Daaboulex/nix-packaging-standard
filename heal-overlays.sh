#!/usr/bin/env bash
set -uo pipefail

# Canonical heal-overlays — Nix Packaging Standard.
#
# EVERY temporary divergence from nixpkgs -- a regression bridge, a dependency
# the packaged upstream needs but nixpkgs' package does not carry yet, or a
# version pin -- lives in overlays/<name>.nix, one fix per file (mirrors the
# main config's parts/overlays/_fixes convention), and carries a predicate that
# retires it:
#
#   {
#     meta = { reason = "..."; added = "YYYY-MM-DD"; upstream = "..."; };
#     dropWhen = pkgs: <bool>;             # true => healed, delete me
#     # ...or, when the breakage is invisible to eval:
#     dropWhenBuilds = pkgs: <derivation>; # builds => healed, delete me
#     overlay = final: prev: { ... };
#   }
#
# Exactly one predicate, and it must TEST the actual condition. A version-string
# proxy is forbidden: it fires on an unrelated bump, the fix is dropped while the
# breakage is still live, and the repo re-breaks later.
#
# The repo composes overlays.default = glue + fixes and exports overlays.probe
# = the glue WITHOUT fixes. This script probes each fix against a probe pkgs
# (the repo's locked nixpkgs + overlays.probe + every OTHER fix, in readDir
# order like overlays.default, allowUnfree), so a fix still needed elsewhere
# cannot break the probe of one that healed: dropWhen is
# evaluated, dropWhenBuilds is BUILT (a build-phase failure -- a broken test
# suite, a pkg-config version reject -- is not eval-visible, so guessing from
# eval would be the version-proxy mistake in another form). A fix that fires is
# HEALED, and its file and every file its meta.owns names are deleted from the
# tree.
#
# This script decides and removes; it does NOT verify. maintenance.yml runs it
# INSIDE the lock-update job, right after `nix flake update`, so every fix is
# judged against the inputs the repo is moving TO -- probing the committed lock
# instead would read a fix needed only on the NEW nixpkgs as healed, drop it,
# and re-break on the next bump. The caller's single verification build then
# gates the lock bump and the removals together, restoring the fixes if that
# build is red.
#
# Contract: exit 0 = ran (see outputs), exit 1 = malformed fix / probe error /
# failed removal (fail closed), exit 2 = environment error. Outputs
# (GITHUB_OUTPUT, or stdout without one):
#   kept=<names>   healed=<names>

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/stdout}"
output() { echo "$1=$2" >>"$OUTPUT_FILE"; }
log() { echo "==> $*"; }
err() { echo "::error::$*"; }

output "kept" ""
output "healed" ""

if [ ! -d overlays ]; then
  log "No overlays/ directory — nothing to heal"
  exit 0
fi

shopt -s nullglob
files=(overlays/*.nix)
if [ ${#files[@]} -eq 0 ]; then
  err "overlays/ exists but holds no .nix fix — remove the empty directory"
  exit 1
fi

command -v nix >/dev/null 2>&1 || {
  err "nix not available"
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  err "jq not available"
  exit 2
}
scratch=$(mktemp -d) || {
  err "could not create a scratch directory under ${TMPDIR:-/tmp}"
  exit 2
}
trap 'rm -rf "$scratch"' EXIT

healed=()
kept=()
removed=()
for f in "${files[@]}"; do
  name=$(basename "$f" .nix)
  # Shape check first — a malformed fix is a hard error, never skipped.
  if ! nix eval --json --impure --expr \
    "let v = import ./${f}; in { reason = v.meta.reason; added = v.meta.added; owns = v.meta.owns or [ ]; hasDrop = v ? dropWhen; hasBuildDrop = v ? dropWhenBuilds; hasOverlay = v ? overlay; }" \
    >"$scratch/meta.json" 2>"$scratch/meta.err"; then
    err "overlays/${name}.nix: malformed — needs meta.reason, meta.added, overlay, and exactly one of dropWhen / dropWhenBuilds ($(tail -1 "$scratch/meta.err"))"
    exit 1
  fi
  if ! jq -e '(.hasDrop != .hasBuildDrop) and .hasOverlay and (.reason | type == "string" and length > 0) and (.added | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and (.owns | type == "array" and all(type == "string"))' \
    "$scratch/meta.json" >/dev/null; then
    err "overlays/${name}.nix: meta.reason must be a nonempty string, meta.added a YYYY-MM-DD date, meta.owns when set a list of repository paths, overlay must exist, and EXACTLY ONE of dropWhen / dropWhenBuilds must be set"
    exit 1
  fi
  owned=()
  owns=$(jq -r '.owns[]' "$scratch/meta.json") || {
    err "overlays/${name}.nix: could not read meta.owns from $scratch/meta.json"
    exit 1
  }
  [ -z "$owns" ] || mapfile -t owned <<<"$owns"
  if ! unit_errors=$(git ls-files -z | bash "$here/scripts/check-fix-unit.sh" "$f" "${owned[@]}"); then
    while IFS= read -r line; do err "$line"; done <<<"$unit_errors"
    exit 1
  fi
  probePkgs="
    let
      flake = builtins.getFlake (toString ./.);
      others = builtins.filter (n: n != \"${name}.nix\" && builtins.match \".*[.]nix\" n != null) (
        builtins.attrNames (builtins.readDir ./overlays)
      );
      pkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        config.allowUnfree = true;
        overlays = [ flake.overlays.probe ] ++ map (n: (import (./overlays + \"/\${n}\")).overlay) others;
      };
    in"
  if jq -e '.hasBuildDrop' "$scratch/meta.json" >/dev/null; then
    # The probe target must always EVALUATE — a predicate that cannot even
    # instantiate is malformed, not "still needed", so it fails closed here
    # instead of silently pinning the fix forever.
    if ! nix eval --json --impure --expr \
      "${probePkgs} let d = (import ./${f}).dropWhenBuilds pkgs; in { drvPath = d.drvPath; fixedOutput = d ? outputHash; }" \
      >"$scratch/probe.json" 2>"$scratch/probe.err"; then
      err "overlays/${name}.nix: dropWhenBuilds must evaluate to a derivation — fix the predicate ($(tail -1 "$scratch/probe.err"))"
      exit 1
    fi
    if jq -e '.fixedOutput' "$scratch/probe.json" >/dev/null; then
      err "overlays/${name}.nix: dropWhenBuilds names a fixed-output derivation (a fetch), which reads as built whenever its output is already in the store and so cannot observe the condition; test the eval-visible condition with dropWhen instead"
      exit 1
    fi
    # Now the real question: does it BUILD without the fix? A failure here is
    # the expected "still broken" answer, never an error.
    if nix build --no-link --impure --expr \
      "${probePkgs} (import ./${f}).dropWhenBuilds pkgs" >"$scratch/build.log" 2>&1; then
      verdict=true
    else
      verdict=false
    fi
  else
    verdict=$(nix eval --json --impure --expr \
      "${probePkgs} (import ./${f}).dropWhen pkgs" 2>"$scratch/probe.err") || {
      err "overlays/${name}.nix: dropWhen probe errored — fix the predicate ($(tail -1 "$scratch/probe.err"))"
      exit 1
    }
  fi
  if [ "$verdict" = "true" ]; then
    log "overlays/${name}.nix: HEALED — nixpkgs provides this again; removing"
    healed+=("$name")
    removed+=("$f" "${owned[@]}")
  else
    log "overlays/${name}.nix: still needed"
    kept+=("$name")
  fi
done

output "kept" "${kept[*]:-}"
if [ ${#healed[@]} -eq 0 ]; then
  exit 0
fi

git rm -q -- "${removed[@]}" || {
  err "could not git rm ${removed[*]}"
  exit 1
}
output "healed" "${healed[*]}"
exit 0
