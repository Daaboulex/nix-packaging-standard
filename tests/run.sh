#!/usr/bin/env bash
# Behavioral regression tests for the canonical update.sh, exercised end-to-end
# against stubbed curl/git/nix (no network; only Test 34 builds a one-line
# fixture derivation with the real nix). Guards the three defects fixed 2026-05:
#   1. tagFilter ignored in github-release  -> foreign namespace ("android/*") selected
#   2. no trackOnly mode                    -> version-read failure on hand-mirrored repos
#   3. version clobber + JSON-resident hash -> mesa-style rev-only packages couldn't update
set -uo pipefail

STD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$STD/update.sh"
FIXTURES="$STD/tests/fixtures"
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
ok() {
  pass=$((pass + 1))
  printf '  ok   %s\n' "$1"
}
no() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
}
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
  */tags*)
    [ -n "${STUB_CURL_TAGS_FILE:-}" ] && { cat "$STUB_CURL_TAGS_FILE" || exit 1; exit 0; }
    ;;
  */compare/*)
    [ -n "${STUB_CURL_COMPARE_FILE:-}" ] && { cat "$STUB_CURL_COMPARE_FILE" || exit 1; exit 0; }
    ;;
  */git/trees/*)
    [ -n "${STUB_CURL_TREE_FILE:-}" ] && { cat "$STUB_CURL_TREE_FILE" || exit 1; exit 0; }
    ;;
  esac
done
# Paged list endpoints: serve $STUB_CURL_PAGE_DIR/page<N>.json, empty past the
# end, so the pagination walk can be exercised without a network.
if [ -n "${STUB_CURL_PAGE_DIR:-}" ]; then
  page=1
  for a in "$@"; do
    case "$a" in
    *page=*)
      page="${a##*page=}"
      page="${page%%&*}"
      ;;
    esac
  done
  [ -f "$STUB_CURL_PAGE_DIR/page$page.json" ] &&
    { cat "$STUB_CURL_PAGE_DIR/page$page.json"; exit 0; }
  echo '[]'
  exit 0
fi
cat "$STUB_CURL_FILE"
SH
cat >"$BIN/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "ls-remote" ] && [ -n "${STUB_GIT_FAIL_ONCE:-}" ] && [ -f "$STUB_GIT_FAIL_ONCE" ]; then
  rm -f "$STUB_GIT_FAIL_ONCE"
  echo "stub: ls-remote failed once" >&2
  exit 128
fi
if [ "${1:-}" = "ls-remote" ]; then
  case "$*" in
    *--tags*) printf '%s' "${STUB_GIT_TAGS:-}"; exit 0 ;;
  esac
  printf '%s\trefs/heads/main\n' "$STUB_GIT_REV"
  exit 0
fi
exit 0
SH
cat >"$BIN/nix" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"prefetch-file"*)
    [ -n "${STUB_PREFETCH_FAIL:-}" ] && { echo "stub: the prefetch says why it failed" >&2; exit 1; }
    printf '{"hash":"sha256-%s="}\n' \
      "$(printf '%s' "${@: -1}" | sha256sum | cut -c1-43)"
    exit 0 ;;
  *"flake check --no-build"*) exit 0 ;;
  *"flake check"*)
    [ -n "${STUB_CHECKS_FAIL:-}" ] && { echo "stub: a check in the suite failed" >&2; exit 1; }
    exit 0 ;;
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
# `sleep` stub: the updater's fetch retry backs off 2s+4s+8s, which is real
# behavior worth keeping and 14s of dead wall-clock to test against.
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/sleep"
chmod +x "$BIN/curl" "$BIN/git" "$BIN/nix" "$BIN/file" "$BIN/sleep"

run_update() { # run_update <repodir>  -> sets RC; outputs in <repodir>/out.env
  local dir="$1"
  (
    cd "$dir" && GITHUB_OUTPUT="$dir/out.env" PATH="$BIN:$PATH" \
      STUB_CURL_FILE="${STUB_CURL_FILE:-}" STUB_GIT_REV="${STUB_GIT_REV:-}" \
      STUB_CURL_RAW_FILE="${STUB_CURL_RAW_FILE:-}" \
      STUB_CURL_TAGS_FILE="${STUB_CURL_TAGS_FILE:-}" \
      STUB_NIX_MISMATCH="${STUB_NIX_MISMATCH:-}" STUB_NIX_FLAG="$dir/.nixflag" \
      STUB_CHECKS_FAIL="${STUB_CHECKS_FAIL:-}" \
      STUB_PREFETCH_FAIL="${STUB_PREFETCH_FAIL:-}" \
      STUB_GIT_TAGS="${STUB_GIT_TAGS:-}" \
      STUB_GIT_FAIL_ONCE="${STUB_GIT_FAIL_ONCE:-}" \
      bash "$UPDATE" >"$dir/log" 2>&1
  )
  RC=$?
}
get() { grep -E "^$2=" "$1/out.env" 2>/dev/null | tail -1 | cut -d= -f2-; }

# ---- Test 1: tagFilter excludes a foreign namespace ------------------------
echo "Test 1: github-release tagFilter skips android/*"
d="$WORK/t1"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^[0-9]" },
  "packageFile": "version.json", "hashes": [], "verify": { "check": "eval" } }
JSON
printf '{ "version": "2026.2", "rev": "x", "hash": "sha256-x", "date": "x" }\n' >"$d/version.json"
STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" run_update "$d"
check "selected desktop 2026.2, not android/2026.5" "2026.2" "$(get "$d" new_version)"
check "recognised up-to-date (no spurious update)" "false" "$(get "$d" updated)"

# ---- Test 2a: trackOnly detects drift, files reminder, writes nothing ------
echo "Test 2a: trackOnly drift -> remirror-needed, marker untouched"
d="$WORK/t2"
mkdir -p "$d/.github"
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
check "drift exits 1" "1" "$RC"
check "error_type remirror-needed" "remirror-needed" "$(get "$d" error_type)"
check "marker file NOT rewritten" "$before" "$(cat "$d/upstream-version.json")"

# ---- Test 2b: trackOnly already current -> clean no-op ---------------------
echo "Test 2b: trackOnly up-to-date -> exit 0, no update"
d="$WORK/t2b"
mkdir -p "$d/.github"
cp "$WORK/t2/.github/update.json" "$d/.github/update.json"
printf '{ "commit": "bbbbbbbb", "date": "x" }\n' >"$d/upstream-version.json"
STUB_CURL_FILE="$WORK/commit.json" run_update "$d"
check "up-to-date exits 0" "0" "$RC"
check "updated=false" "false" "$(get "$d" updated)"

echo "Test 2e: a file ledger lets the marker move by itself only past files nobody ported"
ledger_fixture() { # ledger_fixture <dir> <marker>
  mkdir -p "$1/.github"
  cp "$WORK/t2/.github/update.json" "$1/.github/update.json"
  cat >"$1/upstream-version.json" <<JSON
{
  "repo": "o/r",
  "commit": "$2",
  "date": "2026-01-01",
  "files": {
    "usr/lib/sysctl.d/tuning.conf": { "decision": "ported" },
    "usr/lib/modprobe.d/gpu.conf": { "decision": "left-to-nixos" },
    "usr/bin/tool": { "decision": "not-ported" }
  }
}
JSON
}
compare_of() { # compare_of <file> <status> <path>
  cat >"$1" <<JSON
{ "commits": [ { "commit": { "committer": { "date": "2026-02-03T04:05:06Z" } } } ],
  "files": [ { "filename": "$3", "status": "$2", "patch": "@@ -1 +1 @@\n-old line\n+new line" } ] }
JSON
}

d="$WORK/t2d"
ledger_fixture "$d" aaaaaaa
compare_of "$WORK/compare.json" modified usr/bin/tool
STUB_CURL_FILE="$WORK/commit.json" STUB_CURL_COMPARE_FILE="$WORK/compare.json" run_update "$d"
check "a change to a file nobody ported exits 0" "0" "$RC"
check "and reports an update" "true" "$(get "$d" updated)"
check "the marker moved to the new commit" "bbbbbbb" "$(jq -r .commit "$d/upstream-version.json")"
check "the date is the new commit's" "2026-02-03" "$(jq -r .date "$d/upstream-version.json")"
check "the ledger is kept" "3" "$(jq -r '.files | length' "$d/upstream-version.json")"

for blocked in "modified usr/lib/sysctl.d/tuning.conf ported" \
  "modified usr/lib/modprobe.d/gpu.conf left-to-nixos" \
  "added usr/lib/new.conf no decision yet" \
  "removed usr/bin/tool not-ported"; do
  read -r status path decision <<<"$blocked"
  d="$WORK/t2d-$status-$(basename "$path")"
  ledger_fixture "$d" aaaaaaa
  compare_of "$WORK/compare.json" "$status" "$path"
  before="$(cat "$d/upstream-version.json")"
  STUB_CURL_FILE="$WORK/commit.json" STUB_CURL_COMPARE_FILE="$WORK/compare.json" run_update "$d"
  check "a file $status upstream, $decision, stops for a person" "1 remirror-needed" "$RC $(get "$d" error_type)"
  check "and leaves the marker alone" "$before" "$(cat "$d/upstream-version.json")"
  check "and names the file with its decision" "1" "$(grep -cF "$status, $decision: $path" "$d/log")"
  check "and shows what changed in it" "1" "$(grep -cF '+new line' "$d/log")"
done

d="$WORK/t2d-current"
ledger_fixture "$d" bbbbbbb
printf '%s\n' '{ "truncated": false, "tree": [' \
  '{ "type": "blob", "path": "usr/lib/sysctl.d/tuning.conf" },' \
  '{ "type": "blob", "path": "usr/lib/modprobe.d/gpu.conf" },' \
  '{ "type": "tree", "path": "usr/bin" },' \
  '{ "type": "blob", "path": "usr/bin/tool" } ] }' >"$WORK/tree.json"
STUB_CURL_FILE="$WORK/commit.json" STUB_CURL_TREE_FILE="$WORK/tree.json" run_update "$d"
check "a ledger that lists every upstream file is a clean no-op" "0 false" "$RC $(get "$d" updated)"

printf '%s\n' '{ "truncated": false, "tree": [' \
  '{ "type": "blob", "path": "usr/lib/sysctl.d/tuning.conf" },' \
  '{ "type": "blob", "path": "usr/lib/modprobe.d/gpu.conf" },' \
  '{ "type": "blob", "path": "usr/lib/unlisted.conf" } ] }' >"$WORK/tree.json"
STUB_CURL_FILE="$WORK/commit.json" STUB_CURL_TREE_FILE="$WORK/tree.json" run_update "$d"
check "a ledger that does not match upstream fails as a config error" "1 config-error" "$RC $(get "$d" error_type)"
check "naming the file upstream has and the ledger lacks" "1" "$(grep -cF 'upstream has it, the ledger does not: usr/lib/unlisted.conf' "$d/log")"
check "and the file the ledger has and upstream lacks" "1" "$(grep -cF 'the ledger has it, upstream does not: usr/bin/tool' "$d/log")"

printf '{ "truncated": true, "tree": [] }\n' >"$WORK/tree.json"
STUB_CURL_FILE="$WORK/commit.json" STUB_CURL_TREE_FILE="$WORK/tree.json" run_update "$d"
check "a tree GitHub cut short is refused, not read as complete" "1 config-error" "$RC $(get "$d" error_type)"

d="$WORK/t2d-other-host"
ledger_fixture "$d" aaaaaaa
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "git-ls-remote", "url": "u", "branch": "main" },
  "trackOnly": true, "trackFile": "upstream-version.json", "trackKey": "commit",
  "packageFile": null, "hashes": [], "verify": { "check": "eval" } }
JSON
STUB_GIT_REV="0bc68ab1962d62e66251a43a5b076f3c470b4189" run_update "$d"
check "a ledger on an upstream GitHub cannot compare is a config error" "1 config-error" "$RC $(get "$d" error_type)"

# ---- Test 2c: a retried ls-remote leaves the captured commit clean ---------
echo "Test 2c: one failed ls-remote, then the retry -> clean commit, clean outputs"
d="$WORK/t2c"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "git-ls-remote", "url": "u", "branch": "main" },
  "trackOnly": true, "trackFile": "upstream-version.json", "trackKey": "commit",
  "packageFile": null, "hashes": [], "verify": { "check": "eval" } }
JSON
printf '{ "commit": "aaaaaaa", "date": "x" }\n' >"$d/upstream-version.json"
: >"$d/.git-fail-once"
STUB_GIT_REV="0bc68ab1962d62e66251a43a5b076f3c470b4189" STUB_GIT_FAIL_ONCE="$d/.git-fail-once" run_update "$d"
check "the stubbed ls-remote failure was consumed" "no" "$([ -e "$d/.git-fail-once" ] && echo yes || echo no)"
check "drift exits 1" "1" "$RC"
check "new_version is the commit, not a log line" "0bc68ab" "$(get "$d" new_version)"
check "every output line is key=value" "0" "$(grep -cvE '^[a-z_]+=' "$d/out.env")"
check "the retry is still in the log" "1" "$(grep -c 'Retry 1/3' "$d/log")"

# ---- Test 2d: the two writers of the default branch share one queue --------
echo "Test 2d: callers/update.yml and callers/maintenance.yml name one concurrency group"
group_of() { sed -n '/^concurrency:/,/^[^ ]/s/^  group: //p' "$1"; }
ugroup=$(group_of "$STD/callers/update.yml")
mgroup=$(group_of "$STD/callers/maintenance.yml")
check "update.yml names a concurrency group" "yes" "$([ -n "$ugroup" ] && echo yes || echo no)"
check "maintenance.yml queues behind update.yml's group" "$ugroup" "$mgroup"
check "the group is not per workflow" "no" "$(grep -qF 'github.workflow' <<<"$ugroup" && echo yes || echo no)"

# ---- Test 3: rev-only keeps version, bumps rev + JSON-resident hash --------
echo "Test 3: rev-only preserves version, writes rev + version.json hash"
d="$WORK/t3"
mkdir -p "$d/.github"
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
check "rev-only exits 0" "0" "$RC"
check "marketing version kept" "26.2.0-devel" "$(jq -r .version "$d/version.json")"
check "rev bumped" "$NEWREV" "$(jq -r .rev "$d/version.json")"
check "JSON-resident hash written" "$NEWHASH" "$(jq -r .hash "$d/version.json")"
check "new_version is short rev" "new1111" "$(get "$d" new_version)"

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
d="$WORK/t4"
mkdir -p "$d/.github" "$d/_out/bin" "$d/_out/lib"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "git-ls-remote", "url": "u", "branch": "main" },
  "packageFile": "version.json", "versionScheme": "rev-only",
  "hashes": [], "verify": { "check": "elf" } }
JSON
printf '{ "rev": "old0000000000000000000000000000000000000a", "version": "1.0", "date": "x" }\n' >"$d/version.json"
printf '#!/bin/sh\necho wrapper\n' >"$d/_out/bin/qemu-ga" # non-ELF, scanned first
printf '\177ELF\002\001\001\0' >"$d/_out/lib/libqemu.so"  # real ELF magic, in lib/
chmod +x "$d/_out/bin/qemu-ga"
ln -s _out "$d/result" # nix build => symlink, not a dir
: >"$d/.nixflag"       # make the nix-build stub succeed
STUB_GIT_REV="new2222222222222222222222222222222222222c" run_update "$d"
check "elf verify passes (exit 0)" "0" "$RC"
check "update recorded" "true" "$(get "$d" updated)"
check "no verification-error" "" "$(get "$d" error_type)"

# ---- Test 4b: elf verify fails cleanly when NO ELF exists anywhere ---------
echo "Test 4b: elf verify fails when no ELF artifact is present"
d="$WORK/t4b"
mkdir -p "$d/.github" "$d/_out/bin" "$d/_out/lib"
cp "$WORK/t4/.github/update.json" "$d/.github/update.json"
printf '{ "rev": "old0000000000000000000000000000000000000a", "version": "1.0", "date": "x" }\n' >"$d/version.json"
printf '#!/bin/sh\necho only-a-script\n' >"$d/_out/bin/qemu-ga" # non-ELF; lib/ stays empty
chmod +x "$d/_out/bin/qemu-ga"
ln -s _out "$d/result"
: >"$d/.nixflag"
STUB_GIT_REV="new2222222222222222222222222222222222222c" run_update "$d"
check "no-ELF exits 1" "1" "$RC"
check "error_type verification-error" "verification-error" "$(get "$d" error_type)"

# ---- Test 5: first-party convention (none + self owner) is a clean no-op ----
# Owner-authored software declares upstream {type:none, owner:<self>}: the repo
# IS the upstream, so there is nothing to poll. The extra owner field must not
# trip the updater -- it must take the plain `none` branch and exit 0 cleanly,
# writing nothing. Guards the first-party convention against a future regression
# that starts treating a none-type's owner as something to fetch.
echo "Test 5: first-party (none + self owner) -> no-op, exit 0"
d="$WORK/t5"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "none", "owner": "Daaboulex", "repo": "x" },
  "packageFile": "flake.nix", "hashes": [], "verify": { "check": "wrapper" } }
JSON
run_update "$d"
check "first-party exits 0" "0" "$RC"
check "updated=false" "false" "$(get "$d" updated)"
check "no error_type" "" "$(get "$d" error_type)"

# ---- Tests 6-8: heal-overlays.sh boundary behavior --------------------------
# The probe path needs a real flake + nix; these tests pin the fail-closed
# boundaries that need neither: no dir is a clean no-op, an empty dir and a
# malformed fix are hard errors.
HEAL="$STD/heal-overlays.sh"
run_heal() {
  (cd "$1" && GITHUB_OUTPUT="$1/out.env" bash "$HEAL" >"$1/log" 2>&1)
  RC=$?
}
geth() { grep "^$2=" "$1/out.env" 2>/dev/null | tail -1 | cut -d= -f2-; }

echo "Test 6: heal-overlays without overlays/ -> clean no-op, exit 0"
d="$WORK/t6"
mkdir -p "$d"
run_heal "$d"
check "no-dir exits 0" "0" "$RC"
check "healed empty" "" "$(geth "$d" healed)"

echo "Test 7: heal-overlays with empty overlays/ -> fail closed, exit 1"
d="$WORK/t7"
mkdir -p "$d/overlays"
run_heal "$d"
check "empty dir exits 1" "1" "$RC"

echo "Test 7b: a fix and the files it owns are one unit, and only a file of the unit may name one of them"
d="$WORK/t7b"
mkdir -p "$d/overlays" "$d/docs"
printf 'pin = importJSON ../pin.json;\n' >"$d/overlays/pinned.nix"
printf '{ }\n' >"$d/pin.json"
printf '{ }\n' >"$d/overlays/linked.nix"
printf 'See [overlays/linked.nix](../overlays/linked.nix).\n' >"$d/docs/notes.md"
printf 'overlays/linked.nix\n' >"$d/scratch.txt"
git -C "$d" init -q
git -C "$d" add overlays pin.json docs
unit() {
  (cd "$d" && git ls-files -z | bash "$STD/scripts/check-fix-unit.sh" "$@" >"$d/out" 2>&1)
  RC=$?
}
unit overlays/pinned.nix pin.json
check "a fix that owns the pin it reads passes" "0" "$RC"
unit overlays/linked.nix
check "a tracked file naming the fix is refused once per line with the value and the rule; an untracked one is not read" "1 1 0" \
  "$RC $(grep -c '^docs/notes.md:1: names overlays/linked.nix, a file of the temporary fix overlays/linked.nix; only the fix and the files its meta.owns names may name one' "$d/out") $(grep -c scratch.txt "$d/out")"
unit overlays/linked.nix docs/notes.md
check "a file the fix owns may name it" "0" "$RC"
unit overlays/pinned.nix pin.json absent.json
check "an owned file that is not tracked is refused by name" "1 1" "$RC $(grep -c '^overlays/pinned.nix: absent.json is not a tracked file' "$d/out")"

echo "Test 7c: heal-overlays keeps its scratch files in a directory of its own under TMPDIR and removes it"
d="$WORK/t7c"
mkdir -p "$d/overlays" "$d/bin" "$d/tmp"
cat >"$d/bin/nix" <<'SH'
#!/usr/bin/env bash
readlink "/proc/$$/fd/1" "/proc/$$/fd/2" >>"$STREAMS_AT"
case "$*" in
*hasDrop*) echo '{"reason":"r","added":"2026-11-27","owns":[],"hasDrop":true,"hasBuildDrop":false,"hasOverlay":true}' ;;
*) echo false ;;
esac
SH
chmod +x "$d/bin/nix"
printf '{ }\n' >"$d/overlays/kept.nix"
git -C "$d" init -q
git -C "$d" add overlays
(cd "$d" && PATH="$d/bin:$PATH" TMPDIR="$d/tmp" STREAMS_AT="$d/streams" GITHUB_OUTPUT="$d/out.env" bash "$HEAL" >"$d/log" 2>&1)
RC=$?
tmp=$(cd "$d/tmp" && pwd -P)
files=$(grep -c '^/' "$d/streams")
under=$(grep -c "^$tmp/" "$d/streams")
check "every file the probe writes is under the TMPDIR it was given, and nothing is left there" "0 1 0 0" \
  "$RC $((files > 0)) $((files - under)) $(find "$d/tmp" -mindepth 1 | wc -l)"

if command -v nix >/dev/null 2>&1; then
  echo "Test 8: heal-overlays malformed fix (no meta/dropWhen) -> fail closed, exit 1"
  d="$WORK/t8"
  mkdir -p "$d/overlays"
  echo '{ overlay = final: prev: { }; }' >"$d/overlays/broken.nix"
  run_heal "$d"
  check "malformed exits 1" "1" "$RC"

  echo "Test 8b: each fix is probed with every other fix applied, and never with itself"
  d="$WORK/t8b"
  mkdir -p "$d/overlays"
  NPH=$(nix eval --impure --raw --expr "(builtins.getFlake \"$STD\").inputs.nixpkgs.outPath")
  cat >"$d/flake.nix" <<NIX
{
  inputs.nixpkgs.url = "path:$NPH";
  outputs = { self, nixpkgs }: {
    overlays.probe = _final: _prev: { marker = "glue"; };
  };
}
NIX
  cat >"$d/overlays/a.nix" <<'NIX'
{
  meta = { reason = "a is still needed; it would read healed only if it were applied to its own probe"; added = "2026-11-04"; };
  dropWhen = pkgs: builtins.match ".*[+]a.*" pkgs.marker != null;
  overlay = _final: prev: { marker = prev.marker + "+a"; };
}
NIX
  cat >"$d/overlays/b.nix" <<'NIX'
{
  meta = { reason = "b is healed once the other fixes stand, which a probe without them cannot see"; added = "2026-11-04"; };
  dropWhen = pkgs: builtins.match ".*[+]a.*" pkgs.marker != null;
  overlay = _final: prev: { marker = prev.marker + "+b"; };
}
NIX
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@localhost commit -qm fixture
  run_heal "$d"
  check "the probe runs" "0" "$RC"
  check "a fix healed beside the others is dropped" "b" "$(geth "$d" healed)"
  check "a fix is never judged with itself applied" "a" "$(geth "$d" kept)"

  echo "Test 8c: a healed fix is removed together with every file its meta.owns names"
  d="$WORK/t8c"
  mkdir -p "$d/overlays"
  cp "$WORK/t8b/flake.nix" "$d/flake.nix"
  printf '{ "rev": "1" }\n' >"$d/pin.json"
  cat >"$d/overlays/pinned.nix" <<'NIX'
{
  meta = { reason = "pinned reads a pin of its own, which has no use once the fix heals"; added = "2026-11-27"; owns = [ "pin.json" ]; };
  dropWhen = _pkgs: true;
  overlay = _final: _prev: { pin = (builtins.fromJSON (builtins.readFile ../pin.json)).rev; };
}
NIX
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@localhost commit -qm fixture
  run_heal "$d"
  check "the healed fix and the pin it owns are removed in one change" "0 pinned overlays/pinned.nix pin.json" \
    "$RC $(geth "$d" healed) $(git -C "$d" diff --cached --name-only | tr '\n' ' ' | sed 's/ $//')"

  echo "Test 8d: a fix that a file outside it names fails the heal before anything is removed"
  d="$WORK/t8d"
  mkdir -p "$d/overlays" "$d/docs"
  cp "$WORK/t8b/flake.nix" "$d/flake.nix"
  cat >"$d/overlays/linked.nix" <<'NIX'
{
  meta = { reason = "linked is named by a doc, which would point at nothing once the heal removed it"; added = "2026-11-27"; };
  dropWhen = _pkgs: true;
  overlay = _final: _prev: { };
}
NIX
  printf 'See [the fix](../overlays/linked.nix).\n' >"$d/docs/notes.md"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@localhost commit -qm fixture
  run_heal "$d"
  check "the heal fails closed, names the reference and removes nothing" "1 1 " \
    "$RC $(grep -c '^::error::docs/notes.md:1: names overlays/linked.nix' "$d/log") $(git -C "$d" diff --cached --name-only)"

  echo "Test 8e: fleet-audit names a fix that a file outside it names"
  d="$WORK/t8e"
  mkdir -p "$d/repos"
  git clone -q "$WORK/t8d" "$d/repos/linked"
  git -C "$d/repos/linked" remote remove origin
  (cd "$d" && PKG_REPOS_DIR="$d/repos" bash "$STD/scripts/fleet-audit.sh" --local --no-build linked >"$d/log" 2>&1)
  check "the audit names the file, its line and the fix it names" "1" \
    "$(grep -c '^FAIL  linked: docs/notes.md:1: names overlays/linked.nix, a file of the temporary fix overlays/linked.nix' "$d/log")"
else
  echo "Test 8 skipped (nix unavailable)"
fi

# ---- Test 9: pythonRequirements auto-add above the marker -------------------
# A new upstream requirement (dasbus) whose normalized name exists as a
# python3Packages attr (nix eval stub answers true) is inserted above the
# marker; a requirement already in the env list (loguru) is left alone.
echo "Test 9: pythonRequirements auto-add inserts new dep above marker"
d="$WORK/t9"
mkdir -p "$d/.github"
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
check "update exits 0" "0" "$RC"
check "updated=true" "true" "$(get "$d" updated)"
check "auto_added=dasbus" "dasbus" "$(get "$d" auto_added)"
check "dasbus sits above the marker" "dasbus" \
  "$(grep -B1 'std:requirements-auto-add' "$d/env.nix" | head -1 | tr -d ' ')"
check "loguru not duplicated" "1" "$(grep -c 'loguru' "$d/env.nix")"

# ---- Tests 10-11: classify-build-failure.sh ---------------------------------
CLASSIFY="$STD/classify-build-failure.sh"
RETRY="$STD/retry-transient.sh"
LATEST_RUN="$STD/scripts/latest-worked-run.jq"
EVAL="$STD/evaluate-every-system.sh"
ROLL="$STD/scripts/fleet-roll.sh"
SHRINK="$STD/scripts/check-baselines-shrink.sh"
ASSIST="$STD/scripts/check-assistant-files.sh"
SECTIONS="$STD/scripts/check-readme-sections.sh"
run_classify() {
  (GITHUB_OUTPUT="$1/out.env" bash "$CLASSIFY" "$2" >"$1/clog" 2>&1)
  RC=$?
}

echo "Test 10: classifier names hash-mismatch and extracts every failed drv"
d="$WORK/t10"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error: Cannot build '/nix/store/aaaa-foo-1.0.drv'.
some noise
hash mismatch in fixed-output derivation '/nix/store/bbbb-src.drv'
error: Cannot build '/nix/store/cccc-bar-2.0.drv'.
ERROR:nix_fast_build:Failed attributes: .#checks.x86_64-linux.package-foo .#checks.x86_64-linux.package-bar
LOG
run_classify "$d" "$d/build.log"
check "classifier exits 0" "0" "$RC"
check "class hash-mismatch" "upstream-rerelease-hash-mismatch" "$(get "$d" class)"
check "both failed drvs listed" "2" "$(get "$d" failed_drvs | tr ' ' '\n' | grep -c drv)"
check "failed attrs captured" ".#checks.x86_64-linux.package-foo .#checks.x86_64-linux.package-bar" "$(get "$d" failed_attrs)"

echo "Test 11: classifier fail-safe on a missing log -> unclassified"
d="$WORK/t11"
mkdir -p "$d"
: >"$d/out.env"
run_classify "$d" "$d/nope.log"
check "missing log exits 0" "0" "$RC"
check "class unclassified" "unclassified" "$(get "$d" class)"

echo "Test 11b: an evaluation failure is named eval-error, a clean evaluation is not"
d="$WORK/t11b"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
       error: Failed assertions:
       - The `nixfmt-rfc-style` hook has been removed. Use `hooks.nixfmt` instead.
ERROR:nix_fast_build:EVAL: 10 successes, 2 failures
ERROR:nix_fast_build:Failed attributes: .#checks.x86_64-linux.std-devshell-order .#checks.x86_64-linux.pre-commit
LOG
run_classify "$d" "$d/build.log"
check "class eval-error" "eval-error" "$(get "$d" class)"
: >"$d/out.env"
printf 'ERROR:nix_fast_build:EVAL: 12 successes, 0 failures\n' >"$d/build.log"
run_classify "$d" "$d/build.log"
check "zero evaluation failures is not eval-error" "unclassified" "$(get "$d" class)"

echo "Test 11c: a build that downloads inside the sandbox is sandbox-download, even beside a DNS error"
d="$WORK/t11c"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
eden> -- [CPMUtil] Using bundled package zbic@11b08f2712264bbed731545085cbd9702096ceb7
eden>   status: [6;"Could not resolve hostname"]
eden> CMake Error at CMakeModules/CPMUtil.cmake:190 (file):
eden>   file DOWNLOAD cannot compute hash on failed download
LOG
run_classify "$d" "$d/build.log"
check "class sandbox-download" "sandbox-download" "$(get "$d" class)"

echo "Test 11d: a build that fetched its crates and then failed is not transient; a refused fetch is"
d="$WORK/t11d"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
libc> trying https://static.crates.io/crates/libc/libc-0.2.177.crate
libc> curl: (22) The requested URL returned error: 403
libc> trying https://crates.io/api/v1/crates/libc/0.2.177/download
warning: unable to download 'https://cache.nixos.org/aaaa.narinfo': HTTP error 503 (curl error: HTTP response code said error); retrying in 266 ms
mesa> meson.build:21:0: ERROR: Value "true" for option "amd-options" is not in allowed choices: "use-llvm, virtio"
error: Cannot build '/nix/store/llll-mesa-27.0.0-devel-e6d7ecc.drv'.
LOG
run_classify "$d" "$d/build.log"
check "a refusal a working mirror or a retry recovered from does not make a real failure transient" "unclassified" "$(get "$d" class)"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
libc> trying https://static.crates.io/crates/libc/libc-0.2.177.crate
libc>   % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
libc> curl: (22) The requested URL returned error: 403
libc> error: cannot download libc-0.2.177.tar.gz from any mirror
error: Cannot build '/nix/store/mmmm-libc-0.2.177.tar.gz.drv'.
LOG
run_classify "$d" "$d/build.log"
check "a crate fetch crates.io refused is transient" "transient-infra" "$(get "$d" class)"
: >"$d/out.env"
printf '%s\n' "error: unable to download 'https://static.crates.io/crates/libc/libc-0.2.177.crate': HTTP error 429" >"$d/build.log"
run_classify "$d" "$d/build.log"
check "nix's own crates.io 429 is transient" "transient-infra" "$(get "$d" class)"
: >"$d/out.env"
printf '%s\n' "error: unable to download 'https://example.org/x.tar.gz': Timeout was reached (28)" >"$d/build.log"
run_classify "$d" "$d/build.log"
check "nix's own network timeout is transient" "transient-infra" "$(get "$d" class)"
: >"$d/out.env"
printf '%s\n' "error: unable to download 'https://example.org/x.tar.gz': HTTP error 503" >"$d/build.log"
run_classify "$d" "$d/build.log"
check "an HTTP 503 is transient" "transient-infra" "$(get "$d" class)"
: >"$d/out.env"
printf '%s\n' "error: unable to download 'https://example.org/x.tar.gz': HTTP error 404" >"$d/build.log"
run_classify "$d" "$d/build.log"
check "an HTTP 404 is not transient, it is a source that is gone" "source-not-found" "$(get "$d" class)"
check "and its evidence names the URL" "error: unable to download 'https://example.org/x.tar.gz': HTTP error 404" "$(get "$d" evidence)"

echo "Test 11e: an evaluation that needed a derivation built is import-from-derivation, not a transient store race"
d="$WORK/t11e"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error:
       error: path 'kppsfygrz2j6arlffj8dq6jx0zgprs36-written.drv' is not valid
evaluate-every-system: import from derivation: path 'kppsfygrz2j6arlffj8dq6jx0zgprs36-written.drv' is not valid. Something reads a derivation output while evaluating
LOG
run_classify "$d" "$d/build.log"
check "class import-from-derivation" "import-from-derivation" "$(get "$d" class)"
: >"$d/out.env"
printf '%s\n' "error: path '/nix/store/aaaa-foo' is not valid" >"$d/build.log"
run_classify "$d" "$d/build.log"
check "a store path missing during a build stays transient-infra" "transient-infra" "$(get "$d" class)"

with_escapes() { sed 's/\^\[/\x1b/g'; }

echo "Test 11f: a source that returns 404 is source-not-found, with the URL of the failing builder as evidence"
d="$WORK/t11f"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
source> trying https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton8-32/GE-Proton8-32.tar.gz
source> trying https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-14/GE-Proton11-14.tar.gz
source> trying https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton7-55/GE-Proton7-55.tar.gz
source> curl: (22) The requested URL returned error: 404
source> Warning: Problem (retrying all errors). Retrying in 1 second. 3 retries left.
source> unpacking source archive /build/GE-Proton8-32.tar.gz
source> curl: (22) The requested URL returned error: 404
source> error: cannot download source from any mirror
error: Cannot build '/nix/store/bpdbvak1dnsf2zki2g5805lp987pxjbf-source.drv'.
       Reason: builder failed with exit code 1.
       Output paths:
         /nix/store/b5szxi1hcn4yx43ml0mwmpjbc58csh92-source
       Last 20 log lines:
       >
       > trying https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-14/GE-Proton11-14.tar.gz
       >   % Total    % Received % Xferd  Average Speed  Time    Time    Time   Current
       >                                  Dload  Upload  Total   Spent   Left   Speed
       >
       >   0      0   0      0   0      0      0      0                              0
       > curl: (22) The requested URL returned error: 404
       > Warning: Problem (retrying all errors). Retrying in 1 second. 3 retries left.
       >
       >   0      0   0      0   0      0      0      0                              0
       > curl: (22) The requested URL returned error: 404
       > error: cannot download source from any mirror
       For full logs, run:
         nix log /nix/store/bpdbvak1dnsf2zki2g5805lp987pxjbf-source.drv
error: Cannot build '/nix/store/flwn45qrsvgs037w4zkfvnvpy9w4h9mz-proton-ge-GE-Proton11-14.drv'.
       Reason: 1 dependency failed.
LOG
run_classify "$d" "$d/build.log"
check "a source that 404s has its own class" "source-not-found" "$(get "$d" class)"
check "the evidence is the URL the failing builder tried, not one a builder beside it fetched" \
  "> trying https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-14/GE-Proton11-14.tar.gz" "$(get "$d" evidence)"

echo "Test 11g: an evaluation error quotes its last error: line, not the first frame of its trace"
d="$WORK/t11g"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error:
       … while calling the 'derivationStrict' builtin
         at «nix-internal»/derivation-internal.nix:38:12:
           37|
           38|   strict = drvFunc drvAttrs;
             |            ^
           39|

       … while evaluating derivation 'eden-0.2.1-unstable-2026-11-24'
         whose name attribute is located at «github:NixOS/nixpkgs/2786a2a»/pkgs/stdenv/generic/make-derivation.nix:651:11

       … while evaluating attribute 'preConfigure' of derivation 'eden-0.2.1-unstable-2026-11-24'
         at /home/runner/work/eden-nix/eden-nix/package.nix:159:3:
          158|
          159|   preConfigure = ''
             |   ^
          160|     export CPM_SOURCE_CACHE=$PWD/.cache/cpm

       (stack trace truncated; use '--show-trace' to show the full, detailed trace)

       error: expected a Boolean but found a string: "true"
       at /home/runner/work/eden-nix/eden-nix/deps/default.nix:5:27:
            4|   manifest = lib.importJSON ./cpmfile.json;
            5|   fetchable = _: entry: !(entry.ci or false);
             |                           ^
            6|   version =
::error::The build failed before the source was fetched, so no new hash exists
LOG
run_classify "$d" "$d/build.log"
check "class eval-error" "eval-error" "$(get "$d" class)"
check "the evidence is the last error: line of the trace" 'error: expected a Boolean but found a string: "true"' "$(get "$d" evidence)"

echo "Test 11h: the step that failed names the class, and a pattern only refines it"
d="$WORK/t11h"
mkdir -p "$d"
: >"$d/out.env"
printf 'error: Cannot build %s.\nsomething nobody has a pattern for\n' "'/nix/store/kkkk-x.drv'" >"$d/build.log"
(GITHUB_OUTPUT="$d/out.env" bash "$CLASSIFY" "$d/build.log" build-error >"$d/clog" 2>&1)
check "a failure no pattern knows keeps the class of the step that failed" "build-error" "$(get "$d" class)"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error:
       … while evaluating attribute 'cargo_deps'
         at /nix/store/jr5xyi8j278ax1c55ivd3qgmfjxi2y94-nix-update-1.16.0/lib/python3.14/site-packages/nix_update/eval.nix:128:3:
          127|   go_modules_old = pkg.go-modules.outputHash or null;
          128|   cargo_deps = pkg.cargoDeps.outputHash or null;
             |   ^
          129|   cargo_vendor_deps = pkg.cargoDeps.vendorStaging.outputHash or null;

       … while evaluating a branch condition
         at /nix/store/jr5xyi8j278ax1c55ivd3qgmfjxi2y94-nix-update-1.16.0/lib/python3.14/site-packages/nix_update/eval.nix:57:7:
           56|       in
           57|       if packagesResult.success then packagesResult.value else (tryGetAttrPath attributePath flake).value
             |       ^
           58|     else

       (stack trace truncated; use '--show-trace' to show the full, detailed trace)

       error: opening file "/nix/store/0yn6db264w1lmpybqirmi7inkya372q7-source": No such file or directory
$ nix-instantiate --eval --json --strict /nix/store/jr5xyi8j278ax1c55ivd3qgmfjxi2y94-nix-update-1.16.0/lib/python3.14/site-packages/nix_update/eval.nix
fetch https://github.com/BurntSushi/ripgrep/releases.atom
Update 15.2.0 -> 16.0.0 in package.nix
Traceback (most recent call last):
subprocess.CalledProcessError: Command '['nix-instantiate', '--eval', '--json', '--strict']' returned non-zero exit status 1.
::error::nix-update failed
LOG
(GITHUB_OUTPUT="$d/out.env" bash "$CLASSIFY" "$d/build.log" updater-error >"$d/clog" 2>&1)
check "an evaluation failure inside the updater is refined to eval-error" "eval-error" "$(get "$d" class)"
check "and quotes the line that says what failed" 'error: opening file "/nix/store/0yn6db264w1lmpybqirmi7inkya372q7-source": No such file or directory' "$(get "$d" evidence)"
: >"$d/out.env"
(GITHUB_OUTPUT="$d/out.env" bash "$CLASSIFY" "$d/missing.log" updater-error >"$d/clog" 2>&1)
check "a missing log still carries the class of the step that failed" "updater-error" "$(get "$d" class)"

echo "Test 11i: in an update a fixed-output hash mismatch is a hash the updater missed"
d="$WORK/t11i"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
coolercontrol-ui> patching script interpreter paths in /nix/store/svlm5j8n8l6l2ll9x0apl2zcwi5m25i4-coolercontrol-ui-5.1.2-npm-deps
error: hash mismatch in fixed-output derivation '/nix/store/7jbm6zhh06w9i0kcszdwf0hhmdd7r0b4-coolercontrol-ui-5.1.2-npm-deps.drv':
         specified: sha256-hVbvYrPcqvoOGB6QTNISGbFYErLCo2MIKy+AwJLpbcc=
            got:    sha256-9zwQjaXwuzYVzTaBbIyjs/N074byZlRNntxJC0mpziw=
error: Cannot build '/nix/store/pgj15i761yambkvzbmdwks946lrgy8fn-coolercontrol-ui-5.1.2.drv'.
       Reason: 1 dependency failed.
LOG
(GITHUB_OUTPUT="$d/out.env" bash "$CLASSIFY" --update "$d/build.log" build-error >"$d/clog" 2>&1)
check "the updater missed a hash" "updater-missed-hash" "$(get "$d" class)"
check "the failing drvs are still listed" "/nix/store/pgj15i761yambkvzbmdwks946lrgy8fn-coolercontrol-ui-5.1.2.drv" "$(get "$d" failed_drvs)"
: >"$d/out.env"
run_classify "$d" "$d/build.log"
check "outside an update the same mismatch keeps its name" "upstream-rerelease-hash-mismatch" "$(get "$d" class)"

echo "Test 11j: a failing check of the repo's own, with no package failing, is check-error"
d="$WORK/t11j"
mkdir -p "$d"
: >"$d/out.env"
with_escapes >"$d/build.log" <<'LOG'
^[[2mopenwrt-series-applies>^[[0m applying 0008-mac80211-brcmfmac-enable-2.4-ghz-vht-on-bcm4366.patch
^[[2mopenwrt-series-applies>^[[0m patching file package/kernel/mac80211/Makefile
^[[2mopenwrt-series-applies>^[[0m Hunk #1 FAILED at 12.
^[[2mopenwrt-series-applies>^[[0m 1 out of 1 hunk FAILED -- saving rejects to file package/kernel/mac80211/Makefile.rej
^[[2mopenwrt-series-applies>^[[0m does not apply to this OpenWrt tree without fuzz, rebase it: 0008-mac80211-brcmfmac-enable-2.4-ghz-vht-on-bcm4366.patch
^[[2mopenwrt-series-applies>^[[0m ^[[31;1merror:^[[0m Cannot build '^[[35;1m/nix/store/3wgchy0rrd2ba67vkryrad0qm6hrvhhn-openwrt-series-applies.drv^[[0m'.^[[0m
^[[2mopenwrt-series-applies>^[[0m        Reason: ^[[31;1mbuilder failed with exit code 1^[[0m.^[[0m
WARNING:nix_fast_build.build:build openwrt-series-applies exited with 1 (attempt 1/1)
ERROR:nix_fast_build:BUILD: 10 successes, 1 failures
ERROR:nix_fast_build:Failed attributes: .#checks.aarch64-linux.openwrt-series-applies
LOG
(GITHUB_OUTPUT="$d/out.env" bash "$CLASSIFY" "$d/build.log" build-error >"$d/clog" 2>&1)
check "a patch that no longer applies in the repo's own check is check-error" "check-error" "$(get "$d" class)"
: >"$d/out.env"
printf '%s\n' 'ERROR:nix_fast_build:Failed attributes: .#checks.aarch64-linux.openwrt-series-applies .#checks.aarch64-linux.package-openwrt-build' >>"$d/build.log"
(GITHUB_OUTPUT="$d/out.env" bash "$CLASSIFY" "$d/build.log" build-error >"$d/clog" 2>&1)
check "a failing package beside it keeps the build class" "build-error" "$(get "$d" class)"

echo "Test 11k: lines carrying the attribute prefix nix-fast-build writes are read, Nix's own lines only"
d="$WORK/t11k"
mkdir -p "$d"
: >"$d/out.env"
with_escapes >"$d/build.log" <<'LOG'
^[[2mpackage-scx-git-full>^[[0m curl: (22) The requested URL returned error: 429
^[[2mpackage-scx-git-full>^[[0m Fetching https://static.crates.io/crates/windows-targets/0.48.5/download -> /nix/store/nh8wxvkrmc4za82817jdsrpm0ssgfypb-scx-git-1.1.4-unstable-2026-11-10-vendor-staging
^[[2mpackage-scx-git-full>^[[0m error: cannot download libbpf-linux-types-u128.patch from any mirror
^[[2mpackage-scx-git-full>^[[0m ^[[31;1merror:^[[0m Cannot build '^[[35;1m/nix/store/qw1m8jnzy32gkqxk23zsb8n93bcwk4k9-libbpf-linux-types-u128.patch.drv^[[0m'.^[[0m
^[[2mpackage-scx-git-full>^[[0m        Reason: ^[[31;1mbuilder failed with exit code 1^[[0m.^[[0m
^[[2mpackage-scx-git-full>^[[0m        Output paths:
^[[2mpackage-scx-git-full>^[[0m          ^[[35;1m/nix/store/0h0c14pmdcvv7g98ffbpyi7i92nyzj97-libbpf-linux-types-u128.patch^[[0m^[[0m
^[[2mpackage-scx-git-full>^[[0m        Last 20 log lines:
^[[2mpackage-scx-git-full>^[[0m        > trying https://github.com/libbpf/libbpf/commit/f90a9c487d7542d91fa584b83b6a624a4fbeb341.patch
^[[2mpackage-scx-git-full>^[[0m        > curl: (22) The requested URL returned error: 429
^[[2mpackage-scx-git-full>^[[0m        > Warning: Problem : HTTP error. Retrying in 1 second. 3 retries left.
^[[2mpackage-scx-git-full>^[[0m        > curl: (22) The requested URL returned error: 429
^[[2mpackage-scx-git-full>^[[0m        > error: cannot download libbpf-linux-types-u128.patch from any mirror
^[[2mpackage-scx-git-full>^[[0m        For full logs, run:
^[[2mpackage-scx-git-full>^[[0m          ^[[1mnix log /nix/store/qw1m8jnzy32gkqxk23zsb8n93bcwk4k9-libbpf-linux-types-u128.patch.drv^[[0m^[[0m
^[[2mpackage-scx-git-full>^[[0m Fetching https://static.crates.io/crates/windows-targets/0.52.6/download -> /nix/store/nh8wxvkrmc4za82817jdsrpm0ssgfypb-scx-git-1.1.4-unstable-2026-11-10-vendor-staging
^[[2mpackage-scx-git-full>^[[0m ^[[31;1merror:^[[0m Cannot build '^[[35;1m/nix/store/b5j4pkwxandz7qm0szsbzs36rd452did-scx-git-full-1.1.4-unstable-2026-11-10.drv^[[0m'.^[[0m
^[[2mpackage-scx-git-full>^[[0m        Reason: 1 dependency failed.
WARNING:nix_fast_build.build:build package-scx-git-full exited with 1 (attempt 1/1)
ERROR:nix_fast_build:BUILD: 12 successes, 1 failures
ERROR:nix_fast_build:Failed attributes: .#checks.aarch64-linux.package-scx-git-full
LOG
run_classify "$d" "$d/build.log"
check "a 429 inside a failed attribute's Nix block is transient" "transient-infra" "$(get "$d" class)"
: >"$d/out.env"
with_escapes >"$d/build.log" <<'LOG'
^[[2mpackage-mesa>^[[0m trying https://static.crates.io/crates/libc/libc-0.2.177.crate
^[[2mpackage-mesa>^[[0m curl: (22) The requested URL returned error: 429
^[[2mpackage-mesa>^[[0m meson.build:21:0: ERROR: Value "true" for option "amd-options" is not in allowed choices: "use-llvm, virtio"
^[[2mpackage-mesa>^[[0m ^[[31;1merror:^[[0m Cannot build '^[[35;1m/nix/store/llll-mesa-27.0.0-devel-e6d7ecc.drv^[[0m'.^[[0m
^[[2mpackage-mesa>^[[0m        Reason: builder failed with exit code 1.
^[[2mpackage-mesa>^[[0m        > meson.build:21:0: ERROR: Value "true" for option "amd-options" is not in allowed choices: "use-llvm, virtio"
ERROR:nix_fast_build:Failed attributes: .#checks.x86_64-linux.package-mesa
LOG
run_classify "$d" "$d/build.log"
check "a refusal streamed by another builder of the same attribute does not make a real failure transient" "unclassified" "$(get "$d" class)"

echo "Test 11l: a job that failed and sent no log is runner-lost, whatever another job's log says"
d="$WORK/t11l"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
=== log-update
error: unable to download 'https://example.org/x.tar.gz': HTTP error 503
runner-lost: no log reached the report from the verify job that failed, so its runner stopped before the job could keep one
LOG
(GITHUB_OUTPUT="$d/out.env" bash "$CLASSIFY" --update "$d/build.log" build-error >"$d/clog" 2>&1)
check "class runner-lost" "runner-lost" "$(get "$d" class)"
check "the evidence says no log came" "runner-lost: no log reached the report from the verify job that failed, so its runner stopped before the job could keep one" "$(get "$d" evidence)"

echo "Test 12: two source hashes are unattributable -> config-error before any fetch"
d="$WORK/t12"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^[0-9]" },
  "packageFile": "package.nix", "hashes": [ "hashX64", "hashArm64" ], "verify": { "check": "eval" } }
JSON
printf 'version = "2026.1";\nhashX64 = "sha256-a";\nhashArm64 = "sha256-b";\n' >"$d/package.nix"
STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" run_update "$d"
check "two source hashes exit 1" "1" "$RC"
check "error_type config-error" "config-error" "$(get "$d" error_type)"
check "failed before version read" "" "$(get "$d" old_version)"

echo "Test 12b: one source hash alongside vendor hashes stays allowed"
d="$WORK/t12b"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^[0-9]" },
  "packageFile": "version.json",
  "hashes": [ "hash", "cargoHash", "vendorHash", "npmDepsHash" ], "verify": { "check": "eval" } }
JSON
printf '{ "version": "2026.2", "rev": "x", "hash": "sha256-x", "date": "x" }\n' >"$d/version.json"
STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" run_update "$d"
check "source plus vendor hashes accepted" "0" "$RC"
check "no config error" "" "$(get "$d" error_type)"

echo "Test 12c: a bare hash field set in two files is refused before any fetch"
d="$WORK/t12c"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^[0-9]" },
  "packageFile": "package.nix", "hashes": [ "hash" ], "verify": { "check": "eval" } }
JSON
printf 'version = "2026.1";\nhash = "sha256-a";\n' >"$d/package.nix"
printf 'hash = "sha256-b";\n' >"$d/wheel.nix"
STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" run_update "$d"
check "an ambiguous bare field exits 1" "1" "$RC"
check "error_type config-error" "config-error" "$(get "$d" error_type)"
check "failed before version read" "" "$(get "$d" old_version)"
rm "$d/wheel.nix"
STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" run_update "$d"
check "the same field in one file passes validation" "2026.1" "$(get "$d" old_version)"

echo "Test 13: variantAssets with a non-empty hashes[] -> config-error"
d="$WORK/t13"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^GE-Proton" },
  "packageFile": "package.nix", "versionFile": "sources.nix",
  "variantAssets": { "sourceFile": "sources.nix", "assetPrefix": "", "assetSuffix": ".tar.gz" },
  "hashes": [ "hashX64" ], "verify": { "check": "eval" } }
JSON
printf '{\n  version = "GE-Proton11-1";\n}\n' >"$d/sources.nix"
STUB_CURL_FILE="$STD/tests/fixtures/ge-releases.json" run_update "$d"
check "mutually exclusive exit 1" "1" "$RC"
check "error_type config-error" "config-error" "$(get "$d" error_type)"

echo "Test 14: variantAssets defaultVariant captures the untagged asset"
d="$WORK/t14"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "ge",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^GE-Proton" },
  "packageFile": "package.nix", "versionFile": "sources.nix",
  "variantAssets": { "sourceFile": "sources.nix", "assetPrefix": "",
                     "assetSuffix": ".tar.gz", "defaultVariant": "x86_64" },
  "hashes": [], "verify": { "check": "eval" } }
JSON
cat >"$d/sources.nix" <<'NIX'
{
  version = "GE-Proton11-1";
  # std:variants-begin
  variants = {
    x86_64 = "sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDA=";
  };
  # std:variants-end
  pins = {
    "GE-Proton10-34" = {
      variants = {
        x86_64 = "sha256-PINPINPINPINPINPINPINPINPINPINPINPINPINPINA=";
      };
    };
  };
}
NIX
: >"$d/package.nix"
: >"$d/.nixflag"
STUB_CURL_FILE="$STD/tests/fixtures/ge-releases.json" run_update "$d"
check "run succeeds" "0" "$RC"
check "version bumped" "GE-Proton11-2" "$(get "$d" new_version)"
check "two variants regenerated" "2" "$(get "$d" variants)"
check "untagged asset -> x86_64" "1" "$(grep -A1 '^    x86_64 = {$' "$d/sources.nix" | grep -c '/GE-Proton11-2\.tar\.gz";$')"
check "tagged asset -> aarch64" "1" "$(grep -A1 '^    aarch64 = {$' "$d/sources.nix" | grep -c '/GE-Proton11-2-aarch64\.tar\.gz";$')"
check "checksum assets ignored" "0" "$(grep -c 'sha512sum' "$d/sources.nix")"
check "pins left untouched" "1" "$(grep -c 'sha256-PINPIN' "$d/sources.nix")"

echo "Test 14b: each variant keeps the URL the updater fetched beside its hash"
d="$WORK/t14b"
mkdir -p "$d/.github"
cp "$WORK/t14/.github/update.json" "$d/.github/update.json"
a="https://example.invalid/GE-Proton11-3/GE-Proton11-3-aarch64.tar.gz"
x="https://example.invalid/GE-Proton11-3/GE-Proton11-3-x86_64.tar.gz"
cat >"$d/releases.json" <<JSON
[ { "tag_name": "GE-Proton11-3", "draft": false, "prerelease": false,
    "assets": [
      { "name": "GE-Proton11-3-aarch64.tar.gz", "browser_download_url": "$a" },
      { "name": "GE-Proton11-3-x86_64.sha512sum", "browser_download_url": "$x.sha512sum" },
      { "name": "GE-Proton11-3-x86_64.tar.gz", "browser_download_url": "$x" } ] } ]
JSON
cat >"$d/sources.nix" <<'NIX'
{
  version = "GE-Proton11-2";
  # std:variants-begin
  variants = {
    x86_64 = "sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDA=";
  };
  # std:variants-end
}
NIX
cp "$d/sources.nix" "$d/sources.nix.before"
: >"$d/package.nix"
: >"$d/.nixflag"
STUB_CURL_FILE="$d/releases.json" run_update "$d"
check "run succeeds" "0" "$RC"
want=$(
  cat <<NIX
  # std:variants-begin
  variants = {
    aarch64 = {
      url = "$a";
      hash = "sha256-$(printf '%s' "$a" | sha256sum | cut -c1-43)=";
    };
    x86_64 = {
      url = "$x";
      hash = "sha256-$(printf '%s' "$x" | sha256sum | cut -c1-43)=";
    };
  };
  # std:variants-end
NIX
)
check "each variant holds its own asset's URL and hash" "$want" "$(sed -n '/std:variants-begin/,/std:variants-end/p' "$d/sources.nix")"

echo "Test 14c: an asset that names its variant wins over the untagged one"
d="$WORK/t14c"
mkdir -p "$d/.github"
cp "$WORK/t14/.github/update.json" "$d/.github/update.json"
u="https://example.invalid/GE-Proton11-3/GE-Proton11-3.tar.gz"
for order in tagged-first untagged-first; do
  tagged="{ \"name\": \"GE-Proton11-3-x86_64.tar.gz\", \"browser_download_url\": \"$x\" }"
  untagged="{ \"name\": \"GE-Proton11-3.tar.gz\", \"browser_download_url\": \"$u\" }"
  case "$order" in
  tagged-first) assets="$tagged, $untagged" ;;
  untagged-first) assets="$untagged, $tagged" ;;
  esac
  printf '[ { "tag_name": "GE-Proton11-3", "draft": false, "prerelease": false, "assets": [ %s ] } ]\n' "$assets" >"$d/releases.json"
  cp "$WORK/t14b/sources.nix.before" "$d/sources.nix"
  : >"$d/package.nix"
  : >"$d/.nixflag"
  STUB_CURL_FILE="$d/releases.json" run_update "$d"
  check "$order: run succeeds" "0" "$RC"
  check "$order: the variant is written once" "1" "$(grep -c '^    x86_64 = {$' "$d/sources.nix")"
  check "$order: from the asset that names it" "1" "$(grep -cF "url = \"$x\";" "$d/sources.nix")"
done

echo "Test 14d: a failed prefetch shows the prefetch's own error"
d="$WORK/t14d"
mkdir -p "$d/.github"
cp "$WORK/t14/.github/update.json" "$d/.github/update.json"
cp "$WORK/t14b/releases.json" "$d/releases.json"
cp "$WORK/t14b/sources.nix.before" "$d/sources.nix"
: >"$d/package.nix"
STUB_CURL_FILE="$d/releases.json" STUB_PREFETCH_FAIL=1 run_update "$d"
check "run fails" "1" "$RC"
check "error_type hash-extraction" "hash-extraction" "$(get "$d" error_type)"
check "the prefetch's own line reaches the log" "1" "$(grep -c 'stub: the prefetch says why it failed' "$d/log")"

# ---- Test 15: tagFilter match beyond the first page -------------------------
# A single-page fetch made a tracked namespace invisible when upstream pushes a
# high-volume second namespace ahead of it: CachyOS/wine-cachyos carries ~370
# rolling experimental-* tags before the newest *-wine build tag, so
# github-tag + tagFilter found nothing and failed every scheduled run.
echo "Test 15: github-tag finds a tagFilter match on a later page"
d="$WORK/t15"
mkdir -p "$d/.github" "$d/pages"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-tag", "owner": "o", "repo": "r", "tagFilter": "-wine$" },
  "packageFile": "package.nix", "versionAttr": "tag",
  "hashes": [], "verify": { "check": "eval" } }
JSON
printf 'tag = "cachyos-10.0-20260425-wine";\n' >"$d/package.nix"
jq -nc '[range(100) | {name: "experimental-\(.)"}]' >"$d/pages/page1.json"
jq -nc '[range(100) | {name: "experimental-b\(.)"}]' >"$d/pages/page2.json"
jq -nc '[{name: "experimental-c0"}, {name: "cachyos-10.0-20260425-wine"},
         {name: "cachyos-10.0-20260407-wine"}]' >"$d/pages/page3.json"
STUB_CURL_PAGE_DIR="$d/pages" run_update "$d"
check "paged tag search exits 0" "0" "$RC"
check "newest -wine tag selected" "cachyos-10.0-20260425-wine" "$(get "$d" new_version)"
check "recognised up-to-date" "false" "$(get "$d" updated)"

# ---- Test 15b: an unmatchable filter still terminates -----------------------
echo "Test 15b: no tagFilter match anywhere -> bounded, fails closed"
d="$WORK/t15b"
mkdir -p "$d/.github" "$d/pages"
cp "$WORK/t15/.github/update.json" "$d/.github/update.json"
printf 'tag = "cachyos-10.0-20260425-wine";\n' >"$d/package.nix"
jq -nc '[range(100) | {name: "experimental-\(.)"}]' >"$d/pages/page1.json"
jq -nc '[{name: "experimental-tail"}]' >"$d/pages/page2.json"
STUB_CURL_PAGE_DIR="$d/pages" run_update "$d"
check "unmatchable filter exits 1" "1" "$RC"
check "error_type no-matching-tag" "no-matching-tag" "$(get "$d" error_type)"

# ---- Test 16: standard case delegates to the nix-update shim ---------------
# A plain repo (declared hashes, literal scheme, no tagFilter / variantAssets /
# pythonRequirements / trackOnly) skips the full detection+hash path and calls
# nix-update, then the shared verification chain. NIX_UPDATE stubs the tool.
echo "Test 16: standard case delegates to the nix-update shim"
d="$WORK/t16"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r" },
  "packageFile": "package.nix", "hashes": [ "hash" ], "verify": { "check": "eval" } }
JSON
printf '{\n  version = "1.0.0";\n  hash = "sha256-old";\n}\n' >"$d/package.nix"
cat >"$BIN/fake-nix-update" <<'SH'
#!/usr/bin/env bash
sed -i 's/version = "1.0.0"/version = "1.1.0"/' package.nix
SH
chmod +x "$BIN/fake-nix-update"
: >"$d/.nixflag"
NIX_UPDATE="fake-nix-update" run_update "$d"
check "shim exit 0" "0" "$RC"
check "shim updated true" "true" "$(get "$d" updated)"
check "shim new_version" "1.1.0" "$(get "$d" new_version)"

echo "Test 16b: shim reports no update when nix-update leaves the version"
d="$WORK/t16b"
mkdir -p "$d/.github"
cp "$WORK/t16/.github/update.json" "$d/.github/update.json"
printf '{\n  version = "1.0.0";\n  hash = "sha256-old";\n}\n' >"$d/package.nix"
cat >"$BIN/fake-nix-update-noop" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/fake-nix-update-noop"
: >"$d/.nixflag"
NIX_UPDATE="fake-nix-update-noop" run_update "$d"
check "shim no-op exit 0" "0" "$RC"
check "shim no-op updated false" "false" "$(get "$d" updated)"

echo "Test 16c: shim fails when nix-update sees a newer version but rewrites nothing"
d="$WORK/t16c"
mkdir -p "$d/.github"
cp "$WORK/t16/.github/update.json" "$d/.github/update.json"
printf '{\n  version = "1.0.0";\n  hash = "sha256-old";\n}\n' >"$d/package.nix"
cat >"$BIN/fake-nix-update-elsewhere" <<'SH'
#!/usr/bin/env bash
echo "Update 1.0.0 -> 1.1.0 in /elsewhere/default.nix"
echo "No changes detected, skipping remaining steps"
SH
chmod +x "$BIN/fake-nix-update-elsewhere"
: >"$d/.nixflag"
NIX_UPDATE="fake-nix-update-elsewhere" run_update "$d"
check "shim seen-but-unwritten exit 1" "1" "$RC"
check "shim seen-but-unwritten error_type" "config-error" "$(get "$d" error_type)"
check "shim seen-but-unwritten names the version it saw" "1.1.0" "$(get "$d" new_version)"

echo "Test 16d: shim points nix-update at the version file"
d="$WORK/t16d"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r" },
  "packageFile": "flake.nix", "hashes": [ "hash" ], "verify": { "check": "eval" } }
JSON
printf '{\n  version = "1.0.0";\n  hash = "sha256-old";\n}\n' >"$d/flake.nix"
printf '{ version, src }: { inherit version src; }\n' >"$d/package.nix"
cat >"$BIN/fake-nix-update-override" <<'SH'
#!/usr/bin/env bash
file=""
while [ $# -gt 0 ]; do
  [ "$1" = "--override-filename" ] && file=$2
  shift
done
[ -n "$file" ] || { echo "no --override-filename given" >&2; exit 1; }
echo "Update 1.0.0 -> 1.1.0 in $file"
sed -i 's/version = "1.0.0"/version = "1.1.0"/' "$file"
SH
chmod +x "$BIN/fake-nix-update-override"
: >"$d/.nixflag"
NIX_UPDATE="fake-nix-update-override" run_update "$d"
check "shim with a versionFile exit 0" "0" "$RC"
check "shim with a versionFile updated true" "true" "$(get "$d" updated)"
check "shim rewrote the version file, not the package file" "1.1.0" "$(grep -oP 'version = "\K[^"]+' "$d/flake.nix")"

echo "Test 16e: shim hands every declared subpackage to nix-update"
d="$WORK/t16e"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r" },
  "packageFile": "package.nix", "hashes": [ "hash", "npmDepsHash" ], "subpackages": [ "ui", "docs" ],
  "verify": { "check": "eval" } }
JSON
printf '{\n  version = "1.0.0";\n  hash = "sha256-old";\n  npmDepsHash = "sha256-old";\n}\n' >"$d/package.nix"
cat >"$BIN/fake-nix-update-args" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >nix-update.args
sed -i 's/version = "1.0.0"/version = "1.1.0"/' package.nix
SH
chmod +x "$BIN/fake-nix-update-args"
: >"$d/.nixflag"
NIX_UPDATE="fake-nix-update-args" run_update "$d"
check "shim with subpackages exit 0" "0" "$RC"
check "each subpackage reaches nix-update" "--subpackage ui --subpackage docs" "$(grep -A1 -- '^--subpackage$' "$d/nix-update.args" | grep -v -- '^--$' | tr '\n' ' ' | sed 's/ $//')"

echo "Test 16f: a failing nix-update is named the updater's failure, and the version it saw is written before it exits"
d="$WORK/t16f"
mkdir -p "$d/.github"
cp "$WORK/t16/.github/update.json" "$d/.github/update.json"
printf '{\n  version = "15.2.0";\n  hash = "sha256-old";\n}\n' >"$d/package.nix"
cat >"$BIN/fake-nix-update-fails" <<'SH'
#!/usr/bin/env bash
echo "fetch https://github.com/BurntSushi/ripgrep/releases.atom"
echo "Update 15.2.0 -> 16.0.0 in package.nix"
sed -i 's/version = "15.2.0"/version = "16.0.0"/' package.nix
echo '       error: opening file "/nix/store/0yn6db264w1lmpybqirmi7inkya372q7-source": No such file or directory' >&2
echo "subprocess.CalledProcessError: Command '['nix-instantiate', '--eval']' returned non-zero exit status 1." >&2
exit 1
SH
chmod +x "$BIN/fake-nix-update-fails"
: >"$d/.nixflag"
NIX_UPDATE="fake-nix-update-fails" run_update "$d"
check "a failing nix-update fails the update" "1" "$RC"
check "it is named the updater's failure, not a build error" "updater-error" "$(get "$d" error_type)"
check "the version nix-update saw is the target version" "16.0.0" "$(get "$d" new_version)"

echo "Test 17: no-tracked-ignored-files check catches a tracked file inside an ignored dir"
d="$WORK/t17"
mkdir -p "$d/.claude"
(cd "$d" && git init -q && git config user.email t@t && git config user.name t &&
  printf '.claude/\n' >.gitignore && echo x >.claude/settings.json &&
  git add -f .gitignore .claude/settings.json && git commit -qm init)
GOT="$(cd "$d" && git ls-files -i -c --exclude-per-directory=.gitignore)"
check "check catches tracked+ignored file" ".claude/settings.json" "$GOT"

# ---- Tests 18: unstable-date base tracks upstream's tags --------------------
TODAY="$(date -u +%Y-%m-%d)"

echo "Test 18: unstable-date derives its base from upstream's newest tag"
d="$WORK/t18"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-commit", "owner": "o", "repo": "r", "branch": "main" },
  "versionScheme": "unstable-date", "versionBase": "1.1.1",
  "packageFile": "package.nix", "hashes": [], "verify": { "check": "eval" } }
JSON
printf '{\n  version = "1.1.1-unstable-2026-08-01";\n  rev = "old1111111111111111111111111111111111111";\n}\n' >"$d/package.nix"
printf '{ "sha": "new2222222222222222222222222222222222222c" }\n' >"$WORK/t18-commit.json"
printf '[{"name":"v1.1.2"},{"name":"v1.1.1"},{"name":"v1.1.0"}]\n' >"$WORK/t18-tags.json"
: >"$d/.nixflag"
STUB_CURL_FILE="$WORK/t18-commit.json" STUB_CURL_TAGS_FILE="$WORK/t18-tags.json" run_update "$d"
check "base is upstream's newest tag, not the declared versionBase" \
  "1.1.2-unstable-$TODAY" "$(get "$d" new_version)"
check "derived base is what lands in the package" \
  "1.1.2-unstable-$TODAY" "$(grep -oP 'version = "\K[^"]+' "$d/package.nix")"

echo "Test 18b: a tagless upstream falls back to versionBase"
d="$WORK/t18b"
mkdir -p "$d/.github"
cp "$WORK/t18/.github/update.json" "$d/.github/update.json"
printf '{\n  version = "1.1.1-unstable-2026-08-01";\n  rev = "old1111111111111111111111111111111111111";\n}\n' >"$d/package.nix"
printf '[]\n' >"$WORK/t18b-tags.json"
: >"$d/.nixflag"
STUB_CURL_FILE="$WORK/t18-commit.json" STUB_CURL_TAGS_FILE="$WORK/t18b-tags.json" run_update "$d"
check "tagless upstream keeps versionBase" "1.1.1-unstable-$TODAY" "$(get "$d" new_version)"

echo "Test 18c: a tag fetch error never invents a base"
d="$WORK/t18c"
mkdir -p "$d/.github"
cp "$WORK/t18/.github/update.json" "$d/.github/update.json"
printf '{\n  version = "1.1.1-unstable-2026-08-01";\n  rev = "old1111111111111111111111111111111111111";\n}\n' >"$d/package.nix"
before="$(cat "$d/package.nix")"
: >"$d/.nixflag"
STUB_CURL_FILE="$WORK/t18-commit.json" STUB_CURL_TAGS_FILE="/nonexistent-tags.json" run_update "$d"
check "tag fetch error exits 2 (retry next run)" "2" "$RC"
check "tag fetch error writes nothing" "$before" "$(cat "$d/package.nix")"

echo "Test 18d: unstable-date reads its rev from version.json, not only from .nix"
d="$WORK/t18d"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-commit", "owner": "o", "repo": "r", "branch": "main" },
  "versionScheme": "unstable-date", "versionBase": "1.1.1",
  "versionFile": "version.json", "hashes": [], "verify": { "check": "eval" } }
JSON
printf '{ "version": "1.1.2-unstable-2026-08-01", "rev": "new2222222222222222222222222222222222222c", "hash": "sha256-x", "date": "2026-08-01" }\n' >"$d/version.json"
before="$(cat "$d/version.json")"
: >"$d/.nixflag"
STUB_CURL_FILE="$WORK/t18-commit.json" STUB_CURL_TAGS_FILE="$WORK/t18-tags.json" run_update "$d"
check "unchanged rev in version.json is a no-op" "false" "$(get "$d" updated)"
check "no-op leaves version.json byte-identical" "$before" "$(cat "$d/version.json")"

# ---- Test 19: a red check suite stops the update before it is pushed -------
echo "Test 19: a failing check aborts the update"
d="$WORK/t19"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^[0-9]" },
  "packageFile": "version.json", "hashes": [], "verify": { "check": "eval" } }
JSON
printf '{ "version": "2026.1", "rev": "x", "hash": "sha256-x", "date": "x" }\n' >"$d/version.json"
: >"$d/.nixflag"
STUB_CHECKS_FAIL=1 STUB_CURL_FILE="$STD/tests/fixtures/mullvad-releases.json" run_update "$d"
check "update refuses to proceed" "1" "$RC"
check "reported as a check failure" "eval-error" "$(get "$d" error_type)"

echo "Test 10b: classifier reads coloured paths, every runner's attributes, and names a compile error"
d="$WORK/t10b"
mkdir -p "$d"
: >"$d/out.env"
printf '%s\n' \
  '=== log-ubuntu-latest' \
  "error: Cannot build '$(printf '\033[35;1m')/nix/store/eeee-eden-0.2.1.drv$(printf '\033[0m')'." \
  'eden> /build/source/src/core/memory/cheat_engine.cpp:240:47: error: '"'"'<unknown>'"'"' may be used uninitialized [-Werror=maybe-uninitialized]' \
  'ERROR:nix_fast_build:Failed attributes: .#checks.x86_64-linux.package-eden' \
  '=== log-ubuntu-24.04-arm' \
  'ERROR:nix_fast_build:Failed attributes: .#checks.aarch64-linux.package-eden .#checks.aarch64-linux.package-default' >"$d/build.log"
run_classify "$d" "$d/build.log"
check "classifier exits 0" "0" "$RC"
check "class compile-error" "compile-error" "$(get "$d" class)"
check "the coloured drv path is read" "/nix/store/eeee-eden-0.2.1.drv" "$(get "$d" failed_drvs)"
check "both runners' attributes are listed" "3" "$(get "$d" failed_attrs | tr ' ' '\n' | grep -c checks)"

echo "Test 10c: the classifier hands the report the line that named the class"
d="$WORK/t10c"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error: Cannot build '/nix/store/hhhh-python3.14-unsloth-2026.10.8.drv'.
       Reason: builder failed with exit code 1.
python3.14-unsloth> Checking runtime dependencies for unsloth-2026.10.8-py3-none-any.whl
       >   - json5 not installed
       > Successfully built unsloth-2026.10.8-py3-none-any.whl
LOG
run_classify "$d" "$d/build.log"
check "a missing runtime dependency is named" "missing-python-dep" "$(get "$d" class)"
check "the evidence is the dependency line, not nix's header" "> - json5 not installed" "$(get "$d" evidence | tr -s ' ')"
d="$WORK/t10d"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error: Cannot build '/nix/store/iiii-durdraw-0.31.1.drv'.
smoke>        > Builder called die: makeWrapper doesn't understand the arg --prefix PATH : /nix/store/jjjj-ansilove-4.2.2/bin
smoke>        > Backtrace:
LOG
run_classify "$d" "$d/build.log"
check "a setup hook that dies is named" "setup-hook-error" "$(get "$d" class)"
check "its evidence carries the hook's own message" "1" "$(get "$d" evidence | grep -c "makeWrapper doesn't understand the arg")"
d="$WORK/t10e"
mkdir -p "$d"
: >"$d/out.env"
printf 'error: Cannot build %s.\nsomething nobody has a pattern for\n' "'/nix/store/kkkk-x.drv'" >"$d/build.log"
run_classify "$d" "$d/build.log"
check "an unknown failure stays unclassified" "unclassified" "$(get "$d" class)"
check "and carries no evidence" "" "$(get "$d" evidence)"

echo "Test 20: classifier names a substitution whose pattern upstream moved"
d="$WORK/t20"
mkdir -p "$d"
: >"$d/out.env"
cat >"$d/build.log" <<'LOG'
error: Cannot build '/nix/store/dddd-unsloth-2026.4.5.drv'.
       Reason: builder failed with exit code 1.
       > substituteStream() in derivation python3.14-unsloth: ERROR: pattern requires\ =\ \[\"setuptools==80.9.0\"\] doesn't match anything in file 'pyproject.toml'
LOG
run_classify "$d" "$d/build.log"
check "classifier exits 0" "0" "$RC"
check "class substitution-pattern-drift" "substitution-pattern-drift" "$(get "$d" class)"
check "the failing drv is still listed" "1" "$(get "$d" failed_drvs | tr ' ' '\n' | grep -c drv)"

echo "Test 21: a git-ls-remote base comes from upstream's newest release tag"
d="$WORK/t21"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "x", "versionScheme": "unstable-date", "versionBase": "0.0.1",
  "upstream": { "type": "git-ls-remote", "url": "u", "branch": "main" },
  "packageFile": "package.nix", "hashes": ["hash"], "verify": { "check": "eval" } }
JSON
cat >"$d/package.nix" <<'NIX'
{ }: { rev = "1111111111111111111111111111111111111111"; version = "0.0.1-unstable-2020-01-01"; hash = "sha256-AAAA"; }
NIX
: >"$d/.nixflag"
STUB_GIT_REV=2222222222222222222222222222222222222222 \
  STUB_GIT_TAGS="$(printf 'aaa\trefs/tags/v0.2.0\nbbb\trefs/tags/test-tag2\nccc\trefs/tags/v0.2.1\nddd\trefs/tags/0.0.3.git\neee\trefs/tags/v0.3.0-rc1\n')" \
  run_update "$d"
check "the newest release tag wins, junk and rc excluded" "0.2.1-unstable-$(date -u +%Y-%m-%d)" "$(get "$d" new_version)"

# ---- Test 22: check-shell-pipelines covers workflow files ------------------
# GitHub runs every step under `bash -eo pipefail`, so a piped grep in a
# workflow is the same fail-open as one in a script. The shipped ci.yml and
# maintenance.yml carried three such pipelines the .sh/.nix-only scan never saw.
echo "Test 22: check-shell-pipelines flags a workflow pipeline and accepts the here-string form"
CHECKER="$STD/scripts/check-shell-pipelines.sh"
d="$WORK/t22"
mkdir -p "$d/.github/workflows"
(cd "$d" && git init -q && git config user.email t@t && git config user.name t)
printf 'run: |\n  if ! nix eval .#x | grep -qx true; then exit 0; fi\n' >"$d/.github/workflows/ci.yml" # pipefail-safe: the fixture the checker must refuse
(cd "$d" && git add -A && git commit -qm bad && bash "$CHECKER" >"$d/log" 2>&1)
check "a piped grep -q in a workflow is refused" "1" "$?"
check "the finding names the workflow file" "1" "$(grep -c 'workflows/ci.yml' "$d/log")"
# shellcheck disable=SC2016
printf 'run: |\n  declared=$(nix eval .#x)\n  if [ "$declared" != true ]; then exit 0; fi\n' >"$d/.github/workflows/ci.yml"
(cd "$d" && git add -A && git commit -qm good && bash "$CHECKER" >"$d/log" 2>&1)
check "the captured form passes" "0" "$?"

if command -v nix >/dev/null 2>&1; then
  echo "Test 23: after-lock-update runs the flake's app and stages only what it rewrote"
  HOOK="$STD/after-lock-update.sh"
  NP=$(nix eval --impure --raw --expr "(builtins.getFlake \"$STD\").inputs.nixpkgs.outPath")
  hook_fixture() { # hook_fixture <dir> <app script, or empty for no apps>
    mkdir -p "$1"
    if [ -z "$2" ]; then
      printf '{ outputs = _: { }; }\n' >"$1/flake.nix"
    else
      cat >"$1/flake.nix" <<NIX
{
  inputs.nixpkgs.url = "path:$NP";
  outputs = { nixpkgs, ... }: {
    apps = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
      after-lock-update = {
        type = "app";
        program = "\${nixpkgs.legacyPackages.\${system}.writeShellScript "hook" ''$2''}";
      };
    });
  };
}
NIX
    fi
    printf 'old\n' >"$1/pinned.txt"
    (cd "$1" && git init -q && git config user.email t@t && git config user.name t && git add -A &&
      nix flake lock && git add -A && git commit -qm fixture) >"$1.setup.log" 2>&1 || {
      echo "  fixture setup failed:"
      sed "s/^/    /" "$1.setup.log"
    }
  }
  run_hook() {
    (cd "$1" && bash "$HOOK" >"$1.log" 2>&1)
    local rc=$?
    [ "$rc" -eq 0 ] || tail -5 "$1.log" | sed "s/^/    hook: /"
    return "$rc"
  }

  d="$WORK/t23a"
  hook_fixture "$d" ""
  run_hook "$d"
  check "a flake with no apps is a clean no-op" "0" "$?"
  check "and says there was no app to run" "1" "$(grep -c 'nothing to run' "$d.log")"
  check "and no option reference to write" "1" "$(grep -c 'nothing to write' "$d.log")"

  d="$WORK/t23b"
  hook_fixture "$d" 'echo new > pinned.txt'
  run_hook "$d"
  check "an app rewriting a tracked file exits 0" "0" "$?"
  check "the rewritten file is staged" "pinned.txt" "$(cd "$d" && git diff --cached --name-only)"

  d="$WORK/t23c"
  hook_fixture "$d" 'echo stray > stray.txt'
  run_hook "$d"
  check "an app leaving an untracked file fails closed" "1" "$?"
  check "the failure names the file" "1" "$(grep -c 'stray.txt' "$d.log")"

  d="$WORK/t23d"
  hook_fixture "$d" 'exit 3'
  if run_hook "$d"; then failed=0; else failed=1; fi
  check "a failing app fails the hook" "1" "$failed"

  d="$WORK/t23e"
  hook_fixture "$d" ""
  printf '{ outputs = _: { ' >"$d/flake.nix"
  (cd "$d" && git add -A)
  if run_hook "$d"; then failed=0; else failed=1; fi
  check "a flake that does not evaluate fails the hook" "1" "$failed"

  reference_fixture() { # reference_fixture <dir> <tracked|untracked>: a flake whose only check lives on another system
    mkdir -p "$1/docs"
    printf '%s\n' '{ outputs = _: { checks.riscv64-linux.std-option-reference.rendered = "the new page\n"; }; }' >"$1/flake.nix"
    [ "$2" = tracked ] && printf 'the old page\n' >"$1/docs/OPTIONS.md"
    (cd "$1" && git init -q && git config user.email t@t && git config user.name t && git add -A &&
      git commit -qm fixture) >"$1.setup.log" 2>&1 || {
      echo "  fixture setup failed:"
      sed "s/^/    /" "$1.setup.log"
    }
  }

  d="$WORK/t23f"
  reference_fixture "$d" tracked
  run_hook "$d"
  check "an option reference is rewritten on a host the flake declares nothing for" "0" "$?"
  check "the page is what the check renders" "the new page" "$(cat "$d/docs/OPTIONS.md")"
  check "and it is staged" "docs/OPTIONS.md" "$(cd "$d" && git diff --cached --name-only)"

  d="$WORK/t23g"
  reference_fixture "$d" untracked
  run_hook "$d"
  check "a reference git does not track yet fails closed" "1" "$?"
  check "and the failure names it" "1" "$(grep -cx 'docs/OPTIONS.md' "$d.log")"
else
  echo "Test 23 skipped (nix unavailable)"
fi

echo "Test 24: report-failure keeps one open issue per failure and says how long it has failed"
REPORT="$STD/report-failure.sh"
GHBIN="$WORK/ghbin"
mkdir -p "$GHBIN"
cat >"$GHBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ -n "${STUB_GH_FAIL:-}" ]; then exit 1; fi
if [ -n "${STUB_GH_FAIL_TIMES:-}" ]; then
  n=0
  if [ -f "$GH_CALLS.fails" ]; then n=$(cat "$GH_CALLS.fails"); fi
  if [ "$n" -lt "$STUB_GH_FAIL_TIMES" ]; then
    echo $((n + 1)) >"$GH_CALLS.fails"
    exit 1
  fi
fi
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then cp "$a" "$GH_BODY"; fi
  prev="$a"
done
case "$1 $2" in
"label list") cat "${STUB_GH_LABELS:-/dev/null}" ;;
"issue list") cat "$STUB_GH_LIST" ;;
"issue create") echo "https://github.com/o/r/issues/42" ;;
esac
exit 0
SH
chmod +x "$GHBIN/gh"
report_fixture() { # report_fixture <dir> <open-issues-json>
  mkdir -p "$1"
  : >"$1/out.env"
  : >"$1/calls"
  printf '%s\n' "$2" >"$1/list.json"
  printf 'update-failed\nmaintenance\n' >"$1/labels"
  printf '## Update failed: x 1 -> 2\n' >"$1/head.md"
  printf '%s\n' 'building x' "$(printf '\033[31m')error:$(printf '\033[0m') builder for x failed" "$(printf 'y%.0s' $(seq 1 500))" >"$1/build.log"
}
run_report() { # run_report <dir> <title>
  (cd "$1" && PATH="$GHBIN:$PATH" GH_CALLS="$1/calls" GH_BODY="$1/body.md" STUB_GH_LIST="$1/list.json" STUB_GH_LABELS="$1/labels" \
    STUB_GH_FAIL="${STUB_GH_FAIL:-}" STUB_GH_FAIL_TIMES="${STUB_GH_FAIL_TIMES:-}" REPORT_RETRY_DELAY=0 GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=7 GITHUB_OUTPUT="$1/out.env" \
    FAILED_ATTRS=".#checks.x86_64-linux.package-x" FAIL_EVIDENCE="${FAIL_EVIDENCE:-}" \
    bash "$REPORT" update-failed "Update " "$2" "$1/head.md" "$1/build.log" >"$1/rlog" 2>&1)
  RC=$?
}
today=$(date -u +%F)

d="$WORK/t24a"
report_fixture "$d" '[]'
run_report "$d" "Update x 1 -> 2: build-error"
check "a first failure exits 0" "0" "$RC"
check "a first failure files one issue" "1" "$(grep -c '^issue create --label update-failed --title Update x 1 -> 2: build-error' "$d/calls")"
check "the issue number is reported" "42" "$(get "$d" number)"
check "the body says which run first reported it" "1" "$(grep -c "^First reported on $today by https://github.com/o/r/actions/runs/7$" "$d/body.md")"
check "the body names the failing target" "1" "$(grep -c '^\.#checks\.x86_64-linux\.package-x$' "$d/body.md")"
check "the first-error block opens on the plain error line" "1" "$(sed -n '/First error/,/<\/details>/p' "$d/body.md" | grep -c '^error: builder for x failed$')"
check "the body carries no terminal colour codes" "0" "$(grep -c $'\033' "$d/body.md")"
check "a long log line is cut to 300 characters" "300" "$(grep -m1 '^yyy' "$d/body.md" | tr -d '\n' | wc -c)"
check "an unclassified failure has no cause section" "0" "$(grep -c '^### Cause$' "$d/body.md")"

check "a repo that has the label gets no new one" "0" "$(grep -c '^label create' "$d/calls")"

d="$WORK/t24l"
report_fixture "$d" '[]'
printf 'bug\n' >"$d/labels"
run_report "$d" "Update x 1 -> 2: build-error"
check "a repo without the label still gets its issue" "0" "$RC"
check "the missing label is created first" "label create update-failed" "$(grep -m1 -E '^(label create|issue create)' "$d/calls" | cut -d' ' -f1-3)"
check "the issue is then filed under it" "1" "$(grep -c '^issue create --label update-failed' "$d/calls")"

d="$WORK/t24h"
report_fixture "$d" '[]'
FAIL_EVIDENCE="> - json5 not installed" run_report "$d" "Update x 1 -> 2: missing-python-dep"
check "a classified failure opens with its cause" "1" "$(grep -c '^### Cause$' "$d/body.md")"
check "the cause section quotes the line that named the class" "1" "$(awk '/^### Cause/ { f = 1 } f && /^<details/ { exit } f' "$d/body.md" | grep -c '^> - json5 not installed$')"
check "the cause comes before the first error" "1" "$(awk '/^### Cause/{c=NR} /First error/{f=NR} END {print (c && f && c < f) ? 1 : 0}' "$d/body.md")"

d="$WORK/t24b"
report_fixture "$d" '[{"number":7,"title":"Update x 1 -> 2: build-error","createdAt":"2026-10-04T06:10:00Z"}]'
run_report "$d" "Update x 1 -> 2: build-error"
check "a repeat failure exits 0" "0" "$RC"
check "a repeat failure files nothing new" "0" "$(grep -c '^issue create' "$d/calls")"
check "a repeat failure edits the open issue" "1" "$(grep -c '^issue edit 7 --title Update x 1 -> 2: build-error' "$d/calls")"
check "an unchanged failure adds no comment" "0" "$(grep -c '^issue comment' "$d/calls")"
days=$((($(date -u -d "$today" +%s) - $(date -u -d 2026-10-04 +%s)) / 86400))
check "the body counts the days the issue has been open" "1" "$(grep -c "^Open since 2026-10-04 ($days days); no run has succeeded since\. Latest failing run on $today: " "$d/body.md")"
check "the open issue keeps its number" "7" "$(get "$d" number)"

d="$WORK/t24c"
report_fixture "$d" '[{"number":7,"title":"Update x 1 -> 2: build-error","createdAt":"2026-10-04T06:10:00Z"}]'
run_report "$d" "Update x 1 -> 3: compile-error"
check "a changed failure edits the open issue" "1" "$(grep -c '^issue edit 7 --title Update x 1 -> 3: compile-error' "$d/calls")"
check "a changed report comments once, naming both titles" "1" "$(grep -c '^issue comment 7 --body Now reported as: Update x 1 -> 3: compile-error (previously: Update x 1 -> 2: build-error)' "$d/calls")"

d="$WORK/t24d"
report_fixture "$d" '[{"number":9,"title":"Update x 1 -> 2: build-error","createdAt":"2026-10-05T06:10:00Z"},{"number":7,"title":"Update x 1 -> 2: build-error","createdAt":"2026-10-04T06:10:00Z"},{"number":8,"title":"Maintenance: flake.lock update broke build (eval-error)","createdAt":"2026-10-04T06:10:00Z"}]'
run_report "$d" "Update x 1 -> 2: build-error"
check "a duplicate is closed into the oldest" "1" "$(grep -c '^issue close 9 --reason not planned --comment The same failure is tracked in #7\.' "$d/calls")"
check "an issue with another prefix is left alone" "0" "$(grep -c ' 8 ' "$d/calls")"
check "the oldest stays the open one" "1" "$(grep -c '^issue edit 7 ' "$d/calls")"

d="$WORK/t24e"
report_fixture "$d" '[]'
STUB_GH_FAIL=1 run_report "$d" "Update x 1 -> 2: build-error"
check "a failing gh fails the report" "1" "$RC"
check "a failing gh is tried three times before the report gives up" "3" "$(wc -l <"$d/calls")"

d="$WORK/t24g"
report_fixture "$d" '[]'
STUB_GH_FAIL_TIMES=2 run_report "$d" "Update x 1 -> 2: build-error"
check "a gh call that fails twice and then answers still files the issue" "0:42" "$RC:$(get "$d" number)"

d="$WORK/t24f"
report_fixture "$d" '[]'
rm "$d/build.log"
run_report "$d" "Update x 1 -> 2: build-error"
check "a missing log fails the report before any gh call" "1:0" "$RC:$(wc -l <"$d/calls")"

first_error() { sed -n '/<summary>First error<\/summary>/,/<\/details>/p' "$1/body.md" | sed '1,3d' | sed '/^```$/,$d'; }

d="$WORK/t24i"
report_fixture "$d" '[]'
with_escapes >"$d/build.log" <<'LOG'
^[[2mopenwrt-series-applies>^[[0m applying 0008-mac80211-brcmfmac-enable-2.4-ghz-vht-on-bcm4366.patch
^[[2mopenwrt-series-applies>^[[0m ^[[31;1merror:^[[0m Cannot build '^[[35;1m/nix/store/3wgchy0rrd2ba67vkryrad0qm6hrvhhn-openwrt-series-applies.drv^[[0m'.^[[0m
^[[2mopenwrt-series-applies>^[[0m        Reason: ^[[31;1mbuilder failed with exit code 1^[[0m.^[[0m
^[[2mopenwrt-series-applies>^[[0m        Output paths:
^[[2mopenwrt-series-applies>^[[0m          ^[[35;1m/nix/store/qb0vkik39d04nc9pg27dw0q6gipn4jqm-openwrt-series-applies^[[0m^[[0m
^[[2mopenwrt-series-applies>^[[0m        Last 25 log lines:
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/image/Makefile
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/image/asus_rt-ac86u/rom/etc/image_ident
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/image/asus_rt-ac86u/rom/etc/image_version
^[[2mopenwrt-series-applies>^[[0m        > applying 0004-bcm63xx-cfe-add-board-files-kept-beside-the-package.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file package/kernel/bcm63xx-cfe/Makefile
^[[2mopenwrt-series-applies>^[[0m        > applying 0005-bcm4908-enable-pcie.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/Makefile
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/config-6.18
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/patches-6.18/312-arm64-dts-broadcom-bcm4908-add-PCIe-controllers.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/patches-6.18/810-PCI-brcmstb-map-BCM4908-inbound-windows-through-UBUS.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/patches-6.18/816-PCI-brcmstb-unmask-the-BCM4908-interrupts-in-CPU_INTR1.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/patches-6.18/313-arm64-dts-broadcom-bcmbca-rt-ac86u-enable-PCIe.patch
^[[2mopenwrt-series-applies>^[[0m        > applying 0006-bcm4908-rt-ac86u-enable-wi-fi.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/base-files/lib/preinit/81_brcmfmac_nvram
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/config-6.18
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/image/Makefile
^[[2mopenwrt-series-applies>^[[0m        > applying 0007-bcm4908-rt-ac86u-add-usb-and-leds.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/base-files/etc/board.d/01_leds
^[[2mopenwrt-series-applies>^[[0m        > patching file target/linux/bcm4908/patches-6.18/314-arm64-dts-broadcom-bcmbca-rt-ac86u-add-USB-and-LEDs.patch
^[[2mopenwrt-series-applies>^[[0m        > applying 0008-mac80211-brcmfmac-enable-2.4-ghz-vht-on-bcm4366.patch
^[[2mopenwrt-series-applies>^[[0m        > patching file package/kernel/mac80211/Makefile
^[[2mopenwrt-series-applies>^[[0m        > Hunk #1 FAILED at 12.
^[[2mopenwrt-series-applies>^[[0m        > 1 out of 1 hunk FAILED -- saving rejects to file package/kernel/mac80211/Makefile.rej
^[[2mopenwrt-series-applies>^[[0m        > patching file package/kernel/mac80211/patches/brcm/880-wifi-brcmfmac-enable-2.4-GHz-VHT-on-BCM4366-before-AP-bring-up.patch
^[[2mopenwrt-series-applies>^[[0m        > does not apply to this OpenWrt tree without fuzz, rebase it: 0008-mac80211-brcmfmac-enable-2.4-ghz-vht-on-bcm4366.patch
^[[2mopenwrt-series-applies>^[[0m        For full logs, run:
^[[2mopenwrt-series-applies>^[[0m          ^[[1mnix log /nix/store/3wgchy0rrd2ba67vkryrad0qm6hrvhhn-openwrt-series-applies.drv^[[0m^[[0m
WARNING:nix_fast_build.build:build openwrt-series-applies exited with 1 (attempt 1/1)
^[[2mopenwrt-shipped-defaults>^[[0m ^[[35;1mwarning:^[[0m unknown setting 'lazy-trees'^[[0m
ERROR:nix_fast_build:Failed attributes: .#checks.aarch64-linux.openwrt-series-applies
LOG
run_report "$d" "Maintenance: flake.lock update failed (check-error)"
check "the excerpt opens on the failing builder's error" "openwrt-series-applies> error: Cannot build '/nix/store/3wgchy0rrd2ba67vkryrad0qm6hrvhhn-openwrt-series-applies.drv'." "$(first_error "$d" | head -1)"
check "the excerpt carries the builder's verdict" "1" "$(first_error "$d" | grep -c 'Hunk #1 FAILED at 12\.$')"
check "the excerpt ends on the builder's last line" "openwrt-series-applies>        > does not apply to this OpenWrt tree without fuzz, rebase it: 0008-mac80211-brcmfmac-enable-2.4-ghz-vht-on-bcm4366.patch" "$(first_error "$d" | tail -1)"

d="$WORK/t24j"
report_fixture "$d" '[]'
cp "$WORK/t11f/build.log" "$d/build.log"
run_report "$d" "Update proton-ge 1 -> 2: source-not-found"
check "a builder's own error line beside Nix's block does not open the excerpt" "error: Cannot build '/nix/store/bpdbvak1dnsf2zki2g5805lp987pxjbf-source.drv'." "$(first_error "$d" | head -1)"
check "the excerpt ends on the builder's verdict" "       > error: cannot download source from any mirror" "$(first_error "$d" | tail -1)"

d="$WORK/t24k"
report_fixture "$d" '[]'
cp "$WORK/t11g/build.log" "$d/build.log"
run_report "$d" "Update eden 1 -> 2: eval-error"
check "an evaluation error's excerpt ends on the last line of its trace" "            6|   version =" "$(first_error "$d" | tail -1)"

echo "Test 25: sync.sh writes the callers and deletes retired copies, except a custom updater; a first-party repo carries no Update caller"
SYNC="$STD/sync.sh"
HEADS="$STD/heads"
d="$WORK/t25"
for r in plain custom firstparty; do
  mkdir -p "$d/$r/.git" "$d/$r/.github/workflows" "$d/$r/scripts"
  printf 'stale\n' >"$d/$r/.github/workflows/ci.yml"
  printf 'stale\n' >"$d/$r/.github/workflows/update.yml"
  printf '#!/usr/bin/env bash\n' >"$d/$r/scripts/heal-overlays.sh"
  printf '#!/usr/bin/env bash\n' >"$d/$r/scripts/update.sh"
done
printf '{"upstream":{"type":"github-release"}}\n' >"$d/plain/.github/update.json"
printf '{"upstream":{"type":"custom"}}\n' >"$d/custom/.github/update.json"
printf '{"upstream":{"type":"none"}}\n' >"$d/firstparty/.github/update.json"
PKG_REPOS_DIR="$d" bash "$SYNC" --check plain >/dev/null
check "a repo carrying stale and retired files is reported as drift" "1" "$?"
check "--check changes nothing" "stale" "$(cat "$d/plain/.github/workflows/ci.yml")"
PKG_REPOS_DIR="$d" bash "$SYNC" plain custom firstparty >"$d/log"
check "sync exits clean" "0" "$?"
if cmp -s "$STD/callers/ci.yml" "$d/plain/.github/workflows/ci.yml"; then same=yes; else same=no; fi
check "the CI workflow becomes the caller" "yes" "$same"
check "a retired script is deleted" "absent" "$([ -e "$d/plain/scripts/heal-overlays.sh" ] && echo present || echo absent)"
check "the canonical updater copy is deleted" "absent" "$([ -e "$d/plain/scripts/update.sh" ] && echo present || echo absent)"
check "a custom repo keeps its own updater" "present" "$([ -e "$d/custom/scripts/update.sh" ] && echo present || echo absent)"
check "a custom repo still loses the other retired copies" "absent" "$([ -e "$d/custom/scripts/heal-overlays.sh" ] && echo present || echo absent)"
if cmp -s "$STD/callers/update.yml" "$d/plain/.github/workflows/update.yml"; then same=yes; else same=no; fi
check "a repo with an upstream gets the Update caller" "yes" "$same"
check "a first-party repo loses its Update caller" "absent" "$([ -e "$d/firstparty/.github/workflows/update.yml" ] && echo present || echo absent)"
if cmp -s "$STD/callers/ci.yml" "$d/firstparty/.github/workflows/ci.yml"; then same=yes; else same=no; fi
check "a first-party repo still gets the CI caller" "yes" "$same"
if cmp -s "$STD/.github/ISSUE_TEMPLATE/task.yml" "$d/plain/.github/ISSUE_TEMPLATE/task.yml"; then same=yes; else same=no; fi
check "a repo gets the task form" "yes" "$same"
check "a repo is given no ignore line about the standard's own tree" "0" "$(grep -cE '^!|(^|/)tests/' "$d/plain/.gitignore")"
printf '!tests/fixtures/consumer-stale/CLAUDE.md\n' >>"$d/plain/.gitignore"
PKG_REPOS_DIR="$d" bash "$SYNC" plain >"$d/log"
check "such a line an earlier release wrote is taken out again" "0" "$(grep -cxF '!tests/fixtures/consumer-stale/CLAUDE.md' "$d/plain/.gitignore")"
PKG_REPOS_DIR="$d" bash "$SYNC" --check plain custom firstparty >/dev/null
check "a synced repo is in sync" "0" "$?"
printf 'not json\n' >"$d/plain/.github/update.json"
if PKG_REPOS_DIR="$d" bash "$SYNC" --check plain >/dev/null 2>&1; then rc=passed; else rc=failed; fi
check "a malformed update.json fails the sync instead of guessing its type" "failed" "$rc"

echo "Test 25b: fleet-roll --build-on-ci is an option, and refuses --skip-build, which would skip its evaluation too"
d="$WORK/t25b"
mkdir -p "$d"
PKG_REPOS_DIR="$d" bash "$STD/scripts/fleet-roll.sh" --help >"$d/help"
check "--help names --build-on-ci" "yes" "$(grep -q -- '--build-on-ci' "$d/help" && echo yes || echo no)"
PKG_REPOS_DIR="$d" bash "$STD/scripts/fleet-roll.sh" --build-on-ci --skip-build >"$d/out" 2>&1
check "--build-on-ci with --skip-build exits 2" "2" "$?"
check "and says why" "yes" "$(grep -q 'build-on-ci still evaluates every system' "$d/out" && echo yes || echo no)"

echo "Test 27: check-commit-message refuses each shape the standard names and accepts a conforming message"
CHECKER="$STD/scripts/check-commit-message.sh"
d="$WORK/t27"
mkdir -p "$d"
message() {
  printf '%b' "$2" >"$d/$1"
  bash "$CHECKER" buildhost "$d/$1" >"$d/$1.log" 2>&1
}
good='feat(std): check the commit message\n\nA terminal commit obeyed no shape.\n\nTest: tests/run.sh, all pass\n'
message good "$good"
check "a conforming message passes" "0" "$?"
message fix 'fix(std): keep the lock when a fetch fails\n\nbody\n\nCause: the retry never re-read it\nTest: tests/run.sh\n'
check "a fix commit with a Cause: line passes" "0" "$?"
message editor "$good# a comment git strips\n# ------------------------ >8 ------------------------\nsee /home/me, someone@example.com\n"
check "the editor's comments and the diff below the scissors line are not read" "0" "$?"
refused() {
  local rc=0
  message "$2" "$3" || rc=$?
  check "$1 is refused" "1" "$rc"
  check "$1 is named" "1" "$(grep -c -- "$4" "$d/$2.log")"
}
message coauthor 'feat(std): add stuff\n\nbody\n\nTest: none, docs\n\nCo-authored-by: Some One <12345+some-one@users.noreply.github.com>\n'
check "a human co-author through a GitHub noreply address passes" "0" "$?"
refused "a co-author with a personal address" coauthormail 'feat(std): add stuff\n\nbody\n\nTest: none, docs\n\nCo-authored-by: Some One <some.one@example.com>\n' 'noreply'
refused "a bot co-author" coauthorbot 'feat(std): add stuff\n\nbody\n\nTest: none, docs\n\nCo-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>\n' 'noreply'
refused "a tool co-author" coauthortool 'feat(std): add stuff\n\nbody\n\nTest: none, docs\n\nCo-authored-by: Claude <12345+claude@users.noreply.github.com>\n' 'tool or a bot'
refused "a co-author line alone as the body" coauthoronly 'feat(std): add stuff\n\nTest: none, docs\n\nCo-authored-by: Some One <12345+some-one@users.noreply.github.com>\n' 'body is missing'
refused "a subject without type(scope)" shape 'Add stuff\n\nbody\n\nTest: none, docs\n' 'type(scope): summary'
refused "a capital after the prefix" capital 'feat(std): Add stuff\n\nbody\n\nTest: none, docs\n' 'capital letter'
refused "a full stop on the subject" stop 'feat(std): add stuff.\n\nbody\n\nTest: none, docs\n' 'full stop'
refused "a subject over 72 characters" long "feat(std): $(printf 'x%.0s' $(seq 70))\n\nbody\n\nTest: none, docs\n" '81 characters'
refused "no blank line after the subject" noblank 'feat(std): add stuff\nbody\n\nTest: none, docs\n' 'second line'
refused "no body beyond the Test: line" nobody 'feat(std): add stuff\n\nTest: none, docs\n' 'body is missing'
refused "no Test: line" notest 'feat(std): add stuff\n\nbody\n' 'no Test: line'
refused "a fix commit without a Cause: line" nocause 'fix(std): add stuff\n\nbody\n\nTest: none, docs\n' 'Cause: line'
refused "an email address" email 'feat(std): add stuff\n\nmail someone@example.com\n\nTest: none, docs\n' 'someone@example.com'
refused "a path under /home" home 'feat(std): add stuff\n\nsee /home/me/x\n\nTest: none, docs\n' 'under /home'
refused "an AI trailer" trailer 'feat(std): add stuff\n\nbody\n\nTest: none, docs\n\nCo-Authored-By: Bot\n' 'AI trailer'
refused "a word from the consumer's list" word 'feat(std): add stuff\n\nbuilt on Buildhost today\n\nTest: none, docs\n' 'names buildhost'
refused "a body line over 72 characters" wide "feat(std): add stuff\n\n$(printf 'x%.0s' $(seq 73))\n\nTest: none, docs\n" '73 characters'
message widetest "feat(std): add stuff\n\nbody\n\nTest: $(printf 'x%.0s' $(seq 90))\n"
check "a long Test: line is not a body line" "0" "$?"
message wideurl "feat(std): add stuff\n\nsee https://example.org/$(printf 'x%.0s' $(seq 80))\n\nTest: none, docs\n"
check "a long line holding a URL passes" "0" "$?"
refused "the first person" first 'feat(std): add stuff\n\nI tried the other way before this\n\nTest: none, docs\n' 'first person'
message io 'feat(std): add stuff\n\nthe I/O path and section I stay as they were\n\nTest: none, docs\n'
check "a capital I that is not a person passes" "0" "$?"
refused "a sentence about who asked for the change" owner 'feat(std): add stuff\n\nThe owner asked for a wider tab\n\nTest: none, docs\n' 'narrates the work'
message useful 'feat(std): add stuff\n\nthe user manager and the file owner keep their modes\n\nTest: none, docs\n'
check "the user and a file owner in technical prose pass" "0" "$?"
refused "a link to a chat session" chat 'feat(std): add stuff\n\nbody\n\nTest: none, docs\n\nClaude-Session: https://claude.ai/code/session_x\n' 'trace of the tool'
refused "a review-by-agents note" agents 'feat(std): add stuff\n\nfrom a 5-agent blind review\n\nTest: none, docs\n' 'trace of the tool'
message claudemd 'docs(std): add CLAUDE.md\n\nthe agent desktop app reads CLAUDE.md\n\nTest: none, docs\n'
check "a file name and an agent that is a program pass" "0" "$?"
refused "a Test: line that says where it ran" place 'feat(std): add stuff\n\nbody\n\nTest: nix flake check on the M1\n' 'says where it ran'
message onpush 'feat(std): add stuff\n\nbody\n\nTest: the workflow on push, and tests/run.sh on aarch64-linux\n'
check "a Test: line saying on push or on a system passes" "0" "$?"
message bodym1 'feat(std): add stuff\n\nthe M1 page size is 16K, so the build sets it\n\nTest: none, docs\n'
check "a chip named in the body as a fact about the code passes" "0" "$?"
refused "a date standing alone" date 'feat(std): add stuff\n\nmeasured on 2026-11-12 with both radios capped\n\nTest: none, docs\n' 'holds a date'
refused "a date that ends a sentence" dateend 'feat(std): add stuff\n\nthe table was read on 2026-11-12.\n\nTest: none, docs\n' 'holds a date'
message dateglued 'feat(std): add stuff\n\nmoves to 2026.4.5-unstable-2026-11-15 and reads\nlog-2026-11-15.txt under the tag v2026-11-15\n\nTest: none, docs\n'
check "a date inside a version, a file name or a tag passes" "0" "$?"
scanner=$(command -v ripsecrets) || scanner="$(nix build --no-link --print-out-paths --inputs-from "$STD" 'nixpkgs#ripsecrets')/bin/ripsecrets"
secretly() {
  printf '%b' "$2" >"$d/$1"
  SECRET_SCANNER=$scanner bash "$CHECKER" buildhost "$d/$1" >"$d/$1.log" 2>&1
}
token="ghp""_$(printf 'aB3dE5%.0s' 1 2 3 4 5 6)"
secretly token "feat(std): add stuff\n\nthe runner reads $token here\n\nTest: none, docs\n"
check "a token in the message is refused" "1" "$?"
check "and the token itself is not printed" "0" "$(grep -c "$token" "$d/token.log")"
secretly hashes 'feat(std): add stuff\n\nmoves the lock to 9d4b71d and to\nsha256-ThkfL3D/FhCiZFc9+3BtxwuMmpuK+/bGtXCSo1+yVew=\n\nTest: none, docs\n'
check "a commit id and a source hash are not a token" "0" "$?"
mkdir -p "$d/words"
printf 'grandpiano\n' >"$d/words/list"
privately() {
  printf '%b' "$2" >"$d/$1"
  (
    cd "$d/words" && git init -q . 2>/dev/null
    git -C "$d/words" config std.privateWords "$3"
    if [ -n "${4:-}" ]; then
      cd "$d/words" && GITHUB_ACTIONS=$4 bash "$CHECKER" "$d/$1" >"$d/$1.log" 2>&1
    else
      cd "$d/words" && env -u GITHUB_ACTIONS bash "$CHECKER" "$d/$1" >"$d/$1.log" 2>&1
    fi
  )
}
privately listed 'feat(std): add stuff\n\nbuilt on Grandpiano today\n\nTest: none, docs\n' "$d/words/list"
check "a word from the private list is refused" "1" "$?"
check "and it is named, on this computer only" "1" "$(grep -c 'names grandpiano' "$d/listed.log")"
privately compound 'feat(std): add stuff\n\nthe grandpiano_smu module loads\n\nTest: none, docs\n' "$d/words/list"
check "the same word inside an identifier passes" "0" "$?"
privately missing "$good" "$d/words/absent"
check "a private list that is configured and missing refuses the commit" "1" "$?"
privately onci 'feat(std): add stuff\n\nbuilt on Grandpiano today\n\nTest: none, docs\n' "$d/words/list" true
check "in CI no private name is read, so the same message passes" "0" "$?"
printf 'grand-piano 88\n' >"$d/words/spaced"
privately joined 'feat(std): add stuff\n\nbuilt with the GrandPiano88 here\n\nTest: none, docs\n' "$d/words/spaced"
check "a listed word written without its separators is refused" "1" "$?"
privately commas 'feat(std): add stuff\n\nthe Grand Piano, 88 was what it ran with\n\nTest: none, docs\n' "$d/words/spaced"
check "a listed word written with other separators is refused" "1" "$?"
privately apart 'feat(std): add stuff\n\nthe grand plan keeps a piano of 88 keys\n\nTest: none, docs\n' "$d/words/spaced"
check "the parts of a listed word spread over a sentence pass" "0" "$?"
message hwaddress 'feat(std): add stuff\n\nthe frame came from aa:bb:cc:dd:ee:ff then\n\nTest: none, docs\n'
check "a network hardware address is refused" "1" "$?"
message clocktime 'feat(std): add stuff\n\nthe log line reads 12:30:45 and the ratio 16:9\n\nTest: none, docs\n'
check "a clock time and a ratio are not a hardware address" "0" "$?"
host=$(uname -n | tr '[:upper:]' '[:lower:]')
part=$(tr '.-' '\n' <<<"$host" | awk 'length($0) >= 5 && /[a-z]/' | grep -vxE 'local|localhost|localdomain|nixos|linux|ubuntu|debian|server|desktop|laptop|github' | head -1)
if [ -n "$part" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
  message hostname "feat(std): add stuff\n\nmeasured on $part today\n\nTest: none, docs\n"
  check "a part of this computer's own name is refused without any list" "1" "$?"
else
  ok "this computer's name has no part to refuse, or this is CI, where no private name exists"
fi
readme_repo() {
  mkdir -p "$d/$1"
  (cd "$d/$1" && git init -q . 2>/dev/null && printf '%b' "$2" >README.md && git add README.md)
  printf '%b' "$3" >"$d/$1.msg"
  (cd "$d/$1" && env -u GITHUB_ACTIONS bash "$CHECKER" "$d/$1.msg" >"$d/$1.log" 2>&1)
}
if [ -n "$part" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
  readme_repo subject "# tool\n\nA tuner for the $part line of chips.\n" "feat(std): add stuff\n\nmeasured on $part today\n\nTest: none, docs\n"
  check "a part of this computer's name that the repo's README uses passes there" "0" "$?"
  readme_repo inname "# tool\n\nBuilt on $host only.\n" "feat(std): add stuff\n\nmeasured on $part today\n\nTest: none, docs\n"
  check "a README that holds the part only inside the full name keeps it refused" "1" "$?"
  if [ "$host" != "$part" ]; then
    readme_repo fullname "# tool\n\nA tuner for the $part line of chips.\n" "feat(std): add stuff\n\nmeasured on $host today\n\nTest: none, docs\n"
    check "the full name is refused even where the README uses a part of it" "1" "$?"
  else
    ok "this computer's name has one part, so there is no full name to tell apart"
  fi
else
  ok "no part of a computer's name to weigh against a README here"
fi

echo "Test 28: check-commit-range refuses a bad message anywhere in the pushed range and names its commit"
RANGE="$STD/scripts/check-commit-range.sh"
d="$WORK/t28"
mkdir -p "$d"
g() { git -C "$d" -c user.name=t -c user.email=1+t@users.noreply.github.com "$@"; }
g init -q
g commit -q --allow-empty -F "$WORK/t27/good"
first=$(g rev-parse HEAD)
g commit -q --allow-empty -F "$WORK/t27/shape"
g commit -q --allow-empty -F "$WORK/t27/fix"
range() { (cd "$d" && bash "$RANGE" "$1" "$2" bash "$CHECKER" buildhost >"$d/log" 2>&1); }
range "$first" HEAD
check "a bad message in the range is refused" "1" "$?"
check "the bad commit is named" "1" "$(grep -c '^FAIL .* Add stuff' "$d/log")"
check "the good commit after the base is not" "1" "$(grep -c '^ok ' "$d/log")"
range "$first" "$first"
check "an empty range checks the head commit alone, and a good one passes" "0" "$?"
range 0000000000000000000000000000000000000000 HEAD~1
check "an unknown base checks the head commit alone, and a bad one fails" "1" "$?"
range "$first" nosuchcommit
check "a head that is no commit fails" "1" "$?"
bad=$(g rev-parse HEAD~1)
pushed() { (cd "$d" && PRE_COMMIT_REMOTE_NAME=$1 bash "$RANGE" "$2" "$3" bash "$CHECKER" buildhost >"$d/log" 2>&1); }
g update-ref refs/remotes/origin/main "$bad"
pushed origin "$first" HEAD
check "a bad commit the remote already holds on another branch is not judged again" "0 0 1" \
  "$? $(grep -c '^FAIL ' "$d/log") $(grep -c '^ok ' "$d/log")"
pushed elsewhere "$first" HEAD
check "a remote that does not hold it still refuses it" "1" "$?"
g update-ref refs/remotes/origin/main HEAD
pushed origin "$first" HEAD
check "a range the remote holds in full passes and says so" "0 1" "$? $(grep -c 'already on origin' "$d/log")"
g update-ref -d refs/remotes/origin/main
judged() { (cd "$d" && STD_JUDGED_REF=$1 bash "$RANGE" "$2" "$3" bash "$CHECKER" buildhost >"$d/log" 2>&1); }
g update-ref refs/heads/default "$bad"
judged refs/heads/default "$first" HEAD
check "CI on another branch does not judge again what the default branch holds" "0 0 1" \
  "$? $(grep -c '^FAIL ' "$d/log") $(grep -c '^ok ' "$d/log")"
judged refs/heads/nosuchbranch "$first" HEAD
check "a judged ref that does not exist leaves the whole range to judge" "1" "$?"
g update-ref -d refs/heads/default
git -C "$d" -c user.name=t -c user.email=someone@example.org commit -q --allow-empty -F "$WORK/t27/good"
range HEAD~1 HEAD
check "a commit whose author address is not a GitHub noreply address is refused" "1" "$?"
check "and the address itself is not printed" "0" "$(grep -c 'example.org' "$d/log")"

echo "Test 28b: CI checks the messages even when the consumer's locked standard has no app"
CIMSG="$STD/scripts/check-commit-messages-ci.sh"
mkdir -p "$d/bin"
cat >"$d/bin/nix" <<'SH'
#!/usr/bin/env bash
case "$*" in
*currentSystem*) echo x86_64-linux ;;
*"--json .#apps"*)
  [ "$APPS" = fail ] && exit 1
  echo "$APPS"
  ;;
run*) echo "app ran: $*" ;;
esac
SH
chmod +x "$d/bin/nix"
ci() { (cd "$d" && APPS=$1 PATH="$d/bin:$PATH" bash "$CIMSG" "$2" "$3" >"$d/ci.log" 2>&1); }
ci '["x86_64-linux"]' "$first" HEAD
check "the app runs where this system has it" "0 1" "$? $(grep -c '^app ran: run .#std-check-commit-messages' "$d/ci.log")"
ci '["aarch64-linux"]' "$first" HEAD
check "another system with the app checks, this one does not" "0 1" "$? $(grep -cF 'checked on ["aarch64-linux"]' "$d/ci.log")"
ci '[]' "$first" HEAD
check "no app anywhere runs the standard's checker, which refuses the bad commit" "1 1" "$? $(grep -c '^FAIL .* Add stuff' "$d/ci.log")"
ci '[]' "$first" "$first"
check "no app anywhere and a good head passes" "0" "$?"
ci fail "$first" HEAD
st=$?
check "a flake whose apps do not evaluate fails, never skips" "failed" "$(if [ "$st" -ne 0 ]; then echo failed; else echo passed; fi)"

echo "Test 28c: CI builds only the checks a push changed, and every check when the commit before it is not proven"
TODO="$STD/scripts/checks-to-build.sh"
d="$WORK/t28c"
mkdir -p "$d/bin" "$d/repo"
git -C "$d/repo" init -q
git -C "$d/repo" -c user.name=t -c user.email=1+t@users.noreply.github.com commit -q --allow-empty -m before
proven=$(git -C "$d/repo" rev-parse HEAD)
git -C "$d/repo" -c user.name=t -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -q --allow-empty -m refresh
automated=$(git -C "$d/repo" rev-parse HEAD)
git -C "$d/repo" -c user.name=t -c user.email=1+t@users.noreply.github.com commit -q --allow-empty -m now
cat >"$d/bin/nix" <<'SH'
#!/usr/bin/env bash
case "$*" in
*"rev="*)
  [ "$BEFORE" = fail ] && exit 1
  echo "$BEFORE"
  ;;
*)
  [ "$NOW" = fail ] && exit 1
  echo "$NOW"
  ;;
esac
SH
cat >"$d/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$GREEN_RUNS" = fail ] && exit 1
echo "$GREEN_RUNS"
SH
chmod +x "$d/bin/nix" "$d/bin/gh"
same='{"package":"/nix/store/a.drv","lint":"/nix/store/b.drv"}'
moved='{"package":"/nix/store/a.drv","lint":"/nix/store/b2.drv","added":"/nix/store/n.drv"}'
todo() { # todo <event> <base> <green runs> <before> <now>
  (cd "$d/repo" && GITHUB_EVENT_NAME=$1 GITHUB_REPOSITORY=owner/repo GREEN_RUNS=$3 BEFORE=$4 NOW=$5 PATH="$d/bin:$PATH" \
    bash "$TODO" "$2" x86_64-linux 2>"$d/why" | tr '\n' ' ' | sed 's/ $//')
}
check "a push that changed one check and added one builds those two" "added lint" "$(todo push "$proven" 1 "$same" "$moved")"
check "a push that changed no check builds nothing" "" "$(todo push "$proven" 1 "$same" "$same")"
check "a run that is not a push builds every check" "ALL" "$(todo pull_request "$proven" 1 "$same" "$moved")"
check "a commit before the push that has no green run builds every check" "ALL" "$(todo push "$proven" 0 "$same" "$moved")"
check "and the reason is said" "1" "$(grep -c 'no green CI run' "$d/why")"
check "a forge that does not answer builds every check" "ALL" "$(todo push "$proven" fail "$same" "$moved")"
check "a commit before the push that is not known here builds every check" "ALL" "$(todo push 0000000000000000000000000000000000000000 1 "$same" "$moved")"
check "a commit before the push that does not evaluate builds every check" "ALL" "$(todo push "$proven" 1 fail "$moved")"
check "a commit the automation published after its own build is proven without a run" "added lint" "$(todo push "$automated" 0 "$same" "$moved")"
(cd "$d/repo" && GITHUB_EVENT_NAME=push GITHUB_REPOSITORY=owner/repo GREEN_RUNS=1 BEFORE=$same NOW=fail PATH="$d/bin:$PATH" \
  bash "$TODO" "$proven" x86_64-linux >"$d/out" 2>/dev/null)
check "a head that does not evaluate fails, and reports no check as unchanged" "1 0" "$? $(wc -c <"$d/out" | tr -d ' ')"
check "the workflow reads that failure, never an empty list from a pipe" "0" "$(grep -c '< <(bash .*checks-to-build[.]sh' "$STD/.github/workflows/package-ci.yml")"

echo "Test 28d: a check the source-build count leaves out is named in a warning, and the build step still builds it or fails"
d="$WORK/t28d"
mkdir -p "$d/bin"
ci_step() {
  awk -v want="      - name: $1" '
    $0 == want { inside = 1; next }
    inside && /^      - / { exit }
    inside && /^        run: \|$/ { body = 1; next }
    body { sub(/^          /, ""); print }
  ' "$STD/.github/workflows/package-ci.yml" >"$d/step.sh"
}
cat >"$d/bin/nix" <<'SH'
#!/usr/bin/env bash
case "$*" in
*currentSystem*) echo x86_64-linux ;;
*nix-eval-jobs*) cat "$JOBS" ;;
*--dry-run*) cat "$DRY" ;;
*nix-fast-build*)
  printf '%s\n' "$*" >"$BUILDER_ARGS"
  echo "ERROR:nix_fast_build:EVAL: 1 successes, 1 failures"
  exit 1
  ;;
esac
SH
chmod +x "$d/bin/nix"
cat >"$d/jobs" <<'JSON'
{"attr":"light","attrPath":["light"],"drvPath":"/nix/store/aaaa-light.drv"}
{"attr":"heavy","attrPath":["heavy"],"error":"evaluation exceeded the memory budget of 4096 MiB (workers * max-memory-size) even when run alone"}
{"attr":"broken","attrPath":["broken"],"error":"error:\n       ... while evaluating the attribute 'drvPath'\n\n       error: attribute 'missing' missing"}
JSON
printf 'these 2 derivations will be built:\n  /nix/store/aaaa-light.drv\n  /nix/store/bbbb-dep.drv\n' >"$d/dry"
counted() { (cd "$d" && JOBS="$d/jobs" DRY=$1 PATH="$d/bin:$PATH" bash -e "$d/step.sh" >"$d/log" 2>&1); }
ci_step "Flag a build-the-world bump"
counted "$d/dry"
check "each check that did not evaluate is named in a warning on one line with its reason, and the count goes on" "0 2" \
  "$? $(grep -c -e '^::warning::check heavy .*even when run alone' -e "^::warning::check broken .*error: attribute 'missing' missing" "$d/log")"
check "the count names the checks it leaves out" "1" "$(grep -c '^will build from source this run: 2, without heavy broken,' "$d/log")"
printf 'this derivation will be built:\n  /nix/store/aaaa-light.drv\n' >"$d/dry1"
counted "$d/dry1"
check "one derivation to build is counted as one" "1" "$(grep -c '^will build from source this run: 1,' "$d/log")"
ci_step "Build the checks this push changed, or every check when the commit before it is not proven"
(cd "$d" && BUILDER_ARGS="$d/builder" GITHUB_EVENT_NAME=pull_request RUNNER_TEMP=$d STD=$STD PATH="$d/bin:$PATH" bash -e "$d/step.sh" >"$d/log" 2>&1)
check "the build step hands the whole check set to the builder, and the builder's failure fails it" "1 1" \
  "$? $(grep -c -- '--flake .#checks.x86_64-linux$' "$d/builder")"

echo "Test 26: release.sh builds only what the candidate changed, on the systems this host builds"
d="$WORK/t26"
mkdir -p "$d/bin"
(
  # shellcheck source=/dev/null
  source "$STD/scripts/release.sh"
  printf '{"x86_64-linux":{"a":"/nix/store/a.drv","b":"/nix/store/b.drv"},"aarch64-linux":{"c":"/nix/store/c.drv"}}\n' >"$d/base.json"
  printf '{"x86_64-linux":{"a":"/nix/store/a.drv","b":"/nix/store/b2.drv","n":"/nix/store/n.drv"},"aarch64-linux":{"c":"/nix/store/c.drv"}}\n' >"$d/cand.json"
  check "a changed and a new check are the changed ones" "/nix/store/b2.drv /nix/store/n.drv" "$(changed_drvs "$d/base.json" "$d/cand.json" x86_64-linux | sort | tr '\n' ' ' | sed 's/ $//')"
  check "an unchanged system has nothing to build" "" "$(changed_drvs "$d/base.json" "$d/cand.json" aarch64-linux)"
  echo '{}' >"$d/empty.json"
  check "a HEAD that did not evaluate makes every candidate check changed" "3" "$(changed_drvs "$d/empty.json" "$d/cand.json" x86_64-linux | wc -l)"

  cat >"$d/bin/nix" <<'SH'
#!/usr/bin/env bash
case "$3" in
system) echo aarch64-linux ;;
extra-platforms) echo "" ;;
builders) echo "@$MACHINES" ;;
esac
SH
  chmod +x "$d/bin/nix"
  printf 'ssh-ng://a x86_64-linux,i686-linux /k 20 15 big-parallel - -\n# ssh-ng://b riscv64-linux /k 1 1 - - -\n' >"$d/machines"
  check "the host system and every builder's systems are buildable" "aarch64-linux i686-linux x86_64-linux" \
    "$(PATH="$d/bin:$PATH" MACHINES="$d/machines" build_systems | sort -u | tr '\n' ' ' | sed 's/ $//')"

  STD="$d/std"
  git init -q "$STD"
  git -C "$STD" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$STD" tag v2.42.0
  git -C "$STD" tag v2.9.0
  if newer_than_every_tag v3.0.0; then r=newer; else r=refused; fi
  check "a version past the newest tag is accepted" "newer" "$r"
  if newer_than_every_tag v2.42.0; then r=newer; else r=refused; fi
  check "the newest tag itself is refused" "refused" "$r"
  if newer_than_every_tag v2.10.0; then r=newer; else r=refused; fi
  check "a version older than the newest tag is refused, compared as versions" "refused" "$r"

  git init -q --bare "$d/remote.git"
  git -C "$STD" remote add origin "$d/remote.git"
  git -C "$STD" config user.name t
  git -C "$STD" config user.email t@t
  cat >"$d/remote.git/hooks/update" <<'SH'
#!/bin/sh
[ "$1" = refs/heads/release ] && exit 1
exit 0
SH
  chmod +x "$d/remote.git/hooks/update"
  echo notes >"$d/tagmsg"
  sha=$(git -C "$STD" rev-parse HEAD)
  if (publish "$STD" v3.0.0 "$d/tagmsg" "$sha") >"$d/publish.log" 2>&1; then rc=0; else rc=1; fi
  check "a refused branch move leaves no tag on the remote and none here" "1 0 0" \
    "$rc $(git -C "$d/remote.git" tag -l v3.0.0 | wc -l) $(git -C "$STD" tag -l v3.0.0 | wc -l)"
  rm "$d/remote.git/hooks/update"
  if (publish "$STD" v3.0.0 "$d/tagmsg" "$sha") >"$d/publish.log" 2>&1; then rc=0; else rc=1; fi
  check "the tag and the release branch arrive together" "0 1 $sha" \
    "$rc $(git -C "$d/remote.git" tag -l v3.0.0 | wc -l) $(git -C "$d/remote.git" rev-parse --verify -q refs/heads/release)"

  g() { git -C "$STD" -c user.name=t -c user.email=t@t "$@"; }
  mkdir -p "$STD/callers"
  printf '{"x/ci.yml":"callers/ci.yml","x/old.sh":null}\n' >"$STD/synced-files.json"
  printf 'one\n' >"$STD/callers/ci.yml"
  printf 'result\n' >"$STD/.gitignore"
  printf 'a\n' >"$STD/update.sh"
  g add -A && g commit -qm base && base=$(g rev-parse HEAD)
  printf 'b\n' >"$STD/update.sh"
  g commit -qam script && script=$(g rev-parse HEAD)
  printf 'result\n.devshell\n' >"$STD/.gitignore"
  g commit -qam ignore && ignore=$(g rev-parse HEAD)
  printf 'two\n' >"$STD/callers/ci.yml"
  g commit -qam caller && caller=$(g rev-parse HEAD)
  if consumers_need_roll "$base" "$script"; then r=roll; else r=none; fi
  check "a script change needs no roll" "none" "$r"
  if consumers_need_roll "$script" "$ignore"; then r=roll; else r=none; fi
  check "a new baseline .gitignore line needs a roll" "roll" "$r"
  if consumers_need_roll "$ignore" "$caller"; then r=roll; else r=none; fi
  check "a changed caller needs a roll" "roll" "$r"
  mkdir -p "$STD/heads"
  printf 'head\n' >"$STD/heads/AGENTS.md"
  g add -A && g commit -qm head && head=$(g rev-parse HEAD)
  if consumers_need_roll "$caller" "$head"; then r=roll; else r=none; fi
  check "a changed rule file head needs a roll" "roll" "$r"
  printf '%s %s\n' "$pass" "$fail" >"$d/counts"
)
read -r pass fail <"$d/counts"

echo "Test 29: retry-transient retries only a transient failure, from the checked-out tree, within its budget"
d="$WORK/t29"
mkdir -p "$d/tree"
git -C "$d/tree" init -q
printf 'pin=old\n' >"$d/tree/version.txt"
git -C "$d/tree" add version.txt
git -C "$d/tree" -c user.name=t -c user.email=t@localhost commit -qm base
cat >"$d/updater.sh" <<'UPD'
echo "attempt" >>"$COUNT"
echo "seen=$(cat version.txt)" >>"$GITHUB_OUTPUT"
if grep -q 'pin=new' version.txt; then
  echo "Already up to date"
  exit 0
fi
printf 'pin=new\n' >version.txt
touch stray-file
echo "curl: (6) Could not resolve host: upstream.example"
exit 1
UPD
retry() {
  : >"$d/count"
  : >"$d/out"
  (cd "$d/tree" && git checkout -q -- . && git clean -qfd &&
    COUNT="$d/count" GITHUB_OUTPUT="$d/out" RETRY_BACKOFFS="${BACKOFFS:-0 0}" \
      bash "$RETRY" "$d/log" "$@" -- bash "$d/updater.sh" >/dev/null 2>&1)
  RC=$?
}
retry 600 --reset-tree
check "a retry from the checked-out tree still sees the failure" "1" "$RC"
check "it retried each backoff" "3" "$(wc -l <"$d/count" | tr -d ' ')"
check "the outputs of a failed attempt do not survive the retry" "1" "$(wc -l <"$d/out" | tr -d ' ')"
check "the log holds the final attempt" "1" "$(grep -c 'Could not resolve host' "$d/log")"
retry 600
check "without the reset the failed attempt's rewrite reads as up to date" "0" "$RC"
BACKOFFS=30 retry 10 --reset-tree
check "no retry starts past the budget" "1" "$(wc -l <"$d/count" | tr -d ' ')"
sed -i 's|echo "curl: (6) Could not resolve host: upstream.example"|echo "error: builder failed with exit code 2"|' "$d/updater.sh"
retry 600 --reset-tree
check "a real failure is not retried" "1" "$(wc -l <"$d/count" | tr -d ' ')"
check "and keeps its exit code" "1" "$RC"
cat >"$d/updater.sh" <<UPD
echo "attempt" >>"\$COUNT"
cat "$WORK/t11k/rate-limited.log"
exit 1
UPD
with_escapes >"$WORK/t11k/rate-limited.log" <<'LOG'
^[[2mpackage-scx-git-full>^[[0m ^[[31;1merror:^[[0m Cannot build '^[[35;1m/nix/store/qw1m8jnzy32gkqxk23zsb8n93bcwk4k9-libbpf-linux-types-u128.patch.drv^[[0m'.^[[0m
^[[2mpackage-scx-git-full>^[[0m        Reason: ^[[31;1mbuilder failed with exit code 1^[[0m.^[[0m
^[[2mpackage-scx-git-full>^[[0m        > curl: (22) The requested URL returned error: 429
^[[2mpackage-scx-git-full>^[[0m        > error: cannot download libbpf-linux-types-u128.patch from any mirror
ERROR:nix_fast_build:Failed attributes: .#checks.aarch64-linux.package-scx-git-full
LOG
retry 600
check "a GitHub 429 under the prefix nix-fast-build writes is retried" "3" "$(wc -l <"$d/count" | tr -d ' ')"

echo "Test 30: the run judged is the newest own run that did work, and a stopped schedule is named"
pick() {
  jq -r --argjson now 1793800000 --argjson scheduled "$1" -f "$LATEST_RUN" <<<"$2"
}
recent=2026-11-04T10:00:00Z
old=2026-10-30T10:00:00Z
check "a cadence-skipped day does not hide the run that did work" "completed/success" \
  "$(pick true "[{\"event\":\"schedule\",\"status\":\"completed\",\"conclusion\":\"skipped\",\"createdAt\":\"$recent\"},{\"event\":\"schedule\",\"status\":\"completed\",\"conclusion\":\"success\",\"createdAt\":\"$old\"}]")"
check "a fork pull request on main is not the repo's own run" "completed/failure" \
  "$(pick false "[{\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\",\"createdAt\":\"$recent\"},{\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"failure\",\"createdAt\":\"$old\"}]")"
check "a workflow that only skipped is named with its count" "cadence-only/2" \
  "$(pick true "[{\"event\":\"schedule\",\"status\":\"completed\",\"conclusion\":\"skipped\",\"createdAt\":\"$recent\"},{\"event\":\"schedule\",\"status\":\"completed\",\"conclusion\":\"skipped\",\"createdAt\":\"$recent\"}]")"
check "a schedule with no run for days reads stopped, not green" "stopped/5" \
  "$(pick true "[{\"event\":\"schedule\",\"status\":\"completed\",\"conclusion\":\"success\",\"createdAt\":\"$old\"}]")"
check "a push-only workflow is never read as a stopped schedule" "completed/success" \
  "$(pick false "[{\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"success\",\"createdAt\":\"$old\"}]")"
check "no run at all is none" "none" "$(pick true '[]')"

# ---- Test 31: a hash field is rewritten once --------------------------------
# A repo with one channel per major keeps the pinned releases under the same
# field names as the rolling one (umu-proton-nix: hashX64 at the top and in
# each pin). set_hash used to rewrite every line that named the field, so the
# first update would have dummied and then overwritten every pin's hash with
# the rolling release's.
echo "Test 31: a hash field is rewritten once, the pinned release below keeps its own"
d="$WORK/t31"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "umu",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^GE-Proton" },
  "packageFile": "sources.nix", "hashes": [ "hashX64" ], "verify": { "check": "eval" } }
JSON
cat >"$d/sources.nix" <<'NIX'
{
  version = "GE-Proton11-1";
  hashX64 = "sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDA=";
  pins = {
    "GE-Proton10-34" = {
      hashX64 = "sha256-PINPINPINPINPINPINPINPINPINPINPINPINPINPINA=";
    };
  };
}
NIX
NEWHASH="sha256-NEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWA="
cat >"$WORK/mismatch31.txt" <<EOF
error: hash mismatch in fixed-output derivation '/nix/store/zzz-source.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    $NEWHASH
EOF
STUB_CURL_FILE="$FIXTURES/ge-releases.json" STUB_NIX_MISMATCH="$WORK/mismatch31.txt" run_update "$d"
check "update exits 0" "0" "$RC"
check "version bumped" "GE-Proton11-2" "$(get "$d" new_version)"
check "the rolling hash took the new value" "1" "$(grep -c "^  hashX64 = \"$NEWHASH\";" "$d/sources.nix")"
check "the pinned hash kept its own" "1" "$(grep -c 'sha256-PINPIN' "$d/sources.nix")"
check "no dummy hash was left behind" "0" "$(grep -c 'sha256-AAAA' "$d/sources.nix")"

# ---- Test 32: majorPattern pins the outgoing major ---------------------------
# A repo with one channel per major builds v10 from pins and latest from the
# rolling block. The day upstream opens major 11, latest moves on; without a
# pin for the last 10 the v10 channel vanishes and every consumer naming it
# breaks. With majorPattern the updater freezes the outgoing release first.
echo "Test 32: majorPattern pins the outgoing major before latest moves on"
d="$WORK/t32"
mkdir -p "$d/.github"
cat >"$d/.github/update.json" <<'JSON'
{ "package": "ge",
  "upstream": { "type": "github-release", "owner": "o", "repo": "r", "tagFilter": "^GE-Proton" },
  "packageFile": "package.nix", "versionFile": "sources.nix",
  "majorPattern": "GE-Proton([0-9]+)-.*",
  "variantAssets": { "sourceFile": "sources.nix", "assetPrefix": "",
                     "assetSuffix": ".tar.gz", "defaultVariant": "x86_64" },
  "hashes": [], "verify": { "check": "eval" } }
JSON
cat >"$d/sources.nix" <<'NIX'
{
  # std:rolling-begin
  version = "GE-Proton10-34";
  # std:variants-begin
  variants = {
    x86_64 = "sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDA=";
  };
  # std:variants-end
  # std:rolling-end
  pins = {
    # std:pins-begin
    "GE-Proton9-27" = {
      variants = {
        x86_64 = "sha256-PINPINPINPINPINPINPINPINPINPINPINPINPINPINA=";
      };
    };
    # std:pins-end
  };
}
NIX
: >"$d/package.nix"
: >"$d/.nixflag"
STUB_CURL_FILE="$FIXTURES/ge-releases.json" run_update "$d"
check "rollover exits 0" "0" "$RC"
check "latest moved to the new major" "GE-Proton11-2" "$(get "$d" new_version)"
check "the outgoing release is reported pinned" "GE-Proton10-34" "$(get "$d" pinned)"
check "the new pin sits first in the pins block" "1" "$(grep -A1 'std:pins-begin' "$d/sources.nix" | grep -c '^    "GE-Proton10-34" = {$')"
check "the new pin carries the outgoing hash at pin depth" "1" "$(grep -c '^        x86_64 = "sha256-OLDOLD' "$d/sources.nix")"
check "the rolling variants no longer hold the outgoing hash" "0" "$(grep -c '^    x86_64 = "sha256-OLDOLD' "$d/sources.nix")"
check "the older pin is untouched" "1" "$(grep -c 'sha256-PINPIN' "$d/sources.nix")"
check "no marker was copied into the pin" "1" "$(grep -c 'std:variants-begin' "$d/sources.nix")"
check "the rolling version line is the only version line" "1" "$(grep -c '^  version = ' "$d/sources.nix")"

rolling_fixture() { # rolling_fixture <version> <with-markers: 1|0>
  local v=$1 begin="  # std:rolling-begin" end="  # std:rolling-end" pb="    # std:pins-begin" pe="    # std:pins-end"
  if [ "$2" != 1 ]; then
    begin=''
    end=''
    pb=''
    pe=''
  fi
  cat <<NIX | sed '/^$/d'
{
$begin
  version = "$v";
  # std:variants-begin
  variants = {
    x86_64 = "sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDA=";
  };
  # std:variants-end
$end
  pins = {
$pb
    "GE-Proton9-27" = {
      variants = {
        x86_64 = "sha256-PINPINPINPINPINPINPINPINPINPINPINPINPINPINA=";
      };
    };
$pe
  };
}
NIX
}

echo "Test 32b: a release inside the same major pins nothing"
d="$WORK/t32b"
mkdir -p "$d/.github"
cp "$WORK/t32/.github/update.json" "$d/.github/update.json"
rolling_fixture GE-Proton11-1 1 >"$d/sources.nix"
: >"$d/package.nix"
: >"$d/.nixflag"
STUB_CURL_FILE="$FIXTURES/ge-releases.json" run_update "$d"
check "same-major update exits 0" "0" "$RC"
check "the update was applied" "true" "$(get "$d" updated)"
check "version bumped within the major" "GE-Proton11-2" "$(get "$d" new_version)"
check "nothing reported pinned" "" "$(get "$d" pinned)"
check "the pins block still holds the one pin" "1" "$(grep -c '^    "GE-Proton[0-9-]*" = {$' "$d/sources.nix")"

echo "Test 32c: majorPattern without the markers fails closed"
d="$WORK/t32c"
mkdir -p "$d/.github"
cp "$WORK/t32/.github/update.json" "$d/.github/update.json"
rolling_fixture GE-Proton10-34 0 >"$d/sources.nix"
: >"$d/package.nix"
STUB_CURL_FILE="$FIXTURES/ge-releases.json" run_update "$d"
check "missing markers exit 1" "1" "$RC"
check "error_type config-error" "config-error" "$(get "$d" error_type)"
check "sources.nix was not rewritten" "GE-Proton10-34" "$(sed -nE 's/^  version = "(.*)";$/\1/p' "$d/sources.nix")"

echo "Test 33: fleet-roll reinstalls a missing pre-commit hook whose config link is already current"
d="$WORK/t33"
mkdir -p "$d/bin" "$d/repo/.git/hooks"
printf 'hooks: []\n' >"$d/config.yaml"
ln -s "$d/config.yaml" "$d/repo/.pre-commit-config.yaml"
cat >"$d/bin/nix" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = develop ] || exit 0
if [ "$(readlink .pre-commit-config.yaml 2>/dev/null)" != "$STUB_CONFIG" ]; then
  [ -L .pre-commit-config.yaml ] && unlink .pre-commit-config.yaml
  ln -s "$STUB_CONFIG" .pre-commit-config.yaml
  printf '#!/usr/bin/env bash\nexec /nix/store/00000000000000000000000000000000-pre-commit/bin/pre-commit "$@"\n' >.git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
fi
SH
chmod +x "$d/bin/nix"
(
  eval "$(sed -n '/^hook_live() {$/,/^}$/p; /^refresh_hook() {$/,/^}$/p' "$ROLL")"
  export steplog="$d/steps.log" RELEASE_TREE="$d/std"
  PATH="$d/bin:$PATH" STUB_CONFIG="$d/config.yaml" refresh_hook "$d/repo"
  check "the hook is installed although the config link already pointed at the current config, where git-hooks.nix installs nothing" "present" "$([ -x "$d/repo/.git/hooks/pre-commit" ] && echo present || echo absent)"
  check "the config link points at the current config again" "$d/config.yaml" "$(readlink "$d/repo/.pre-commit-config.yaml")"
  printf '%s %s\n' "$pass" "$fail" >"$d/counts"
)
read -r pass fail <"$d/counts"

echo "Test 34: the every-system evaluation refuses a read of a derivation output at evaluation time, even when the store holds the file"
d="$WORK/t34"
mkdir -p "$d/ifd-at-eval" "$d/ifd-free"
sys=$(nix eval --impure --raw --expr 'builtins.currentSystem')
sed "s/@system@/$sys/" "$FIXTURES/ifd-at-eval/flake.nix" >"$d/ifd-at-eval/flake.nix"
sed "s/@system@/$sys/" "$FIXTURES/ifd-free/flake.nix" >"$d/ifd-free/flake.nix"
nix build --no-link --option allow-import-from-derivation true "path:$d/ifd-at-eval#checks.$sys.reads-at-eval" >"$d/build.log" 2>&1
check "the fixture builds, so the file it reads at evaluation is valid in the store" "0" "$?"
(cd "$d/ifd-at-eval" && bash "$EVAL") >"$d/ifd.log" 2>&1
check "a check reading a derivation output at evaluation fails although the store holds the file" "1" "$?"
check "and the failure names import from derivation" "yes" "$(grep -q 'import from derivation' "$d/ifd.log" && echo yes || echo no)"
(cd "$d/ifd-free" && bash "$EVAL") >"$d/free.log" 2>&1
check "a check reading the same file in its build step passes" "0" "$?"

echo "Test 35: check-baselines-shrink lets a baseline shrink and a floor rise, and refuses the opposite"
d="$WORK/t35"
b="$d/.std/baseline"
mkdir -p "$b"
g() { git -C "$d" -c user.name=t -c user.email=t@t "$@"; }
step() {
  g add .std
  g commit -q -m "$1"
}
shrink() { (cd "$d" && bash "$SHRINK" "$1" "$2" >"$d/log" 2>&1); }
g init -q
printf 'one\ntwo\n' >"$b/vulture.py"
printf '77\n' >"$b/coverage-python.floor"
printf '{\n"a": 1,\n"b": 2\n}\n' >"$b/basedpyright.json"
step start
shrink "" HEAD
check "a first commit has nothing before it and passes" "0" "$?"
printf 'one\n' >"$b/vulture.py"
printf '80\n' >"$b/coverage-python.floor"
printf '{\n"a": 1\n}\n' >"$b/basedpyright.json"
printf 'nullPointer:main.cpp\n' >"$b/cppcheck.txt"
step better
shrink HEAD~1 HEAD
check "a shorter baseline, a higher floor and a new baseline file pass" "0" "$?"
check "the new baseline file is named as new" "1" "$(grep -c '^new  .std/baseline/cppcheck.txt' "$d/log")"
printf 'one\nthree\n' >"$b/vulture.py"
step grown
shrink HEAD~1 HEAD
check "a baseline that gained a line is refused" "1" "$?"
check "and the file is named" "1" "$(grep -c '^FAIL .std/baseline/vulture.py gained 1 line' "$d/log")"
shrink 0000000000000000000000000000000000000000 HEAD
check "an unknown base compares the head with its first parent, and the growth is still refused" "1" "$?"
printf 'four\nthree\n' >"$b/vulture.py"
step swapped
shrink HEAD~1 HEAD
check "a line swapped for another, the count unchanged, is refused" "1" "$?"
printf '79\n' >"$b/coverage-python.floor"
step dropped
shrink HEAD~1 HEAD
check "a floor that dropped is refused" "1" "$?"
check "and the drop is named" "1" "$(grep -c 'drops the floor from 80 to 79' "$d/log")"
printf 'about eighty\n' >"$b/coverage-python.floor"
step garbled
shrink HEAD~1 HEAD
check "a floor that is not a whole number is refused" "1" "$?"
printf '{\n"a": 1,\n"c": 3\n}\n' >"$b/basedpyright.json"
step longer
shrink HEAD~1 HEAD
check "a JSON baseline with more lines is refused" "1" "$?"
shrink HEAD~1 nosuchcommit
check "a head that is no commit fails" "1" "$?"

echo "Test 36: check-assistant-files refuses a rules file over 200 lines, a path under /home and a personal email address"
d="$WORK/t36"
mkdir -p "$d"
seq 200 >"$d/CLAUDE.md"
seq 201 >"$d/AGENTS.md"
bash "$ASSIST" "$d/CLAUDE.md" >"$d/log" 2>&1
check "a file of 200 lines passes" "0" "$?"
bash "$ASSIST" "$d/CLAUDE.md" "$d/AGENTS.md" >"$d/log" 2>&1
check "a file of 201 lines is refused" "1" "$?"
check "and it is named with its length" "1" "$(grep -c 'AGENTS.md is 201 lines' "$d/log")"
printf 'Build in /home/someone/work.\n' >"$d/AGENTS.md"
bash "$ASSIST" "$d/AGENTS.md" >"$d/log" 2>&1
check "a path under /home is refused" "1" "$?"
printf 'Ask a.person@example.org.\n' >"$d/AGENTS.md"
bash "$ASSIST" "$d/AGENTS.md" >"$d/log" 2>&1
check "a personal email address is refused" "1" "$?"
check "and it is named" "1" "$(grep -c 'a.person@example.org' "$d/log")"
printf 'Credit 1+someone@users.noreply.github.com.\n' >"$d/AGENTS.md"
bash "$ASSIST" "$d/AGENTS.md" >"$d/log" 2>&1
check "a GitHub noreply address passes" "0" "$?"
bash "$ASSIST" "$HEADS/AGENTS.md" "$HEADS/CONTRIBUTING.md" >"$d/log" 2>&1
check "the standard's own heads pass" "0" "$?"

echo "Test 36b: check-no-errands refuses a line about who asks or waits, and reads no code"
ERRANDS="$HEADS/../scripts/check-no-errands.sh"
printf '# Notes\n\nOpen: does the vendor ship the 16K build?\n' >"$d/open.md"
bash "$ERRANDS" "$d/open.md" >"$d/log" 2>&1
check "an open point written as its question passes" "0" "$?"
printf '# Notes\n\nSam will ask the vendor about the 16K build.\n' >"$d/errand.md"
bash "$ERRANDS" "$d/errand.md" >"$d/log" 2>&1
check "a line about someone asking someone is refused" "1" "$?"
check "and it is named with its file and line" "1" "$(grep -c 'errand.md:3: ' "$d/log")"
printf '# Notes\n\nWaiting for the answer from upstream before the next release.\n' >"$d/waiting.md"
bash "$ERRANDS" "$d/waiting.md" >"$d/log" 2>&1
check "a line about waiting for an answer is refused" "1" "$?"
cat >"$d/code.md" <<'MD'
# Notes

```sh
echo "will ask the server"
```

~~~
will ask the server
~~~

The flag `will ask` prompts.
MD
bash "$ERRANDS" "$d/code.md" >"$d/log" 2>&1
check "the same words in a fenced block of either kind or in inline code pass" "0" "$?"
bash "$ERRANDS" "$HEADS/AGENTS.md" "$HEADS/CONTRIBUTING.md" "$HEADS/../README.md" >"$d/log" 2>&1
check "the standard's own rules and README pass" "0" "$?"

echo "Test 36c: untyped-issues.jq names an open issue from a person that has no single type"
UNTYPED="$HEADS/../scripts/untyped-issues.jq"
cat >"$d/issues.json" <<'JSON'
[
  {"number": 1, "title": "typed", "labels": [{"name": "type/bug"}, {"name": "waiting"}]},
  {"number": 2, "title": "bare", "labels": []},
  {"number": 3, "title": "old label", "labels": [{"name": "bug"}]},
  {"number": 4, "title": "two types", "labels": [{"name": "type/bug"}, {"name": "type/task"}]},
  {"number": 5, "title": "a failed refresh", "labels": [{"name": "maintenance"}]},
  {"number": 6, "title": "a failed update", "labels": [{"name": "update-failed"}]}
]
JSON
check "one without a type, one with an old label and one with two types are named, the automation's own are not" \
  "#2 bare; #3 old label; #4 two types" "$(jq -r -f "$UNTYPED" "$d/issues.json")"
echo '[{"number": 1, "title": "typed", "labels": [{"name": "type/task"}]}]' >"$d/typed.json"
check "a repo whose issues all carry one type names nothing" "" "$(jq -r -f "$UNTYPED" "$d/typed.json")"
UNSCOPED="$HEADS/../scripts/unscoped-issues.jq"
cat >"$d/titles.json" <<'JSON'
[
  {"number": 1, "title": "overlay: the frame counter drifts", "labels": [{"name": "type/bug"}]},
  {"number": 2, "title": "The frame counter drifts", "labels": [{"name": "type/bug"}]},
  {"number": 3, "title": "MAKO, lsfg-vk: frame generation on another GPU", "labels": [{"name": "upstream"}]},
  {"number": 4, "title": "Question: does it run on arm", "labels": []},
  {"number": 5, "title": "see https://example.org/x for details", "labels": []},
  {"number": 6, "title": "No part here", "labels": [{"name": "maintenance"}]}
]
JSON
check "a title without a part and a colon is named, also when its only colon sits in a link, and the automation's own is not" \
  "#2 The frame counter drifts; #5 see https://example.org/x for details" "$(jq -r -f "$UNSCOPED" "$d/titles.json")"

echo "Test 37: check-readme-sections holds a title and an install section, and asks for no marker"
readme_case() { # readme_case <name> <line>...  -> runs the hook in a directory holding that README
  d="$WORK/t37-$1"
  mkdir -p "$d"
  shift
  printf '%s\n' "$@" >"$d/README.md"
  (cd "$d" && bash "$SECTIONS" >"$d/log" 2>&1)
}
readme_case plain '# Tool' '' 'What it is.' '' '## Install' '' 'How.'
check "a page with a title and an install section passes, with no marker in it" "0" "$?"
readme_case quick '# Tool' '' '## Quick Start'
check "Quick Start counts as the install section" "0" "$?"
readme_case untitled 'What it is.' '' '## Installation'
check "a page with no title is refused" "1" "$?"
check "and the refusal says so" "1" "$(grep -c 'no title' "$d/log")"
readme_case uninstallable '# Tool' '' '## Usage' '' '<!-- BEGIN generated:installation -->'
check "a marker is not an install section" "1" "$?"
check "and the refusal names the section" "1" "$(grep -c 'how to install it' "$d/log")"
echo "Test 38: sync.sh writes the rule files, rewrites only their head, refuses one it cannot merge, and stops ignoring AGENTS.md"
d="$WORK/t38"
for r in fresh own unmergeable; do
  mkdir -p "$d/$r/.git" "$d/$r/.github"
  printf '{"upstream":{"type":"none"}}\n' >"$d/$r/.github/update.json"
done
printf 'result\nAGENTS.md\nCLAUDE.md\n' >"$d/fresh/.gitignore"
PKG_REPOS_DIR="$d" bash "$SYNC" --check fresh >/dev/null
check "a repo with no rule files is reported as drift" "1" "$?"
check "--check writes no rule file" "absent" "$([ -e "$d/fresh/AGENTS.md" ] && echo present || echo absent)"
PKG_REPOS_DIR="$d" bash "$SYNC" fresh >"$d/log"
check "sync exits clean on a repo with no rule files" "0" "$?"
if cmp -s "$HEADS/AGENTS.md" "$d/fresh/AGENTS.md"; then same=yes; else same=no; fi
check "a new AGENTS.md is the head" "yes" "$same"
if cmp -s "$HEADS/CONTRIBUTING.md" "$d/fresh/CONTRIBUTING.md"; then same=yes; else same=no; fi
check "a new CONTRIBUTING.md is the head" "yes" "$same"
check "AGENTS.md leaves the ignore list" "0" "$(grep -cxF 'AGENTS.md' "$d/fresh/.gitignore")"
check "CLAUDE.md stays on the ignore list" "1" "$(grep -cxF 'CLAUDE.md' "$d/fresh/.gitignore")"
PKG_REPOS_DIR="$d" bash "$SYNC" --check fresh >/dev/null
check "a synced repo is in sync" "0" "$?"
printf '# AGENTS.md\n\nAn older head.\n\n## This project\n\nBuild with make.\n' >"$d/own/AGENTS.md"
cp "$HEADS/CONTRIBUTING.md" "$d/own/CONTRIBUTING.md"
printf '\nTag a release by hand.\n' >>"$d/own/CONTRIBUTING.md"
PKG_REPOS_DIR="$d" bash "$SYNC" own >"$d/log"
check "sync exits clean on a repo with its own part" "0" "$?"
if cmp -s -n "$(wc -c <"$HEADS/AGENTS.md")" "$HEADS/AGENTS.md" "$d/own/AGENTS.md"; then same=yes; else same=no; fi
check "an older head is rewritten" "yes" "$same"
check "the repo's own part is kept" "Build with make." "$(tail -n 1 "$d/own/AGENTS.md")"
check "a file that already begins with the head is left alone" "Tag a release by hand." "$(tail -n 1 "$d/own/CONTRIBUTING.md")"
for name in AGENTS.md CONTRIBUTING.md; do
  if cmp -s -n "$(wc -c <"$HEADS/$name")" "$HEADS/$name" "$HEADS/../$name"; then same=yes; else same=no; fi
  check "the standard's own $name begins with its head" "yes" "$same"
done
printf '# Contributing\n\nSend a patch.\n' >"$d/unmergeable/CONTRIBUTING.md"
PKG_REPOS_DIR="$d" bash "$SYNC" unmergeable >"$d/log"
check "a rules file with no This project heading fails the sync" "1" "$?"
check "and it is named" "1" "$(grep -c 'MERGE  unmergeable/CONTRIBUTING.md' "$d/log")"
check "and its content is untouched" "Send a patch." "$(tail -n 1 "$d/unmergeable/CONTRIBUTING.md")"

echo "Test 39: sync-meta.sh names a repo that lacks a label and creates only the missing ones"
d="$WORK/t40"
mkdir -p "$d/repos/plain/.git" "$d/repos/plain/.github" "$d/bin"
git -C "$d/repos/plain" init -q
git -C "$d/repos/plain" remote add origin https://github.com/owner/plain.git
printf '{"description":"Plain packaged for NixOS","topics":["nix"]}\n' >"$d/repos/plain/.github/update.json"
cat >"$d/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$GH_CALLS"
case "$1 $2" in
"repo view") printf '{"description":"Plain packaged for NixOS","repositoryTopics":[{"name":"nix"}]}\n' ;;
"label list") cat "$GH_LABELS" ;;
esac
SH
chmod +x "$d/bin/gh"
printf 'type/bug\ntype/feature\ntype/task\nlater\nupstream\n' >"$d/labels"
GH_CALLS="$d/calls" GH_LABELS="$d/labels" PATH="$d/bin:$PATH" PKG_REPOS_DIR="$d/repos" bash "$HEADS/../sync-meta.sh" --check plain >"$d/log" 2>&1
check "a repo lacking one label is drift" "1" "$?"
check "and the drift is named as labels" "1" "$(grep -c 'DRIFT  plain \[labels\]' "$d/log")"
: >"$d/calls"
GH_CALLS="$d/calls" GH_LABELS="$d/labels" PATH="$d/bin:$PATH" PKG_REPOS_DIR="$d/repos" bash "$HEADS/../sync-meta.sh" plain >"$d/log" 2>&1
check "the missing label is created" "1" "$(grep -c '^label create waiting ' "$d/calls")"
check "and no label that exists is created again" "1" "$(grep -c '^label create ' "$d/calls")"
printf 'waiting\n' >>"$d/labels"
GH_CALLS="$d/calls" GH_LABELS="$d/labels" PATH="$d/bin:$PATH" PKG_REPOS_DIR="$d/repos" bash "$HEADS/../sync-meta.sh" --check plain >"$d/log" 2>&1
check "a repo with every label is in sync" "0" "$?"
printf 'type/bug\ntype/feature\ntype/task\nlater\nwaiting\n' >"$d/labels"
GH_CALLS="$d/calls" GH_LABELS="$d/labels" PATH="$d/bin:$PATH" PKG_REPOS_DIR="$d/repos" bash "$HEADS/../sync-meta.sh" --check plain >"$d/log" 2>&1
check "a repo without the label for a matter another project must change is drift" "1" "$?"
printf 'upstream\nbug\nenhancement\n' >>"$d/labels"
GH_CALLS="$d/calls" GH_LABELS="$d/labels" PATH="$d/bin:$PATH" PKG_REPOS_DIR="$d/repos" bash "$HEADS/../sync-meta.sh" --check plain >"$d/log" 2>&1
check "a repo that still carries the forge's default labels is drift" "1" "$?"
: >"$d/calls"
GH_CALLS="$d/calls" GH_LABELS="$d/labels" PATH="$d/bin:$PATH" PKG_REPOS_DIR="$d/repos" bash "$HEADS/../sync-meta.sh" plain >"$d/log" 2>&1
check "each default label it carries is removed" "2" "$(grep -cE '^label delete (bug|enhancement) ' "$d/calls")"
check "and no label of the set is removed" "0" "$(grep -cE '^label delete (type/|later|waiting|upstream)' "$d/calls")"
mkdir -p "$d/repos/forms/.github/ISSUE_TEMPLATE"
git -C "$d/repos/forms" init -q
git -C "$d/repos/forms" remote add origin https://github.com/owner/forms.git
: >"$d/repos/forms/.github/ISSUE_TEMPLATE/task.yml"
printf 'type/bug\n' >"$d/labels"
GH_CALLS="$d/calls" GH_LABELS="$d/labels" PATH="$d/bin:$PATH" PKG_REPOS_DIR="$d/repos" bash "$HEADS/../sync-meta.sh" --check forms >"$d/log" 2>&1
check "a repo that carries the issue forms and no update.json is held to the labels too" "1" "$?"
check "and its drift is named as labels" "1" "$(grep -c 'DRIFT  forms \[labels\]' "$d/log")"

echo "Test 40: fleet-roll's restore removes a file the sync wrote, also one the restored ignore list hides again"
d="$WORK/t41"
mkdir -p "$d/repo"
git -C "$d/repo" init -q
printf 'result\nAGENTS.md\n' >"$d/repo/.gitignore"
git -C "$d/repo" add .gitignore
git -C "$d/repo" -c user.name=t -c user.email=t@t commit -qm base
printf 'result\n' >"$d/repo/.gitignore"
printf 'head\n' >"$d/repo/AGENTS.md"
printf 'head\n' >"$d/repo/CONTRIBUTING.md"
(
  eval "$(sed -n '/^restore() {$/,/^}$/p' "$HEADS/../scripts/fleet-roll.sh")"
  restore "$d/repo"
)
check "the rule file the old ignore list hides is gone" "absent" "$([ -e "$d/repo/AGENTS.md" ] && echo present || echo absent)"
check "the other written file is gone" "absent" "$([ -e "$d/repo/CONTRIBUTING.md" ] && echo present || echo absent)"
check "the ignore list is the committed one again" "1" "$(grep -cxF 'AGENTS.md' "$d/repo/.gitignore")"
check "and the repo is clean" "" "$(git -C "$d/repo" status --porcelain --ignored)"

echo "Test 41: the Track work section holds the words the owner fixed"
track_words() {
  awk '/^## Track work$/{on=1; print; next} on && /^## /{exit} on' "$1" | tr -s '[:space:]' ' ' | sed 's/ $//' | sha256sum | cut -d' ' -f1
}
fixed=aaa2d4ba212759c45833ba55dc40ca42263173daee06e02da4bdbddb8d1da803
check "heads/CONTRIBUTING.md carries them; a change needs his word and this value in the same commit" "$fixed" "$(track_words "$HEADS/CONTRIBUTING.md")"
sed 's/two cases only/three cases only/' "$HEADS/CONTRIBUTING.md" >"$WORK/t39.md"
if [ "$(track_words "$WORK/t39.md")" = "$fixed" ]; then rc=same; else rc=differs; fi
check "one changed word gives another value" "differs" "$rc"
sed 's/^- An open task is an issue in the repo it belongs to. /- An open task is an issue in the repo it belongs to.\n  /' "$HEADS/CONTRIBUTING.md" >"$WORK/t39.md"
check "another line wrap gives the same value" "$fixed" "$(track_words "$WORK/t39.md")"

echo "Test 41b: fleet-roll names a failed push by its cause, and a push the remote took counts as pushed"
d="$WORK/t41b"
mkdir -p "$d"
cat >"$d/network" <<'LOG'
std-home-proof...........................................................Passed
error: RPC failed; curl 56 Recv failure: Connection reset by peer
LOG
cat >"$d/hook" <<'LOG'
std-home-proof...........................................................Failed
error: failed to push some refs
LOG
git init -q --bare "$d/remote.git"
git init -q -b main "$d/clone"
git -C "$d/clone" remote add origin "$d/remote.git"
git -C "$d/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$d/clone" push -q origin main
(
  eval "$(sed -n '/^why_push_failed() {$/,/^}$/p' "$HEADS/../scripts/fleet-roll.sh")"
  eval "$(sed -n '/^remote_holds_head() {$/,/^}$/p' "$HEADS/../scripts/fleet-roll.sh")"
  eval "$(grep -x 'BRANCH=main' "$HEADS/../scripts/fleet-roll.sh")"
  check "a network failure after the hooks passed is not blamed on a hook" \
    "error: RPC failed; curl 56 Recv failure: Connection reset by peer" "$(why_push_failed "$d/network")"
  check "a failed hook is named as the hook" "1" "$(why_push_failed "$d/hook" | grep -c 'pre-push hook refused')"
  if remote_holds_head "$d/clone"; then r=held; else r=missing; fi
  check "a commit the remote holds counts as pushed" "held" "$r"
  git -C "$d/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m next
  if remote_holds_head "$d/clone"; then r=held; else r=missing; fi
  check "a commit the remote does not hold does not" "missing" "$r"
  git -C "$d/clone" switch -q -c testing
  git -C "$d/clone" push -q origin testing
  if BRANCH=testing remote_holds_head "$d/clone"; then r=held; else r=missing; fi
  check "a roll into another branch asks the remote for that branch" "held" "$r"
  if BRANCH=main remote_holds_head "$d/clone"; then r=held; else r=missing; fi
  check "and the main branch there still does not hold it" "missing" "$r"
  printf '%s %s\n' "$pass" "$fail" >"$d/counts"
)
read -r pass fail <"$d/counts"

echo "Test 41c: fleet-roll rolls into the branch it is given, main when none is"
PKG_REPOS_DIR="$d" bash "$ROLL" --help >"$d/help"
check "the usage names the option" "1" "$(grep -c -- '--branch <name>' "$d/help")"
PKG_REPOS_DIR="$d" bash "$ROLL" --branch >"$d/out" 2>&1
check "a branch option without a name is refused" "2 1" "$? $(grep -c 'requires the name of a branch' "$d/out")"
check "no step names the main branch outright" "0" "$(grep -c 'origin/main\|push origin main\|refs/heads/main\|expected main' "$ROLL")"

standard_root="${HEADS%/heads}"
echo "Test 42: a repo carries main, and testing for a next release, and no other branch"
check "main and testing are no extra branch" "" "$(printf 'main\ntesting\n' | bash "$standard_root/scripts/extra-branches.sh")"
check "any other branch is named" "exp/try update/pkg-1.2" "$(printf 'main\nexp/try\ntesting\nupdate/pkg-1.2\n' | bash "$standard_root/scripts/extra-branches.sh" | tr '\n' ' ' | sed 's/ $//')"
check "a branch that only starts like testing is named" "testing-old" "$(printf 'main\ntesting-old\n' | bash "$standard_root/scripts/extra-branches.sh")"
check "the CI every repo carries runs on a push to testing" "1" "$(grep -c 'branches: \[main, master, testing\]' "$standard_root/callers/ci.yml")"
check "the audit reads the same list, for GitHub and for the clone" "2" "$(grep -c 'scripts/extra-branches.sh' "$standard_root/scripts/fleet-audit.sh")"

echo "Test 43: every check is built through build-checks.sh, its evaluation workers sized to the available memory"
d="$WORK/t43"
mkdir -p "$d/bin"
cat >"$d/bin/nix" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >"$NIX_ARGS"
STUB
chmod +x "$d/bin/nix"
cores=$(nproc)
sized() {
  printf 'MemTotal: 99999999 kB\nMemAvailable: %s kB\n' "$1" >"$d/meminfo"
  : >"$d/args"
  (cd "$d" && PATH="$d/bin:$PATH" MEMINFO="$d/meminfo" NIX_ARGS="$d/args" bash "$standard_root/build-checks.sh" x86_64-linux >/dev/null 2>&1)
  RC=$?
}
workers() { sed -n 's/.*--eval-workers \([0-9]*\).*/\1/p' "$d/args"; }
sized $((5 * 1024 * 1024))
check "less memory than one worker needs still evaluates on one" "1" "$(workers)"
check "each worker restarts at its stated size" "1" "$(grep -c -- '--eval-max-memory-size 4096' "$d/args")"
check "one build task per core" "1" "$(grep -c -- "-j $cores " "$d/args")"
check "the checks of the system it is given are built" "1" "$(grep -c -- '--flake .#checks.x86_64-linux$' "$d/args")"
sized $((12 * 1024 * 1024))
check "a worker per 6 GiB available" "$((cores < 2 ? cores : 2))" "$(workers)"
sized $((1024 * 1024 * 1024))
check "never more workers than cores" "$cores" "$(workers)"
printf 'MemTotal: 1 kB\n' >"$d/meminfo"
(cd "$d" && PATH="$d/bin:$PATH" MEMINFO="$d/meminfo" NIX_ARGS="$d/args" bash "$standard_root/build-checks.sh" x86_64-linux >/dev/null 2>&1)
check "a meminfo without MemAvailable is refused" "2" "$?"
check "the standard builds through build-checks.sh alone" "0" "$(
  bash "$standard_root/scripts/check-fast-build-callers.sh" "$standard_root" >/dev/null 2>&1
  echo $?
)"
mkdir -p "$d/tree/scripts" "$d/tree/.github/workflows"
cp "$standard_root/build-checks.sh" "$d/tree/"
mkdir -p "$d/tree/.devshell/work/copy"
cp "$standard_root/build-checks.sh" "$d/tree/.devshell/work/copy/"
check "a copy under the ignored dev state is not a caller" "0" "$(
  bash "$standard_root/scripts/check-fast-build-callers.sh" "$d/tree" >/dev/null 2>&1
  echo $?
)"
printf 'run: nix run --inputs-from . nixpkgs#nix-fast-build -- --flake .#checks.x\n' >"$d/tree/.github/workflows/ci.yml"
check "a workflow running nix-fast-build itself is refused" "1" "$(
  bash "$standard_root/scripts/check-fast-build-callers.sh" "$d/tree" >/dev/null 2>&1
  echo $?
)"
rm "$d/tree/.github/workflows/ci.yml"
sed -i "s/ --eval-workers \"\\\$workers\"//" "$d/tree/build-checks.sh"
check "build-checks.sh without its worker count is refused" "1" "$(
  bash "$standard_root/scripts/check-fast-build-callers.sh" "$d/tree" >/dev/null 2>&1
  echo $?
)"

