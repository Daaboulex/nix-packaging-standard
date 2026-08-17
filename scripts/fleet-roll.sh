#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat <<'USAGE'
fleet-roll - adopt a new nix-packaging-standard tag across every consumer repo.

  PKG_REPOS_DIR=/path/to/repos ./scripts/fleet-roll.sh <tag> [options] [repo...]

  <tag>          the standard tag to adopt, e.g. v2.27.0. Must exist locally.
  --execute      commit and push. WITHOUT IT THIS IS A DRY RUN: each repo is
                 bumped, synced and verified, then restored to its clean state.
  --notes <file> the commit body, required by --execute. What the tag changes
                 is the author's to state; the script will not invent it.
  --skip-build   skip the local canonical build. Refused with --execute, since
                 pushing unverified is the thing this exists to prevent.
  --sync         fast-forward a clone that is clean and strictly behind its
                 remote. A clone that is ahead, diverged or dirty is still a
                 failure; only a provably lossless fast-forward is taken.
  repo...        restrict to these repos (default: every consumer).

Scope: every directory under PKG_REPOS_DIR holding a .github/update.json.
A repo already pinned to <tag> is reported and left alone.

Exit: 0 = every targeted repo rolled or dry-ran clean; 1 = at least one repo
failed; 2 = usage or environment error. Fails closed: a dirty repo, a repo out
of sync with its remote, a missing tag, or a failing build is a failure and is
never rolled past.
USAGE
}

STD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTE=0
SKIP_BUILD=0
SYNC=0
NOTES=""
TAG=""
declare -a TARGETS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --execute) EXECUTE=1 ;;
  --skip-build) SKIP_BUILD=1 ;;
  --sync) SYNC=1 ;;
  --notes)
    shift
    NOTES="${1:-}"
    ;;
  -*)
    echo "fleet-roll: unknown option '$1'" >&2
    exit 2
    ;;
  *)
    if [ -z "$TAG" ]; then TAG="$1"; else TARGETS+=("$1"); fi
    ;;
  esac
  shift
done

[ -n "$TAG" ] || {
  usage >&2
  exit 2
}
REPOS_DIR="${PKG_REPOS_DIR:?set PKG_REPOS_DIR to the directory holding the packaging-repo clones}"
[ -d "$REPOS_DIR" ] || {
  echo "fleet-roll: PKG_REPOS_DIR '$REPOS_DIR' is not a directory" >&2
  exit 2
}

for tool in git nix jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "fleet-roll: required tool '$tool' not found" >&2
    exit 2
  }
done

if [ "$EXECUTE" -eq 1 ] && [ "$SKIP_BUILD" -eq 1 ]; then
  echo "fleet-roll: --execute with --skip-build is refused; a push must be verified" >&2
  exit 2
fi
if [ "$EXECUTE" -eq 1 ]; then
  [ -n "$NOTES" ] && [ -f "$NOTES" ] || {
    echo "fleet-roll: --execute requires --notes <file> holding the commit body" >&2
    exit 2
  }
fi
git -C "$STD" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "fleet-roll: tag '$TAG' does not exist in $STD" >&2
  exit 2
}

rolled=0
skipped=0
retired=0
failed=0
declare -a FAILED_REPOS=()

TRANSIENT='crates\.io|error: cannot download|unable to download|http error 5[0-9][0-9]|status code: (403|429|5[0-9][0-9])|curl: \(|couldn.t resolve host|connection reset by peer|temporary failure in name resolution|operation timed out'
LOGDIR=$(mktemp -d -t fleet-roll-XXXXXX)

note() { printf '  %s\n' "$1"; }
fail_repo() {
  printf 'FAIL  %s: %s\n' "$1" "$2"
  failed=$((failed + 1))
  FAILED_REPOS+=("$1")
}

restore() {
  local dir="$1"
  git -C "$dir" checkout -- . >/dev/null 2>&1
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$dir/$f"
  done < <(git -C "$dir" ls-files --others --exclude-standard)
}

