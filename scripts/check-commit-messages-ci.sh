#!/usr/bin/env bash
set -euo pipefail

base=$1
head=$2
std=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
where=$(nix eval --json .#apps --apply 'apps: builtins.filter (s: builtins.getAttr s apps ? std-check-commit-messages) (builtins.attrNames apps)')

case "$where" in
*"\"$system\""*)
  nix run ".#std-check-commit-messages" -- "$base" "$head"
  ;;
"[]")
  echo "this flake's locked standard predates the std-check-commit-messages app, so the standard's own checker runs here, without the consumer's args"
  bash "$std/scripts/check-commit-range.sh" "$base" "$head" bash "$std/scripts/check-commit-message.sh"
  ;;
*)
  echo "the messages are checked on $where, where the app is"
  ;;
esac
