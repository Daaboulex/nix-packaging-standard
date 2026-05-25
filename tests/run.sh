#!/usr/bin/env bash
# Behavioral regression tests for the canonical update.sh, exercised end-to-end
# against stubbed curl/git/nix (no network, no real build). Guards the three
# defects fixed 2026-05:
#   1. tagFilter ignored in github-release  -> foreign namespace ("android/*") selected
#   2. no trackOnly mode                    -> version-read failure on hand-mirrored repos
#   3. version clobber + JSON-resident hash -> mesa-style rev-only packages couldn't update
set -uo pipefail

STD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$STD/update.sh"
# /tmp is often mounted noexec (e.g. NixOS); the PATH stubs must be executable,
# so probe candidate bases and create WORK in the first exec-capable one.
mkexecdir() {
  local base d
  for base in "${TMPDIR:-/tmp}" "$HOME/.cache" "$HOME"; do
    [ -d "$base" ] || continue
    d="$(mktemp -d "$base/nps-test.XXXXXX" 2>/dev/null)" || continue
    if printf '#!/bin/sh\n' >"$d/.probe" && chmod +x "$d/.probe" && "$d/.probe" 2>/dev/null; then
      rm -f "$d/.probe"
      printf '%s' "$d"
      return 0
    fi
    rm -rf "$d"
  done
  echo "run.sh: no exec-capable temp dir found" >&2
  return 1
}
WORK="$(mkexecdir)" || exit 1
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$2', got '$3')"; fi
}

# Stub bin: curl emits $STUB_CURL_FILE; git ls-remote emits $STUB_GIT_REV;
# nix flake-check is ok, nix build emits $STUB_NIX_MISMATCH once (then succeeds).
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/curl" <<'SH'
#!/usr/bin/env bash
cat "$STUB_CURL_FILE"
SH
cat >"$BIN/git" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "ls-remote" ] && { printf '%s\trefs/heads/main\n' "$STUB_GIT_REV"; exit 0; }
exit 0
SH
cat >"$BIN/nix" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"flake check"*) exit 0 ;;
  *build*)
    [ -f "$STUB_NIX_FLAG" ] && exit 0
    : >"$STUB_NIX_FLAG"
    [ -n "${STUB_NIX_MISMATCH:-}" ] && cat "$STUB_NIX_MISMATCH"
    exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/curl" "$BIN/git" "$BIN/nix"

run_update() { # run_update <repodir>  -> sets RC; outputs in <repodir>/out.env
  local dir="$1"
  (
    cd "$dir" && GITHUB_OUTPUT="$dir/out.env" PATH="$BIN:$PATH" \
      STUB_CURL_FILE="${STUB_CURL_FILE:-}" STUB_GIT_REV="${STUB_GIT_REV:-}" \
      STUB_NIX_MISMATCH="${STUB_NIX_MISMATCH:-}" STUB_NIX_FLAG="$dir/.nixflag" \
      bash "$UPDATE" >"$dir/log" 2>&1
  )
  RC=$?
}
get() { grep -E "^$2=" "$1/out.env" 2>/dev/null | tail -1 | cut -d= -f2-; }

# ---- Test 1: tagFilter excludes a foreign namespace ------------------------
echo "Test 1: github-release tagFilter skips android/*"
d="$WORK/t1"; mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^[0-9]" },
  "packageFile": "version.json", "hashes": [], "verify": { "check": "eval" } }
JSON
printf '{ "version": "2026.2", "rev": "x", "hash": "sha256-x", "date": "x" }\n' >"$d/version.json"
STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" run_update "$d"
check "selected desktop 2026.2, not android/2026.5" "2026.2" "$(get "$d" new_version)"
check "recognised up-to-date (no spurious update)"  "false"  "$(get "$d" updated)"

# ---- Test 2a: trackOnly detects drift, files reminder, writes nothing ------
echo "Test 2a: trackOnly drift -> remirror-needed, marker untouched"
d="$WORK/t2"; mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-commit", "owner": "o", "repo": "r", "branch": "master" },
  "trackOnly": true, "trackFile": "upstream-version.json", "trackKey": "commit",
  "packageFile": null, "hashes": [], "verify": { "check": "eval" } }
JSON
printf '{ "commit": "aaaaaaa", "date": "x" }\n' >"$d/upstream-version.json"
printf '{ "sha": "bbbbbbbb000000000000000000000000000000000" }\n' >"$WORK/commit.json"
before="$(cat "$d/upstream-version.json")"
STUB_CURL_FILE="$WORK/commit.json" run_update "$d"
check "drift exits 1"               "1"               "$RC"
check "error_type remirror-needed"  "remirror-needed" "$(get "$d" error_type)"
check "marker file NOT rewritten"   "$before"         "$(cat "$d/upstream-version.json")"

# ---- Test 2b: trackOnly already current -> clean no-op ---------------------
echo "Test 2b: trackOnly up-to-date -> exit 0, no update"
d="$WORK/t2b"; mkdir -p "$d/.github"
cp "$WORK/t2/.github/update.json" "$d/.github/update.json"
printf '{ "commit": "bbbbbbbb", "date": "x" }\n' >"$d/upstream-version.json"
STUB_CURL_FILE="$WORK/commit.json" run_update "$d"
check "up-to-date exits 0" "0"     "$RC"
check "updated=false"      "false" "$(get "$d" updated)"

# ---- Test 3: rev-only keeps version, bumps rev + JSON-resident hash --------
echo "Test 3: rev-only preserves version, writes rev + version.json hash"
d="$WORK/t3"; mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "git-ls-remote", "url": "u", "branch": "main" },
  "packageFile": "version.json", "versionScheme": "rev-only",
  "hashes": [ { "field": "hash", "file": "version.json" } ], "verify": {} }
JSON
cat >"$d/version.json" <<'JSON'
{
  "rev": "old0000000000000000000000000000000000000a",
  "hash": "sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLD=",
  "version": "26.2.0-devel",
  "date": "2026-01-01"
}
JSON
NEWREV="new1111111111111111111111111111111111111b"
NEWHASH="sha256-NEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEW="
cat >"$WORK/mismatch.txt" <<EOF
error: hash mismatch in fixed-output derivation '/nix/store/zzz-source.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    $NEWHASH
EOF
STUB_GIT_REV="$NEWREV" STUB_NIX_MISMATCH="$WORK/mismatch.txt" run_update "$d"
check "rev-only exits 0"          "0"             "$RC"
check "marketing version kept"    "26.2.0-devel"  "$(jq -r .version "$d/version.json")"
check "rev bumped"                "$NEWREV"       "$(jq -r .rev "$d/version.json")"
check "JSON-resident hash written" "$NEWHASH"     "$(jq -r .hash "$d/version.json")"
check "new_version is short rev"  "new1111"       "$(get "$d" new_version)"

echo
echo "------------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
