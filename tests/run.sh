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
for a in "$@"; do
  case "$a" in
  *raw.githubusercontent*)
    [ -n "${STUB_CURL_RAW_FILE:-}" ] && { cat "$STUB_CURL_RAW_FILE"; exit 0; }
    ;;
  esac
done
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
  "eval "*) echo true; exit 0 ;;
  *build*)
    [ -f "$STUB_NIX_FLAG" ] && exit 0
    : >"$STUB_NIX_FLAG"
    [ -n "${STUB_NIX_MISMATCH:-}" ] && cat "$STUB_NIX_MISMATCH"
    exit 1 ;;
  *) exit 0 ;;
esac
SH
# `file` stub: classify by ELF magic (7f 45 4c 46) so the elf-verify test is
# deterministic and host-independent — real `file` may be absent (e.g. a
# minimal NixOS) and we don't want the test to depend on its exact wording.
cat >"$BIN/file" <<'SH'
#!/usr/bin/env bash
p="${@: -1}"
if [ "$(head -c4 "$p" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
  echo "$p: ELF 64-bit LSB executable"
else
  echo "$p: ASCII text"
fi
SH
chmod +x "$BIN/curl" "$BIN/git" "$BIN/nix" "$BIN/file"

run_update() { # run_update <repodir>  -> sets RC; outputs in <repodir>/out.env
  local dir="$1"
  (
    cd "$dir" && GITHUB_OUTPUT="$dir/out.env" PATH="$BIN:$PATH" \
      STUB_CURL_FILE="${STUB_CURL_FILE:-}" STUB_GIT_REV="${STUB_GIT_REV:-}" \
      STUB_CURL_RAW_FILE="${STUB_CURL_RAW_FILE:-}" \
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

# ---- Test 4: elf verify is robust to multi-output / non-ELF-first layout ---
# Regression for vfio-stealth-nix #5. The verify must SCAN for a real ELF, not
# demand that the first executable be one. qemu is multi-output and ships a
# non-ELF qemu-ga; the broken per-repo check did `find result/bin | head -1`
# and failed on it. Here bin/ holds only a non-ELF wrapper and the real ELF
# lives in lib/, so a correct scan must look past bin/'s first entry. `result`
# is a symlink (as `nix build` makes it) so the trailing `rm -f result` works,
# and both bin/ and lib/ exist so the scan's `find` doesn't error on a missing
# dir under set -e.
echo "Test 4: elf verify finds the ELF past a non-ELF bin entry"
d="$WORK/t4"; mkdir -p "$d/.github" "$d/_out/bin" "$d/_out/lib"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "git-ls-remote", "url": "u", "branch": "main" },
  "packageFile": "version.json", "versionScheme": "rev-only",
  "hashes": [], "verify": { "check": "elf" } }
JSON
printf '{ "rev": "old0000000000000000000000000000000000000a", "version": "1.0", "date": "x" }\n' >"$d/version.json"
printf '#!/bin/sh\necho wrapper\n' >"$d/_out/bin/qemu-ga"   # non-ELF, scanned first
printf '\177ELF\002\001\001\0' >"$d/_out/lib/libqemu.so"    # real ELF magic, in lib/
chmod +x "$d/_out/bin/qemu-ga"
ln -s _out "$d/result"                                       # nix build => symlink, not a dir
: >"$d/.nixflag"                                             # make the nix-build stub succeed
STUB_GIT_REV="new2222222222222222222222222222222222222c" run_update "$d"
check "elf verify passes (exit 0)"   "0"    "$RC"
check "update recorded"              "true" "$(get "$d" updated)"
check "no verification-error"        ""     "$(get "$d" error_type)"

# ---- Test 4b: elf verify fails cleanly when NO ELF exists anywhere ---------
echo "Test 4b: elf verify fails when no ELF artifact is present"
d="$WORK/t4b"; mkdir -p "$d/.github" "$d/_out/bin" "$d/_out/lib"
cp "$WORK/t4/.github/update.json" "$d/.github/update.json"
printf '{ "rev": "old0000000000000000000000000000000000000a", "version": "1.0", "date": "x" }\n' >"$d/version.json"
printf '#!/bin/sh\necho only-a-script\n' >"$d/_out/bin/qemu-ga"   # non-ELF; lib/ stays empty
chmod +x "$d/_out/bin/qemu-ga"
ln -s _out "$d/result"
: >"$d/.nixflag"
STUB_GIT_REV="new2222222222222222222222222222222222222c" run_update "$d"
check "no-ELF exits 1"                "1"                  "$RC"
check "error_type verification-error" "verification-error" "$(get "$d" error_type)"

# ---- Test 5: first-party convention (none + self owner) is a clean no-op ----
# Owner-authored software declares upstream {type:none, owner:<self>}: the repo
# IS the upstream, so there is nothing to poll. The extra owner field must not
# trip the updater -- it must take the plain `none` branch and exit 0 cleanly,
# writing nothing. Guards the first-party convention against a future regression
# that starts treating a none-type's owner as something to fetch.
echo "Test 5: first-party (none + self owner) -> no-op, exit 0"
d="$WORK/t5"; mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "none", "owner": "Daaboulex", "repo": "x" },
  "packageFile": "flake.nix", "hashes": [], "verify": { "check": "wrapper" } }