echo "Test 44: fleet-audit names a lock behind the release, extra local branches and remotes, unpushed commits and a clone behind GitHub"
d="$WORK/t44"
mkdir -p "$d/bin" "$d/repos" "$d/gh/repos/owner/std/branches"
cat >"$d/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
shift
expr=.
while [ $# -gt 0 ]; do
  case "$1" in
  --jq)
    expr=$2
    shift
    ;;
  --paginate) ;;
  *) endpoint=$1 ;;
  esac
  shift
done
[ -f "$GH_DATA/$endpoint" ] || {
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
}
jq -r "$expr" "$GH_DATA/$endpoint"
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"$d/bin/sleep"
chmod +x "$d/bin/gh" "$d/bin/sleep"
pinned=1111111111111111111111111111111111111111
released=2222222222222222222222222222222222222222
printf '{"commit":{"sha":"%s"}}\n' "$released" >"$d/gh/repos/owner/std/branches/release"
printf '[{"name":"v1.1.0","commit":{"sha":"%s"}},{"name":"v1.0.0","commit":{"sha":"%s"}}]\n' "$released" "$pinned" >"$d/gh/repos/owner/std/tags"
g() { git -C "$d/repos/$1" -c user.name=t -c user.email=t@t "${@:2}"; }
consumer() { # consumer <name> <locked std rev>  -> a clone of owner/<name> with one commit on main
  mkdir -p "$d/repos/$1/.github" "$d/gh/repos/owner/$1"
  git init -q -b main "$d/repos/$1"
  printf '{"upstream":{"type":"none"}}\n' >"$d/repos/$1/.github/update.json"
  printf '{"nodes":{"std":{"locked":{"owner":"owner","repo":"std","rev":"%s","type":"github"},"original":{"owner":"owner","repo":"std","ref":"release","type":"github"}}}}\n' "$2" >"$d/repos/$1/flake.lock"
  g "$1" add -A
  g "$1" commit -qm base
  g "$1" remote add origin "https://github.com/owner/$1.git"
}
on_github() { # on_github <name> <main sha>  -> GitHub holds main at that commit
  printf '[{"name":"main","commit":{"sha":"%s"}}]\n' "$2" >"$d/gh/repos/owner/$1/branches"
}
consumer steady "$released"
on_github steady "$(g steady rev-parse HEAD)"
consumer trailing "$pinned"
on_github trailing "$(g trailing rev-parse HEAD)"
consumer cluttered "$released"
on_github cluttered "$(g cluttered rev-parse HEAD)"
g cluttered branch merged
g cluttered switch -q -c old-default
g cluttered commit -q --allow-empty -m kept
g cluttered switch -q main
g cluttered remote add fork https://github.com/someone/cluttered.git
consumer ahead "$released"
on_github ahead "$(g ahead rev-parse HEAD)"
g ahead commit -q --allow-empty -m one
g ahead commit -q --allow-empty -m two
consumer unfetched "$released"
on_github unfetched 3333333333333333333333333333333333333333
consumer unmerged "$released"
g unmerged commit -q --allow-empty -m upstream
on_github unmerged "$(g unmerged rev-parse HEAD)"
g unmerged update-ref refs/remotes/origin/main HEAD
g unmerged reset -q --hard HEAD~1
audit() { (cd "$d" && PATH="$d/bin:$PATH" GH_DATA="$d/gh" GH_OWNER=owner PKG_REPOS_DIR="$d/repos" bash "$standard_root/scripts/fleet-audit.sh" "$@" >"$d/log" 2>&1); }
audit --skip-nix steady trailing cluttered ahead unfetched unmerged
check "a lock behind the release is named with the release it pins and the one the branch is at" "1" \
  "$(grep -c '^FAIL  trailing: flake.lock pins owner/std at v1.0.0 while its release branch is at v1.1.0$' "$d/log")"
