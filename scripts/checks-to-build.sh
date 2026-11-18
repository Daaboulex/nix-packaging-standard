#!/usr/bin/env bash
set -euo pipefail

base=$1
system=$2
automation='41898282+github-actions[bot]@users.noreply.github.com'
drv_paths='builtins.mapAttrs (_: check: check.drvPath)'

every() {
  echo "every check is built: $1" >&2
  echo ALL
  exit 0
}

[ "${GITHUB_EVENT_NAME:-}" = push ] || every "this run is not a push"
if [ -z "$base" ] || ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  every "the commit before this push is not known here"
fi
if [ "$(git log -1 --format=%ae "$base")" != "$automation" ]; then
  green=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$base&status=success&per_page=100" \
    --jq '[.workflow_runs[] | select(.path | endswith("/ci.yml"))] | length') ||
    every "the forge did not say whether the commit before this push was green"
  [ "$green" -gt 0 ] || every "the commit before this push has no green CI run"
fi
before=$(nix eval --json "git+file://$PWD?rev=$base#checks.$system" \
  --option allow-import-from-derivation false --apply "$drv_paths") ||
  every "the commit before this push does not evaluate"
now=$(nix eval --json ".#checks.$system" --option allow-import-from-derivation false --apply "$drv_paths")

jq -rn --argjson before "$before" --argjson now "$now" '
  ($before | [.[]]) as $built
  | [$now | to_entries[] | select(.value as $drv | $built | index($drv) | not) | .key] | sort | .[]'
