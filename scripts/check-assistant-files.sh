#!/usr/bin/env bash
set -euo pipefail

limit=200
email='[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
noreply='@users\.noreply\.github\.com$'
bad=0
for file in "$@"; do
  lines=$(wc -l <"$file")
  if [ "$lines" -gt "$limit" ]; then
    echo "$file is $lines lines; a file written for an assistant stays at $limit or under. Keep what the repository cannot show, move the rest into the README, and turn a rule that must hold into a check."
    bad=1
  fi
  if grep -q '/home/' "$file"; then
    echo "$file names a path under /home; a rules file holds nothing of one person's machine. Say the path relative to the repository."
    bad=1
  fi
  while IFS= read -r address; do
    if [[ $address =~ $noreply ]]; then
      continue
    fi
    echo "$file holds an email address: $address; a rules file names no person. Point at the issue forms instead."
    bad=1
  done < <(grep -oE "$email" "$file" || true)
done
exit "$bad"
