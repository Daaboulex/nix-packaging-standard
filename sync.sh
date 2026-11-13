#!/usr/bin/env bash
set -euo pipefail

usage="usage: PKG_REPOS_DIR=<dir> sync.sh [--check] [repo...]"
STD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="${PKG_REPOS_DIR:?set PKG_REPOS_DIR to the directory holding the packaging-repo clones; $usage}"

declare -A FILES=()
declare -a RETIRED=()
declare -a RETIRED_IGNORES=(AGENTS.md)
while IFS=$'\t' read -r dst src; do
  if [ -z "$src" ]; then
    RETIRED+=("$dst")
  else
    FILES["$src"]="$dst"
  fi
done < <(jq -r 'to_entries[] | [.key, (.value // "")] | @tsv' "$STD/synced-files.json")
[ "${#FILES[@]}" -gt 0 ] || {
  echo "sync.sh: synced-files.json is empty or unreadable" >&2
  exit 2
}

CHECK=0
declare -a targets=()
for arg in "$@"; do
  case "$arg" in
  --check) CHECK=1 ;;
  -*)
    echo "sync.sh: unknown option '$arg'; $usage" >&2
    exit 2
    ;;
  *) targets+=("$arg") ;;
  esac
done
if [ ${#targets[@]} -eq 0 ]; then
  while IFS= read -r d; do targets+=("$(basename "$d")"); done \
    < <(find "$REPOS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
fi

drift=0
unmerged=0
for repo in "${targets[@]}"; do
  dir="$REPOS_DIR/$repo"
  if [ "$dir" -ef "$STD" ]; then
    echo "skip   $repo (the standard itself: it is the source, never a target)"
    continue
  fi
  [ -e "$dir/.git" ] || {
    echo "skip   $repo (not a git clone)"
    continue
  }
  [ -f "$dir/.github/update.json" ] || {
    echo "skip   $repo (no update.json)"
    continue
  }
  rtype=$(jq -r '.upstream.type // ""' "$dir/.github/update.json")
  for src in "${!FILES[@]}"; do
    if [ "$src" = "callers/update.yml" ] && [ "$rtype" = none ]; then
      continue
    fi
    dst="$dir/${FILES[$src]}"
    if [ -f "$dst" ] && cmp -s "$STD/$src" "$dst"; then
      continue
    fi
    drift=1
    if [ "$CHECK" -eq 1 ]; then
      echo "DRIFT  $repo/${FILES[$src]}"
    else
      mkdir -p "$(dirname "$dst")"
      cp "$STD/$src" "$dst"
      echo "synced $repo/${FILES[$src]}"
    fi
  done

  for name in AGENTS.md CONTRIBUTING.md; do
    head="$STD/heads/$name"
    dst="$dir/$name"
    if [ -f "$dst" ] && cmp -s -n "$(wc -c <"$head")" "$head" "$dst"; then
      continue
    fi
    drift=1
    if [ "$CHECK" -eq 1 ]; then
      echo "DRIFT  $repo/$name"
    elif [ ! -f "$dst" ]; then
      cp "$head" "$dst"
      echo "synced $repo/$name (new: this repo's own rules go under This project)"
    elif grep -qx '## This project' "$dst"; then
      {
        cat "$head"
        sed '1,/^## This project$/d' "$dst"
      } >"$dst.new"
      mv "$dst.new" "$dst"
      echo "synced $repo/$name (head rewritten, This project kept)"
    else
      unmerged=1
      echo "MERGE  $repo/$name has no This project heading: move its content under one by hand, then sync again"
    fi
  done

  retire=("${RETIRED[@]}")
  if [ "$rtype" = none ]; then
    retire+=(".github/workflows/update.yml")
  fi
  for dst in "${retire[@]}"; do
    if [ "$dst" = scripts/update.sh ] && [ "$rtype" = custom ]; then
      echo "keep   $repo/scripts/update.sh (custom updater)"
      continue
    fi
    [ -e "$dir/$dst" ] || continue
    drift=1
    if [ "$CHECK" -eq 1 ]; then
      echo "DRIFT  $repo/$dst is retired and still present"
    else
      rm "$dir/$dst"
      echo "retired $repo/$dst"
    fi
  done

  gi="$dir/.gitignore"
  [ -f "$gi" ] || : >"$gi"
  for line in "${RETIRED_IGNORES[@]}"; do
    grep -qxF "$line" "$gi" || continue
    drift=1
    if [ "$CHECK" -eq 1 ]; then
      echo "DRIFT  $repo/.gitignore still ignores: $line"
    else
      grep -vxF "$line" "$gi" >"$gi.new" || true
      mv "$gi.new" "$gi"
      echo "healed $repo/.gitignore -= $line"
    fi
  done
  while IFS= read -r line; do
    case "$line" in "" | "#"*) continue ;; esac
    grep -qxF "$line" "$gi" && continue
    drift=1
    if [ "$CHECK" -eq 1 ]; then
      echo "DRIFT  $repo/.gitignore misses baseline: $line"
    else
      printf '%s\n' "$line" >>"$gi"
      echo "healed $repo/.gitignore += $line"
    fi
  done <"$STD/.gitignore"
done

if [ "$CHECK" -eq 1 ]; then
  if [ "$drift" -eq 0 ]; then
    echo "all repos in sync with the canonical standard"
    exit 0
  fi
  echo "drift detected: run sync.sh to fix"
  exit 1
fi
if [ "$unmerged" -eq 1 ]; then
  echo
  echo "a rules file could not be merged: see the MERGE lines above"
  exit 1
fi
echo
echo "Done. Review each repo's diff, then commit and push within that repo."
