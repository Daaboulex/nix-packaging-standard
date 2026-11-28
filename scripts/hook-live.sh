#!/usr/bin/env bash
set -uo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: hook-live.sh <clone>" >&2
  exit 2
}
hook="$1/.git/hooks/pre-commit"
[ -f "$hook" ] || {
  echo "$hook does not exist, so a commit runs none of the repo's checks"
  exit 1
}
text=$(<"$hook") || {
  echo "$hook cannot be read"
  exit 1
}
programs=$(grep -oE '/nix/store/[^/[:space:]"]+/bin/[^/[:space:]"]+' <<<"$text") || {
  echo "$hook runs no program from the store, so it is not a hook the dev shell installed"
  exit 1
}
while IFS= read -r program; do
  [ -x "$program" ] || {
    echo "$hook runs $program, which is no longer in the store"
    exit 1
  }
done <<<"$programs"
config=$(grep -oE -- '--config="?[^"[:space:]]+' <<<"$text") || {
  echo "$hook names no --config, so the config it runs cannot be checked"
  exit 1
}
config=${config#--config=}
config="$1/${config#\"}"
[ -e "$config" ] || {
  echo "$hook runs the config $config, which no longer resolves"
  exit 1
}
