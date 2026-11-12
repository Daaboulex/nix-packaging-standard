#!/usr/bin/env bash
set -euo pipefail

limit=200
bad=0
for file in "$@"; do
  lines=$(wc -l <"$file")
  if [ "$lines" -gt "$limit" ]; then
    echo "$file is $lines lines; a file written for an assistant stays at $limit or under. Keep what the repository cannot show, move the rest into the README, and turn a rule that must hold into a check."
    bad=1
  fi
done
exit "$bad"
