#!/usr/bin/env bash
set -uo pipefail

# Sync canonical repo METADATA (GitHub description + topics) from each repo's
# .github/update.json to GitHub. The file-level companion to sync.sh: sync.sh
# bootstraps the workflow/script files; sync-meta.sh applies the metadata that
# lives only on GitHub and can otherwise silently drift.
#
#   sync-meta.sh            # sync every repo
#   sync-meta.sh <repo>...  # named repos only
#   sync-meta.sh --check    # report drift, change nothing, exit 1 if any
#
# Source of truth: the `description` and `topics` keys in each repo's
# .github/update.json (schema-validated). Owner defaults to Daaboulex.

REPOS_DIR="${PKG_REPOS_DIR:?set PKG_REPOS_DIR to the directory holding the packaging-repo clones}"
OWNER="${GH_OWNER:-Daaboulex}"

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
  uj="$REPOS_DIR/$repo/.github/update.json"
  [ -f "$uj" ] || continue
  desc=$(jq -r '.description // empty' "$uj")
  want_topics=$(jq -r '.topics[]?' "$uj" | sort)
  [ -z "$desc" ] && [ -z "$want_topics" ] && continue

  live_desc=$(gh repo view "$OWNER/$repo" --json description --jq '.description // ""' 2>/dev/null || echo "")
  live_topics=$(gh repo view "$OWNER/$repo" --json repositoryTopics --jq '.repositoryTopics[].name' 2>/dev/null | sort)

  desc_drift=0; topic_drift=0
  [ -n "$desc" ] && [ "$desc" != "$live_desc" ] && desc_drift=1
  [ -n "$want_topics" ] && [ "$want_topics" != "$live_topics" ] && topic_drift=1

  if [ "$CHECK" -eq 1 ]; then
    if [ "$desc_drift" -eq 1 ] || [ "$topic_drift" -eq 1 ]; then
      echo "DRIFT  $repo$([ $desc_drift = 1 ] && echo ' [description]')$([ $topic_drift = 1 ] && echo ' [topics]')"
      drift=1
    fi
    continue
  fi

  if [ "$desc_drift" -eq 1 ]; then
    gh repo edit "$OWNER/$repo" --description "$desc" >/dev/null && echo "synced $repo description"
  fi
  if [ "$topic_drift" -eq 1 ]; then
    args=()
    while IFS= read -r t; do [ -n "$t" ] && args+=(-f "names[]=$t"); done <<<"$want_topics"
    gh api "repos/$OWNER/$repo/topics" -X PUT -H "Accept: application/vnd.github+json" "${args[@]}" >/dev/null \
      && echo "synced $repo topics"
  fi
done

if [ "$CHECK" -eq 1 ]; then
  [ "$drift" -eq 0 ] && {
    echo "all repo metadata in sync with update.json"
    exit 0
  }
  echo "metadata drift detected — run sync-meta.sh to fix"
  exit 1
fi
echo
echo "Done."
