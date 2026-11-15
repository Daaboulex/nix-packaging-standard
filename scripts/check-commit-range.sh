#!/usr/bin/env bash
set -euo pipefail

base=$1
head=$2
shift 2

held=()
holder=""
if [ -n "${PRE_COMMIT_REMOTE_NAME:-}" ]; then
  held=("--remotes=$PRE_COMMIT_REMOTE_NAME")
  holder=$PRE_COMMIT_REMOTE_NAME
elif [ -n "${STD_JUDGED_REF:-}" ] && git rev-parse --verify --quiet "$STD_JUDGED_REF^{commit}" >/dev/null; then
  held=("$STD_JUDGED_REF")
  holder=$STD_JUDGED_REF
fi
commits=()
if [ -n "$base" ] && git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  mapfile -t commits < <(git rev-list --reverse "$base..$head")
  if [ -n "$holder" ] && [ "${#commits[@]}" != 0 ]; then
    mapfile -t commits < <(git rev-list --reverse "$base..$head" --not "${held[@]}")
    if [ "${#commits[@]}" = 0 ]; then
      echo "every commit after '$base' up to $head is already on $holder; nothing new to check"
      exit 0
    fi
  fi
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
noreply='^([^@[:space:]]+@users\.noreply\.github\.com|noreply@github\.com)$'
bad=0
for commit in "${commits[@]}"; do
  git log -1 --format=%B "$commit" >"$work/message"
  if "$@" "$work/message"; then
    echo "ok   $(git log -1 --format='%h %s' "$commit")"
  else
    echo "FAIL $(git log -1 --format='%h %s' "$commit")"
    bad=1
  fi
  while IFS= read -r address; do
    if ! [[ $address =~ $noreply ]]; then
      echo "FAIL $(git log -1 --format='%h' "$commit") carries an author or committer address that is not a GitHub noreply address; set user.email to the noreply form and recommit"
      bad=1
      break
    fi
  done < <(git log -1 --format='%ae%n%ce' "$commit")
done
exit "$bad"
