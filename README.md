# Nix Packaging Standard

Canonical source of the shared tooling used by every `*-nix` packaging repo.

**This repo is the single source of truth**, consumed two ways:

1. **Nix-side logic** (lint/format gate, dev shell, package→check aliasing,
   conformance + schema checks) is a flake-parts **flakeModule** that each repo
   imports through `inputs.std`, which follows the `release` branch and is
   locked like any other input.
2. **GitHub Actions** are three reusable workflows in
   `.github/workflows/package-*.yml`. Each consumer carries three small callers
   (`callers/*.yml`, kept byte-identical by `std-conformance`), and every job
   fetches the standard at the commit that defines the workflow it runs, so
   the scripts and the workflow that calls them always come from one commit.
   A fix to a workflow or script reaches the whole fleet on its next run once
   it is released; nothing is copied into the consumers.

The `release` branch only moves through `scripts/release.sh`, which checks the
candidate against every consumer first (see "Releasing").

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
      url = "github:Daaboulex/nix-packaging-standard/release";
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

Follow the **`release` branch**, never `main` and never a tag. `main` is where
the standard is developed; `release` only fast-forwards to a commit that passed
the standard's CI and the fleet check, and each repo's scheduled lock refresh
moves it there and verifies the result like any other input bump. A tag pin
never moves: on 2026-10-23, 17 repos still sat on v2.40.1 after v2.42.0 had
fixed their failure reports. `std-follows-release` refuses one.

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

- **Default branch**: `main`, and a single branch — the Maintenance
  cleanup job prunes stale `update/*` branches.
- **No per-repo dependabot**: GitHub Actions are pinned by SHA in this
  standard's reusable workflows and bumped here by dependabot; a consumer's
  callers pin no action, so a consumer `.github/dependabot.yml` has nothing to
  bump and consumers carry none. `fleet-audit` enforces this.
- **Issues enabled**: the Update and Maintenance workflows report a failed update or
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
- **Commit message**: `check-commit-message` runs on every commit's message.
  The subject reads `type(scope): summary`, lowercase after the prefix, at most
  72 characters, no full stop; a blank line; a body saying why; one `Test:`
  line (`Test: none, <why>` when nothing ran); a `fix` commit also has a
  `Cause:` line. No email address, no path under `/home`, no AI trailer. A
  person whose work a commit carries is credited with one line per person,
  `Co-authored-by: Name <id+login@users.noreply.github.com>`, the GitHub
  noreply form; any other address, a bot login, or a tool's name there is
  refused, and the line does not count as the body. Body lines wrap at 72;
  the `Test:` and `Cause:` lines and a line holding a URL are exempt.

  A message says what changed and why, not how the work went or where it
  ran. Refused: `the owner` and `this session` (a sentence about who asked or
  when), a link to a chat session, a `Claude-Session:` trailer, a note such as
  `5-agent review`, `I tried` and its kin, and a `Test:` line that ends in a
  place (`on the M1`, `on the host`). `Test:` names what ran. These rules were
  measured against 3983 commits of the fleet before they were written: each
  matched narration only. Words that also occur in honest prose (`the user`,
  `we`, `our`, `agent`, a step number, a date) are not refused, because a
  check that refuses a true sentence gets worked around.

  Machine and person names never enter a repository, a test or CI, so no
  list of them is published. The check derives them where the commit is
  made: this computer's own name and the machines in its Nix builders file,
  whole and in parts of five characters or more, plus the words in the file
  `git config std.privateWords` names, one per line, for what cannot be
  derived. A name inside an identifier (`ryzen_smu`) passes. A configured
  list that cannot be read refuses the commit. In CI nothing is derived:
  a runner knows no private name.

  A name is kept out before it is public or not at all, and CI runs after
  the push. So the same check runs twice on the committing computer:
  `check-commit-message` at the commit and `check-pushed-commits` at the
  push, over every outgoing commit, which also catches a commit made with
  the hook skipped. Both, and CI after them, refuse a commit whose author or
  committer address is not a GitHub noreply address, without printing it.
  A consumer may still list words as the hook's `args`
  (`pre-commit.settings.hooks.check-commit-message.args = [ "word" ];`);
  that list is public, so it is for words that are not private.

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
  endpoint rate-limits CI and 403s); CI also retries transient fetch
  failures, twice, after 60 and 300 seconds.

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
  adjectives, no generic CI-boilerplate paragraph, no emoji.
- **Written for a person who has never seen the repo.** The page answers, in
  this order: what it is and who it is for, whether it works and on what, how
  to install it, how to use it, what does not work, what to do when it
  breaks. One idea to a paragraph, four sentences at most. The proof stays
  out of the page: a check's name, the date something was measured, an issue
  number, the reason a design is the way it is. Those live under `docs/`
  (`DESIGN.md`, `COMPATIBILITY.md`, `DEVELOPMENT.md`), linked from a closing
  "More" section. No section twice, and no marker block: a `generated:`
  comment pair that nothing fills is not structure. `check-readme-sections`
  holds only the floor, a title and an install section; no tool can judge
  whether a page reads well, so the rest is read by a person. The README of
  `steam-arm64-nix` is the worked example.
- **Links resolve.** A reference to a file of the same repository is written
  as a link, and the `lychee` hook checks every relative link in every `.md`
  file, offline. A file name in backticks is not checked: it may name someone
  else's file, an upstream source or a runtime log. Measured before the rule
  was written: all 149 relative links of the fleet resolved, and 87 of 324
  backticked names matched no file, most of them not the repository's own.
- **A table that restates the code is generated from it.** The detections
  table below is rendered by `flake-modules/detections.nix`, which the options
  read too, and the hook list by `flake-modules/hooks.nix`;
  `std-readme-tables-current` fails when either differs from the page.
- **Options are listed in `docs/OPTIONS.md`, written from the modules.** A
  flake that exports a module names it in `perSystem`, under the heading its
  options are listed under:

  ```nix
  std.option-reference."NixOS module" = ./module.nix;
  ```

  `nix run .#std-write-option-reference` writes the file: every visible
  option with its description, type and default, and its example unless it
  is a boolean. The README shows the few options a person sets first and
  links to the file; it carries no option table of its own.
  `std-option-reference` fails when the file is missing or differs from the
  modules, when the README does not link to it, when an option has no
  description, and when a default or example shows a store path or a
  derivation (it would change with every lock update: write it with
  `lib.literalExpression`). Maintenance runs the writer after the lock
  update, so a type nixpkgs words differently cannot leave the file behind.
  A flake that names no module gets neither the check nor the app.
