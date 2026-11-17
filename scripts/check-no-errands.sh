#!/usr/bin/env bash
set -euo pipefail

errand='(^|[^[:alnum:]])(will ask|is going to ask|is asking|will (check|confirm|clarify) with|confirms? with|(is|are) asked (to|whether|if)|wait(s|ing)? (for|on) [^.]{0,60}(answer|reply|approval|decision|go-ahead)|is (for|up to) [^.]{1,40} to (decide|confirm|approve|answer|settle))([^[:alnum:]]|$)'
bad=0
for file in "$@"; do
  prose=$(awk '
    /^[[:space:]]*(```|~~~)/ { fenced = !fenced; next }
    !fenced { gsub(/`[^`]*`/, ""); print FILENAME ":" FNR ": " $0 }
  ' "$file")
  found=$(grep -iE "$errand" <<<"$prose" || true)
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    bad=1
  fi
done
if [ "$bad" = 1 ]; then
  echo "A line says who asks, waits for or confirms something with someone. Write the open point as the question that is open."
fi
exit "$bad"
