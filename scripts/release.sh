#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
release - verify HEAD of the standard against every consumer, then tag it and move the release branch to it.

  PKG_REPOS_DIR=/path/to/repos scripts/release.sh <version> [--skip <repo>]... [--dry-run]

  <version>      vMAJOR.MINOR.PATCH: newer than every tag, with its own History entry in README.md.
  --skip <repo>  leave this consumer out of the fleet check; the tag message names it.
  --dry-run      run every check and print the tag message, but tag and push nothing.

Refuses unless the tree is clean on main and pushed, the standard's CI passed on GitHub for that
commit, and the release branch fast-forwards to it.

Fleet check: each consumer under PKG_REPOS_DIR is cloned at its origin/main (HEAD when it has no
remote), the clone is rolled to the candidate (pin and synced files), and every system it declares
is evaluated with std overridden to the candidate. Every check whose derivation the candidate
changed is built on each system this host or its builders can build; any other system is evaluated
only, and the tag message says so.

Exit: 0 released (or dry run passed), 1 refused or a consumer failed, 2 usage.
USAGE
}

STD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

changed_drvs() {
  jq -r --arg s "$3" --slurpfile b "$1" \
    '($b[0] | [.[]? | .[]?]) as $old | (.[$s] // {}) | .[] | select(. as $d | $old | index($d) | not)' "$2"
}

build_systems() {
  local builders
  nix config show system
  nix config show extra-platforms | tr ' ' '\n' | awk 'NF'
  builders=$(nix config show builders)
  case "$builders" in
  @*) builders=$(cat "${builders#@}") ;;
  esac
  printf '%s\n' "$builders" | tr ';' '\n' |
    awk '$1 !~ /^#/ && NF >= 2 && $2 != "-" { n = split($2, s, ","); for (i = 1; i <= n; i++) print s[i] }'
}

newer_than_every_tag() {
  local version="$1" newest
  newest=$(git -C "$STD" tag --list 'v*' | sort -V | tail -1)
  [ -z "$newest" ] && return 0
  [ "$newest" != "$version" ] && [ "$(printf '%s\n%s\n' "$newest" "$version" | sort -V | tail -1)" = "$version" ]
}

consumers_need_roll() {
  local -a carried
  mapfile -t carried < <(git -C "$STD" show "$2:synced-files.json" | jq -r '.[] | values')
  [ "${#carried[@]}" -gt 0 ] || {
    echo "release: synced-files.json at $2 names no file" >&2
    return 0
  }
  ! git -C "$STD" diff --quiet "$1" "$2" -- "${carried[@]}" .gitignore synced-files.json
}

eval_checks() {
  local flake="$1"
  shift
  nix eval --json "$flake#checks" "$@" \
    --apply 'builtins.mapAttrs (_: builtins.mapAttrs (_: c: c.drvPath))'
}

refuse() {
  echo "release: $1" >&2
  exit 1
}