if [ "${#TARGETS[@]}" -eq 0 ]; then
  while IFS= read -r d; do TARGETS+=("$(basename "$d")"); done \
    < <(find "$REPOS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
fi

if [ "$EXECUTE" -eq 1 ]; then
  printf '== fleet-roll %s -- EXECUTE (commits and pushes) ==\n' "$TAG"
else
  printf '== fleet-roll %s -- DRY RUN (nothing is committed or pushed) ==\n' "$TAG"
fi

for repo in "${TARGETS[@]}"; do
  dir="$REPOS_DIR/$repo"
  [ -e "$dir/.git" ] || continue
  [ -f "$dir/.github/update.json" ] || continue
  if command -v gh >/dev/null 2>&1 &&
    [ "$(cd "$dir" && gh repo view --json isArchived --jq .isArchived 2>/dev/null)" = true ]; then
    printf 'skip  %s: archived upstream, retired from the fleet\n' "$repo"
    retired=$((retired + 1))
    continue
  fi

  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    fail_repo "$repo" "working tree is not clean; refusing to roll over local work"
    continue
  fi
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  if [ "$branch" != main ]; then
    fail_repo "$repo" "on branch '$branch', expected main"
    continue
  fi
  if ! git -C "$dir" fetch --quiet origin 2>/dev/null; then
    fail_repo "$repo" "cannot reach origin"
    continue
  fi
  counts=$(git -C "$dir" rev-list --left-right --count "origin/main...HEAD" 2>/dev/null) || counts=""
  behind=$(awk '{print $1}' <<<"$counts")
  ahead=$(awk '{print $2}' <<<"$counts")
  if [ "${behind:-1}" != 0 ] && [ "${ahead:-1}" = 0 ] && [ "$SYNC" -eq 1 ]; then
    if git -C "$dir" merge --ff-only --quiet origin/main 2>/dev/null; then
      printf 'sync  %s: fast-forwarded %s commit(s)\n' "$repo" "$behind"
      counts=$(git -C "$dir" rev-list --left-right --count "origin/main...HEAD" 2>/dev/null) || counts=""
      behind=$(awk '{print $1}' <<<"$counts")
      ahead=$(awk '{print $2}' <<<"$counts")
    else
      fail_repo "$repo" "fast-forward refused by git despite a clean tree behind origin"
      continue
    fi
  fi
  if [ "${behind:-1}" != 0 ] || [ "${ahead:-1}" != 0 ]; then
    fail_repo "$repo" "out of sync with origin/main (behind=${behind:-?} ahead=${ahead:-?}); --sync fast-forwards a clean clone that is only behind"
    continue
  fi

  current=$(grep -oE 'nix-packaging-standard\?ref=[^"]+' "$dir/flake.nix" 2>/dev/null | head -1 | cut -d= -f2)
  if [ -z "$current" ]; then
    fail_repo "$repo" "no pinned nix-packaging-standard ref found in flake.nix"
    continue
  fi
  if [ "$current" = "$TAG" ]; then
    printf 'ok    %s: already at %s\n' "$repo" "$TAG"
    skipped=$((skipped + 1))
    continue
  fi

  printf '\n-- %s: %s -> %s\n' "$repo" "$current" "$TAG"

  if ! sed -i -E "s#(nix-packaging-standard\?ref=)[^\"]+#\1${TAG}#" "$dir/flake.nix"; then
    fail_repo "$repo" "could not rewrite the pin in flake.nix"
    restore "$dir"
    continue
  fi
  if ! grep -q "nix-packaging-standard?ref=${TAG}" "$dir/flake.nix"; then
    fail_repo "$repo" "pin rewrite did not take"
    restore "$dir"
    continue
  fi

  if ! (cd "$dir" && nix flake update std >/dev/null 2>&1); then
    fail_repo "$repo" "nix flake update std failed"
    restore "$dir"
    continue
  fi

  if ! PKG_REPOS_DIR="$REPOS_DIR" bash "$STD/sync.sh" "$repo" >/dev/null 2>&1; then
    fail_repo "$repo" "sync.sh failed"
    restore "$dir"
    continue
  fi

  note "changed: $(git -C "$dir" diff --name-only | tr '\n' ' ')"

  if [ "$SKIP_BUILD" -eq 0 ]; then
    sys=$(nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null)
    buildlog="$LOGDIR/$repo.log"
    build_one() {
      (cd "$dir" && nix run --inputs-from . nixpkgs#nix-fast-build -- \
        --skip-cached --no-nom --flake ".#checks.$sys") >"$buildlog" 2>&1
    }
    build_one
    brc=$?
    if [ "$brc" -ne 0 ] && grep -qiE "$TRANSIENT" "$buildlog"; then
      note "build: transient fetch failure, retrying once in 60s"
      sleep 60
      build_one
      brc=$?
    fi
    if [ "$brc" -ne 0 ]; then
      why=$(grep -oiE 'HTTP error [0-9]{3}|error: [0-9]{3}|Too Many Requests|cannot download|unable to download|hash mismatch|Failed attributes: [^ ]*|builder for .* failed' "$buildlog" | sort -u | head -2 | tr '\n' ';')
      if grep -qiE "$TRANSIENT" "$buildlog"; then
        fail_repo "$repo" "TRANSIENT fetch failure, still failing after one retry: ${why:-see log}  log: $buildlog"
      else
        fail_repo "$repo" "build failed: ${why:-see log}  log: $buildlog"
      fi
      restore "$dir"
      continue
    fi
    note "build: green"
  else
    note "build: SKIPPED (not eligible to push)"
  fi

  if [ "$EXECUTE" -eq 1 ]; then
    msg=$(mktemp)
    {
      printf 'chore(std): adopt nix-packaging-standard %s\n\n' "$TAG"
      cat "$NOTES"
      printf '\nEval: local-fast-build=green\n'
    } >"$msg"
    if ! git -C "$dir" commit --quiet -a -F "$msg"; then
      rm -f "$msg"
      fail_repo "$repo" "commit failed"
      restore "$dir"
      continue
    fi
    rm -f "$msg"
    if ! git -C "$dir" push --quiet origin main; then
      git -C "$dir" reset --hard --quiet HEAD~1
      fail_repo "$repo" "push refused (archived or no write access); commit undone, nothing left behind"
      continue
    fi
    note "pushed: $(git -C "$dir" log -1 --format=%h)"
  else
    restore "$dir"
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      fail_repo "$repo" "dry run could not restore a clean tree; inspect before re-running"
      continue
    fi
    note "restored: clean"
  fi
  rolled=$((rolled + 1))
done

printf '\n== summary ==\n'
printf 'rolled: %s   already at %s: %s   retired: %s   failed: %s\n' "$rolled" "$TAG" "$skipped" "$retired" "$failed"
if [ "$failed" -gt 0 ]; then
  printf 'failed repos: %s\n' "${FAILED_REPOS[*]}"
  printf 'build logs kept in: %s\n' "$LOGDIR"
  exit 1
fi
rm -rf "$LOGDIR"
if [ "$EXECUTE" -eq 0 ]; then
  printf 'DRY RUN -- nothing was committed or pushed. Re-run with --execute --notes <file>.\n'
fi
exit 0
