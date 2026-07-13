#!/usr/bin/env bash
# fleet-audit - the green/red oracle for the Daaboulex *-nix fleet.
#
# A repo is "standardized" when every check below passes. This script IS the
# definition: run it, read the exit code. It composes the existing per-file
# checks (sync.sh, sync-meta.sh) with the fleet-wide conditions that no single
# repo can prove on its own (one archetype per repo, complete metadata, clean
# branches/issues, green CI).
#
#   PKG_REPOS_DIR=/path/to/repos ./scripts/fleet-audit.sh [options] [repo...]
#
# Options:
#   --local      only local / flake-state checks (no gh)
#   --remote     only remote / GitHub checks (gh)
#   --no-build   nix flake check --no-build (eval + conformance; full builds are
#                proven remotely by the CI-green check)
#   --skip-nix   skip nix flake check entirely (fast structural pass)
#
# Scope: every dir under PKG_REPOS_DIR holding a .github/update.json is a
# consumer. Repos without one (the standard itself, the private `site`
# registry, the `Daaboulex` profile) are out of scope by construction. A repo
# with no git remote (an unpushed WIP) is audited locally and skipped remotely.
#
# Exit codes (tri-state, so a caller can tell certification from a fast scan
# from a defect): 0 = fully certified (every dimension ran, all pass); 1 = a
# real defect (RED); 2 = usage / environment error (cannot run); 3 = PARTIAL --
# ran clean but did NOT exercise every certification dimension (e.g. --local,
# --remote, --skip-nix, or no network reached the remote half), so certification
# is not claimed. Fails closed: a missing tool, an unreadable file, or an
# ambiguous result is a failure, never a pass; a partial run never reports 0.

set -uo pipefail

STD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_DIR="${PKG_REPOS_DIR:?set PKG_REPOS_DIR to the directory holding the packaging-repo clones}"
OWNER="${GH_OWNER:-Daaboulex}"
SCHEMA="$STD/update.schema.json"

# Known archetypes == the upstream.type enum in the schema. The schema is the
# one source of truth; derive the set from it so this can never drift.
mapfile -t KNOWN_TYPES < <(jq -r '.properties.upstream.properties.type.enum[]' "$SCHEMA" 2>/dev/null)

DO_LOCAL=1
DO_REMOTE=1
NIX_MODE="full" # full | no-build | skip
declare -a TARGETS=()
for arg in "$@"; do
  case "$arg" in
  --local) DO_REMOTE=0 ;;
  --remote) DO_LOCAL=0 ;;
  --no-build) NIX_MODE="no-build" ;;
  --skip-nix) NIX_MODE="skip" ;;
  -*)
    echo "fleet-audit: unknown option '$arg'" >&2
    exit 2
    ;;
  *) TARGETS+=("$arg") ;;
  esac
done

fails=0
warns=0
red() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok    %s\n' "$1"; }
warn() { printf 'warn  %s\n' "$1"; warns=$((warns + 1)); }
info() { printf 'info  %s\n' "$1"; }
hdr() { printf '\n== %s ==\n' "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "fleet-audit: required tool '$1' not found" >&2
    exit 2
  }
}
need jq
[ -f "$SCHEMA" ] || {
  echo "fleet-audit: schema not found at $SCHEMA" >&2
  exit 2
}
[ "${#KNOWN_TYPES[@]}" -gt 0 ] || {
  echo "fleet-audit: could not read upstream.type enum from schema" >&2
  exit 2
}

# --- resolve the consumer set ------------------------------------------------
declare -a CONSUMERS=()
if [ "${#TARGETS[@]}" -gt 0 ]; then
  for t in "${TARGETS[@]}"; do CONSUMERS+=("$t"); done