main() {
  local version="" dry=0 arg
  declare -a skip=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run) dry=1 ;;
    --skip)
      shift
      [ -n "${1:-}" ] || {
        usage >&2
        exit 2
      }
      skip+=("$1")
      ;;
    -*)
      echo "release: unknown option '$1'" >&2
      exit 2
      ;;
    *)
      [ -z "$version" ] || {
        usage >&2
        exit 2
      }
      version="$1"
      ;;
    esac
    shift
  done
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    usage >&2
    exit 2
  }
  local repos_dir="${PKG_REPOS_DIR:?set PKG_REPOS_DIR to the directory holding the consumer clones}"
  for arg in git nix jq gh; do
    command -v "$arg" >/dev/null || refuse "required tool '$arg' not found"
  done

  [ -z "$(git -C "$STD" status --porcelain)" ] || refuse "the working tree is not clean"
  [ "$(git -C "$STD" rev-parse --abbrev-ref HEAD)" = main ] || refuse "not on main"
  git -C "$STD" fetch --quiet origin || refuse "could not fetch the standard's remote"
  local sha
  sha=$(git -C "$STD" rev-parse HEAD)
  [ "$sha" = "$(git -C "$STD" rev-parse origin/main)" ] || refuse "HEAD $sha is not origin/main; push main first"
  newer_than_every_tag "$version" || refuse "$version is not newer than every existing tag ($(git -C "$STD" tag --list 'v*' | sort -V | tail -1))"
  [ -z "$(git -C "$STD" ls-remote --tags origin "refs/tags/$version")" ] || refuse "$version already exists on the remote"
  grep -qE "^$version \(" "$STD/README.md" || refuse "README.md has no History entry for $version"
  if git -C "$STD" rev-parse -q --verify refs/remotes/origin/release >/dev/null; then
    git -C "$STD" merge-base --is-ancestor origin/release "$sha" ||
      refuse "origin/release is not an ancestor of $sha, so the release branch would not fast-forward"
  fi
  local slug ci
  slug=$(gh repo view "$(git -C "$STD" remote get-url origin)" --json nameWithOwner --jq .nameWithOwner) ||
    refuse "could not resolve the GitHub repository of origin"
  ci=$(gh run list -R "$slug" --workflow ci.yml --commit "$sha" --limit 1 --json status,conclusion --jq '.[0] | "\(.status)/\(.conclusion)"') ||
    refuse "could not read the CI runs of $sha"
  [ "$ci" = completed/success ] || refuse "CI on $sha is '${ci:-no run}', not completed/success"

  local work
  work=$(mktemp -d -t std-release-XXXXXX)
  mkdir -p "$work/std" "$work/clones" "$work/logs"
  git -C "$STD" archive "$sha" | tar -x -C "$work/std" || refuse "could not extract $sha"
  local release_url
  release_url=$(nix eval --raw --file "$work/std/lib.nix" releaseUrl) || refuse "could not read releaseUrl from lib.nix"
  local -a systems
  mapfile -t systems < <(build_systems | sort -u)
  [ "${#systems[@]}" -gt 0 ] || refuse "could not read which systems this host builds"
  echo "== release $version ($sha): this host builds ${systems[*]}"

  local verified=0 built=0 failed=0 repo dir clone log s
  local -a failures=() eval_only=() skipped=()
  while IFS= read -r dir; do
    repo=$(basename "$dir")
    [ -e "$dir/.git" ] && [ -f "$dir/.github/update.json" ] || continue
    [ "$dir" -ef "$STD" ] && continue
    if grep -qxF "$repo" <<<"$(printf '%s\n' "${skip[@]}")"; then
      skipped+=("$repo")
      echo "skip  $repo"
      continue
    fi
    clone="$work/clones/$repo"
    log="$work/logs/$repo.log"
    local target
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      if ! git -C "$dir" fetch --quiet origin >>"$log" 2>&1; then
        failures+=("$repo: could not fetch origin; $log")
        continue
      fi
      if ! target=$(git -C "$dir" rev-parse --verify -q refs/remotes/origin/main); then
        failures+=("$repo: origin has no main branch")
        continue
      fi
    else
      target=$(git -C "$dir" rev-parse HEAD)
    fi
    if ! { git clone --quiet --shared --no-checkout "$dir" "$clone" &&
      git -C "$clone" checkout --quiet --detach "$target"; } >>"$log" 2>&1; then
      failures+=("$repo: could not clone $target; $log")
      continue
    fi
    if ! eval_checks "git+file://$clone" >"$work/$repo.base.json" 2>>"$log"; then
      echo "{}" >"$work/$repo.base.json"
      echo "  $repo: HEAD does not evaluate, so every check of the candidate counts as changed" | tee -a "$log"
    fi
    sed -i -E "s#\"github:Daaboulex/nix-packaging-standard[^\"]*\"#\"$release_url\"#" "$clone/flake.nix"
    if ! grep -qF "\"$release_url\"" "$clone/flake.nix"; then
      failures+=("$repo: flake.nix names no std input this script can point at $release_url")
      continue
    fi
    if ! PKG_REPOS_DIR="$work/clones" bash "$work/std/sync.sh" "$repo" >>"$log" 2>&1; then
      failures+=("$repo: sync.sh failed; $log")
      continue
    fi
    git -C "$clone" add -A
    if ! git -C "$clone" diff --cached --quiet; then
      git -C "$clone" -c user.name=release -c user.email=release@localhost commit --quiet -m "roll to $version" >>"$log" 2>&1 ||
        {
          failures+=("$repo: could not commit the roll in the clone; $log")
          continue
        }
    fi
    if ! eval_checks "git+file://$clone" --override-input std "git+file://$STD?rev=$sha" >"$work/$repo.cand.json" 2>>"$log"; then
      failures+=("$repo: does not evaluate against $version; $log")
      continue
    fi
    local repo_failed=0
    for s in $(jq -r 'keys[]' "$work/$repo.cand.json"); do
      local -a changed
      mapfile -t changed < <(changed_drvs "$work/$repo.base.json" "$work/$repo.cand.json" "$s")
      [ "${#changed[@]}" -gt 0 ] || continue
      if grep -qxF "$s" <<<"$(printf '%s\n' "${systems[@]}")"; then
        echo "  $repo: building ${#changed[@]} changed check(s) for $s"
        if nix build --no-link --keep-going "${changed[@]/%/^*}" >>"$log" 2>&1; then
          built=$((built + ${#changed[@]}))
        else
          failures+=("$repo: a changed check fails on $s; $log")
          repo_failed=1
        fi
      else
        eval_only+=("$repo on $s: ${#changed[@]} changed check(s) evaluated, not built")
      fi
    done
    if [ "$repo_failed" -eq 0 ]; then
      verified=$((verified + 1))
      echo "ok    $repo"
    fi
  done < <(find "$repos_dir" -maxdepth 1 -mindepth 1 -type d | sort)

  failed=${#failures[@]}
  if [ "$failed" -gt 0 ]; then
    printf '\nFAILED %s consumer(s); logs in %s\n' "$failed" "$work/logs"
    printf '  %s\n' "${failures[@]}"
    exit 1
  fi
  [ "$verified" -gt 0 ] || refuse "no consumer found under $repos_dir"

  local msg="$work/tag-message"
  {
    printf 'nix-packaging-standard %s\n\n' "$version"
    printf 'Fleet check: %s consumer(s) cloned at origin/main, rolled to %s and evaluated on\n' "$verified" "$sha"
    printf 'every declared system; %s changed check(s) built on %s.\n' "$built" "${systems[*]}"
    if [ "${#eval_only[@]}" -gt 0 ]; then
      printf '\nEvaluated only, no host here builds the system:\n'
      printf -- '- %s\n' "${eval_only[@]}"
    fi
    if [ "${#skipped[@]}" -gt 0 ]; then
      printf '\nLeft out of the fleet check on request: %s\n' "${skipped[*]}"
    fi
  } >"$msg"
  echo
  cat "$msg"

  local prev
  prev=$(git -C "$STD" tag --list 'v*' | sort -V | tail -1)
  local roll_needed=0 update_changed=0
  if [ -n "$prev" ] && consumers_need_roll "$prev" "$sha"; then
    roll_needed=1
  fi
  if [ -n "$prev" ] && ! git -C "$STD" diff --quiet "$prev" "$sha" -- .github/workflows/package-update.yml update.sh classify-build-failure.sh report-failure.sh declared-runners.sh; then
    update_changed=1
  fi

  if [ "$dry" -eq 1 ]; then
    echo
    echo "DRY RUN: nothing tagged or pushed."
    rm -rf "$work"
    exit 0
  fi
  git -C "$STD" tag -a "$version" -F "$msg" "$sha" || refuse "could not create the tag"
  git -C "$STD" push origin "refs/tags/$version" || refuse "the tag $version was created locally but not pushed"
  if ! git -C "$STD" push origin "$sha:refs/heads/release"; then
    refuse "$version is pushed but the release branch did not move; push it with: git -C $STD push origin $sha:refs/heads/release"
  fi
  rm -rf "$work"
  echo
  echo "released $version: origin/release is $sha"
  if [ "$roll_needed" -eq 1 ]; then
    echo "What consumers carry changed since $prev; each consumer fails std-conformance or std-devstate at its next lock refresh until rolled:"
    echo "  PKG_REPOS_DIR=$repos_dir $STD/scripts/fleet-roll.sh --execute --notes <file>"
  fi
  if [ "$update_changed" -eq 1 ]; then
    echo "The Update workflow or a script it runs changed since $prev, and nothing ran it before this release."
    echo "Every consumer runs it at 06:00 UTC; dispatch it on one consumer now and read the run:"
    echo "  gh workflow run update.yml -R Daaboulex/ripgrep-nix"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