JSON
run_update "$d"
check "first-party exits 0" "0"     "$RC"
check "updated=false"       "false" "$(get "$d" updated)"
check "no error_type"       ""      "$(get "$d" error_type)"

# ---- Tests 6-8: heal-overlays.sh boundary behavior --------------------------
# The probe path needs a real flake + nix; these tests pin the fail-closed
# boundaries that need neither: no dir is a clean no-op, an empty dir and a
# malformed fix are hard errors.
HEAL="$STD/heal-overlays.sh"
run_heal() { (cd "$1" && GITHUB_OUTPUT="$1/out.env" bash "$HEAL" >"$1/log" 2>&1); RC=$?; }
geth() { grep "^$2=" "$1/out.env" 2>/dev/null | tail -1 | cut -d= -f2-; }

echo "Test 6: heal-overlays without overlays/ -> clean no-op, exit 0"
d="$WORK/t6"; mkdir -p "$d"
run_heal "$d"
check "no-dir exits 0" "0" "$RC"
check "healed empty"   ""  "$(geth "$d" healed)"

echo "Test 7: heal-overlays with empty overlays/ -> fail closed, exit 1"
d="$WORK/t7"; mkdir -p "$d/overlays"
run_heal "$d"
check "empty dir exits 1" "1" "$RC"

if command -v nix >/dev/null 2>&1; then
  echo "Test 8: heal-overlays malformed fix (no meta/dropWhen) -> fail closed, exit 1"
  d="$WORK/t8"; mkdir -p "$d/overlays"
  echo '{ overlay = final: prev: { }; }' >"$d/overlays/broken.nix"
  run_heal "$d"
  check "malformed exits 1" "1" "$RC"
else
  echo "Test 8 skipped (nix unavailable)"
fi

# ---- Test 9: pythonRequirements auto-add above the marker -------------------
# A new upstream requirement (dasbus) whose normalized name exists as a
# python3Packages attr (nix eval stub answers true) is inserted above the
# marker; a requirement already in the env list (loguru) is left alone.
echo "Test 9: pythonRequirements auto-add inserts new dep above marker"
d="$WORK/t9"; mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^[0-9]" },
  "packageFile": "version.json", "hashes": [], "verify": { "check": "eval" },
  "pythonRequirements": { "file": "requirements.txt", "envFile": "env.nix", "ignore": ["skipme"] } }
JSON
printf '{ "version": "2026.1", "rev": "x", "hash": "sha256-x", "date": "x" }\n' >"$d/version.json"
cat >"$d/env.nix" <<'NIX'
      ps: with ps; [
        loguru
        # std:requirements-auto-add
      ]
NIX
printf 'loguru==0.7.2\ndasbus==1.7\nskipme==1.0\n# a comment\n' >"$WORK/t9-reqs.txt"
: >"$d/.nixflag"
STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" \
  STUB_CURL_RAW_FILE="$WORK/t9-reqs.txt" run_update "$d"
check "update exits 0"        "0"      "$RC"
check "updated=true"          "true"   "$(get "$d" updated)"
check "auto_added=dasbus"     "dasbus" "$(get "$d" auto_added)"
check "dasbus sits above the marker" "dasbus" \
  "$(grep -B1 'std:requirements-auto-add' "$d/env.nix" | head -1 | tr -d ' ')"
check "loguru not duplicated" "1" "$(grep -c 'loguru' "$d/env.nix")"

# ---- Tests 10-11: classify-build-failure.sh ---------------------------------
CLASSIFY="$STD/classify-build-failure.sh"
run_classify() { (GITHUB_OUTPUT="$1/out.env" bash "$CLASSIFY" "$2" >"$1/clog" 2>&1); RC=$?; }

echo "Test 10: classifier names hash-mismatch and extracts every failed drv"
d="$WORK/t10"; mkdir -p "$d"; : >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error: Cannot build '/nix/store/aaaa-foo-1.0.drv'.
some noise
hash mismatch in fixed-output derivation '/nix/store/bbbb-src.drv'
error: Cannot build '/nix/store/cccc-bar-2.0.drv'.
ERROR:nix_fast_build:Failed attributes: .#checks.x86_64-linux.package-foo .#checks.x86_64-linux.package-bar
LOG
run_classify "$d" "$d/build.log"
check "classifier exits 0"      "0" "$RC"
check "class hash-mismatch"     "upstream-rerelease-hash-mismatch" "$(get "$d" class)"
check "both failed drvs listed" "2" "$(get "$d" failed_drvs | tr ' ' '\n' | grep -c drv)"
check "failed attrs captured"   ".#checks.x86_64-linux.package-foo .#checks.x86_64-linux.package-bar" "$(get "$d" failed_attrs)"

echo "Test 11: classifier fail-safe on a missing log -> unclassified"
d="$WORK/t11"; mkdir -p "$d"; : >"$d/out.env"
run_classify "$d" "$d/nope.log"
check "missing log exits 0"  "0"            "$RC"
check "class unclassified"   "unclassified" "$(get "$d" class)"

echo
echo "------------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