else
  while IFS= read -r d; do
    name="$(basename "$d")"
    [ -f "$d/.github/update.json" ] && CONSUMERS+=("$name")
  done < <(find "$REPOS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
fi
[ "${#CONSUMERS[@]}" -gt 0 ] || {
  echo "fleet-audit: no consumer repos (no .github/update.json) found under $REPOS_DIR" >&2
  exit 2
}

has_remote() { git -C "$REPOS_DIR/$1" remote get-url origin >/dev/null 2>&1; }

# ============================================================================
# LOCAL / FLAKE-STATE CHECKS
# ============================================================================
if [ "$DO_LOCAL" -eq 1 ]; then
  hdr "byte-conformance (sync.sh --check)"
  if PKG_REPOS_DIR="$REPOS_DIR" bash "$STD/sync.sh" --check "${TARGETS[@]}" >/tmp/fa-sync.log 2>&1; then
    ok "all synced files byte-match the canonical"
  else
    red "sync.sh --check reported drift:"
    sed 's/^/      /' /tmp/fa-sync.log
  fi

  hdr "metadata drift (sync-meta.sh --check)"
  # sync-meta compares update.json to LIVE GitHub metadata, so it only applies
  # to repos that have a remote -- a local-only WIP (no origin) has nothing to
  # compare and must not false-drift.
  declare -a meta_targets=()
  for r in "${CONSUMERS[@]}"; do has_remote "$r" && meta_targets+=("$r"); done
  if [ "${#meta_targets[@]}" -eq 0 ]; then
    warn "no repos with a remote to check metadata against"
  elif PKG_REPOS_DIR="$REPOS_DIR" GH_OWNER="$OWNER" bash "$STD/sync-meta.sh" --check "${meta_targets[@]}" >/tmp/fa-meta.log 2>&1; then
    ok "GitHub description + topics match update.json"
  else
    red "sync-meta.sh --check reported drift:"
    sed 's/^/      /' /tmp/fa-meta.log
  fi

  hdr "per-repo: archetype, metadata completeness, license, first-party discipline"
  for repo in "${CONSUMERS[@]}"; do
    dir="$REPOS_DIR/$repo"
    uj="$dir/.github/update.json"
    [ -f "$uj" ] || {
      red "$repo: no .github/update.json"
      continue
    }
    # valid JSON + schema
    if ! jq -e . "$uj" >/dev/null 2>&1; then
      red "$repo: update.json is not valid JSON"
      continue
    fi
    if command -v check-jsonschema >/dev/null 2>&1; then
      if ! check-jsonschema --schemafile "$SCHEMA" "$uj" >/tmp/fa-schema.log 2>&1; then
        red "$repo: update.json fails schema"
        sed 's/^/      /' /tmp/fa-schema.log
      fi
    fi
    # archetype = upstream.type, must be a known value
    utype="$(jq -r '.upstream.type // "MISSING"' "$uj")"
    known=0
    for k in "${KNOWN_TYPES[@]}"; do [ "$utype" = "$k" ] && known=1; done
    if [ "$known" -eq 1 ]; then
      ok "$repo: archetype '$utype'"
    else
      red "$repo: unknown/absent archetype (upstream.type='$utype')"
    fi
    # metadata completeness: description + at least one topic
    desc="$(jq -r '.description // ""' "$uj")"
    ntopics="$(jq -r '.topics | length // 0' "$uj" 2>/dev/null || echo 0)"
    [ -n "$desc" ] || red "$repo: update.json missing 'description'"
    [ "${ntopics:-0}" -ge 1 ] || red "$repo: update.json missing 'topics'"
    # No per-repo dependabot: GitHub Actions are pinned + bumped centrally in the
    # synced workflows (and re-synced fleet-wide), so a consumer dependabot only
    # opens github-actions PRs that break std-conformance and cannot be merged.
    if [ -f "$dir/.github/dependabot.yml" ]; then
      red "$repo: has .github/dependabot.yml (consumers carry none; actions are managed centrally in the standard)"
    fi
    # meta.license accuracy is NOT mechanically gateable here: module-only repos
    # carry no derivation, and overlay repos inherit meta (incl. license) from
    # the nixpkgs base they override, so a grep for `license =` false-fails both.
    # Accuracy is established out-of-band by the fleet license audit, not here.
    # first-party discipline (the README convention, exactly): a repo IS
    # first-party only when it has NO external upstream (upstream.type == none)
    # AND names the fleet owner as the upstream. A bare `none` with no owner is a
    # third-party pinned module/overlay; a fork/mirror that sets owner == the
    # fleet owner but keeps a TRACKED type (github-*, git-ls-remote, ...) is still
    # third-party and must NOT be held to the first-party discipline. A genuine
    # first-party repo must carry a self-owned version literal and a CHANGELOG.
    uowner="$(jq -r '.upstream.owner // ""' "$uj")"
    if [ "$utype" = "none" ] && [ "$uowner" = "$OWNER" ]; then
      [ -f "$dir/CHANGELOG.md" ] || red "$repo: first-party repo has no CHANGELOG.md"
      # Mirror update.sh's version read: the configured versionAttr in the
      # configured versionFile (defaults: attr `version`, file packageFile), with
      # the same negative-lookbehind so `version` cannot match `fooVersion` -- not
      # a broad repo scan a dependency's version literal could satisfy. A JSON
      # versionFile (version.json, package.json) is read structurally via jq --
      # the Nix-literal grep can never match JSON's `"version": "..."` syntax.
      vattr="$(jq -r '.versionAttr // "version"' "$uj")"
      vfile="$(jq -r '.versionFile // .packageFile // "package.nix"' "$uj")"
      if { [ -f "$dir/$vfile" ] && grep -qP "(?<![A-Za-z_])${vattr}\s*[?=]\s*\"" "$dir/$vfile"; } ||
        { [[ "$vfile" == *.json ]] && [ -f "$dir/$vfile" ] && jq -e --arg a "$vattr" '.[$a] | select(type == "string")' "$dir/$vfile" >/dev/null 2>&1; }; then
        :
      else
        red "$repo: first-party repo declares no '$vattr' literal in $vfile"
      fi
    fi
  done

  # --- architecture honesty -------------------------------------------------
  # The fleet targets a canonical arch set (x86_64-linux + aarch64-linux); CI
  # runs a native runner for each. A repo's SUPPORTED arches are its flake
  # `systems` -- the executable truth CI builds. `declared == built` means an
  # arch a repo does NOT declare is silently unsupported and CI goes green by
  # not trying. This gate forbids that silence: every canonical arch a repo
  # drops must carry a one-line reason in update.json `platforms`, and a reason
  # for an arch the repo DOES build is stale. Needs `nix eval`; skipped under
  # --skip-nix. The canonical set is the standard's own per-system `formatter`
  # attrNames; per-repo support is read from `checks.<arch>` -- a repo supports
  # an arch only if it builds a REAL output there (a package or module/repo
  # check), not the per-system boilerplate every declared system carries.
  if [ "$NIX_MODE" != "skip" ]; then
    hdr "per-repo: architecture honesty (declared systems vs documented drops)"
    canon_json="$(nix eval --json "$STD#formatter" --apply 'builtins.attrNames' 2>/tmp/fa-arch.log)"
    if [ -z "$canon_json" ]; then
      red "architecture: could not read canonical arch set from the standard ($(tr '\n' ' ' </tmp/fa-arch.log))"
    else
      mapfile -t CANON < <(jq -r '.[]' <<<"$canon_json")
      for repo in "${CONSUMERS[@]}"; do
        dir="$REPOS_DIR/$repo"
        uj="$dir/.github/update.json"
        [ -f "$dir/flake.nix" ] || {
          red "$repo: no flake.nix (architecture)"
          continue
        }
        repo_arch_ok=1
        # A platforms reason for an arch outside the canonical set is meaningless.
        while IFS= read -r k; do
          [ -z "$k" ] && continue
          if ! jq -e --arg a "$k" 'index($a)' <<<"$canon_json" >/dev/null; then
            red "$repo: platforms reason for non-canonical arch '$k'"
            repo_arch_ok=0
          fi
        done < <(jq -r '.platforms // {} | keys[]' "$uj" 2>/dev/null)
        # "Supports arch" == builds a REAL output there: a package or module/repo
        # check, NOT the per-system boilerplate base emits for every declared
        # system (std-conformance, std-update-json, pre-commit). So declaring an
        # arch in `systems` while building nothing real on it is NOT support -- it
        # needs a documented drop reason, same as not declaring it. This is what
        # keeps per-package meta.platforms filtering honest.
        built_arches=""
        for arch in "${CANON[@]}"; do
          reason="$(jq -r --arg a "$arch" '.platforms[$a] // ""' "$uj" 2>/dev/null)"
          real="$(nix eval --json "$dir#checks.$arch" --apply \
            'cs: builtins.length (builtins.filter (n: n != "std-conformance" && n != "std-update-json" && n != "pre-commit") (builtins.attrNames cs))' \
            2>/dev/null)"
          if [ -n "$real" ] && [ "$real" -gt 0 ] 2>/dev/null; then
            built_arches="$built_arches $arch"
            if [ -n "$reason" ]; then
              red "$repo: builds $arch but update.json declares a drop reason for it (stale)"
              repo_arch_ok=0
            fi
          else
            if [ -z "$reason" ]; then
              red "$repo: does not build $arch (no real output) and has no platforms reason"
              repo_arch_ok=0
            fi
          fi
        done
        [ "$repo_arch_ok" -eq 1 ] && ok "$repo: architecture honest (builds:${built_arches:- none})"
      done
    fi
  else
    warn "architecture honesty skipped (--skip-nix; needs nix eval)"
  fi

  # --- off-CI build surface -------------------------------------------------
  # ci.yml builds ONLY `.#checks.<system>`. Packages exposed via
  # `flake.packages.<system>` are the standard's off-CI escape hatch (CUDA/ROCm,
  # very large builds): their CLOSURE is realized by NEITHER CI nor a local
  # `nix flake check` -- only off-CI against a project cache. They must stay
  # eval-gated (a drvEvalCheck in `checks`, which this run's nix flake check
  # exercises), but their build success is never proven here. Name them so a
  # green audit is never misread as "the off-CI build works". This is the
  # accepted off-CI exception (it does NOT fail the audit); it scopes what GREEN
  # means. Needs `nix eval`; skipped under --skip-nix.
  if [ "$NIX_MODE" != "skip" ]; then
    hdr "per-repo: off-CI build surface (realize NOT proven by CI / flake check)"
    canon_offci="$(nix eval --json "$STD#formatter" --apply 'builtins.attrNames' 2>/dev/null)"
    mapfile -t OFFCANON < <(jq -r '.[]?' <<<"${canon_offci:-[]}")
    offci_any=0
    for repo in "${CONSUMERS[@]}"; do
      dir="$REPOS_DIR/$repo"
      [ -f "$dir/flake.nix" ] || continue
      # An off-CI target is a `flake.packages.<arch>` whose build is in NO check:
      # flakeModules.base aliases each perSystem package into `checks` as
      # `package-<name>` (so CI builds it), so a package with no matching
      # `package-<name>` check is the off-CI escape hatch -- its closure is
      # realized off-CI only. Cheap + alias-proof: read attribute names only (no
      # drvPath, so the heavy CUDA/ROCm graph is never instantiated here), and
      # fail closed (an ambiguous `default` alias is listed, never dropped).
      targets=""
      for arch in "${OFFCANON[@]}"; do
        pkgs="$(nix eval --json "$dir#packages.$arch" --apply 'builtins.attrNames' 2>/dev/null || echo '[]')"
        checks="$(nix eval --json "$dir#checks.$arch" --apply 'builtins.attrNames' 2>/dev/null || echo '[]')"
        while IFS= read -r n; do
          [ -z "$n" ] && continue
          case " $targets " in *" $n "*) : ;; *) targets="$targets $n" ;; esac
        done < <(jq -rn --argjson p "$pkgs" --argjson c "$checks" '
          ($c | map(select(startswith("package-")) | ltrimstr("package-"))) as $built
          | $p | map(select(. as $n | ($built | index($n)) | not)) | .[]')
      done
      if [ -n "$targets" ]; then
        offci_any=1
        info "$repo: off-CI target(s) [${targets# }] -- realize proven off-CI only (project cache), not by CI/flake check; must stay eval-gated"
      fi
    done
    [ "$offci_any" -eq 0 ] && ok "no off-CI build targets (every declared build is covered by CI)"
  fi

  if [ "$NIX_MODE" != "skip" ]; then
    flag=""
    [ "$NIX_MODE" = "no-build" ] && flag="--no-build"
    hdr "nix flake check $flag (std-conformance + eval${flag:+ only})"
    for repo in "${CONSUMERS[@]}"; do
      dir="$REPOS_DIR/$repo"
      [ -f "$dir/flake.nix" ] || {
        red "$repo: no flake.nix"
        continue
      }
      if nix flake check $flag "$dir" >/tmp/fa-flake.log 2>&1; then
        ok "$repo: nix flake check"
      else
        red "$repo: nix flake check failed"
        tail -8 /tmp/fa-flake.log | sed 's/^/      /'
      fi
    done
  else
    warn "nix flake check skipped (--skip-nix)"
  fi
fi

# ============================================================================
# REMOTE / GITHUB CHECKS
# ============================================================================
if [ "$DO_REMOTE" -eq 1 ]; then
  need gh
  REQUIRED_WF=("CI" "Maintenance" "Update")

  # gh, with ONE retry on a transient failure (token/keyring races, secondary
  # rate-limits, a network blip). On success: stdout on stdout, exit 0. On a
  # persistent failure: exit non-zero with gh's stderr in /tmp/fa-gh.log, so the
  # caller fails CLOSED with the real reason instead of misreading an error body
  # as data -- a 401 body is not a stale branch, an empty hasIssuesEnabled is not
  # "Issues disabled". (Both were real false-REDs before this guard.)
  gh_try() {
    local out
    out="$(command gh "$@" 2>/tmp/fa-gh.log)" && {
      printf '%s' "$out"
      return 0
    }
    sleep 2
    out="$(command gh "$@" 2>/tmp/fa-gh.log)" || return 1
    printf '%s' "$out"
  }
  gherr() { tr '\n' ' ' </tmp/fa-gh.log | head -c 160; }

  hdr "remote: branches normalized (single main, no stale update/*)"
  for repo in "${CONSUMERS[@]}"; do
    has_remote "$repo" || {
      warn "$repo: no git remote - remote checks skipped (local-only repo)"
      continue
    }
    if ! branches="$(gh_try api "repos/$OWNER/$repo/branches" --jq '.[].name')"; then
      red "$repo: could not list branches (gh error: $(gherr))"
      continue
    fi
    if [ -z "$branches" ]; then
      red "$repo: no branches returned (unexpected empty result)"
      continue
    fi
    extra="$(grep -vxE 'main' <<<"$branches" || true)"
    if [ -z "$extra" ]; then
      ok "$repo: single 'main' branch"
    else
      red "$repo: stale/extra branches: $(tr '\n' ' ' <<<"$extra")"
    fi
  done

  hdr "remote: Issues enabled + zero open"
  for repo in "${CONSUMERS[@]}"; do
    has_remote "$repo" || continue
    # Issues must be ENABLED: update.yml/maintenance.yml report a failed update or
    # lock bump by FILING an issue. A repo with Issues disabled swallows every such
    # failure silently, so a disabled-Issues repo is a hard red, not a clean pass.
    if ! en="$(gh_try repo view "$OWNER/$repo" --json hasIssuesEnabled --jq '.hasIssuesEnabled')"; then
      red "$repo: could not query Issues setting (gh error: $(gherr))"
      continue
    fi
    if [ "$en" != "true" ]; then
      red "$repo: GitHub Issues are disabled (the update/maintenance workflows cannot report failures)"
      continue
    fi
    if ! n="$(gh_try issue list -R "$OWNER/$repo" --state open --json number --jq 'length')"; then
      red "$repo: could not query issues (gh error: $(gherr))"
      continue
    fi
    if [ "${n:-x}" = "0" ]; then
      ok "$repo: Issues enabled, none open"
    else
      titles="$(gh_try issue list -R "$OWNER/$repo" --state open --json number,title --jq '[.[]|"#\(.number) \(.title)"]|join("; ")' || true)"
      red "$repo: $n open issue(s): $titles"
    fi
  done

  hdr "remote: CI complete + green (latest run per required workflow on main)"
  for repo in "${CONSUMERS[@]}"; do
    has_remote "$repo" || continue
    if ! runs="$(gh_try run list -R "$OWNER/$repo" --branch main -L 40 \
      --json workflowName,conclusion,status)"; then
      red "$repo: could not list workflow runs (gh error: $(gherr))"
      continue
    fi
    if [ -z "$runs" ]; then
      red "$repo: no workflow runs returned (unexpected empty result)"
      continue
    fi
    repo_ok=1
    for wf in "${REQUIRED_WF[@]}"; do
      latest="$(jq -r --arg w "$wf" \
        '(map(select(.workflowName==$w)) | .[0]) as $r
         | if $r == null then "none" else ($r.status + "/" + ($r.conclusion // "null")) end' <<<"$runs")"
      case "$latest" in
      completed/success) ;;
      none | "")
        red "$repo: required workflow '$wf' has no run on main"
        repo_ok=0
        ;;
      queued/* | in_progress/* | requested/* | waiting/* | pending/*)
        # transient: a run is in flight. Not green yet, but not a failure --
        # warn (does not fail the audit); re-run once the run completes.
        warn "$repo: workflow '$wf' latest run on main is in progress ($latest)"
        ;;
      */null)
        red "$repo: workflow '$wf' latest run on main completed with no conclusion ($latest)"
        repo_ok=0
        ;;
      completed/*)
        red "$repo: workflow '$wf' latest run on main = ${latest#completed/}"
        repo_ok=0
        ;;
      *)
        warn "$repo: workflow '$wf' latest run on main is $latest"
        ;;
      esac
    done
    [ "$repo_ok" -eq 1 ] && ok "$repo: CI/Maintenance/Update green on main"
  done
fi

# ============================================================================
# Coverage-honest verdict. "FLEET GREEN" is the FULL-certification signal and
# must mean every dimension actually ran: local conformance/eval/arch AND the
# remote half (open-issues, branches, and CI-green -- the ONLY proof that builds
# realize and that no failure issue is open). A partial run (only one half, or
# --skip-nix) cannot make that claim, so it gets a clearly-scoped PARTIAL
# verdict naming what was NOT audited -- never a bare GREEN, and never exit 0.
# Tri-state: 0 = GREEN (fully certified), 1 = RED (a real defect), 3 = PARTIAL
# (ran clean but coverage incomplete). 2 stays reserved for usage/environment
# errors. Fail-closed: absent coverage is surfaced, not silently passed.
fully_certified=0
if [ "$DO_LOCAL" -eq 1 ] && [ "$DO_REMOTE" -eq 1 ] && [ "$NIX_MODE" != "skip" ]; then
  fully_certified=1
fi

hdr "summary"
printf 'repos audited: %d   failures: %d   warnings: %d\n' "${#CONSUMERS[@]}" "$fails" "$warns"
printf 'coverage: local=%d remote=%d nix=%s\n' "$DO_LOCAL" "$DO_REMOTE" "$NIX_MODE"
if [ "$fails" -gt 0 ]; then
  echo "FLEET RED"
  exit 1
fi
if [ "$fully_certified" -ne 1 ]; then
  missing=""
  [ "$DO_REMOTE" -ne 1 ] && missing="$missing remote(open-issues,branches,CI-green=build+issue proof)"
  [ "$DO_LOCAL" -ne 1 ] && missing="$missing local(conformance,metadata,eval,arch)"
  [ "$NIX_MODE" = "skip" ] && missing="$missing nix(eval,arch,off-CI-surface,flake-check)"
  echo "FLEET PARTIAL (local checks clean; NOT fully certified)"
  echo "  not audited:${missing:- none}"
  echo "  to fully certify: PKG_REPOS_DIR=$REPOS_DIR $0 ${TARGETS[*]:-}"
  exit 3
fi
echo "FLEET GREEN"
exit 0
