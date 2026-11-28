#!/usr/bin/env bash
set -euo pipefail

usage="usage: name-standard-gap.sh <flake.lock> <commit of the standard this workflow runs at>; prints a notice when the lock pins another commit of the standard"
lock="${1:?$usage}"
running="${2:?$usage}"

pinned=$(jq -r '.nodes[.root].inputs.std as $std | if ($std | type) == "string" then .nodes[$std].locked.rev // "no commit" else "" end' "$lock")
if [ -n "$pinned" ] && [ "$pinned" != "$running" ]; then
  echo "::notice title=The workflow and the lock are at different commits of the standard::the workflow and its scripts run at $running; flake.lock pins $pinned for the checks, hooks and lib until a lock refresh passes"
fi