check "a local branch other than the allowed ones is named, merged or not" "1" \
  "$(grep -c '^FAIL  cluttered: extra local branch(es): merged old-default$' "$d/log")"
check "a remote other than origin is named" "1" "$(grep -c '^FAIL  cluttered: remote(s) other than origin: fork$' "$d/log")"
check "commits on main that GitHub does not hold are named with their count" "1" \
  "$(grep -c '^FAIL  ahead: local main holds 2 commit(s) no branch on GitHub holds$' "$d/log")"
check "so are those of a local branch GitHub does not have" "1" \
  "$(grep -c '^FAIL  cluttered: local old-default holds 1 commit(s) no branch on GitHub holds$' "$d/log")"
check "a branch GitHub already holds is not named as unpushed" "0" "$(grep -c '^FAIL  cluttered: local merged' "$d/log")"
check "a clone behind GitHub's main is named with the count" "1" \
  "$(grep -c "^FAIL  unmerged: local main is 1 commit(s) behind GitHub's main$" "$d/log")"
check "a clone that lacks the commit GitHub's main is at is named behind, and nothing is counted" "1 0" \
  "$(grep -c "^FAIL  unfetched: GitHub's main points at a commit this clone has not fetched" "$d/log") $(grep -c '^FAIL  unfetched: local main' "$d/log")"
