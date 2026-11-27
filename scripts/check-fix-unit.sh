#!/usr/bin/env bash
set -uo pipefail

usage="usage: check-fix-unit.sh <fix> [<file the fix owns>...], given the repository's tracked files NUL-separated on stdin"
[ $# -gt 0 ] || {
  echo "$usage" >&2
  exit 2
}
fix=$1
mapfile -d '' -t tracked

bad=0
for u in "$@"; do
  for f in "${tracked[@]}"; do [ "$f" = "$u" ] && continue 2; done
  echo "$fix: $u is not a tracked file; a fix and every file its meta.owns names must be tracked, so the heal removes them together"
  bad=1
done
[ "$bad" = 0 ] || exit 1

outside=()
patterns=()
for f in "${tracked[@]}"; do
  for u in "$@"; do [ "$f" = "$u" ] && continue 2; done
  outside+=("$f")
done
for u in "$@"; do patterns+=(-e "$u"); done
[ ${#outside[@]} -gt 0 ] || exit 0

rc=0
hits=$(grep -aHnoF "${patterns[@]}" -- "${outside[@]}") || rc=$?
if [ "$rc" -gt 1 ]; then
  echo "$fix: grep could not read the tracked files (exit $rc)"
  exit 2
fi
seen=
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  [ "$hit" != "$seen" ] || continue
  seen=$hit
  echo "${hit%:*}: names ${hit##*:}, a file of the temporary fix $fix; only the fix and the files its meta.owns names may name one, so the heal leaves no reference behind: drop the reference, or add ${hit%%:*} to meta.owns"
  bad=1
done <<<"$hits"
exit "$bad"
