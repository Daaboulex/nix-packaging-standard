#!/usr/bin/env bash
set -euo pipefail

README="README.md"
[ -f "$README" ] || exit 0

errors=0
if ! grep -qE '^# ' "$README"; then
  echo "README.md: no title, a line starting with '# ' that names what this is"
  errors=$((errors + 1))
fi
if ! grep -qE '^## (Install|Installation|Quick Start)$' "$README"; then
  echo "README.md: no section that says how to install it (## Install, ## Installation or ## Quick Start)"
  errors=$((errors + 1))
fi

[ "$errors" -eq 0 ] && exit 0
echo ""
echo "The README is the page a person reads first: see the Documentation rules of github:Daaboulex/nix-packaging-standard."
exit 1
