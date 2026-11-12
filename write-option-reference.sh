#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2016
carrier=$(nix eval --impure --raw --expr \
  'let checks = (builtins.getFlake (toString ./.)).checks or { }; carriers = builtins.filter (system: checks.${system} ? std-option-reference) (builtins.attrNames checks); in if carriers == [ ] then "" else builtins.head carriers')

if [ -z "$carrier" ]; then
  echo "write-option-reference: the flake names no module under std.option-reference, nothing to write"
  exit 0
fi

mkdir -p docs
nix eval --raw ".#checks.$carrier.std-option-reference.rendered" >docs/OPTIONS.md.new
mv docs/OPTIONS.md.new docs/OPTIONS.md
echo "write-option-reference: docs/OPTIONS.md written from the modules as $carrier evaluates them"