check "a clone in step with GitHub on the current release is not named" "0" \
  "$(grep -cE '^FAIL  steady: (flake.lock|extra local|remote\(s\)|local |GitHub)' "$d/log")"
audit --local --skip-nix ahead
check "a --local run compares nothing with GitHub" "0" "$(grep -c 'holds 2 commit(s)' "$d/log")"

echo "Test 44b: fleet-audit keeps its scratch files in a directory of its own under TMPDIR and removes it"
mkdir -p "$d/streams-bin" "$d/tmp"
cat >"$d/streams-bin/gh" <<'SH'
#!/usr/bin/env bash
readlink "/proc/$$/fd/2" >>"$STREAMS_AT"
exec "$GH_STUB" "$@"
SH
chmod +x "$d/streams-bin/gh"
(cd "$d" && PATH="$d/streams-bin:$d/bin:$PATH" GH_STUB="$d/bin/gh" STREAMS_AT="$d/streams" TMPDIR="$d/tmp" GH_DATA="$d/gh" GH_OWNER=owner PKG_REPOS_DIR="$d/repos" \
  bash "$standard_root/scripts/fleet-audit.sh" --remote --skip-nix steady >"$d/log" 2>&1)
tmp=$(cd "$d/tmp" && pwd -P)
files=$(grep -c '^/' "$d/streams")
under=$(grep -c "^$tmp/" "$d/streams")
check "every file gh's errors go to is under the TMPDIR it was given, and nothing is left there" "1 0 0" \
  "$((files > 0)) $((files - under)) $(find "$d/tmp" -mindepth 1 | wc -l)"

