#!/usr/bin/env bash
set -euo pipefail

free_names_allowed='with { }; '
nix_parse() { nix-instantiate --store dummy:// --parse "$@" >/dev/null; }
nix_parse --expr "$free_names_allowed{ }"
work=$(mktemp -d)
find . -type f -name '*.md' -printf '%P\0' >"$work/documents"
mapfile -d '' -t documents <"$work/documents"

parses() {
  local candidate=$work/$1/$document
  mkdir -p "$(dirname "$candidate")"
  {
    printf '%s%s' "$free_names_allowed" "$2"
    cat "$work/blocks/$document/$line"
    printf '%s\n' "$3"
  } >"$candidate"
  nix_parse "$candidate" 2>"$candidate.error"
}

bad=0
for document in "${documents[@]}"; do
  mkdir -p "$work/blocks/$document"
  opened=$(gawk -v blocks="$work/blocks/$document" '
    !open && /^ *```nix([[:space:]]|$)/ { open = NR; body = ""; for (i = 0; i < NR; i++) body = body "\n"; next }
    open && /^ *```[[:space:]]*$/ { printf "%s", body > (blocks "/" open); print open; open = 0; next }
    open { body = body $0 "\n" }
  ' "$document")
  for line in $opened; do
    if ! parses expression '' '' && ! parses attribute-set-body '{' '}'; then
      echo "$document:$line: this nix block parses neither as an expression nor as the body of an attribute set"
      echo "as an expression:"
      cat "$work/expression/$document.error"
      echo "as the body of an attribute set:"
      cat "$work/attribute-set-body/$document.error"
      bad=1
    fi
  done
done
exit "$bad"
