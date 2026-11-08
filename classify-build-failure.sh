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
NET=$(mktemp)
trap 'rm -f "$PLAIN" "$NET"' EXIT
sed 's/\x1b\[[0-9;]*m//g' "$LOG" >"$PLAIN"
LOG="$PLAIN"

failed_attrs=$(grep -oE 'Failed attributes: .*' "$LOG" | sed 's/Failed attributes: //' |
  tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
failed_attrs="${failed_attrs% }"
failed_drvs=$(grep -oE "Cannot build '/nix/store/[^']+\.drv'" "$LOG" |
  sed "s|Cannot build '||; s|'\$||" | sort -u | head -12 | tr '\n' ' ')

failed_names=$(tr ' ' '\n' <<<"$failed_drvs" | sed -E 's|^/nix/store/[a-z0-9]+-||; s|\.drv$||; s|-[0-9].*$||' | tr '\n' ' ')
awk -v names="$failed_names" '
  BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") failed[a[i]] = 1 }
  /; retrying in [0-9]/ { next }
  /^[[:space:]]*warning:/ { next }
  match($0, /^[A-Za-z0-9][A-Za-z0-9+._-]*> /) {
    if (substr($0, 1, RLENGTH - 2) in failed) print
    next
  }
  { print }
' "$LOG" >"$NET"

class=unclassified
evidence=""
match_in() {
  local file="$1" line
  if line=$(grep -m1 "$3" -- "$4" "$file"); then
    class="$2"
    evidence=$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-300)
  fi
}
match() { match_in "$LOG" "$@"; }
match_in "$NET" transient-infra -iE "couldn.t resolve host|could not resolve host|temporary failure in name resolution|connection reset by peer|status code: (403|429|5[0-9][0-9])|http error (429|5[0-9][0-9])|returned error: (429|5[0-9][0-9])|curl: \((6|7|28|35|52|56)\)|unable to download '[^']+': .*\((6|7|28|35|52|56)\)$|operation timed out|timeout was reached|service unavailable"
match_in "$NET" transient-infra -E "unable to download '[^']*crates\.io[^']*': HTTP error (403|429)"
if line=$(grep -A3 -E "trying https://([a-z0-9-]+\.)*crates\.io/" -- "$NET" | grep -m1 -E 'returned error: (403|429)'); then
  class=transient-infra
  evidence=$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-300)
fi
match_in "$NET" transient-infra -E "path '[^']+' is not valid|does not exist in the Nix store|no such path in the store"
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
match import-from-derivation -F 'evaluate-every-system: import from derivation:'

out "class" "$class"
out "evidence" "$evidence"
out "failed_attrs" "${failed_attrs:-}"
out "failed_drvs" "${failed_drvs% }"
exit 0