echo "Test 45: the fleet watch names a repo it could not read, sweeps on, and dates its issue"
d="$WORK/t45"
mkdir -p "$d"
sed -n '/^ *script: |$/,$p' "$standard_root/.github/workflows/fleet-watch.yml" | sed '1d; s/^            //' >"$d/sweep.js"
cat >"$d/run.js" <<'JS'
const fs = require('fs');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const sweep = new AsyncFunction('github', 'context', fs.readFileSync(process.argv[2], 'utf8'));
const content = (o) => ({ data: { content: Buffer.from(JSON.stringify(o)).toString('base64') } });
const written = [];
const github = {
  paginate: async () => [
    { name: 'unreadable', full_name: 'owner/unreadable', default_branch: 'main', archived: false },
    { name: 'red', full_name: 'owner/red', default_branch: 'main', archived: false }
  ],
  rest: {
    repos: {
      listForUser: () => {},
      getContent: async ({ path }) => content(path === 'flake.lock'
        ? { nodes: { std: { original: { ref: 'release' } } } }
        : { upstream: { type: 'none' } })
    },
    issues: {
      listForRepo: async () => ({ data: [] }),
      create: async ({ body }) => written.push(body),
      update: async ({ body }) => written.push(body),
      createComment: async () => {}
    },
    actions: {
      listWorkflowRuns: async ({ repo }) => {
        if (repo === 'unreadable') throw Object.assign(new Error('Server Error'), { status: 502 });
        return { data: { workflow_runs: [{ event: 'push', head_repository: { full_name: `owner/${repo}` }, status: 'completed', conclusion: 'failure', created_at: new Date().toISOString() }] } };
      }
    }
  }
};
sweep(github, { repo: { owner: 'owner', repo: 'standard' } }).then(
  () => process.stdout.write(written.join('\n')),
  (e) => {
    console.error(`the sweep stopped: ${e.message}`);
    process.exit(1);
  }
);
JS
node "$d/run.js" "$d/sweep.js" >"$d/body" 2>"$d/err"
check "one repo that cannot be read does not stop the sweep" "0 " "$? $(tr '\n' ' ' <"$d/err")"
check "it is named as unread, with the error" "1" "$(grep -c '^- unreadable: unread on this sweep (HTTP 502: Server Error)$' "$d/body")"
check "and the sweep goes on to the next repo" "1" "$(grep -c '^- red: ci.yml = failure$' "$d/body")"
check "the issue carries the time of its sweep" "1" "$(grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$d/body")"

