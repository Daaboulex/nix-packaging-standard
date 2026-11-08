#!/usr/bin/env bash
set -uo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT
nix flake check --no-build --all-systems --no-eval-cache --option allow-import-from-derivation false "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  needed=$(grep -m1 -oE "cannot build '[^']+' during evaluation|path '[^']+' is not valid" "$log")
  if [ -n "$needed" ]; then
    echo "evaluate-every-system: import from derivation: $needed. Something reads a derivation output while evaluating (builtins.readFile, import or importJSON of a built file), which passes on a store that already holds the file and fails on every other; read the file in the build step instead." >&2
  fi
fi
exit "$rc"
