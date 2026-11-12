#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
retry-transient - run a command, retrying it only after a failure the classifier names transient-infra.

  retry-transient.sh <log> <budget-seconds> [--reset-tree] -- <command> [args]...

  <log>            receives the final attempt's output, so the report classifies the failure that stood
  <budget-seconds> no retry starts unless its backoff plus the last attempt's duration still fit in it
  --reset-tree     before a retry, restore the checked-out tree and empty $GITHUB_OUTPUT, so the retry
                   starts from what the first attempt saw instead of the rewrite a failed attempt left

  RETRY_BACKOFFS   seconds to wait before each retry (default "60 300 900")

Exit: the final attempt's own exit code, or 2 on a usage error.
USAGE
}

[ "$#" -ge 4 ] || {
  usage >&2
  exit 2
}
log=$1
budget=$2
shift 2
[[ $budget =~ ^[0-9]+$ ]] || {
  echo "retry-transient: the budget '$budget' is not a whole number of seconds" >&2
  exit 2
}
reset=no
if [ "$1" = --reset-tree ]; then
  reset=yes
  shift
fi
[ "$1" = -- ] || {
  usage >&2
  exit 2
}
shift
[ "$#" -gt 0 ] || {
  usage >&2
  exit 2
}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
attempt=$(mktemp)
cls=$(mktemp)
trap 'rm -f "$attempt" "$cls"' EXIT

run() {
  local began=$SECONDS
  "$@" 2>&1 | tee "$attempt"
  rc=${PIPESTATUS[0]}
  took=$((SECONDS - began))
}

transient() {
  : >"$cls"
  GITHUB_OUTPUT="$cls" bash "$here/classify-build-failure.sh" "$attempt"
  grep -qx 'class=transient-infra' "$cls"
}

start=$SECONDS
run "$@"
for backoff in ${RETRY_BACKOFFS:-60 300 900}; do
  [ "$rc" -eq 0 ] && break
  transient || break
  if [ $((SECONDS - start + backoff + took)) -gt "$budget" ]; then
    echo "::warning::not retrying: the wait of ${backoff}s and another ${took}s attempt would pass the ${budget}s budget"
    break
  fi
  echo "::warning::transient fetch failure (exit $rc); retrying in ${backoff}s"
  sleep "$backoff"
  if [ "$reset" = yes ]; then
    if ! { git reset -q --hard HEAD && git clean -qfd; }; then
      echo "::error::could not restore the checked-out tree before the retry"
      break
    fi
    [ -z "${GITHUB_OUTPUT:-}" ] || : >"$GITHUB_OUTPUT"
  fi
  run "$@"
done
cp "$attempt" "$log"
exit "$rc"