- **No history.** A page says what is true now. What a release changed lives
  in its tag message.
- **A file for an assistant is the exception.** The README is the one source,
  for a person and a tool alike. Where a repository keeps a `CLAUDE.md`,
  `AGENTS.md` or `GEMINI.md`, it holds only what the code cannot show and
  stays at 200 lines or under (`check-assistant-files`). A rule that must
  hold becomes a hook or a check, never a sentence in that file.

## `flakeModules`

| Module | Provides |
| --- | --- |
| `base` | git-hooks gate (every hook in the table below), `formatter`, `devShells.default`, every declared package aliased into `checks` on the systems its `meta.platforms` supports (so `nix flake check` BUILDS it), and these checks: `std-conformance` (synced files byte-match the canonical), `std-no-retired-copies` (no script copy the workflows no longer read), `std-follows-release` (`inputs.std.url` is the `release` branch, `releaseUrl`), `std-update-json` (`.github/update.json` satisfies the schema), `std-devstate` (the baseline `.gitignore` entries are present), `std-devshell-order` (every dev shell pins `PRE_COMMIT_HOME` before it installs the hooks), `std-homestate` (no `home.file` in the home root), `std-meta-maintainers` (maintainers carry the nixpkgs shape), `std-no-fail-open` (no shell shape that reports success while doing nothing), `std-no-deprecated-system` (no `pkgs.system` read), `std-no-host-profile` (no path under the host's profile), and, where the flake names a module under `std.option-reference`, `std-option-reference` (`docs/OPTIONS.md` is what the modules declare, and the README links to it) |

The hooks `base` installs, rendered from `flake-modules/hooks.nix`:

<!-- BEGIN generated:hooks -->
| When | Hooks |
|---|---|
| at the commit | `actionlint`, `check-assistant-files`, `check-merge-conflicts`, `check-readme-sections`, `check-shell-pipelines`, `deadnix`, `end-of-file-fixer`, `lychee`, `mixed-line-endings`, `nixfmt`, `ruff`, `ruff-format`, `rumdl`, `shfmt`, `statix`, `taplo`, `trim-trailing-whitespace`, `typos` |
| on the commit message | `check-commit-message` |
| at the push | `check-pushed-commits`, `std-home-proof` |
<!-- END generated:hooks -->

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
| `steamCompatTool (pkgs: { attribute, brand, homepage, description, license, sources, majorPattern, buildOf, assetUrl, variantsOf, tokens, fetch? })` | Prebuilt Steam compatibility tools (GE-Proton, Proton-CachyOS, UMU-Proton). Takes the tool's facts as a function of the nixpkgs they are built against and returns `overlay`, the flake's `overlays.default`, written from `prev` because the helper decides its attribute names from the pkgs it is given, and `forPkgs pkgs`: the host's tool attributes with their channel passthrus and the x86_64 payload, every channel of every variant a two-output derivation with a stable vdf key and a display name in the fleet's format, plus `checks.compat-tool-shape`, which builds every pin, and `checks.overlay-applies`, which proves the overlay yields the flake's own derivations. See "Steam compatibility tools" below. |
| `patchAssertions` (a shell string, not a function) | Any `postPatch` that rewrites upstream source with `sed`/`awk` rather than `substituteInPlace --replace-fail`. Prepend it, then assert after every edit with `landed` / `gone` / `present` / `exactly_one` / `landed_soft`. Without it a renamed upstream anchor makes the edit apply to nothing and the package still builds green. See "Patching upstream source" below. |
| `devStateHook` (a shell string) | The exports that keep every tool's cache and home under the project's `.devshell/`; `base` wires it into the default shell. See "Self-contained dev state" below. |
| `mkDevShell { pkgs, config } args` | A custom dev shell that cannot get the pin order wrong: the pins, then the hook install, then the caller's own hook. |
| `releaseUrl` (a string) | The one `inputs.std.url` every consumer declares; `std-follows-release`, `scripts/release.sh` and `scripts/fleet-roll.sh` all read it here. |
| `failOpenPatterns` (a list) | The shell shapes `std-no-fail-open` refuses, each with its bad and good example; the standard's own check proves each pattern matches only the bad form. |
| `failOpenScan { lib, src } pattern` | The shell text that searches a source tree for one of those patterns, used by `std-no-fail-open`. It fails when the tree cannot be read, and a line marked `std:fail-open-ok: <reason>` is exempt. |

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
| `synced-files.json` | *(the map itself)* | Consumer path to canonical file, or `null` for a retired copy that must be absent: the one map `sync.sh` reads and `std-conformance` and `std-no-retired-copies` enforce |
| `callers/ci.yml` | `.github/workflows/ci.yml` | Triggers, permissions and concurrency of CI, passing the `RECLAIM_DISK` repository variable (`on` or `off`; unset is `off`, anything else fails the run); calls `package-ci.yml@release` |
| `callers/update.yml` | `.github/workflows/update.yml`, except in a first-party repo (upstream type `none`), which carries none | The Update trigger, one cron for Sunday and one for the other days, queued with Maintenance in the `writes-default-branch` concurrency group so the two writers of the default branch never push over each other; the job's condition reads the `UPDATE_CADENCE` repository variable (`daily` or `weekly`; unset is `daily`), so a day it does not run starts no runner, and passes it on (anything else fails the Sunday run); calls `package-update.yml@release` |
| `callers/maintenance.yml` | `.github/workflows/maintenance.yml` | The Maintenance trigger, one cron for Sunday, one for Wednesday and one for the other days, in the `writes-default-branch` group it shares with Update; the job's condition reads the `MAINTENANCE_CADENCE` repository variable (`daily`, `biweekly` or `weekly`; unset is `weekly`), so a day it does not run starts no runner, and passes it on (anything else fails the Sunday run) |
| `.github/workflows/package-ci.yml` | *(reusable, not synced)* | Archetype-blind CI: every declared system evaluated with import from derivation forbidden, then every output built on a runner per declared system |
| `.github/workflows/package-update.yml` | *(reusable, not synced)* | The update, verified on every declared system before it pushes |
| `.github/workflows/package-maintenance.yml` | *(reusable, not synced)* | `flake.lock` refresh on the repo's cadence: heal probe, every declared system evaluated, the checks built on a runner per declared system, pushed only if all are green |
| `update.sh` | *(run from here; retired copy `scripts/update.sh`)* | Detect + apply upstream updates. A `custom` repo keeps its own `scripts/update.sh`, which the Update workflow runs instead |
| `heal-overlays.sh` | *(run from here; retired copy `scripts/heal-overlays.sh`)* | Probe every temporary divergence against the updated inputs and drop the healed ones |
| `after-lock-update.sh` | *(run from here; retired copy `scripts/after-lock-update.sh`)* | Run the flake's `apps.<system>.after-lock-update` and then its `std-write-option-reference` after the lock update, each when the flake declares it, and stage the tracked files they rewrote |
| `classify-build-failure.sh` | *(run from here; retired copy `scripts/classify-build-failure.sh`)* | Name a red run's failure class and enumerate its failed targets |
| `retry-transient.sh` | *(run from here)* | Run an updater or a build, retrying only a `transient-infra` failure within a time budget, optionally from the checked-out tree, and leave the final attempt as the log |
| `declared-runners.sh` | *(run from here; retired copy `scripts/declared-runners.sh`)* | Name a GitHub runner for every system the flake declares checks on, refusing an unknown system or a flake that does not evaluate |
| `evaluate-every-system.sh` | *(run from here)* | Evaluate every system the flake declares with import from derivation forbidden, so a check that reads a built file at evaluation fails on every store alike and the failure is named; CI's plan job, the Maintenance refresh and `fleet-roll` run it |
| `report-failure.sh` | *(run from here; retired copy `scripts/report-failure.sh`)* | Keep one open issue per failure: file it the first day, then rewrite it each failing run with the days since it opened, commenting only when the failure changes |
| `flake-modules/option-reference.nix` | *(imported by `base`; retired copy `scripts/update-readme-options.sh`)* | Write and check `docs/OPTIONS.md` from the modules a flake names under `std.option-reference` |
| `.envrc` | `.envrc` | `use flake`, so nix-direnv carries the dev-state pins into every entry point |
| `.editorconfig` | `.editorconfig` | The fleet's editor defaults |
| `update.schema.json` | *(reference, not synced)* | JSON Schema for `update.json` |
| `sync.sh` | *(run from here)* | Write the synced files into repos and delete the retired copies |
| `sync-meta.sh` | *(run from here)* | Apply repo description + topics from `update.json` to GitHub |
| `scripts/release.sh` | *(run from here)* | The only way `release` moves: CI on the commit, then the fleet check, then the tag and the fast-forward |
| `scripts/fleet-audit.sh` | *(run from here)* | The fleet's green/red oracle: conformance + metadata + archetype + branches + issues + CI, local and remote |
| `scripts/fleet-roll.sh` | *(run from here)* | Adopt the `release` head across every consumer: pin, lock, sync from that commit, install the adopted release's hook set (the gitignored config link is removed first, so git-hooks.nix installs even where only the hook is gone), build, commit, push, each repo restored on any failure; `--build-on-ci` evaluates every declared system and leaves the build to each repo's CI on push |
| `scripts/check-shell-pipelines.sh`, `scripts/check-readme-sections.sh`, `scripts/check-commit-message.sh` | *(hooks, not synced)* | The pre-commit hooks `base` wires into every consumer |
| `scripts/check-commit-range.sh` | *(app, not synced)* | Runs the commit-message hook over a commit range; `base` wires it as `apps.std-check-commit-messages` |
| `scripts/check-commit-messages-ci.sh` | *(run from here)* | CI's commit-message check on every push and pull request: the consumer's app where this runner's system has it, nothing where another system has it, and the standard's own checker where the consumer's locked standard has no app |

"Run from here" means a job fetches the file from the standard at the commit
of the reusable workflow it runs (`job.workflow_repository` at
`job.workflow_sha`). What a consumer carries is byte-identical fleet-wide and
enforced by `std-conformance`; a release that changes it needs a `fleet-roll`
right after it, and `scripts/release.sh` says so when it does.

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

## Code-quality detections

A detection is an existing tool run over the repository as a flake check, switched on
per repository and per language. Unset is off; there is no bundle.

```nix
perSystem.std.detect.shell = {
  mode = "report";
  paths = [ "." ];
};
```

Every detection takes `mode`, `paths` and an optional `exclude` (files or directories
under `paths` to leave out). Each becomes the check `std-detect-<name>`.

<!-- BEGIN generated:detections -->
| `std.detect.<name>` | Tool | Finds | Exit on findings | Extra options | Judged leftovers live in |
|---|---|---|---|---|---|
| `shell` | shellcheck | quoting faults, unreachable code and functions never called, in `.sh` and `.bash` | 1 |  | a `shellcheck disable` directive at the line |
| `duplicates-cpp` | PMD CPD | copied C and C++, also with names and values changed | 4 | `minimumTokens` | `exclude` |
| `duplicates-python` | PMD CPD | copied Python, exact copies only | 4 | `minimumTokens` | `exclude` |
| `dead-python` | vulture | functions, classes and variables nothing uses | 3 |  | an allow-list `.py` file under `paths`; `[tool.vulture]` in `pyproject.toml` |
| `analysis-cpp` | cppcheck | null dereferences, dangling lifetimes, missing returns; with `unusedFunction`, functions nothing calls | 7 | `checks`, `suppressions` | the `suppressions` list |
| `types-python` | basedpyright | type errors | 1 | `baseline`, `python` | the `baseline` file |
| `coverage-python` | coverage.py under pytest | total coverage under a floor | 2 | `floor`, `python` | the `floor` file, one whole number |
| `mutation-python` | mutmut | tests that run code without checking its result | none: report only |  |  |
<!-- END generated:detections -->

`mode = "gate"` fails the check on any finding: the tool's own exit code is the verdict
and nothing re-reads its output. `mode = "report"` passes on a clean run and on the
tool's findings code, and fails on any other exit code, so a crash or a timeout is never
read as a report. Both modes keep the tool's output: `nix build
.#checks.<system>.std-detect-<name>` and read `result/report`. A detection runs once
per repository, on the system the lint check runs on.

A detection that is switched on fails when a path it names does not exist or when its
paths hold no file of its language.

What no detection covers, so a green run never implies it: copied Nix, shell or Meson
code; a renamed copy in Python; the same logic written differently in any language;
unused Nix files and flake inputs. C++ coverage is not here either: gcovr has to run
inside the instrumented build, so a repository that wants a floor adds it to its own
check, as vkDaedalus does for its sanitizer build.

Limits of single tools:

- shellcheck and cppcheck give a file that does not parse the same exit code as a
  finding, so in report mode a parse failure appears in the report instead of failing
  the check.
- shellcheck reads a script template as it is written: a `@placeholder@` that Nix fills
  in at build time is reported as a constant.
- vulture counts anything reached by a decorator, `getattr` or a framework as unused
  until `[tool.vulture]` names it.
- mutmut exits 0 whatever survives, so `mutation-python` takes `mode = "report"` only.
  Its report starts with mutmut's own counts and lists every surviving change. Some
  survivors are harmless: a change that no test could ever notice. It imports the
  project with nixpkgs' mutmut, so it fits a project without dependencies today.
- coverage counts a line that ran, not a line whose result was checked. That is what
  `mutation-python` is for.

Baselines live in `.std/baseline/`, in each tool's own format, and only shrink. CI
runs `scripts/check-baselines-shrink.sh` over every push: a file there may not gain a
line, a `.floor` file may not drop, and a `.json` baseline may not grow in lines (JSON
rewrites a neighbouring line when an entry goes, so only the count is held). A new
file is accepted, and shows as a new file in the diff. A finding in new code is
silenced where it is, with the tool's own marker.

Adoption goes in three steps: the detection is proven to fail on a planted defect
(`std-detect-fixtures` in this repository builds, for every detection, a planted defect
that must fail the gate and a clean control that must pass it), it runs as a report
while the findings are judged, and it becomes a gate once they are fixed.

## CI model

One archetype-blind `package-ci.yml`, called by every consumer. It runs the AI-artifact
guard, reclaims ~20 GB of preinstalled toolchains nix never uses when the repository
variable `RECLAIM_DISK` is `on` (a large source build otherwise exhausts the runner's
~14 GB default disk; the step takes one to five minutes on an x86_64 runner, longer
than many repos' whole build, so it is opt-in), then builds every
output the flake declares for each runner's system via `nix-fast-build
--skip-cached`. The matrix is not fixed: a plan job runs
`declared-runners.sh`, which names `ubuntu-latest` for `x86_64-linux`
and `ubuntu-24.04-arm` for `aarch64-linux` among the systems the flake declares
checks on, so no runner starts for an arch the repo does not build, and a flake
that does not evaluate fails the plan instead of reading as "nothing declared".
A package whose `meta.platforms` excludes a declared arch is simply not built
there (declared == built, per system *and* per package). There
is no per-repo build target, no archetype conditional, and no binary-cache token:
`cache.nixos.org` substitutes every unmodified dependency for free.

Before the matrix starts, the plan job evaluates every declared system with
`allow-import-from-derivation` off (`evaluate-every-system.sh`). A check that
reads a derivation output at evaluation time (`builtins.readFile` of a
`writeText`, say) passes on any store that already holds the file and fails on
any other, so a developer's host and the push build both go green while the
Sunday refresh on another architecture cannot build the path; Nix refuses the
read even for a path the store holds, so the same evaluation fails everywhere
and names the file. The Maintenance refresh, `fleet-roll` and the release's
fleet check evaluate the same way.

The lint check (`pre-commit`) runs once per repo, on `x86_64-linux` when the
repo declares it and otherwise on its first declared system: it reads the same
files with the same rules on any architecture, and on `aarch64-linux` its
`rumdl` is the 16K-page build the M1 needs, which no binary cache holds, so an
arm job spent 26 of its 27 minutes compiling it (rosemary-lineage-root,
2026-10-23). Every job of the three
reusable workflows carries a `timeout-minutes` at about twice the longest run
measured on 2026-10-26 (240 for a build or verify, 180 for the updater, 60 for
the lock refresh, 15 or less for the rest), so a hung step fails in hours at
most instead of burning the six-hour default; `std-every-job-has-a-timeout`
refuses a job without one.

The commit-message hook can be skipped locally, so the build job runs it
again over every commit of the push or pull request
(`scripts/check-commit-messages-ci.sh`): through the `std-check-commit-messages`
app, with the consumer's own `args`, on the system that has the app, and
through the standard's own checker, without those `args`, when the consumer's
locked standard is older than the app, so a stale lock never skips the check
(Test 28b); by hand that is `nix run .#std-check-commit-messages -- <base> <head>`. A base the
checkout does not know, such as a new branch, checks the head commit alone,
and `check-commit-range.sh` is proven by `tests/run.sh` Test 28.

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

CI builds, it does not run. A runner has no GPU, no display and no KVM, so
nothing that appears only once the program executes is ever exercised, and a
package can stay green for months while being broken from its first launch.
Close that gap by turning each runtime failure you find into a static check in
the same change. A green run means the outputs build, never that they work.

The one place a built binary does run on a runner is the Update verification
(`verify.binary`, and a custom updater's smoke test). A runner is not a dev
host: it has no GPU, no display, no KVM, and Ubuntu's AppArmor refuses the
unprivileged user namespace a `buildFHSEnv` wrapper's `bwrap` needs, so
the Update workflow opens that knob before the update runs and proves it with
`unshare`. A verification added to an update path is proven on a runner
(dispatch the Update workflow once) before the change is called done: a pass
on a development host says nothing about the runner's kernel, sandboxing or
devices, and the first live run is otherwise the first test.

## Architecture and platforms

The fleet's canonical target set is **`x86_64-linux` + `aarch64-linux`**, and
the CI, Update and Maintenance workflows build on a native runner for each
one a repo declares (`ubuntu-latest`, `ubuntu-24.04-arm`). A repo's **supported
arches are its flake `systems`** — the executable truth CI builds; nothing
restates it.

Because CI is `declared == built`, an arch a repo does **not** list in `systems`
is silently unsupported: no runner starts for it and CI goes green *by not
trying*. That silence is the trap — a green check that never meant the arch
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

`sync.sh` copies each synced file and deletes each retired copy; a `custom`-type
repo keeps its own `scripts/update.sh`. Enforcement is the per-repo
`std-conformance` and `std-no-retired-copies` checks; `sync.sh --check` is the
same comparison locally.

## Releasing

```bash
export PKG_REPOS_DIR=/path/to/repos
scripts/release.sh v3.0.1 --notes notes.md --dry-run   # every check, the tag message, nothing pushed
scripts/release.sh v3.0.1 --notes notes.md             # then tag it and fast-forward release
```

`release.sh` refuses unless the tree is clean on `main` and pushed, the
standard's own CI passed on GitHub for that commit, the version is newer than
every tag, a notes file says what the release changes, and `release`
fast-forwards to the commit. The notes are written for a person and open the
tag message, so `git show v3.0.1` is the record of a release. This page holds
no history: it says what is true now.
It then runs the fleet check: each consumer is fetched and cloned at its
`origin/main` (its HEAD when it has no remote), the clone is rolled to the
candidate (pin and synced files), and every system the consumer
declares is evaluated with `std` overridden to the candidate. A check whose
derivation did not change cannot change its result, so only the changed ones
are built, on every system this host or its remote builders build; any other
system is evaluated only. The tag message records how many consumers passed,
how many changed checks were built and where, which systems were evaluated
only, and every consumer left out with `--skip`. One failing consumer refuses
the release.

When a release changes what consumers carry (every file `synced-files.json`
names, the map itself, or the baseline `.gitignore`), each consumer's next lock
refresh fails `std-conformance` or `std-devstate` until it is rolled, so
`release.sh` names the roll to run: `scripts/fleet-roll.sh --execute --notes
<file>`. Everything else, every workflow and script change, reaches the fleet
on its next run. A roll left to run unattended adds `--build-on-ci`: each repo
is still evaluated on every declared system before its push, and its own CI
builds it on that push, instead of this host compiling every consumer's checks
for its own system first.

Two of the three workflows run before a release reaches anyone: this repo's CI
calls `package-ci.yml` from the same commit on every push, and its own
Maintenance calls the local `package-maintenance.yml`, so `main` refreshes this
repo's lock with the workflow it is about to release. `release.sh` requires
that CI to be green. The Update workflow has no canary here (this repo has no
upstream to update); when it or a script it runs changed, `release.sh` says so
and names the dispatch to run on one consumer before 06:00 UTC, when every
consumer runs it.

actionlint 1.7.12 does not yet know `job.workflow_repository` and
`job.workflow_sha` (rhysd/actionlint#707 is open), so this repo's own
actionlint hook ignores exactly those two findings. `std-actionlint-ignore-still-needed`
fails the day the pinned actionlint accepts them, so the ignore goes with the
next lock bump that makes it unnecessary.

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
- **custom updaters** -- a `custom` repo's own `scripts/update.sh` gates a bump
  on the full check suite; one whose only flake check is `nix flake check
  --no-build` is RED, because that flag evaluates every build-time check and
  runs none (an eval-only pass beside the full suite, say over every
  architecture, is fine);
- **remote** (`gh`) -- every repo on GitHub carrying `.github/update.json` has a
  clone under `PKG_REPOS_DIR` (a full sweep only: the fleet is what GitHub holds,
  not what happens to be cloned, and a consumer nobody cloned is reached by no
  sync, no roll and no audit), a single `main` branch (no stale `update/*`),
  zero open automation issues, and a green latest run that did work of CI /
  Maintenance / Update on `main` (a day its cadence skipped is not a run, and a
  first-party repo has no Update to judge).

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
`std-devstate` check fails a repo whose core entries went missing. The proof
behind the rule, `std-home-proof`, runs at push time: it enters the dev shell
in a fresh clone with an empty home and fails on anything written there; on a
host the flake declares no dev shell for, it enters the hook set
`host-hooks.nix` builds for that host instead, the shell that host actually
uses.

## Packaged apps keep their state out of the home root

A packaged app's state belongs in the XDG directories, never loose in the home
root, and the way to put it there is the app's own mechanism -- never a file
moved by hand and never a store link over a path the app writes itself. Try in
this order and stop at the first that holds: the app already follows XDG, so do
nothing; it documents a variable or a flag, so the wrapper or the module sets it
to an absolute path; it owns a pointer or home file of its own, so activation
seeds that file when it is absent and leaves it alone otherwise; it hardcodes the
path with no knob at all, so the README names the upstream file and line that
proves it, which is what makes the exception reviewable instead of a shrug.

Three paths are never relocated. `~/.ssh` has no mechanism at all. `GNUPGHOME`
exists but derives a socket directory that systemd's own units do not agree
with, so moving it breaks gpg-agent. `~/.var` belongs to Flatpak.

A home-manager module therefore declares `xdg.configFile` or `xdg.dataFile`, or
sets the documented variable; `home.file.".<name>"` is refused by `std-homestate`.
Prove where an app looks by reading its source or its own documentation, and cite
that in the commit: a version that reads `$XDG_CONFIG_HOME` today is a fact with
a date on it, not a permanent property.

## Packages pin what they need, not the host's profile

A derivation names its dependencies and reaches them by store path. A path under
the host's profile is not a dependency, it is a guess about the machine the
package lands on: `/run/current-system/sw/bin`, `/etc/profiles/per-user`,
`/nix/var/nix/profiles` and `~/.nix-profile` all change under the package
without it noticing, and none of them is guaranteed to hold the program at all.

The failure is quiet. A wrapper that puts a profile directory on `PATH` still
builds and still starts, and only the feature that needed the absent binary goes
missing, with nothing in the log to read. `std-no-host-profile` refuses these
paths in every tracked `*.nix` and `*.sh`.

Runtime interfaces NixOS itself defines stay allowed: `/run/opengl-driver` is
the graphics contract, and a daemon's socket under `/run` is that daemon's
address, not a profile lookup.

## Replacing an environment makes you own it

Extending `PATH` or `LD_LIBRARY_PATH` for a wrapped program leaves its own
lookups intact. Replacing one takes them over, and from that point every binary
the program runs has to be on the list you wrote, including the helpers it
executes internally and never documents.

A missing helper is often read as a feature being unavailable rather than as an
error, so the call returns success and the work simply does not happen. Pin the
helpers the wrapped program executes, and assert the load-bearing ones in a
check, because nothing reports their absence at runtime.

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

## Prefer upstream's own switch to any edit

Before writing a patch or a substitution, read upstream for the knob it already
ships, and use it: a build option, a command-line flag, an environment
variable, a config key. Every one found in the 2026-10 audit removed an edit
that broke on a later release: eden's `-Werror` turns off with upstream's
`-DENABLE_WERROR=OFF`; StreamController takes its data directory from `--data`;
coolercontrold now spawns an absolute `/bin/sh`, so the substitution that
pointed it at a shell had nothing left to fix. A package built against
nixpkgs-unstable switches off upstream's warnings-as-errors through that
option, because a new compiler's new warning is not a defect of the package.

A patch that stays carries its own retirement: a check that fails the build
the day upstream adopts the change, with the step to take in its message
(coolercontrol's `*-still-needed` checks retired four patches that way in
5.1.1). An edit without one is permanent the moment it lands.

## Regenerate, never restate

Anything upstream already states, the package reads instead of copying: a
version from `Cargo.toml` with `lib.importTOML`, npm dependencies with
`importNpmLock` from the lock file, Python requirements through
`pythonRequirements`, a second derivation's hash through `subpackages`. A
package that overrides a nixpkgs derivation to track git main does not
inherit an edit written against one release's literal text: unsloth passes
`pypaBuildFlags = [ "--skip-dependency-check" ]` instead of matching upstream's
setuptools pins, which move with every bump. A copied value is correct for one
release and wrong from the next, and the update that finds it out fails.

## Errors stay visible, and a tool's own state stays its own

No package, module or activation step hides a failure: no `|| true`, no
`2>/dev/null` in front of a failure, no empty `except`. A step that may
legitimately have nothing to do tests for that case explicitly (`[ -e ... ]`)
and fails on anything else. `update.sh`, which every consumer carried until
v3.0.0, still carries these shapes, and so may the custom updaters, which is
why `std-no-fail-open` does not refuse them yet: adding the shape is its own
release, through the fleet check, once both are clean.

Nix seeds a tool's file once when it is absent and never replays it: no unit
that re-applies settings at login or boot, no store link over a file the
program writes. A rewrite of the tool's own file is allowed only as a guarded
migration of a legacy value, and is removed once every host has migrated.

A source build finds the libraries it `dlopen`s through its RUNPATH
(`patchelf --add-rpath`, `addDriverRunpath`), proven by a check that resolves
each one from the binary, never through `LD_LIBRARY_PATH` in a wrapper, which
leaks into every child process the program starts.

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

Prebuilt Proton forks (GE-Proton, Proton-CachyOS, UMU-Proton) package through
`std.lib.steamCompatTool` as two-output derivations mirroring nixpkgs
`proton-ge-bin`: a stub `out` plus `steamcompattool` holding the tool, consumed
via `programs.steam.extraCompatPackages`. The helper writes each tool's
`compatibilitytool.vdf` itself, because that file carries two names with two
jobs:

- The **key** (the entry under `compat_tools`) is what Steam saves in
  `config.vdf` for a game's choice. It is `<attribute>-<channel>`, lowercase, no
  version, no arch: `proton-ge-latest`, `proton-ge-v10`, `proton-cachyos-v3-v11`.
  It never moves, so a game's choice survives every update, and the native build
  and the x86_64 payload of one channel share it, so one Steam root serving an
  aarch64 and an x86 client keeps one mapping.
- The **display name** is what the dropdown shows: `<Brand> <major> (<qualifiers>)`
  in Valve's own `Proton 11.0` shape, with upstream's facts only. The brand is
  upstream's spelling (`GE-Proton`, `Proton-CachyOS`, `UMU-Proton`), the major is
  written the way upstream writes it (`11` for GE-Proton11-12, `10.0` for
  UMU-Proton-10.0-4), and the brackets hold the variant word first, the build
  (`buildOf tag`: `12`, `4e`, `sunset`, a date as `2026-10-15`), and `latest` last
  on the rolling channel: `GE-Proton 11 (12, latest)`, `GE-Proton 10 (34)`,
  `Proton-CachyOS 11.0 (v3, 2026-10-15, latest)`, `UMU-Proton 9.0 (4e)`. No arch
  word anywhere.

The repo hands the helper a function from the nixpkgs the tools are built
against to the tool's facts: `sources` (the rolling release's facts at the top,
one entry per pinned release under `pins`, between the `# std:rolling` and
`# std:pins` markers the updater's `majorPattern` rollover writes),
`majorPattern` read from `.github/update.json` so the helper and the updater
share one regex, `variantsOf` (how a release names its per-variant hashes),
`assetUrl`, and `tokens`: upstream's asset token (`x86_64`, `x86_64_v3`,
`arm64`, `aarch64`) to the system it runs on, the attribute suffix (`-v3`) and
the qualifier word (`v3`). The helper returns `overlay`, which the repo exports
as `flake.overlays.default`, and `forPkgs`, which `perSystem` calls with its
`pkgs`. The overlay is written by the standard, from `prev` and never from
`final`: the helper decides its attribute names from the pkgs it is given, so
an overlay that reached for them through `final` recurses forever, and no repo
writes that line itself. `forPkgs pkgs` returns `tools`, the attributes a flake
exposes: `<attribute>` is the host's own build, `<attribute><suffix>` an ISA
variant of it, and `<attribute>-x86_64<suffix>` the x86_64 payload on every
host (for an x86 client under FEX on aarch64; on x86_64 it is the same
derivation), each with its channels as **passthru** (`.latest`, `.v<major>`),
never as top-level packages.
The rolling release carries two channels: `latest`, and its own line's
`v<major>` shown as a pin (`GE-Proton 11 (12)`), so a consumer that names `v11`
follows the newest 11 until upstream closes the line and the rollover freezes
it; a pin inside the rolling major is refused, since the rollover owns that line.
`forPkgs pkgs` also returns two `checks`. `compat-tool-shape` references every
channel of every exposed token, so `declared == built` holds for the pins
through the check, and asserts the `proton` entry point, both vdf files, the
key and display formats, no arch or build-type word in either name, no `latest`
on a pin, and unique keys. `overlay-applies` extends the host's nixpkgs with
the overlay and proves that every tool attribute, and every channel under it,
is the very derivation the flake exposes as a package.

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
out=$(producer)
if grep -q PATTERN <<<"$out"; then
```

The capture must not swallow the producer's own failure: `$(producer || true)`
turns an error into an empty value that reads as "no match", the same wrong
branch by another road. `std-no-fail-open` refuses that shape for `nix eval`.

`check-shell-pipelines` enforces this over every tracked `*.sh`, `*.nix` and
workflow file (a step with `shell: bash` runs under `bash -eo pipefail`; a step
with no `shell:` runs under `bash -e` alone, so a workflow step that pipes sets
`pipefail` itself).
A line already ending in `|| true` is accepted, since its status is discarded
either way. Mark a deliberate exception on the same line with `pipefail-safe`.

## Rolling-CI failure handling

Rolling inputs break in classes, and every class is either fenced or NAMED:
update verification builds and the updater's check suite run with
`--keep-going`, so one red run enumerates every failing dependency instead of
fix-one-discover-next; every failure issue carries a machine class
(`transient-infra`, `eval-error`, `compile-error`, `sandbox-download`,
`setup-hook-error`, `upstream-rerelease-hash-mismatch`, `nixpkgs-package-drop`,
`missing-python-dep`, `requirements-coverage`,
`python-metadata-version-mismatch`, `substitution-pattern-drift`,
`import-from-derivation`, or an honest
`unclassified`) plus the failed attributes of every runner and the failed
derivations (`classify-build-failure.sh`); temporary divergences
bridge nixpkgs regressions, missing dependencies, and pins, and remove
themselves once they stop doing any work; and the weekly Fleet CI watch
(standard repo only) keeps one open issue naming any consumer with an open
`update-failed` or `maintenance` issue or a required workflow whose latest run
that did work is red, or that is missing, closing it when the fleet is clean.

Each job uploads its log under its own file name and the report downloads them
with `merge-multiple`, so the log reaches the issue whether one job failed or
several. `report-failure.sh` keeps one open issue per failure: the
first failing run files it, every later failing run rewrites its title and body
with the days since it opened, and it comments only when the failure itself
changes, so a failure that has lasted three weeks reads as three weeks old.

`transient-infra` covers a runner-side store/fetch race as well as a network
one (`path '...' is not valid`): the same revision re-runs green, so it is never
a repo defect to chase. It is read only from lines of the derivations that
failed and from Nix's own lines, never from a warning Nix retried past, so a
mirror that refused before another served the file, or a substituter that
recovered, cannot make a real failure transient. It is the one thing every retry
retries on: CI, Maintenance, Update and its verify build all run through
`retry-transient.sh` (`tests/run.sh` Test 29). The Update retry starts again from
the checked-out tree with empty step outputs, so a retry never reads a failed
attempt's rewrite as already up to date, and no retry starts unless it fits the
job's time budget, so retrying cannot run a job past its timeout and lose its
report.

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
  # Probed against pkgs WITHOUT this fix (overlays.probe plus every other
  # fix): true means nixpkgs works normally again and CI removes this file.
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

`dropWhenBuilds` never names a fixed-output derivation (a `fetchurl`,
`fetchzip`, `fetchFromGitHub` source). Nix reports such a build as done whenever
its output already sits in the store, so a fix that rewrites a source URL would
read as healed on any machine that ever fetched the file, and be dropped while
the URL is still broken. A source-URL fix tests the eval-visible condition it
rewrites instead (`dropWhen = pkgs: !builtins.any (pkgs.lib.hasPrefix
"https://broken.host/") pkgs.foo.src.urls`), and both `heal-overlays.sh` and
`fleet-audit` refuse a `dropWhenBuilds` whose derivation carries an
`outputHash`.

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
exports `overlays.probe` = the glue alone. `heal-overlays.sh`, run by the
Maintenance workflow, probes every fix against the glue plus every OTHER fix,
composed in the same `readDir` order as `overlays.default` -- evaluating a
`dropWhen`, **building** a `dropWhenBuilds` -- and deletes the ones that fire.
Leaving only the fix under test out is what "without the fix" means: with every
fix removed, one fix that is still needed (a meson flag nixpkgs passes and the
package refuses) breaks the probe of every other fix before it reaches its own
condition, so none of them could ever heal (`tests/run.sh` Test 8b).

**Where it runs is load-bearing.** Maintenance runs the probe INSIDE the
lock-update job, immediately after `nix flake update` and before the
verification build, so every fix is judged against the inputs the repo is moving
**to**. Probing the committed lock instead reads a fix that is needed only on
the NEW nixpkgs as healed, drops it, and re-breaks on the next bump -- a churn
loop, and the second half of what made a version proxy so damaging. Because the
removals share the lock bump's verification on every declared system, the two
land together or neither does: green pushes both in one commit, red pushes
nothing, so the fixes stay, and files a `maintenance` issue naming what was kept
and which healed removals were not pushed. Nothing is ever dropped blind.

Fail-closed by construction: a fix with no predicate, with both, with malformed
`meta`, with a `dropWhenBuilds` that cannot even evaluate, or with a
`dropWhenBuilds` on a fixed-output derivation is a hard error in both
`heal-overlays.sh` and `fleet-audit` -- never silently read as "still needed",
which would pin it forever, nor as "healed", which would drop it blind. The lock keeps moving under automated
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
  "majorPattern": "GE-Proton([0-9]+)-.*", // optional; pins the outgoing
                                      //   major when a new one lands
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
  The updater rewrites a field **by name**, and only the **first** literal of
  that name in its file: the rolling release's facts come first, and a pinned
  release below them may repeat the field name untouched (the shape the major
  rollover writes). Two hashes of one release still need **distinct** attribute
  names (`hash`, `cargoHash`, `vendorHash`, `npmDepsHash`, ...): a second
  `hash = "..."` literal of the same release is never reached and the build
  keeps failing on it. Bind the extra hash to a named literal
  (`cargoHash = "sha256-...";` then `hash = cargoHash;`) so it is uniquely
  targetable.
  Exactly **one** of them may be a *source* hash. A failing source FOD reports no
  field identity, so the updater can only route its mismatch to the single
  declared non-vendor field; a second source hash absorbs nothing, stays dummied,
  and the convergence loop can never finish. Declaring two fails closed with
  `config-error` — use `variantAssets` instead.
- **`subpackages`** names attributes of the default package whose own
  fixed-output hashes nix-update must refresh too, each handed to it as
  `--subpackage`. nix-update reaches only the hashes of the package it updates,
  so a hash in a separate derivation, a web UI's `npmDepsHash` built apart from
  the daemon that embeds it, stays stale and the next bump fails on it. Expose
  that derivation through `passthru` (`passthru.ui = coolercontrol-ui-data;`)
  and list the attribute here (`"subpackages": [ "ui" ]`).
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
- **`majorPattern`** (an ERE matching the whole version with one group, the
  major line) turns a new upstream major into a pin instead of a loss. When the
  newest tag's group differs from the current version's, the updater copies the
  rolling block of `versionFile` (`# std:rolling-begin` to `# std:rolling-end`,
  minus the version line and the markers) into the pins block right after
  `# std:pins-begin`, under the outgoing version, then writes the new version
  and regenerates the rolling block as usual. A repo that builds its `v<major>`
  channels from `pins` keeps every line resolving the day a 12-1 lands, with no
  hand edit; a release inside the same major pins nothing, and a version already
  pinned is left alone. Both marker pairs are required and the pattern may not
  contain `|`.
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
  `upstream-version.json`/`commit`) and files a `remirror-needed` reminder issue.
  It builds nothing. Requires a commit-tracked upstream type.

  A `files` object in the track file is the file ledger: every upstream path
  with a `decision` of `ported`, `left-to-nixos` or `not-ported`. With it the
  updater reads which files changed. When each was only modified and is
  `not-ported`, the marker moves by itself and the run commits it. Any other
  change stops for a person, and the issue names each file with its decision
  and shows the first 40 lines of its difference: a ported file, a file left
  to NixOS (the claim that NixOS does the same may no longer hold), and a file
  added, removed or renamed (the ledger itself must change). A run that finds
  upstream unchanged checks that the ledger lists exactly the files upstream
  has, and fails as `config-error` naming each difference. A ledger needs a
  `github-commit` upstream (`tests/run.sh` Test 2e).
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
their bespoke script must honour the same exit contract and gate the bump the
way the canonical's `check_suite` does: the full `nix flake check
--no-eval-cache`, never `--no-build`, which evaluates every build-time check
and runs none (`fleet-audit` reds it).

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
- **exit 2** — a transient condition only (unreachable host, DNS, 5xx, 403/429,
  a timeout) → no issue, retried next run. A 404, a moved file, a changed
  upstream layout or schema will not resolve by waiting: that is exit 1 with an
  `error_type`, so the failure is filed the day it starts. The workflow counts
  consecutive exit-2 runs and escalates a week-long streak to an `update-failed`
  issue (`error_type: stalled`), so a permanent failure cannot hide behind the
  transient exit indefinitely (eden-nix#13: a 404 reported as exit 2 kept the
  Update run green for two months while the pin stood still).
- Outputs (to `$GITHUB_OUTPUT`): `updated`, `old_version`, `new_version`,
  `package_name`, `upstream_url`, `error_type`.

## Update and Maintenance behaviour

- Update success → the change is built on a runner for every other system the
  flake declares checks on (`declared-runners.sh`), then committed and
  pushed to the default branch as the exact commit that was verified. A system
  that fails files the same `update-failed` issue as `exit 1` and pushes
  nothing.
- Update failure (`exit 1`) → the one open `update-failed` issue is filed or
  rewritten with the build log and a recovery branch, and the run ends red, so
  the Actions page and the Fleet CI watch see it too; the next success closes
  the issue. A branch that cannot be pushed is named in the issue with git's
  own error, never dropped silently.
- Update transient (`exit 2`) → no issue, but the run carries a streak counter
  in the Actions cache; the seventh consecutive exit-2 run files the same
  `update-failed` issue with `error_type: stalled`, and the next exit-0 run
  closes it and resets the streak.
- `EXIT_CODE=${PIPESTATUS[0]}` captures the real exit — **not** `tee`'s.
- Maintenance: `nix flake update` on the repo's cadence, then the flake's
  `after-lock-update` app when it declares one (a repo that pins something
  outside `flake.lock`, such as meson wrap files, rewrites it from the new lock
  there; the app may only rewrite tracked files, an untracked file fails the
  run, and what it rewrote rides the same verification and commit as the lock),
  then `std-write-option-reference` under the same terms where the flake
  names a module,
  the heal probe, every declared system evaluated with import from derivation
  forbidden (`evaluate-every-system.sh`), then the checks built on a runner
  for every declared system; push only if every one is green, else file or
  rewrite the one open `maintenance` issue, whose class names an evaluation
  failure (`eval-error`) apart from a build one; plus stale-branch cleanup
  (>30 days).
- A Maintenance refresh that changes no input and heals no fix builds nothing:
  the committed lock is the one that was verified when it was pushed, so the
  verify and publish jobs are skipped and no open issue is touched.
- Every verify job restores the Nix store of the newest earlier run for its
  runner and saves it again under the new lock, so CI on the pushed commit
  starts from the store the verification built.
- Update runs on the repo's `UPDATE_CADENCE` and Maintenance on its
  `MAINTENANCE_CADENCE`: each caller schedules one cron per kind of day and its
  job's condition compares `github.event.schedule` with the cadence, so a day
  it does not run starts no runner and bills nothing. The reusable workflows
  still check the cadence, which keeps a caller from before v3.2.0 correct
  until its roll. Publishing, reporting and retiring attempt branches share
  one `finish` job.
- A first-party repo (upstream type `none`) has nothing for Update to follow,
  so it carries no Update caller: `sync.sh` deletes it and
  `std-no-retired-copies` refuses one.
- An issue opens with a Cause section: the log line that named its class (for
  `missing-python-dep` the dependency the check found missing, for
  `setup-hook-error` the hook's own `die` message), ahead of the first error
  and the log tail.
- A private repo past its included Actions minutes cannot report anything:
  GitHub refuses to start every job, the report job too. `fleet-audit` names
  such a run as refused at the spending limit; the weekly Fleet CI watch runs
  with this repo's token and does not see private repos.

## License

MIT. See `LICENSE`.
