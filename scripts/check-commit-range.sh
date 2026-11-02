#!/usr/bin/env bash
set -euo pipefail

base=$1
head=$2
shift 2

commits=()
if [ -n "$base" ] && git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  mapfile -t commits < <(git rev-list --reverse "$base..$head")
fi
if [ "${#commits[@]}" = 0 ]; then
  echo "no commit after '$base' up to $head is known here; checking $head alone"
  mapfile -t commits < <(git rev-list -1 "$head")
fi
if [ "${#commits[@]}" = 0 ]; then
  echo "$head is not a commit here"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bad=0
for commit in "${commits[@]}"; do
  git log -1 --format=%B "$commit" >"$work/message"
  if "$@" "$work/message"; then
    echo "ok   $(git log -1 --format='%h %s' "$commit")"
  else
    echo "FAIL $(git log -1 --format='%h %s' "$commit")"
    bad=1
  fi
done
exit "$bad"
