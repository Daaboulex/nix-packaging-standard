#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
fetch-uncached-sources - fetch from upstream every fixed-output derivation that the packages and checks the
flake in the current directory declares for this system would build, which on a store nothing was restored
into is every pinned source no binary cache holds.

  fetch-uncached-sources.sh

Exit: 0 when each such source was fetched or none was needed; 1 when the flake did not evaluate, or the dry
run failed or printed no plan; otherwise the exit code of the nix command that failed; 2 on a usage error.
USAGE
}

[ "$#" -eq 0 ] || {
  usage >&2
  exit 2
}

if ! evaluated=$(nix eval --json --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    system = builtins.currentSystem;
    drvPaths = outputs:
      if builtins.hasAttr system outputs then
        map (output: output.drvPath) (builtins.attrValues (builtins.getAttr system outputs))
      else
        [ ];
  in
  drvPaths (flake.packages or { }) ++ drvPaths (flake.checks or { })'); then
  echo "::error::fetch-uncached-sources: the packages and checks of this flake did not evaluate, so the sources they pin could not be read"
  exit 1
fi
declared=$(jq -r 'unique[]' <<<"$evaluated")
if [ -z "$declared" ]; then
  echo "nothing needed fetching: this flake declares no package or check for this system"
  exit 0
fi
mapfile -t drvs <<<"$declared"

if ! plan=$(nix build --dry-run --no-link "${drvs[@]/%/^*}" 2>&1); then
  printf '%s\n' "$plan"
  echo "::error::fetch-uncached-sources: the dry run failed, so what no binary cache holds could not be read"
  exit 1
fi
if ! grep -qE '^(this|these [0-9]+) (derivation|derivations|path|paths) will be (built|fetched)' <<<"$plan"; then
  printf '%s\n' "$plan"
  echo "::error::fetch-uncached-sources: the dry run printed no plan, no line saying what will be built or fetched, so what no binary cache holds could not be read"
  exit 1
fi

fixed=()
built=$(awk '/^[[:space:]]+\/nix\/store\/[^[:space:]]+\.drv$/ { print $1 }' <<<"$plan")
if [ -n "$built" ]; then
  mapfile -t candidates <<<"$built"
  for drv in "${candidates[@]}"; do
    shown=$(nix derivation show "$drv")
    fixed_output=$(jq -r 'first(.. | objects | select(has("outputHash"))) | [.urls // .url // empty] | flatten | "fixed:" + join(" ")' <<<"$shown")
    [ -n "$fixed_output" ] || continue
    fixed+=("$drv")
    name=${drv##*/}
    name=${name#*-}
    name=${name%.drv}
    urls=${fixed_output#fixed:}
    echo "fetching $name${urls:+ from $urls}"
  done
fi
if [ "${#fixed[@]}" -eq 0 ]; then
  echo "nothing needed fetching: the plan builds no fixed-output derivation, so a binary cache holds every source it needs"
  exit 0
fi

nix build --no-link --keep-going --print-build-logs "${fixed[@]/%/^*}"
echo "fetched ${#fixed[@]} pinned source(s) no binary cache holds"
