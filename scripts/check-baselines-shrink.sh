#!/usr/bin/env bash
set -euo pipefail

base=$1
head=$2
dir=.std/baseline

if ! git rev-parse --verify --quiet "$head^{commit}" >/dev/null; then
  echo "$head is not a commit here"
  exit 1
fi
if [ -z "$base" ] || ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  if ! git rev-parse --verify --quiet "$head^1^{commit}" >/dev/null; then
    echo "$head has no parent, so no baseline existed before it"
    exit 0
  fi
  echo "'$base' is not a commit here; comparing $head with its first parent"
  base=$(git rev-parse "$head^1")
fi

whole_number() {
  case "$1" in
  "" | *[!0-9]*) return 1 ;;
  esac
}

bad=0
refuse() {
  echo "FAIL $1"
  bad=1
}

while IFS= read -r file; do
  if ! git cat-file -e "$base:$file" 2>/dev/null; then
    echo "new  $file"
    continue
  fi
  case "$file" in
  *.floor)
    was=$(git show "$base:$file")
    now=$(git show "$head:$file")
    if ! whole_number "$was" || ! whole_number "$now"; then
      refuse "$file must hold one whole number: it held '$was' and holds '$now'"
    elif [ "$now" -lt "$was" ]; then
      refuse "$file drops the floor from $was to $now; a floor only rises"
    else
      echo "ok   $file ($was to $now)"
    fi
    ;;
  *.json)
    was=$(git show "$base:$file" | wc -l)
    now=$(git show "$head:$file" | wc -l)
    if [ "$now" -gt "$was" ]; then
      refuse "$file grew from $was to $now lines; a baseline only shrinks"
    else
      echo "ok   $file ($was to $now lines)"
    fi
    ;;
  *)
    added=$(git diff --numstat "$base" "$head" -- "$file" | cut -f1)
    if [ "${added:-0}" != 0 ]; then
      refuse "$file gained $added line(s); a baseline only shrinks, so silence a new finding where it is, with the tool's own marker"
    else
      echo "ok   $file"
    fi
    ;;
  esac
done < <(git ls-tree -r --name-only "$head" -- "$dir")
exit "$bad"
