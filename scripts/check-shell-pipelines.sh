#!/usr/bin/env bash
# check-shell-pipelines — refuse a pipeline whose last stage short-circuits and
# whose exit status is then read. Canonical script, run by the pre-commit hook
# wired in flakeModules.base (repos do not carry their own copy).
#
# `grep -q` exits on its first match. That closes the pipe, the producer takes
# SIGPIPE, and under `set -o pipefail` the whole pipeline reports failure. A
# successful match therefore reads as a failed test, so the branch taken is the
# wrong one. writeShellApplication always sets pipefail, so every shell string
# in a Nix file is in scope too.
#
# The fix is to capture first and match against a here-string:
#     out=$(producer 2>/dev/null || true)
#     if grep -q PATTERN <<<"$out"; then
#
# A deliberate exception is marked on the same line with: pipefail-safe
set -euo pipefail

errors=0

scan() {
  local f=$1
  # shellcheck disable=SC2016
  while IFS=: read -r line text; do
    [ -n "${line:-}" ] || continue
    case "$text" in
    *pipefail-safe*) continue ;;
    *"|| true"*) continue ;;
    esac
    echo "$f:$line: pipeline ends in 'grep -q', whose early exit SIGPIPEs the producer under pipefail"
    echo "    $(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
    errors=$((errors + 1))
  done < <(grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "$f" 2>/dev/null || true)
}

files=$(git ls-files '*.sh' '*.nix' 2>/dev/null || true)
for f in $files; do
  [ -f "$f" ] || continue
  case "$f" in
  scripts/check-shell-pipelines.sh) continue ;;
  esac
  scan "$f"
done

if [ "$errors" -ne 0 ]; then
  echo ""
  echo "Capture the producer first, then match a here-string, so the producer's exit"
  echo "status is not decided by the consumer closing the pipe early:"
  echo "    out=\$(producer 2>/dev/null || true)"
  echo "    if grep -q PATTERN <<<\"\$out\"; then"
  echo "Mark a deliberate exception on the same line with: pipefail-safe"
  exit 1
fi
