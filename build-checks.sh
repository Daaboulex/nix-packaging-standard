#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
build-checks - build every check the flake in the current directory declares for one system, with
nix-fast-build sized to the machine it runs on. Every workflow and script builds through it.

  build-checks.sh <system>

  evaluation   one worker per EVAL_WORKER_MIB of available memory, at least one and at most one per
               core; each worker restarts once it passes EVAL_MAX_MEMORY_MIB
  build        one build task per core; how many builds really run at once stays nix's own max-jobs

  MEMINFO      the meminfo file to read the available memory from (default /proc/meminfo)

Exit: nix-fast-build's own exit code, or 2 on a usage error.
USAGE
}

[ "$#" -eq 1 ] || {
  usage >&2
  exit 2
}
system=$1

EVAL_MAX_MEMORY_MIB=4096
# why: a worker grows to its restart size, and the builds that run beside the evaluation need room too
EVAL_WORKER_MIB=$((EVAL_MAX_MEMORY_MIB * 3 / 2))

cores=$(nproc)
available_kib=$(awk '/^MemAvailable:/ { print $2 }' "${MEMINFO:-/proc/meminfo}")
[[ $available_kib =~ ^[0-9]+$ ]] || {
  echo "build-checks: no MemAvailable in ${MEMINFO:-/proc/meminfo}" >&2
  exit 2
}
workers=$((available_kib / 1024 / EVAL_WORKER_MIB))
[ "$workers" -ge 1 ] || workers=1
[ "$workers" -le "$cores" ] || workers=$cores

echo "build-checks: $workers evaluation worker(s) for $((available_kib / 1024)) MiB available, $cores build task(s) for $cores core(s)"
exec nix run --inputs-from . nixpkgs#nix-fast-build -- \
  -j "$cores" --eval-workers "$workers" --eval-max-memory-size "$EVAL_MAX_MEMORY_MIB" \
  --skip-cached --no-nom --flake ".#checks.$system"
