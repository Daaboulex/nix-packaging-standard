#!/usr/bin/env bash
# check-readme-sections — verify README.md has the required structural sections.
# Canonical script, run by the pre-commit hook wired in flakeModules.base
# (repos do not carry their own copy).
set -euo pipefail

README="README.md"
[ -f "$README" ] || exit 0

errors=0
check_marker() {
  if ! grep -qF "<!-- BEGIN generated:$1 -->" "$README"; then
    echo "README.md: missing <!-- BEGIN generated:$1 --> marker"
    errors=$((errors + 1))
  fi
}

check_marker "badges"
check_marker "upstream"
check_marker "footer"

if ! grep -qE "^## (Installation|Quick Start)" "$README" &&
  ! grep -qF "<!-- BEGIN generated:installation -->" "$README"; then
  echo "README.md: missing installation section (## Installation, ## Quick Start, or generated:installation marker)"
  errors=$((errors + 1))
fi

[ "$errors" -eq 0 ] && exit 0
echo ""
echo "Fix: add the missing generated:* marker(s) to README.md (structure governed by github:Daaboulex/nix-packaging-standard)."
exit 1
