#!/usr/bin/env bash
set -uo pipefail

LOG="${1:?usage: classify-build-failure.sh <logfile>; writes class, evidence, failed_attrs and failed_drvs}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/stdout}"
out() { echo "$1=$2" >>"$OUTPUT_FILE"; }

[ -r "$LOG" ] || {
  out "class" "unclassified"
  out "evidence" ""
  out "failed_attrs" ""
  out "failed_drvs" ""
  exit 0
}

PLAIN=$(mktemp)
trap 'rm -f "$PLAIN"' EXIT
sed 's/\x1b\[[0-9;]*m//g' "$LOG" >"$PLAIN"
LOG="$PLAIN"

failed_attrs=$(grep -oE 'Failed attributes: .*' "$LOG" | sed 's/Failed attributes: //' |
  tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
failed_attrs="${failed_attrs% }"
failed_drvs=$(grep -oE "Cannot build '/nix/store/[^']+\.drv'" "$LOG" |
  sed "s|Cannot build '||; s|'\$||" | sort -u | head -12 | tr '\n' ' ')

class=unclassified
evidence=""
match() {
  local line
  if line=$(grep -m1 "$2" -- "$3" "$LOG"); then
    class="$1"
    evidence=$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-300)
  fi
}
match transient-infra -iE "couldn.t resolve host|temporary failure in name resolution|connection reset by peer|status code: (403|429)|operation timed out|service unavailable"
match transient-infra -E "path '[^']+' is not valid|does not exist in the Nix store|no such path in the store"
match eval-error -E 'nix_fast_build:EVAL: [0-9]+ successes, [1-9]|error: Failed assertions|while evaluating (the attribute|the option|derivation)'
match compile-error -E '\.(c|cc|cpp|cxx|h|hh|hpp|hxx):[0-9]+:[0-9]+: (fatal )?error: |\[-Werror(=[a-z0-9-]+)?\]'
match setup-hook-error -F 'Builder called die:'
match sandbox-download -F 'file DOWNLOAD cannot compute hash on failed download'
match upstream-rerelease-hash-mismatch -F 'hash mismatch in fixed-output'
match nixpkgs-package-drop -E 'not supported for interpreter python|is marked as broken'
match missing-python-dep -F 'ModuleNotFoundError'
match missing-python-dep -E '^ *> *- [a-zA-Z0-9_.-]+ not installed'
match requirements-coverage -F 'requirements not present in the env'
match python-metadata-version-mismatch -F 'METADATA specifies version'
match substitution-pattern-drift -E "ERROR: pattern .* doesn.t match anything in file"

out "class" "$class"
out "evidence" "$evidence"
out "failed_attrs" "${failed_attrs:-}"
out "failed_drvs" "${failed_drvs% }"
exit 0
