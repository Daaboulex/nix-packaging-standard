#!/usr/bin/env bash
set -uo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: check-fast-build-callers.sh <standard-root>" >&2
  exit 2
}
root=$1

found=$(cd "$root" && grep -rlE '#nix-fast-build|nix-fast-build[[:space:]]+-' \
  --include='*.sh' --include='*.yml' --include='*.yaml' --include='*.nix' \
  --exclude-dir=tests --exclude-dir=.git --exclude-dir=.devshell --exclude-dir=.direnv .)
rc=$?
[ "$rc" -le 1 ] || {
  echo "check-fast-build-callers: grep failed with exit $rc reading $root" >&2
  exit 2
}
callers=$(while IFS= read -r file; do echo "${file#./}"; done <<<"$found" | sort)

stray=$(grep -vxE 'build-checks\.sh|scripts/check-fast-build-callers\.sh' <<<"$callers" | sed '/^$/d')
if [ -n "$stray" ]; then
  echo "nix-fast-build runs outside build-checks.sh in:"
  while IFS= read -r file; do echo "  $file"; done <<<"$stray"
  echo "build every check through build-checks.sh, which sizes the evaluation workers to the machine's memory; nix-fast-build's own default starts one 4 GiB worker per core and exhausts a runner's memory"
  exit 1
fi

if ! grep -qx 'build-checks.sh' <<<"$callers"; then
  echo "build-checks.sh no longer runs nix-fast-build"
  exit 1
fi

for flag in "-j \"\$cores\"" "--eval-workers \"\$workers\"" "--eval-max-memory-size \"\$EVAL_MAX_MEMORY_MIB\""; do
  if ! grep -qF -- "$flag" "$root/build-checks.sh"; then
    echo "build-checks.sh does not pass $flag to nix-fast-build, so nix-fast-build falls back to a default that ignores the machine"
    exit 1
  fi
done
