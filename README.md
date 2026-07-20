# Nix Packaging Standard

Canonical source of the shared tooling used by every `*-nix` packaging repo in
the [Daaboulex](https://github.com/Daaboulex) NixOS package fleet.

**This repo is the single source of truth**, consumed two ways:

1. **Nix-side logic** (lint/format gate, dev shell, package→check aliasing,
   conformance + schema checks) is a flake-parts **flakeModule** that each repo
   imports via a pinned `inputs.std` — versioned, type-checked, reproducible.
2. **GitHub Actions YAML + scripts** (which cannot be a Nix import) are
   bootstrapped into each repo by `sync.sh`, and their byte-identity to the
   canonical is then enforced by the `std-conformance` flake check — no
   curl-based drift workflow, no `raw.githubusercontent` dependency.

## How a repo consumes the standard

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    std = {
      url = "github:Daaboulex/nix-packaging-standard?ref=v2.12.0"; # pin a tag
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.git-hooks.follows = "git-hooks";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ]; # see "Architecture and platforms"
      imports = [ inputs.std.flakeModules.base ];
      perSystem =
        { pkgs, ... }:
        {
          packages.default = pkgs.callPackage ./package.nix { };
        };
    };
}
```

Pin a **release tag**, never `main`: an eval-breaking change in the standard
must never reach a repo except by a deliberate, reviewed lock bump.

## Repo conventions

Every consumer repo is the **same shape**: a Nix package (plus an overlay and,
where useful, a NixOS/Home Manager module) for one piece of software. There is no
per-repo "archetype" taxonomy beyond a single declared field. **`upstream.type`
in `.github/update.json` is the repo's update path** (how, or whether, a new
version is detected): `github-release` / `github-commit` / `custom` / `none` are
values of that one field, not different kinds of repo, and the standard treats
every repo identically except along that axis. Your own software is the `none`
path with yourself named as the upstream (first-party); see the update-type
paths below.

Every fleet repo follows these. Metadata (description + topics) is declared in
`.github/update.json` and applied with `sync-meta.sh`, so it can't silently drift.

- **Default branch**: `main`, and a single branch — the `maintenance.yml`
  cleanup job prunes stale `update/*` branches.
- **No per-repo dependabot**: GitHub Actions are pinned by SHA in the synced
  workflows and bumped centrally in this standard, then re-synced fleet-wide. A
  consumer `.github/dependabot.yml` would only open `github-actions` PRs that
  cannot be merged (they break `std-conformance`), so consumers carry none —
  dependabot lives only on this standard repo. `fleet-audit` enforces this.
- **Issues enabled**: `update.yml`/`maintenance.yml` report a failed update or
  lock bump by filing an issue, so every repo keeps GitHub Issues enabled — a
  disabled-Issues repo would swallow those failures silently. `fleet-audit`
  enforces this.
- **License**: the repo's `LICENSE` is **MIT** — it licenses *your* Nix packaging
  code, which is permissive and reusable. The packaged software's licence is
  declared in the derivation's `meta.license`, which **must be accurate**. Two
  exceptions keep upstream's licence verbatim: **forks** (the repo vendors
  upstream source) and **derivative transcriptions** (e.g. a module that
  re-expresses GPL config). Proprietary upstreams: MIT packaging + `meta.license`
  marked unfree.
- **Topics**: `nix`, `nixos`, `flake` baseline; add `nixos-module` /
  `home-manager` when the repo ships one; then the software name and a few domain
  topics. Lowercase, hyphenated.
- **Description**: `<Upstream Name> packaged for NixOS — <one concise clause>`.
  HM-only → "… Home Manager module — …"; forks lead with the fork's value-add;
  original (non-packaging) projects describe themselves directly. ≤120 chars,
  one clause, **no cross-repo references, no marketing fluff**.
- **Architecture**: the flake's `systems` is the supported arch set; every arch
  dropped from the fleet canonical set carries a reason in `platforms` — see
  [Architecture and platforms](#architecture-and-platforms).

### Git-tracked / overlay packages (`*-git`)

Packages that track an upstream branch (mesa-git, scx-git) follow the pinned-repo
rules above, plus:

- **Inherit, don't fork** the nixpkgs build closure — override `src`/`rev`/hashes
  on the nixpkgs derivation; do not fork shared libraries (libdrm, libbpf) or
  strip the validated driver/build flags. The closure stays in lockstep with
  nixpkgs and bleeding-edge drift is contained to `src`.
- **Relax exact-output assertions** — an `installCheck` that asserts the precise
  set of produced binaries/outputs breaks on every upstream add/remove; check
  "produced a reasonable set" instead.
- **Skip flaky upstream tests with `doCheck = false`, not file-by-file** —
  overriding a nixpkgs package (even only to dodge a test) changes its
  derivation, forcing a from-source rebuild that re-runs the package's WHOLE
  upstream test suite. Disabling one fragile test path at a time is whack-a-mole:
  the next numerically- or timing-fragile test breaks the next bump. If you
  change none of the package's code, skip its check phase entirely
  (`doCheck = false`) — its real correctness is already gated by nixpkgs' own
  build (the canonical case: unsloth's `accelerate` override).
- **Crates** come from `static.crates.io` (the `crates.io/api/v1` download
  endpoint rate-limits CI and 403s); `ci.yml` also retries transient fetch
  failures once.

## `flakeModules`

| Module | Provides |
| --- | --- |
| `base` | git-hooks gate (`nixfmt-rfc-style`, `typos`, `rumdl`, `check-readme-sections`), `formatter`, `devShells.default`, every declared package aliased into `checks` on the systems its `meta.platforms` supports (so `nix flake check` BUILDS it), `std-conformance` (synced files byte-match the canonical), `std-update-json` (validates `.github/update.json` against the schema) |

## `lib`

Helpers consumed as `inputs.std.lib.*`. Module repos add a module-instantiation
check that forces FULL evaluation (options + assertions + every `mkIf` path)
without building the closure — eval-only and cheap, even in CI.

| Helper | Use case |
| --- | --- |
| `nixosModuleCheck { nixpkgs, system, module, config?, overlays? }` | NixOS module repos. `overlays` supplies the repo's overlay when the module refs overlay-only pkgs. |
| `homeModuleCheck { nixpkgs, home-manager, system, module, config?, overlays? }` | Home Manager module repos. Imports nixpkgs with `config.allowUnfree = true` for unfree packages. |
| `drvEvalCheck { pkgs, name?, drv }` | Packages whose closure is not on `cache.nixos.org` and cannot build on a free CI runner (CUDA/ROCm, very large builds). Forces `drv`'s full build-graph evaluation without realizing it; skips with a trivial pass on a system the drv's `meta.platforms` excludes. See the off-CI exception below. |
| `pythonSitePackagesCheck { pkgs, drv, package, name? }` | First-party python application repos. Proves the BUILT output ships exactly one top-level import package (plus its dist-info) in `site-packages` -- a flat top-level module (`cli.py`, `utils.py`) collides with any other application in a merged environment. See "Python apps: one top-level package" below. |

Example:

```nix
checks.module-eval-nixos = inputs.std.lib.nixosModuleCheck {
  inherit (inputs) nixpkgs;
  inherit system;
  overlays = [ self.overlays.default ];
  module = ./module.nix;
  config.programs.foo.enable = true;
};
```

## Files

| File | Bootstrapped to (per repo) | Purpose |
| --- | --- | --- |
| `flake.nix` | _(not synced)_ | Exposes `flakeModules.*` |
| `flake-modules/base.nix` | _(imported, not synced)_ | The shared flakeModule |
| `update.sh` | `scripts/update.sh` | Detect + apply upstream updates |
| `ci.yml` | `.github/workflows/ci.yml` | Archetype-blind CI (build every output) |
| `maintenance.yml` | `.github/workflows/maintenance.yml` | Weekly `flake.lock` refresh |
| `update.yml` | `.github/workflows/update.yml` | Scheduled Update workflow |
| `update.schema.json` | _(reference, not synced)_ | JSON Schema for `update.json` |
| `sync.sh` | _(run from here)_ | Bootstrap canonical files into repos |
| `sync-meta.sh` | _(run from here)_ | Apply repo description + topics from `update.json` to GitHub |
| `scripts/fleet-audit.sh` | _(run from here)_ | The fleet's green/red oracle: conformance + metadata + archetype + branches + issues + CI, local and remote |

The synced workflow files + `scripts/update.sh` are byte-identical fleet-wide
and enforced by `std-conformance`. Keep them **stable** across minor standard
releases — evolve via additive flakeModules. A change to a synced file is a
major bump that re-syncs every repo in one coordinated batch.

## Per-repo extensions

The standard is designed for dendritic extension — each repo adds what it needs
in its own `perSystem`, never by patching the standard:

- **Module collision** (`disabledModules`): when nixpkgs ships a module at the
  same option path, the repo's `module.nix` adds
  `disabledModules = [ "programs/foo.nix" ];` (streamcontroller, coolercontrol).
- **Custom devShell**: `lib.mkForce` the standard's lint-only default to fold in
  the repo's own build toolchain (eden: cmake/ninja/ccache).
- **Typos exclusions**: `_typos.toml` with `[files] extend-exclude` to skip
  vendored/forked C++ source (vkBasalt, lmstudio).
- **Rumdl exclusions/overrides**: in `perSystem`, extend
  `pre-commit.settings.hooks.rumdl.excludes` or `.settings.configuration` to
  skip vendored markdown or disable rules the README legitimately triggers
  (vkBasalt: `MD033` for inline-HTML screenshots).
- **Unfree**: `config.nixpkgs.config.allowUnfree = true` in the module-eval
  config (lmstudio); standalone `pkgs` import with `config.allowUnfree = true`
  in `perSystem` (mesa-git).

## CI model

One archetype-blind `ci.yml`, identical fleet-wide. It runs the AI-artifact
guard, reclaims ~20 GB of preinstalled toolchains nix never uses (large source
builds otherwise exhaust the runner's ~14 GB default disk), then on a
`[ubuntu-latest, ubuntu-24.04-arm]` matrix builds every output the flake declares
for that runner's system via `nix-fast-build --skip-cached` — so a repo that
declares no outputs for an arch, **or a package whose `meta.platforms` excludes
it**, simply no-ops there (declared == built, per system *and* per package). There
is no per-repo build target, no archetype conditional, and no binary-cache token:
`cache.nixos.org` substitutes every unmodified dependency for free.

**Exception — off-CI packages.** A package whose closure is not on
`cache.nixos.org` and cannot build on a free runner (CUDA/ROCm toolchains, very
large builds) is exposed via `flake.packages.<system>` — a real `nix build .#x`
target — instead of `perSystem.packages` (which `base` aliases into `checks` and
so builds). CI gates it with `std.lib.drvEvalCheck`, forcing its full
build-graph evaluation without realizing it: CI proves it *evaluates* (catching
dependency/version breakage) while the heavy build runs off-CI against a project
cache (e.g. `cachix use cuda-maintainers`). Document that substituter in the
repo README — declare the off-CI build, never silently drop coverage.

## Architecture and platforms

The fleet's canonical target set is **`x86_64-linux` + `aarch64-linux`**, and
`ci.yml` runs a native runner for each (`ubuntu-latest`, `ubuntu-24.04-arm`). A
repo's **supported arches are its flake `systems`** — the executable truth CI
builds; nothing restates it.

Because CI is `declared == built`, an arch a repo does **not** list in `systems`
is silently unsupported: the runner for it finds no outputs and goes green *by
not trying*. That silence is the trap — a green check that never meant the arch
works. So the standard makes every dropped arch **declared, with a reason**:

- **To support an arch** — add it to `systems`. The native runner then builds
  and proves it on every push; nothing else to declare.
- **To drop an arch** — record a one-line reason in `.github/update.json`
  `platforms`, keyed by the dropped arch:

  ```jsonc
  "platforms": { "aarch64-linux": "amd64-only upstream .deb" }
  ```

`fleet-audit` binds the two: it reads each repo's evaluable `systems` and, for
every canonical arch the repo does not build, requires a `platforms` reason — a
silent drop is **RED**, and a reason for an arch the repo *does* build is stale
(**RED**). `"untested"` is **not** a reason: declare the arch and let the arm
runner settle it. Genuine x86-only constraints are the real reasons — 32-bit-only
(`pkgsi686Linux`), a prebuilt amd64 binary/`.deb`, x86 assembly in upstream
source, or an x86-pinned kernel/firmware.

**Per-package, not just per-repo.** `flakeModules.base` aliases a package into
`checks.<system>` only when it is `lib.meta.availableOn` that system, and
`std.lib.drvEvalCheck` skips on a system the drv's `meta.platforms` excludes. So a
repo may mix arch-portable and x86_64-only packages in one flake — each builds only
where its own `meta` allows (a package with an x86-only dependency must say so in
its `meta.platforms`). Accordingly `fleet-audit` treats an arch as **supported only
when the repo builds a real output there** (a `package-*` or module/repo check) — not
when it merely lists the system; declaring an arch that builds nothing real still
needs a documented `platforms` reason.

## `sync.sh`

```bash
git clone https://github.com/Daaboulex/nix-packaging-standard.git
cd nix-packaging-standard
export PKG_REPOS_DIR=/path/to/repos   # directory holding the packaging clones

./sync.sh                       # bootstrap canonical files into all repos
./sync.sh ripgrep-nix           # named repos only
./sync.sh --check               # report drift, change nothing, exit 1 if any
```

`custom`-type repos keep a bespoke `scripts/update.sh` (skipped here).
Enforcement is the per-repo `std-conformance` flake check; `sync.sh --check` is
the same comparison locally.

## `fleet-audit`

The fleet's single green/red oracle. It composes the per-file checks above with
the fleet-wide conditions no single repo can prove on its own, and exits 0 only
when every one passes **in a full run**.

It is **coverage-honest**: a run reports `FLEET GREEN` only when it exercised
*every* certification dimension -- the local half (conformance, metadata, eval,
arch) **and** the remote half (open issues, branches, and CI-green, the only
proof that builds realize and that no failure issue is open). A partial run
(`--local`, `--remote`, `--skip-nix`, or one where the network never reached the
remote half) reports `FLEET PARTIAL`, names what it did not audit, and never
claims certification. Exit codes are tri-state so a caller can tell the states
apart: **0** = GREEN (fully certified), **1** = RED (a real defect), **2** =
usage/environment error (could not run), **3** = PARTIAL (ran clean, coverage
incomplete). Anything wanting certification checks for `0`.

```bash
export PKG_REPOS_DIR=/path/to/repos
./scripts/fleet-audit.sh              # full audit, local + remote
./scripts/fleet-audit.sh --local      # flake-state only (no gh)
./scripts/fleet-audit.sh --remote     # GitHub state only
./scripts/fleet-audit.sh --no-build   # eval + conformance, skip full builds
./scripts/fleet-audit.sh --skip-nix   # skip nix flake check (fast structural pass)
./scripts/fleet-audit.sh ripgrep-nix  # named repos only
```

It checks, per consumer (every dir with a `.github/update.json`):

- **local** -- `sync.sh --check` (synced files byte-match), `sync-meta.sh
  --check` (GitHub metadata matches `update.json`), a known `upstream.type`,
  complete metadata (`description` + `topics`), the first-party discipline (a
  self-owned version + a `CHANGELOG.md`, and a python app wires the
  single-package site-packages gate), architecture honesty (every canonical
  arch the flake does not build carries a `platforms` reason), and `nix flake
  check` (`std-conformance` + eval; full builds are proven remotely by CI);
- **off-CI surface** -- names each package whose closure CI never realizes
  (exposed via `flake.packages.<system>` with no `package-<name>` check, the
  off-CI escape hatch): an informational line, so a green audit is never misread
  as "the off-CI CUDA/ROCm build works" -- its build is proven only off-CI
  against a project cache, and it must stay eval-gated. Does not fail the audit;
  it scopes what GREEN means;
- **temporary overlays** -- every `overlays/<name>.nix` fix is shape-checked
  (`meta.reason`, `meta.added`, `dropWhen`, `overlay`, plus an exported
  `overlays.probe`) and NAMED with its reason and age, so a live nixpkgs
  workaround is always visible fleet-wide; a malformed or orphaned one fails
  the audit;
- **remote** (`gh`) -- a single `main` branch (no stale `update/*`), zero open
  issues, and a green latest run of CI / Maintenance / Update on `main`.

A repo with no git remote (an unpushed WIP) is audited locally and skipped
remotely. The standard itself, the private `site` registry, and the `Daaboulex`
profile carry no `update.json` and are out of scope by construction.

## Self-contained dev state

A project dev shell never writes `$HOME`, and per-project build/cache dirs
stay out of the tree: the default shell exports each tool's cache/home/build
dir into the project's gitignored `.devshell/` (`std.lib.devStateHook` --
pre-commit, ruff, mypy, python bytecode, pip, cargo target, npm cache; extend
per tool from the `$DEVSHELL_STATE` seam. `CARGO_HOME`/`HF_HOME` stay
machine-global by explicit choice: shared registry/model caches). The synced
canonical `.envrc` (`use flake`, activate once with `direnv allow`) makes
nix-direnv capture those exports for every in-project entry point -- `nix
develop`, `nix run`, `nix shell`, and raw tool calls. Build outputs (`result*`),
`.direnv/`, `.devshell/`, and ad-hoc tool litter (coverage, `dist/`, `target/`,
`node_modules/`, venvs) stay untracked via the baseline `.gitignore`; the
`std-devstate` check fails a repo whose core entries went missing.

## Python env+source apps: requirements coverage

An app packaged as a `python.withPackages` env plus upstream source (no wheel
build) gets no `pythonRuntimeDepsCheck`, so a new upstream requirement would
ship silently and fail only at the user's runtime import. Two pieces close
the loop:

- `std.lib.requirementsCoveredCheck { pkgs, env, src, file?, ignore? }` -- a
  CI check comparing the source's requirements file against the distributions
  actually present in the built env, failing by name.
- `update.json` `pythonRequirements { file, envFile? }` -- update.sh fetches
  the new tag's requirements file and auto-adds each nixpkgs-resolvable new
  requirement above the `# std:requirements-auto-add` marker in `envFile`;
  the coverage check then proves it during the update's verification build.
  An unmappable name (pypi name != nixpkgs attr) fails the run naming the
  requirement instead of shipping broken.

## Python apps: one top-level package

`site-packages` is a global namespace: every application in a merged
environment (a Nix profile's `buildEnv`, a venv) lands in the same directory,
so a flat top-level module (`cli.py`, `utils.py`) collides with any other
application shipping the same generic name and the profile fails to build on
the conflict. First-party python apps therefore ship EVERYTHING under one
package named after the project (`src/<name>/...`, entry points
`<name>.module:fn`, no setuptools `py-modules`) and wire
`std.lib.pythonSitePackagesCheck { pkgs, drv, package }` so the built output
proves it stays that way. fleet-audit reds a first-party python repo (a
`pyproject.toml` at the root) that does not wire the check.

## Rolling-CI failure handling

Rolling inputs break in classes, and every class is either fenced or NAMED:
update verification builds run with `--keep-going`, so one red run enumerates
every failing dependency instead of fix-one-discover-next; the maintenance
issue carries a machine class (`transient-infra`,
`upstream-rerelease-hash-mismatch`, `nixpkgs-package-drop`,
`missing-python-dep`, `requirements-coverage`, or an honest `unclassified`)
plus the complete failed-attribute and failed-derivation lists
(`scripts/classify-build-failure.sh`); temporary overlays bridge nixpkgs
regressions and remove themselves when upstream heals; and the weekly Fleet
CI watch (standard repo only) keeps one open issue naming any consumer whose
required workflow is red or missing, closing it when the fleet is clean.

## Temporary nixpkgs overlays (self-healing)

When a nixpkgs regression blocks a repo (a package breaks on the new default
python, a dependency stops building), the bridge is a TEMPORARY overlay, never
an ad-hoc pin: one fix per file under `overlays/`, mirroring the main config's
`parts/overlays/_fixes` convention:

```nix
{
  meta = {
    reason = "torchao is disabled on python 3.14, nixpkgs' default python3";
    added = "2026-07-13";
    upstream = "https://github.com/NixOS/nixpkgs/...";   # optional
  };
  # Probed against pkgs WITHOUT the fixes (overlays.probe): true means
  # nixpkgs works normally again and CI removes this file.
  dropWhen = pkgs: (builtins.tryEval pkgs.python3Packages.torchao.drvPath).success;
  overlay = final: prev: { ... };
}
```

The repo composes `overlays.default` = its permanent glue + every fix, and
exports `overlays.probe` = the glue alone. `scripts/heal-overlays.sh` (synced,
run by Maintenance at the repo's cadence) evaluates every `dropWhen` against
the probe pkgs; a fix that fires is deleted, the full check suite verifies the
removal, and only a green tree is pushed -- a red verification restores the
fix and files a `maintenance` issue instead. The lock keeps moving under
automated maintenance, the workaround stays captured and visible (fleet-audit
names each one), and it retires itself the moment nixpkgs actually heals.

## `.github/update.json` schema

```jsonc
{
  "package": "ripgrep",               // package / repo name
  "upstream": { "type": "...", ... }, // see upstream types below
  "packageFile": "package.nix",       // file `nix build .#default` centers on
  "versionFile": "flake.nix",         // file holding the canonical version
                                      //   literal (default: packageFile)
  "versionAttr": "version",           // attribute name to match (default
                                      //   "version"; e.g. "portmasterVersion")
  "revFile": "package.nix",           // file holding the src `rev` literal
                                      //   (default: versionFile)
  "versionScheme": "unstable-date",   // optional; "literal" (default),
                                      //   "unstable-date", or "rev-only"
                                      //   (the latter two: commit-tracked)
  "versionBase": "2.0.0",             // base for "unstable-date" (optional)
  "hashes": [                         // SRI hash fields, dependency order:
    "hash",                           //   bare name -> auto-located, or
    { "field": "vendorHash",          //   {field,file} to disambiguate when
      "file": "agfs.nix" }            //   a name appears in several files
  ],
  "verify": { "binary": null, "check": "wrapper" }
}
```

- **`platforms`** documents the *exceptions* to the canonical arch set: an
  object keyed by each canonical arch the flake's `systems` does NOT build, whose
  value is the one-line drop reason. Absent means the repo builds the full set.
  The supported set is never restated here — it stays in `systems`. See
  [Architecture and platforms](#architecture-and-platforms).
- **`versionAttr`** matches both `version = "x"` and parameterized
  `<attr> ? "x"` default-argument forms.
- **`versionFile`** decouples the version literal's location from `packageFile`.
- **`revFile`** scopes the `rev` literal bump for commit-tracked upstreams.
- **`hashes`** entries list SRI hash fields in evaluation-dependency order
  (source first), each a bare field name or `{"field","file"}` to disambiguate.
  The updater rewrites a field **by name**, so each hash needs a **distinct**
  attribute name (`hash`, `cargoHash`, `vendorHash`, `npmDepsHash`, ...): two
  `hash = "..."` literals in one file collide and the updater clobbers both with
  one value. Bind the extra hash to a named literal (`cargoHash = "sha256-...";`
  then `hash = cargoHash;`) so it is uniquely targetable.
- For commit-tracked packages prefer **`versionFile: "version.json"`**.
- **`versionScheme`** controls the written version literal (commit-tracked types
  only). `literal` (default) writes the upstream string verbatim (a bare 7-char
  SHA for commit-tracked repos); `unstable-date` writes
  `<versionBase>-unstable-<YYYY-MM-DD>` (the nixpkgs VCS-snapshot convention);
  `rev-only` bumps `rev` (+ hash + date) and LEAVES the human-set `version`
  string untouched (git-snapshot packages like mesa-git whose version is
  upstream's self-reported value). Comparison is by `rev` for both non-`literal`
  schemes.
- **`tagFilter`** (an ERE under `upstream`, for `github-release`/`github-tag`)
  pins to one tag namespace when upstream publishes several (e.g. `^[0-9]` to
  skip an `android/*` namespace); the newest matching tag wins.
- **`trackOnly: true`** is the hand-mirrored mode: the updater only DETECTS
  upstream movement (against `trackFile`/`trackKey`, default
  `upstream-version.json`/`commit`) and files a `remirror-needed` reminder issue
  -- it never writes, builds, or advances a version. Requires a commit-tracked
  upstream type.
- **`verify.check`** is one of `elf` / `wrapper` / `desktop` / `eval`. `eval`
  (also the default when omitted) makes eval + a clean build the whole
  verification; the others additionally assert the named artifact exists under
  `result/`. `verify.binary` (+ `verify.args`) instead runs a built binary.

### Upstream types

`github-release` · `github-tag` · `github-commit` · `gitlab-tag` ·
`gitlab-commit` · `gitea-commit` · `git-ls-remote` · `none` · `custom`

`none` — module/multi-component repos with nothing to track.
`custom` — the repo ships its own `scripts/update.sh` (multi-channel apps, or
non-API sources like OCCT). The canonical `update.sh` exits 0 early for them;
their bespoke script must honour the same exit contract.

**First-party** (owner-authored software: gpucycler, corecycler) is the `none`
path with the fleet owner named as the upstream:
`upstream: { "type": "none", "owner": "<you>", "repo": "<self>" }`. The repo IS
the upstream, so version and releases are self-owned (a hand-cut tag plus a
`CHANGELOG.md` entry) and nothing external is polled: `update.sh` no-ops on the
`none` branch. A bare `none` with no `owner` is a third-party package with no
tracked upstream (a pinned module/overlay); `none` with the fleet owner is
first-party. `fleet-audit` enforces the discipline (a self-owned version literal
plus a `CHANGELOG.md`).

## `update.sh` contract

- **exit 0** — no update needed, or update applied + verified.
- **exit 1** — a real failure (config, version read/write, hash extraction,
  build, verification) → workflow opens an `update-failed` issue.
- **exit 2** — network / API error → no issue, retried next run.
- Outputs (to `$GITHUB_OUTPUT`): `updated`, `old_version`, `new_version`,
  `package_name`, `upstream_url`, `error_type`.

## `update.yml` / `maintenance.yml` behaviour

- Update success → silent commit + push to the default branch.
- Update failure (`exit 1`) → `update-failed` issue with the build log + a
  recovery branch; previous failure issues auto-close on the next success.
- `EXIT_CODE=${PIPESTATUS[0]}` captures the real exit — **not** `tee`'s.
- Maintenance: weekly `nix flake update`, rebuild, push only if green, else open
  a labeled issue; plus stale-branch cleanup (>30 days).

## History

Pre-2026-05-19 each repo carried its own `update.sh` and they silently diverged.
The standard was centralized, then promoted to this dedicated repo 2026-05-20.
v2.0.0 (2026-05) replaced file-copy + a curl-based `drift-check` with the
flake-parts `flakeModule` + in-flake `std-conformance` model above.

## License

MIT. See `LICENSE`.
