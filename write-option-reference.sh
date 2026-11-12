#!/usr/bin/env bash
set -euo pipefail

problem=$(mktemp)
trap 'rm -f "$problem"' EXIT

# shellcheck disable=SC2016
if ! carrier=$(nix eval --raw ".#checks" "$@" --apply \
  'checks: let carriers = builtins.filter (system: checks.${system} ? std-option-reference) (builtins.attrNames checks); in if carriers == [ ] then "" else builtins.head carriers' 2>"$problem"); then
  if grep -q "does not provide attribute" "$problem"; then
    carrier=""
  else
    cat "$problem" >&2
    exit 1
  fi
fi

if [ -z "$carrier" ]; then
  echo "write-option-reference: the flake names no module under std.option-reference, nothing to write"
  exit 0
fi

mkdir -p docs
nix eval --raw ".#checks.$carrier.std-option-reference.rendered" "$@" >docs/OPTIONS.md.new
mv docs/OPTIONS.md.new docs/OPTIONS.md
echo "write-option-reference: docs/OPTIONS.md written from the modules as $carrier evaluates them"
