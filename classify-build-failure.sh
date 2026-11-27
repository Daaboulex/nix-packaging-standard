#!/usr/bin/env bash
set -uo pipefail

usage="usage: classify-build-failure.sh [--update] <logfile> [<class of the step that failed>]; writes class, evidence, failed_attrs and failed_drvs"
in_update=no
if [ "${1:-}" = --update ]; then
  in_update=yes
  shift
fi
LOG="${1:?$usage}"
base="${2:-unclassified}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/stdout}"
out() { echo "$1=$2" >>"$OUTPUT_FILE"; }

[ -r "$LOG" ] || {
  out "class" "$base"
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
attr_names=$(tr ' ' '\n' <<<"$failed_attrs" | sed -E 's|^\.#checks\.[^.]+\.||' | tr '\n' ' ')
awk -v names="$failed_names" -v attrs="$attr_names" '
  BEGIN {
    n = split(names, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") failed[a[i]] = 1
    n = split(attrs, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") attr[a[i]] = 1
  }
  /; retrying in [0-9]/ { next }
  /^[[:space:]]*warning:/ { next }
  match($0, /^[A-Za-z0-9][A-Za-z0-9+._-]*> /) {
    name = substr($0, 1, RLENGTH - 2)
    rest = substr($0, RLENGTH + 1)
    if (name in failed) print
    else if (name in attr) {
      if (rest ~ /^error:/) nix_block[name] = 1
      else if (rest !~ /^[[:space:]]/) nix_block[name] = 0
      if (nix_block[name]) print
    }
    next
  }
  { print }
' "$LOG" >"$NET"

class="$base"
evidence=""
if [ -n "$failed_attrs" ] && [[ " $attr_names" != *" package-"* ]]; then
  class=check-error
fi
match_in() {
  local file="$1" line
  if line=$(grep -m1 "$3" -- "$4" "$file"); then
    class="$2"
    evidence=$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-300)
  fi
}
match() { match_in "$LOG" "$@"; }
not_found=$(awk '
  /error: Cannot build / { url = "" }
  /[[:space:]]> trying https?:\/\// { url = $0 }
  /[[:space:]]> curl: \([0-9]+\) The requested URL returned error: 404/ { print (url != "" ? url : $0); exit }
  /unable to download .https?:\/\/[^ ]+.: HTTP error 404/ { print; exit }
' "$NET")
if [ -n "$not_found" ]; then
  class=source-not-found
  evidence=$(printf '%s' "$not_found" | sed 's/^[[:space:]]*//' | cut -c1-300)
fi
match_in "$NET" transient-infra -iE "couldn.t resolve host|could not resolve host|temporary failure in name resolution|connection reset by peer|status code: (403|429|5[0-9][0-9])|http error (429|5[0-9][0-9])|returned error: (429|5[0-9][0-9])|curl: \((6|7|28|35|52|56)\)|unable to download '[^']+': .*\((6|7|28|35|52|56)\)$|operation timed out|timeout was reached|service unavailable"
match_in "$NET" transient-infra -E "unable to download '[^']*crates\.io[^']*': HTTP error (403|429)"
if line=$(grep -A3 -E "trying https://([a-z0-9-]+\.)*crates\.io/" -- "$NET" | grep -m1 -E 'returned error: (403|429)'); then
  class=transient-infra
  evidence=$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-300)
fi
match_in "$NET" transient-infra -E "path '[^']+' is not valid|does not exist in the Nix store|no such path in the store"
nix_trace_frame=$'\xe2\x80\xa6 while '
if at=$(grep -n -m1 -E "nix_fast_build:EVAL: [0-9]+ successes, [1-9]|error: Failed assertions|while evaluating (the attribute|the option|derivation)|$nix_trace_frame" -- "$LOG"); then
  class=eval-error
  evidence=$(awk -v from="${at%%:*}" '
    NR < from { next }
    NR == from { last = $0 }
    NR > from && /^[^[:space:]]/ { exit }
    /^[[:space:]]*error: [^[:space:]]/ { last = $0 }
    END { print last }
  ' "$LOG" | sed 's/^[[:space:]]*//' | cut -c1-300)
fi
match compile-error -E '\.(c|cc|cpp|cxx|h|hh|hpp|hxx):[0-9]+:[0-9]+: (fatal )?error: |\[-Werror(=[a-z0-9-]+)?\]'
match setup-hook-error -F 'Builder called die:'
match sandbox-download -F 'file DOWNLOAD cannot compute hash on failed download'
if [ "$in_update" = yes ]; then
  match updater-missed-hash -F 'hash mismatch in fixed-output'
else
  match upstream-rerelease-hash-mismatch -F 'hash mismatch in fixed-output'
fi
match nixpkgs-package-drop -E 'not supported for interpreter python|is marked as broken'
match missing-python-dep -F 'ModuleNotFoundError'
match missing-python-dep -E '^ *> *- [a-zA-Z0-9_.-]+ not installed'
match requirements-coverage -F 'requirements not present in the env'
match python-metadata-version-mismatch -F 'METADATA specifies version'
match substitution-pattern-drift -E "ERROR: pattern .* doesn.t match anything in file"
match import-from-derivation -F 'evaluate-every-system: import from derivation:'
match runner-lost -E '^runner-lost: '

out "class" "$class"
out "evidence" "$evidence"
out "failed_attrs" "${failed_attrs:-}"
out "failed_drvs" "${failed_drvs% }"
exit 0