echo "Test 46: the reports name the step that failed, a job that sent no log is runner-lost, and that run is dispatched once more"
mwf="$standard_root/.github/workflows/package-maintenance.yml"
uwf="$standard_root/.github/workflows/package-update.yml"
check "each stage of the Maintenance refresh names its class" "6" "$(grep -cE 'stage="[^"]+" class=[a-z-]+$' "$mwf")"
check "Maintenance classifies with the class of the step that failed" "1" "$(grep -cF "classify-build-failure.sh\" /tmp/lock-build.log \"\$STEP_CLASS\"" "$mwf")"
check "Update classifies as an update, with the class of the step that failed" "1" "$(grep -cF "classify-build-failure.sh\" --update /tmp/update.log \"\$ERROR_TYPE\"" "$uwf")"
check "the Update title carries the classifier's class" "1" "$(grep -cF "title=\"Update \$pkg\$versions: \$FAIL_CLASS\"" "$uwf")"
check "a Maintenance job whose runner is alive always sends a log" "2" "$(grep -cF "run: touch \"\$LOG\"" "$mwf")"
check "an Update verify job whose runner is alive always sends a log" "1" "$(grep -cF "run: touch \"\$LOG\"" "$uwf")"
check "a Maintenance job that failed and sent no log is runner-lost" "1" "$(grep -cE '^ +echo "runner-lost: ' "$mwf")"
check "an Update verify job that failed and sent no log is runner-lost" "1" "$(grep -cE '^ +echo "runner-lost: ' "$uwf")"
check "a lost Maintenance runner dispatches its run once more, and the retry dispatches nothing" "2" "$(grep -cE "runner-lost' && github.event_name != 'repository_dispatch'|event_type=maintenance-retry$" "$mwf")"
check "a lost Update runner dispatches its run once more, and the retry dispatches nothing" "2" "$(grep -cE "runner-lost' && github.event_name != 'repository_dispatch'|event_type=update-retry$" "$uwf")"
check "a dispatched retry passes the Maintenance cadence" "1" "$(grep -cF "[ \"\$EVENT\" = repository_dispatch ]" "$mwf")"
check "a dispatched retry passes the Update cadence" "1" "$(grep -cF "[ \"\$EVENT\" = repository_dispatch ]" "$uwf")"
check "the Maintenance caller starts the retry" "1" "$(grep -cF 'types: [maintenance-retry]' "$standard_root/callers/maintenance.yml")"
check "the Update caller starts the retry" "1" "$(grep -cF 'types: [update-retry]' "$standard_root/callers/update.yml")"

