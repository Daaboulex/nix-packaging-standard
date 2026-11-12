#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
system=$(nix eval --impure --raw --expr builtins.currentSystem)
ran=0

declared=$(nix eval --impure --json --expr \
  "let f = builtins.getFlake (toString ./.); in f ? apps && f.apps ? \"$system\" && f.apps.\"$system\" ? after-lock-update")

case "$declared" in
false)
  echo "after-lock-update: the flake declares no apps.$system.after-lock-update, nothing to run"
  ;;
true)
  nix run ".#after-lock-update"
  ran=1
  ;;
*)
  echo "after-lock-update: could not read the flake's apps: $declared" >&2
  exit 1
  ;;
esac

written=$(bash "$here/write-option-reference.sh")
printf '%s\n' "$written"
case "$written" in
*"docs/OPTIONS.md written"*) ran=1 ;;
esac

[ "$ran" = 1 ] || exit 0

untracked=$(git ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
  echo "after-lock-update created files git does not track; it may only rewrite tracked ones:" >&2
  printf '%s\n' "$untracked" >&2
  exit 1
fi

git add -u
git diff --cached --stat
