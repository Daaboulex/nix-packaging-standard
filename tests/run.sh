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
      STUB_GIT_TAGS="${STUB_GIT_TAGS:-}" \
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

if command -v nix >/dev/null 2>&1; then
  echo "Test 8: heal-overlays malformed fix (no meta/dropWhen) -> fail closed, exit 1"
  d="$WORK/t8"
  mkdir -p "$d/overlays"
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
check "untagged asset -> x86_64" "1" "$(grep -c '^    x86_64 = "sha256-[^O]' "$d/sources.nix")"
check "tagged asset -> aarch64" "1" "$(grep -c '^    aarch64 = "sha256-' "$d/sources.nix")"
check "checksum assets ignored" "0" "$(grep -c 'sha512sum' "$d/sources.nix")"
check "pins left untouched" "1" "$(grep -c 'sha256-PINPIN' "$d/sources.nix")"

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
  check "and says nothing was run" "1" "$(grep -c 'nothing to run' "$d.log")"

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
  printf '## Update failed: x 1 -> 2\n' >"$1/head.md"
  printf '%s\n' 'building x' "$(printf '\033[31m')error:$(printf '\033[0m') builder for x failed" "$(printf 'y%.0s' $(seq 1 500))" >"$1/build.log"
}
run_report() { # run_report <dir> <title>
  (cd "$1" && PATH="$GHBIN:$PATH" GH_CALLS="$1/calls" GH_BODY="$1/body.md" STUB_GH_LIST="$1/list.json" \
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

echo "Test 25: sync.sh writes the callers and deletes retired copies, except a custom updater; a first-party repo carries no Update caller"
SYNC="$STD/sync.sh"
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
  printf '%s %s\n' "$pass" "$fail" >"$d/counts"
)
read -r pass fail <"$d/counts"

echo
echo "------------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