echo "Test 47: a red refresh that held back healed fixes names what failed, and blames no predicate"
d="$WORK/t47"
mkdir -p "$d/std"
printf '#!/usr/bin/env bash\nexit 0\n' >"$d/std/report-failure.sh"
awk '/- name: Report the failure$/ { f = 1 } f && /^ +run: \|$/ { r = 1; next } r && $0 != "" && $0 !~ /^          / { exit } r { sub(/^          /, ""); print }' "$mwf" |
  sed "s#/tmp/#$d/#g" >"$d/report.sh"
(cd "$d" && STD="$d/std" PREPARE=success STOPPED='' HEAL=success HEALED=venus-protocol KEPT=amd-options \
  FAIL_CLASS=check-error FAILED_ATTRS=.#checks.x86_64-linux.pre-commit bash report.sh)
check "the held-back fixes are named with the target that failed, and no predicate is blamed" "0 1 0" \
  "$? $(grep -c '^\*\*Healed fixes NOT pushed\*\*: .venus-protocol.\..* failed in .\.#checks\.x86_64-linux\.pre-commit.,' "$d/issue-head.md") $(grep -ci predicate "$d/issue-head.md")"

echo "Test 48: the commits the automation writes pass the commit-message check"
d="$WORK/t48"
mkdir -p "$d/bin" "$d/candidate"
echo patch >"$d/candidate/candidate.patch"
cat >"$d/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
diff) exit 1 ;;
commit)
  shift
  : >"$MESSAGE"
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -m ]; then
      printf '%s\n\n' "$2" >>"$MESSAGE"
      shift
    fi
    shift
  done
  ;;
