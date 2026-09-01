# Nix Packaging Standard

Canonical source of the shared tooling used by every `*-nix` packaging repo.

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

Every consumer repo follows these. Metadata (description + topics) is declared in
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

## Documentation

A repo's README documents its OWN flake and nothing else; the rules are checkable
against the tree:

- **True to the code.** Every package attribute (`nix build .#x`), NixOS/Home
  Manager option path, and command the README shows resolves against the repo's
  flake. A documented output or option that does not exist is a defect.
- **License agreement.** The License section, the `LICENSE` file, and the
  derivation `meta.license` state the same license (packaging MIT, per Repo
  conventions); a section disclaiming or contradicting the shipped LICENSE is wrong.
- **No branding.** No maintainer attribution or personal-identity line; functional
  links (upstream, clone URL) stay.
- **Plain, not marketing.** Concrete terms for what the repo is and does — no hype
  adjectives, no generic CI-boilerplate paragraph, no emoji. The `generated:*`
  marker blocks carry the machine-fillable surface; everything outside them is
  hand-written and must be accurate.

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
| `pristineBinaryCheck { pkgs, package, binaryPath, name? }` | Prebuilt self-reading binaries (embedded resources / appended payloads). Asserts the installed binary is byte-identical to `package.src`, so no fixup phase can silently corrupt it. See "Prebuilt self-reading binaries" below. |
| `patchAssertions` (a shell string, not a function) | Any `postPatch` that rewrites upstream source with `sed`/`awk` rather than `substituteInPlace --replace-fail`. Prepend it, then assert after every edit with `landed` / `gone` / `present` / `exactly_one` / `landed_soft`. Without it a renamed upstream anchor makes the edit apply to nothing and the package still builds green. See "Patching upstream source" below. |

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
| `flake.nix` | *(not synced)* | Exposes `flakeModules.*` |
| `flake-modules/base.nix` | *(imported, not synced)* | The shared flakeModule |
| `update.sh` | `scripts/update.sh` | Detect + apply upstream updates |
| `ci.yml` | `.github/workflows/ci.yml` | Archetype-blind CI (build every output) |
| `maintenance.yml` | `.github/workflows/maintenance.yml` | Weekly `flake.lock` refresh |
| `update.yml` | `.github/workflows/update.yml` | Scheduled Update workflow |
| `update.schema.json` | *(reference, not synced)* | JSON Schema for `update.json` |
| `sync.sh` | *(run from here)* | Bootstrap canonical files into repos |
| `sync-meta.sh` | *(run from here)* | Apply repo description + topics from `update.json` to GitHub |
| `scripts/fleet-audit.sh` | *(run from here)* | The fleet's green/red oracle: conformance + metadata + archetype + branches + issues + CI, local and remote |

The synced workflow files + `scripts/update.sh` are byte-identical fleet-wide
and enforced by `std-conformance`. Keep them **stable** across minor standard
releases — evolve via additive flakeModules. A change to a synced file is a
major bump that re-syncs every repo in one coordinated batch.

## Overlays compose against the consumer, not against our own lock

An overlay exists so a consumer can get the package built against *their*
nixpkgs, with their overlays and their fixes applied. Write it as:

```nix
flake.overlays.default = final: _prev: {
  thing = final.callPackage ./package.nix { };
};
```

Not as:

```nix
flake.overlays.default = _final: prev: {
  thing = self.packages.${prev.stdenv.hostPlatform.system}.thing;   # wrong
};
```

The second hands back a package this repo already built against the nixpkgs in
its own `flake.lock`. The consumer's nixpkgs version, their overlays and any
fix they carry are all ignored, and their system ends up with a second nixpkgs
closure for one package. It still evaluates, which is why it survives review:
the defect is invisible until someone asks why a consumer overlay had no
effect.

