#!/usr/bin/env bash
set -euo pipefail

# Sync the canonical standard files into the packaging-repo clones.
#
#   sync.sh            # sync every repo
#   sync.sh <repo>...  # sync named repos only
#   sync.sh --check    # report drift, change nothing, exit 1 if any
#
# Project-agnostic: every path is derived, never hardcoded. The
# packaging-repo directory is taken from PKG_REPOS_DIR (e.g. the consuming
# nix flake's `repos/` directory, or a /tmp clone tree). Each repo commits
# + pushes its own changes; CI runs --check so a per-repo copy can never
# silently drift from the canonical.

STD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="${PKG_REPOS_DIR:?set PKG_REPOS_DIR to the directory holding the packaging-repo clones}"

# canonical file in the standard repo  ->  destination path inside each repo.
# sync.sh BOOTSTRAPS these into a repo; the std-conformance flake check
# (flakeModules.base) then enforces byte-identity — no curl-based drift-check.
declare -A FILES=(
  ["update.sh"]="scripts/update.sh"
  ["heal-overlays.sh"]="scripts/heal-overlays.sh"
  ["update.yml"]=".github/workflows/update.yml"
  ["maintenance.yml"]=".github/workflows/maintenance.yml"
  ["ci.yml"]=".github/workflows/ci.yml"
)

CHECK=0
declare -a targets=()
for arg in "$@"; do
  case "$arg" in
  --check) CHECK=1 ;;
  *) targets+=("$arg") ;;
  esac
done
if [ ${#targets[@]} -eq 0 ]; then
  while IFS= read -r d; do targets+=("$(basename "$d")"); done \
    < <(find "$REPOS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
fi

drift=0
for repo in "${targets[@]}"; do
  dir="$REPOS_DIR/$repo"
  [ -e "$dir/.git" ] || {
    echo "skip   $repo (not a git clone)"
    continue
  }
  [ -f "$dir/.github/update.json" ] || {
    echo "skip   $repo (no update.json)"
    continue
  }
  # custom-type repos keep their own bespoke scripts/update.sh — sync only
  # the generic workflow into them, never the canonical update.sh.
  rtype=$(jq -r '.upstream.type // "none"' "$dir/.github/update.json" 2>/dev/null || echo none)
  for src in "${!FILES[@]}"; do
    if [ "$src" = "update.sh" ] && [ "$rtype" = "custom" ]; then
      echo "keep   $repo/scripts/update.sh (custom updater)"
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
done

if [ "$CHECK" -eq 1 ]; then
  [ "$drift" -eq 0 ] && {
    echo "all repos in sync with the canonical standard"
    exit 0
  }
  echo "drift detected — run sync.sh to fix"
  exit 1
fi
echo
echo "Done. Review each repo's diff, then commit + push within that repo."