esac
exit 0
SH
chmod +x "$d/bin/git"
publish_step() { # publish_step <workflow> <step name>
  awk -v want="      - name: $2" '
    $0 == want { inside = 1; next }
    inside && /^      - / { exit }
    inside && /^        run: \|$/ { body = 1; next }
    body { sub(/^          /, ""); print }
  ' "$standard_root/.github/workflows/$1" | sed "s|/tmp/candidate|$d/candidate|g" >"$d/step.sh"
}
written() { # written <env assignments...> -> the checker's verdict on the message the step commits
  (cd "$d" && env PATH="$d/bin:$PATH" MESSAGE="$d/message" BRANCH=main "$@" bash -e "$d/step.sh" >/dev/null 2>&1) || return 9
  bash "$standard_root/scripts/check-commit-message.sh" "$d/message" >"$d/verdict" 2>&1
}
publish_step package-maintenance.yml "Push the verified lock"
written HEALED=
check "a lock refresh" "0" "$?"
written HEALED="one-fix another-fix"
check "a lock refresh that drops healed fixes" "0 1" "$? $(grep -c 'one-fix another-fix' "$d/message")"
publish_step package-update.yml "Push the verified update"
written PKG=some-package OLDV=1.0.0-unstable-2026-01-01 NEWV=1.0.0-unstable-2026-01-02 AUTO_ADDED=
check "an update" "0 chore(update): some-package 1.0.0-unstable-2026-01-02" "$? $(sed -n 1p "$d/message")"
written PKG=some-package OLDV=1 NEWV=2 AUTO_ADDED="new-dep"
check "an update that adds a requirement" "0 1" "$? $(grep -c 'new-dep' "$d/message")"
check "every commit a workflow writes carries a Test line" "0" "$(
  grep -h -A3 'git commit ' "$standard_root"/.github/workflows/*.yml | awk '
    /git commit / { open++ }
    /Test: / { tested++ }
    END { print open - tested }'
)"
echo
echo "------------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
