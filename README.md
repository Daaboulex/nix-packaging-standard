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
      url = "github:Daaboulex/nix-packaging-standard?ref=v2.5.0"; # pin a tag
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.git-hooks.follows = "git-hooks";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ]; # add "aarch64-linux" only if it builds
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
- **Crates** come from `static.crates.io` (the `crates.io/api/v1` download
  endpoint rate-limits CI and 403s); `ci.yml` also retries transient fetch
  failures once.

## `flakeModules`

| Module | Provides |
| --- | --- |
| `base` | git-hooks gate (`nixfmt-rfc-style`, `typos`, `rumdl`, `check-readme-sections`), `formatter`, `devShells.default`, every declared package aliased into `checks` (so `nix flake check` BUILDS it), `std-conformance` (synced files byte-match the canonical), `std-update-json` (validates `.github/update.json` against the schema) |

## `lib`

Helpers consumed as `inputs.std.lib.*`. Module repos add a module-instantiation
check that forces FULL evaluation (options + assertions + every `mkIf` path)
without building the closure — eval-only and cheap, even in CI.

| Helper | Use case |
| --- | --- |
| `nixosModuleCheck { nixpkgs, system, module, config?, overlays? }` | NixOS module repos. `overlays` supplies the repo's overlay when the module refs overlay-only pkgs. |
| `homeModuleCheck { nixpkgs, home-manager, system, module, config?, overlays? }` | Home Manager module repos. Imports nixpkgs with `config.allowUnfree = true` for unfree packages. |
| `drvEvalCheck { pkgs, name?, drv }` | Packages whose closure is not on `cache.nixos.org` and cannot build on a free CI runner (CUDA/ROCm, very large builds). Forces `drv`'s full build-graph evaluation without realizing it. See the off-CI exception below. |

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
guard, then on a `[ubuntu-latest, ubuntu-24.04-arm]` matrix builds every output
the flake declares for that runner's system via
`nix-fast-build --skip-cached` — so a repo that declares no outputs for an arch
simply no-ops there (declared == built). There is no per-repo build target, no
archetype conditional, and no binary-cache token: `cache.nixos.org` substitutes
every unmodified dependency for free.

**Exception — off-CI packages.** A package whose closure is not on
`cache.nixos.org` and cannot build on a free runner (CUDA/ROCm toolchains, very
large builds) is exposed via `flake.packages.<system>` — a real `nix build .#x`
target — instead of `perSystem.packages` (which `base` aliases into `checks` and
so builds). CI gates it with `std.lib.drvEvalCheck`, forcing its full
build-graph evaluation without realizing it: CI proves it *evaluates* (catching
dependency/version breakage) while the heavy build runs off-CI against a project
cache (e.g. `cachix use cuda-maintainers`). Document that substituter in the
repo README — declare the off-CI build, never silently drop coverage.

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
when every one passes.

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
  self-owned version + a `CHANGELOG.md`), and `nix flake check`
  (`std-conformance` + eval; full builds are proven remotely by CI);
- **remote** (`gh`) -- a single `main` branch (no stale `update/*`), zero open
  issues, and a green latest run of CI / Maintenance / Update on `main`.

A repo with no git remote (an unpushed WIP) is audited locally and skipped
remotely. The standard itself, the private `site` registry, and the `Daaboulex`
profile carry no `update.json` and are out of scope by construction.

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

- **`versionAttr`** matches both `version = "x"` and parameterized
  `<attr> ? "x"` default-argument forms.
- **`versionFile`** decouples the version literal's location from `packageFile`.
- **`revFile`** scopes the `rev` literal bump for commit-tracked upstreams.
- **`hashes`** entries list SRI hash fields in evaluation-dependency order
  (source first), each a bare field name or `{"field","file"}` to disambiguate.
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
