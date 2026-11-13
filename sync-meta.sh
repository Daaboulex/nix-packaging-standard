#!/usr/bin/env bash
set -uo pipefail

# Sync canonical repo METADATA (GitHub description + topics) from each repo's
# .github/update.json to GitHub, and the labels the issue forms and
# CONTRIBUTING.md name. The file-level companion to sync.sh: sync.sh
# bootstraps the workflow/script files; sync-meta.sh applies the metadata that
# lives only on GitHub and can otherwise silently drift.
#
#   sync-meta.sh            # sync every repo
#   sync-meta.sh <repo>...  # named repos only
#   sync-meta.sh --check    # report drift, change nothing, exit 1 if any
#
# Source of truth: the `description` and `topics` keys in each repo's
# .github/update.json (schema-validated). The GitHub repository is read from
# each clone's origin.

REPOS_DIR="${PKG_REPOS_DIR:?set PKG_REPOS_DIR to the directory holding the packaging-repo clones}"

gh_slug() {
  local u
  u=$(git -C "$REPOS_DIR/$1" remote get-url origin 2>/dev/null) || return 1
  u=${u%.git}
  u=${u#*://}
  u=${u#*@}
  u=${u#*[:/]}
  case "$u" in
  */*) printf '%s\n' "$u" ;;
  *) return 1 ;;
  esac
}

LABELS=(
  "type/bug|d73a4a|Something does not work as described"
  "type/feature|0e8a16|Something new or different"
  "type/task|1d76db|Work to do, with when it counts as done"
  "later|c5def5|An idea nobody owes"
  "waiting|fbca04|Blocked on a person, a delivery or a decision"
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
  uj="$REPOS_DIR/$repo/.github/update.json"
  [ -f "$uj" ] || continue
  desc=$(jq -r '.description // empty' "$uj")
  want_topics=$(jq -r '.topics[]?' "$uj" | sort)

  # An unpushed WIP has no remote to carry metadata, and fleet-audit skips such
  # a repo's remote half too -- reporting it as drift would be a red nothing can
  # clear.
  if ! git -C "$REPOS_DIR/$repo" remote get-url origin >/dev/null 2>&1; then
    echo "skip   $repo (no git remote)"
    continue
  fi

  # One query, and a FAILED query is an error, never silently-empty live state:
  # swallowing a transient gh fault used to invent drift out of a remote blip.
  if ! live=$(gh repo view "$(gh_slug "$repo")" --json description,repositoryTopics 2>/tmp/sync-meta-gh.err); then
    echo "ERROR  $repo: could not query GitHub metadata: $(tail -1 /tmp/sync-meta-gh.err)"
    drift=1
    continue
  fi
  live_desc=$(jq -r '.description // ""' <<<"$live")
  live_topics=$(jq -r '(.repositoryTopics // [])[].name' <<<"$live" | sort)

  if ! live_labels=$(gh label list -R "$(gh_slug "$repo")" --limit 200 --json name --jq '.[].name' 2>/tmp/sync-meta-gh.err); then
    echo "ERROR  $repo: could not query GitHub labels: $(tail -1 /tmp/sync-meta-gh.err)"
    drift=1
    continue
  fi
  missing_labels=()
  for entry in "${LABELS[@]}"; do
    grep -qxF "${entry%%|*}" <<<"$live_labels" || missing_labels+=("$entry")
  done
  label_drift=0
  [ "${#missing_labels[@]}" -gt 0 ] && label_drift=1

  desc_drift=0
  topic_drift=0
  [ -n "$desc" ] && [ "$desc" != "$live_desc" ] && desc_drift=1
  [ -n "$want_topics" ] && [ "$want_topics" != "$live_topics" ] && topic_drift=1

  if [ "$CHECK" -eq 1 ]; then
    if [ "$desc_drift" -eq 1 ] || [ "$topic_drift" -eq 1 ] || [ "$label_drift" -eq 1 ]; then
      echo "DRIFT  $repo$([ $desc_drift = 1 ] && echo ' [description]')$([ $topic_drift = 1 ] && echo ' [topics]')$([ $label_drift = 1 ] && echo ' [labels]')"
      drift=1
    fi
    continue
  fi

  if [ "$desc_drift" -eq 1 ]; then
    gh repo edit "$(gh_slug "$repo")" --description "$desc" >/dev/null && echo "synced $repo description"
  fi
  if [ "$topic_drift" -eq 1 ]; then
    args=()
    while IFS= read -r t; do [ -n "$t" ] && args+=(-f "names[]=$t"); done <<<"$want_topics"
    gh api "repos/$(gh_slug "$repo")/topics" -X PUT -H "Accept: application/vnd.github+json" "${args[@]}" >/dev/null &&
      echo "synced $repo topics"
  fi
  for entry in "${missing_labels[@]}"; do
    name=${entry%%|*}
    rest=${entry#*|}
    gh label create "$name" -R "$(gh_slug "$repo")" --color "${rest%%|*}" --description "${rest#*|}" >/dev/null &&
      echo "synced $repo label $name"
  done
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