A package that genuinely cannot be built by the consumer (a prebuilt artifact
that must be fetched with this repo's own hashes, say) is the exception, and
the overlay should say so in a comment naming the reason.

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

On a dev host with binfmt emulation (qemu-aarch64 for image builds),
`nix flake check` treats foreign arches as locally buildable and grinds
their check set under emulation. Gate locally scoped to the native system
(`nix-fast-build --flake .#checks.<system>`) and let each arch's native CI
runner validate its own leg.

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
- **temporary divergences** -- every `overlays/<name>.nix` fix is shape-checked
  (`meta.reason`, `meta.added`, `overlay`, exactly one of
  `dropWhen`/`dropWhenBuilds`, plus an exported `overlays.probe`) and NAMED with
  its reason and age, so a live workaround, added dependency, or pin is always
  visible fleet-wide; a malformed or orphaned one fails the audit;
- **remote** (`gh`) -- a single `main` branch (no stale `update/*`), zero open
  issues, and a green latest run of CI / Maintenance / Update on `main`.

A repo with no git remote (an unpushed WIP) is audited locally and skipped
remotely. The standard itself, the private `site` registry, and the owner's
GitHub profile carry no `update.json` and are out of scope by construction.

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

## Python subpackages: declare the version the artifact actually has

A component inside a monorepo release versions itself independently, so passing
the *release* version down to it makes the derivation contradict the wheel it
builds. nixpkgs' `pythonMetadataCheckPhase` catches exactly that and fails with
"has version 'X' but .dist-info/METADATA specifies version 'Y'" (openviking's
`ragfs-python` shipped the 0.4.11 release version over a crate that declares
0.1.0).

Declare the component's own version. It then agrees with METADATA by
construction, needs no patching, and that check becomes a permanent guard: an
upstream bump of the component fails loudly instead of shipping a lie. Reach for
`pyprojectVersionPatchHook` only when the release version genuinely must be
stamped in -- and note it rewrites `pyproject.toml` in the source ROOT, so it
does not reach a project under `buildAndTestSubdir`.

## Patching upstream source

`substituteInPlace --replace-fail` fails closed and is always the first choice.
For the edits it cannot express -- an insertion, a line-range rewrite, an `awk`
pass -- a bare `sed -i` reports nothing: when upstream renames what it matched,
the edit applies to nothing, the package builds green, and the change it was
meant to make is simply absent.

Prepend `inputs.std.lib.patchAssertions` and assert after every edit:

```nix
packages.default = pkgs.callPackage ./package.nix {
  inherit (inputs.std.lib) patchAssertions;
};
```

```nix
postPatch = patchAssertions + ''
  sed -i 's/if (getuid()) {/if (false) {/' gui/main.cpp
  landed gui/main.cpp 'if (false) {' "main.cpp: privilege check disabled"
'';
```

Assert the postcondition, not the precondition: a `grep -q` guard before the
edit can pass while the edit itself matches nothing, which is how a guard ends
up looser than the `sed` it protects. Where the postcondition is an *absence*,
pair `gone` with `present` -- on its own `gone` passes just as happily against
a source that never held the text.

`exactly_one` is for an insertion anchor: it refuses to insert when the anchor
matches twice, which would otherwise duplicate a C label or a table entry.
`landed_soft` warns instead of failing, for an edit that is deliberately
best-effort.

## Prebuilt self-reading binaries

Some prebuilt binaries read their own file at runtime -- embedded resource
maps, appended payloads, .NET single-file bundles. `autoPatchelfHook`,
explicit `patchelf`, or `strip` grows or reshapes the ELF, the embedded
offsets shift, and the binary breaks at runtime while every build stays
green (OCCT's launcher died with "No map found" after a ~38KB patchelf
growth). The rules:

- Install the binary byte-pristine: no patchelf, no strip, `dontStrip` as
  needed. Gate it with `lib.pristineBinaryCheck` so the property is
  enforced, not assumed.
- Launch through the host loader instead of patching the interpreter:
  `/lib64/ld-linux-x86-64.so.2` exists on FHS distros and via nix-ld on
  NixOS. Guard in the wrapper with a clear failure message when absent.
- Supply libraries via wrapper env (`LD_LIBRARY_PATH`, `LD_PRELOAD` shims),
  never via ELF surgery on the self-reading file. Patching COPIES of
  ordinary libraries stays fine.
- Runtime self-extraction targets `$TMPDIR` on some apps; hardened hosts
  mount `/tmp` noexec, so the wrapper exports an exec-allowed `TMPDIR`
  (XDG data or cache) before exec.
- `substituteInPlace` only with `--replace-fail` / `--replace-warn`; bare
  `--replace` is deprecated and hides missing-pattern drift.

Upstreams with rolling download URLs can also re-release in place: the FOD
hash is the discriminator. Recorded hash == current upstream means local
corruption (fixup phases); a mismatch means upstream replaced the artifact
-- re-pin and note it.

## Steam compatibility tools

Prebuilt Proton forks (GE-Proton, Proton-CachyOS) package as two-output
derivations mirroring nixpkgs `proton-ge-bin`: a stub `out` plus
`steamcompattool` holding the tool, consumed via
`programs.steam.extraCompatPackages`.

- Normalize the `compatibilitytool.vdf` identity to a stable, version-free
  name (`substituteInPlace --replace-fail`), overridable via a
  `steamDisplayName` argument. Steam maps games to the vdf identity: a
  versioned name breaks every per-game mapping on each release.
- The shape check asserts the tool layout (`compatibilitytool.vdf`, the
  `proton` entry point), the stable identity prefix, and -- via a grep for
  `package.version` -- that no versioned identity leaked.
- Package every variant upstream publishes (ISA tiers, arm64) as a variant
  map in one `package.nix`; a new upstream variant is one added entry. The
  baseline variant forces all variant sources (an `allVariantSources` list
  attr) so `update.sh`'s hash convergence reaches every hash through
  `.#default`.

## Short-circuiting pipelines under `pipefail`

`grep -q` exits on its first match. That closes the pipe, the producer takes
SIGPIPE, and under `set -o pipefail` the pipeline reports failure. A successful
match therefore reads as a failed test and the wrong branch is taken. The same
holds for `head -n`, which stops reading just as early.

`writeShellApplication` always sets `pipefail`, so every shell string inside a
Nix file is in scope, not just `*.sh`.

Capture first, then match a here-string, so the producer's exit status is not
decided by the consumer closing the pipe:

```bash
out=$(producer 2>/dev/null || true)
if grep -q PATTERN <<<"$out"; then
```

`check-shell-pipelines` enforces this over every tracked `*.sh` and `*.nix`.
A line already ending in `|| true` is accepted, since its status is discarded
either way. Mark a deliberate exception on the same line with `pipefail-safe`.

## Rolling-CI failure handling

Rolling inputs break in classes, and every class is either fenced or NAMED:
update verification builds run with `--keep-going`, so one red run enumerates
every failing dependency instead of fix-one-discover-next; the maintenance
issue carries a machine class (`transient-infra`,
`upstream-rerelease-hash-mismatch`, `nixpkgs-package-drop`,
`missing-python-dep`, `requirements-coverage`,
`python-metadata-version-mismatch`, or an honest `unclassified`)
plus the complete failed-attribute and failed-derivation lists
(`scripts/classify-build-failure.sh`); temporary divergences bridge nixpkgs
regressions, missing dependencies, and pins, and remove themselves once they
stop doing any work; and the weekly Fleet CI watch (standard repo only) keeps
one open issue naming any consumer whose required workflow is red or missing,
closing it when the fleet is clean.

`transient-infra` covers a runner-side store/fetch race as well as a network
one (`path '...' is not valid`): the same revision re-runs green, so it is never
a repo defect to chase.

## Temporary divergences from nixpkgs (self-healing)

**Every** temporary divergence from nixpkgs goes here — there is no other
sanctioned place for one, and none of them may be permanent:

- a **regression bridge** (a package breaks on the new default python, a
  dependency stops building, an upstream test suite goes incompatible);
- an **added dependency** the packaged upstream needs but nixpkgs' own package
  does not carry yet — the normal case for a repo whose overridden `src` has
  moved ahead of nixpkgs' release;
- a **version pin**.

One fix per file under `overlays/`, mirroring the main config's
`parts/overlays/_fixes` convention. Each carries `meta`, an `overlay`, and
**exactly one** heal predicate:

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

**The predicate must test the real condition.** A version-string proxy
(`dropWhen = pkgs: pkgs.foo.version != "1.2.3"`) is forbidden: it fires on an
unrelated bump, so the fix is dropped while the breakage is still live and the
repo re-breaks on a later run. Pick by what the condition actually is:

| Predicate | Use when the condition is visible at | Fires on |
| --- | --- | --- |
| `dropWhen = pkgs: <bool>` | **eval** — an attribute exists again, a dependency is back in `propagatedBuildInputs`, an option is gone | the boolean going true |
| `dropWhenBuilds = pkgs: <drv>` | **build** — a failing test suite, a `pkg-config` version reject, a patch that no longer applies | that derivation building cleanly without the fix |

An added dependency is eval-visible, so it uses `dropWhen` and retires itself
the moment nixpkgs' own package carries the dependency:

```nix
{
  meta = {
    reason = "unsloth git-main added a structlog runtime dep; nixpkgs' unsloth predates it";
    added = "2026-07-30";
  };
  dropWhen =
    pkgs:
    builtins.any (d: (d.pname or "") == "structlog") (
      pkgs.python3Packages.unsloth.propagatedBuildInputs or [ ]
    );
  overlay = final: prev: { ... };
}
```

The repo composes `overlays.default` = its permanent glue + every fix, and
exports `overlays.probe` = the glue alone. `scripts/heal-overlays.sh` (synced)
probes every fix against the probe pkgs -- evaluating a `dropWhen`, **building**
a `dropWhenBuilds` -- and deletes the ones that fire.

**Where it runs is load-bearing.** Maintenance runs the probe INSIDE the
lock-update job, immediately after `nix flake update` and before the
verification build, so every fix is judged against the inputs the repo is moving
**to**. Probing the committed lock instead reads a fix that is needed only on
the NEW nixpkgs as healed, drops it, and re-breaks on the next bump -- a churn
loop, and the second half of what made a version proxy so damaging. Because the
removals share the lock bump's single verification, the two land together or
neither does: green pushes both in one commit, red restores the fixes, pushes
nothing, and files a `maintenance` issue naming what was kept and what was
restored. Nothing is ever dropped blind.

Fail-closed by construction: a fix with no predicate, with both, with malformed
`meta`, or with a `dropWhenBuilds` that cannot even evaluate is a hard error in
both `heal-overlays.sh` and `fleet-audit` -- never silently read as "still
needed", which would pin it forever. The lock keeps moving under automated
maintenance, every live workaround stays captured and visible (fleet-audit names
each one with its reason and age), and each retires itself the moment it stops
doing any work.

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
  "versionBase": "2.0.0",             // "unstable-date" FALLBACK base, read
                                      //   only when upstream has no tag
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
  Exactly **one** of them may be a *source* hash. A failing source FOD reports no
  field identity, so the updater can only route its mismatch to the single
  declared non-vendor field; a second source hash absorbs nothing, stays dummied,
  and the convergence loop can never finish. Declaring two fails closed with
  `config-error` — use `variantAssets` instead.
- **`variantAssets`** is the multi-variant prebuilt-release mode (mutually
  exclusive with `hashes`). The updater enumerates the newest matching release's
  assets, takes each `<variant>` from `<assetPrefix><tag>-<variant><assetSuffix>`,
  prefetches it unpacked (the exact hash a `fetchzip` yields, root dir stripped),
  and regenerates the `variants` attrset between the `# std:variants-begin` /
  `# std:variants-end` markers in `sourceFile`. Attribution is by asset URL, so
  any number of variants converge in one pass and a newly published one is picked
  up with no config change. `defaultVariant` names the variant whose asset carries
  no `-<variant>` token (GE-Proton ships `<tag>.tar.gz` for x86_64 next to
  `<tag>-aarch64.tar.gz`). Pins outside the markers are never rewritten.
- For commit-tracked packages prefer **`versionFile: "version.json"`**.
- **`versionScheme`** controls the written version literal (commit-tracked types
  only). `literal` (default) writes the upstream string verbatim (a bare 7-char
  SHA for commit-tracked repos); `unstable-date` writes
  `<base>-unstable-<YYYY-MM-DD>` (the nixpkgs VCS-snapshot convention), where
  `<base>` is upstream's newest `tagFilter`-matching tag, refetched on every
  bump so an upstream release can never leave the snapshot understating itself
  (a `github-commit` package whose upstream tags 1.1.2 stops writing `1.1.1-...`
  without anyone editing config). `versionBase` is the fallback, read only when
  upstream publishes no tag or the type has no tag API (`gitlab-commit`,
  `gitea-commit`, `git-ls-remote`); a tag fetch that errors fails closed with
  exit 2 rather than falling back to a possibly stale base;
  `rev-only` bumps `rev` (+ hash + date) and LEAVES the human-set `version`
  string untouched (git-snapshot packages like mesa-git whose version is
  upstream's self-reported value). Comparison is by `rev` for both non-`literal`
  schemes.
- **`tagFilter`** (an ERE under `upstream`, for `github-release`/`github-tag`,
  and for the base-tag lookup of a `github-commit` package on `unstable-date`)
  pins to one tag namespace when upstream publishes several (e.g. `^[0-9]` to
  skip an `android/*` namespace); the newest matching tag wins. The search
  **pages** through the list (up to ten 100-item pages) until it matches, so a
  tracked namespace stays reachable behind a high-volume one — CachyOS/wine-cachyos
  carries ~370 rolling `experimental-*` tags ahead of its newest `*-wine` build
  tag. A filter that matches nothing fails closed with `no-matching-tag`.
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
path with the owner named as the upstream:
`upstream: { "type": "none", "owner": "<you>", "repo": "<self>" }`. The repo IS
the upstream, so version and releases are self-owned (a hand-cut tag plus a
`CHANGELOG.md` entry) and nothing external is polled: `update.sh` no-ops on the
`none` branch. A bare `none` with no `owner` is a third-party package with no
tracked upstream (a pinned module/overlay); `none` with the owner is
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
v2.13.0 (2026-07) added `pristineBinaryCheck` plus the prebuilt
self-reading-binary and Steam compatibility-tool conventions.
v2.14.0 (2026-07) added `variantAssets` for multi-variant prebuilt releases.
v2.15.0 (2026-07) made a second *source* hash in `hashes` fail closed instead of
silently misrouting every mismatch onto the first field, and taught
`variantAssets` the `defaultVariant` asset naming.
v2.16.0 (2026-07) made the `tagFilter` search page through the tag/release list
instead of reading only the first 100 entries — an upstream that publishes a
high-volume second tag namespace previously hid the tracked one from the updater
entirely, failing every scheduled run.
v2.17.0 (2026-07) generalized `overlays/` from "nixpkgs regression bridge" to
**every** temporary divergence — regression, added dependency, or pin — and gave
it a predicate that cannot lie: `dropWhenBuilds` BUILDS the un-fixed target, so a
breakage invisible to eval (a broken test suite, a `pkg-config` version reject)
heals on real evidence instead of a version-string proxy. A proxy predicate had
dropped openviking's `pandas-stubs` fix on an unrelated bump and the repo
re-broke. Exactly one predicate is now required, and a `dropWhenBuilds` that
cannot evaluate fails closed rather than pinning the fix forever. The heal probe
also MOVED into the lock-update job, right after `nix flake update`: as a
separate job it probed the committed lock, so a fix needed only on the new
nixpkgs read as healed and was dropped, then the next bump re-broke it. Removals
now share the lock bump's single verification and land atomically with it, and a
red build restores them (from HEAD -- `git rm` had already cleared the index, so
the old restore could not have worked). The failure classifier also learned the
runner-side store race (`transient-infra`), the missing-runtime-dependency form
nixpkgs' `pythonRuntimeDepsCheck` reports, and
`python-metadata-version-mismatch`.
v2.31.0 (2026-08) closed the gap where a patch that rewrites upstream source
reports nothing. `update.sh` gated its auto-push on `nix flake check
--no-build`, so every build-time check in every repo was evaluated and never
run -- the upstream-version bump, the one moment a source rewrite stops
matching, was the one path that could not see it. `patchAssertions` gives that
rewrite the postcondition `substituteInPlace --replace-fail` already has, and
`std-no-fail-open` gates the three shell shapes that report success while doing
nothing: `grep -c ... || echo N`, bare `--replace`, and `--replace-warn`. Found
live: a kernel CPUID anchor that had gained an argument, a printk rewrite
upstream had already made unnecessary, a getuid() guard that no longer existed,
and two edits that were no-ops by construction -- every one of them reporting
success. This repo's own CI also began running its declared flake checks, which
it never had.

v2.32.0 (2026-08) stopped `update.yml` destroying its own successful work.
Dispatched on an `update/*` branch it ran the whole verification chain against
the real upstream release, committed the bump, pushed it, and then its own
branch-retirement job deleted the branch it had just pushed to: the retirement
loop skips only the branch named by a FAILED update's issue, so on success it
retires every `update/*` ref for the package, including the one the run is
standing on. Found live, on a real lmstudio update. The fix is not the missing
self-exclusion but the precondition: a run dispatched off the default branch is
working on a branch and has no business garbage-collecting refs at all, so the
whole step is now gated on the default branch, which removes the class and fails
in the safe direction. `std-update-retire-guard` proves it both ways, requiring
the shipped canonical to carry the gate and the same detector to reject a copy
with the gate stripped. Dependabot's action bump also reached the workflows this
repo ships, not only the ones it runs, which is the split `std-action-pins`
exists to catch and had been failing on since the pull request opened.

v2.32.1 (2026-08) closed a fail-open in `fleet-roll.sh` itself. A repo named on
the command line that was not a consumer was skipped in silence: the per-repo
loop `continue`s past anything without a `.github/update.json`, which is right
for the discovered set because that sweeps every directory, and wrong for an
explicit one. Found live, asking for two repos and getting a roll of one with
`failed: 0` and exit 0 -- the exact shape this tool exists to prevent, in the
tool. Named targets are now validated before any repo is touched and refused
with exit 2. Consumers gain nothing from this tag: `fleet-roll.sh` is not a
synced file, so v2.32.1 is byte-identical to v2.32.0 from a consumer's side.

## License

MIT. See `LICENSE`.
