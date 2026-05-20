# Nix Packaging Standard

Canonical source of the shared tooling used by every `*-nix` packaging repo in
the [Daaboulex](https://github.com/Daaboulex) NixOS package fleet.

**This repo is the single source of truth.** Per-repo copies are synced from
here by `sync.sh`; never edit a per-repo copy directly — the per-repo
`drift-check` workflow will fail CI if they diverge.

History: prior to 2026-05-19 there was no canonical copy — each repo carried
its own `update.sh`, and the copies silently diverged (3+ variants). The
standard was first centralized inside `Daaboulex/nixos:repo-standard/`, then
promoted to this dedicated repo on 2026-05-20 so the standard versions
independently of the consuming flake.

## Files

| File                 | Synced to (per repo)                | Purpose                              |
| -------------------- | ----------------------------------- | ------------------------------------ |
| `update.sh`          | `scripts/update.sh`                 | Detect + apply upstream updates      |
| `update.yml`         | `.github/workflows/update.yml`      | Scheduled Update workflow            |
| `drift-check.yml`    | `.github/workflows/drift-check.yml` | CI: synced files match the canonical |
| `update.schema.json` | _(not synced — reference)_          | JSON Schema for `update.json`        |
| `sync.sh`            | _(not synced — run from here)_      | Push canonical files into repos      |
| `README.md`          | _(this file)_                       | The standard, documented             |

## `sync.sh`

```bash
git clone https://github.com/Daaboulex/nix-packaging-standard.git
cd nix-packaging-standard

# Point at the directory holding the packaging-repo clones (each must be its
# own git clone of its repo, with .github/update.json present).
export PKG_REPOS_DIR=/path/to/repos

./sync.sh                       # sync canonical files into all repos
./sync.sh coolercontrol-nix     # named repos only
./sync.sh --check               # report drift only, exit 1 if any
```

Each repo commits + pushes its own changes. The synced `drift-check.yml`
workflow then fails CI if any synced file (`scripts/update.sh` + the two
canonical workflows) diverges from the canonical — it compares each file's
sha256 against
`raw.githubusercontent.com/Daaboulex/nix-packaging-standard/main/`.
(`custom`-type repos keep a bespoke `update.sh` and skip that one file.)
Run `sync.sh --check` for the same check locally.

## `.github/update.json` schema

```jsonc
{
  "package": "openviking",            // package / repo name
  "upstream": { "type": "...", ... }, // see upstream types below
  "packageFile": "package.nix",       // file `nix build .#default` centers on
  "versionFile": "flake.nix",         // file holding the canonical version
                                      //   literal (default: packageFile)
  "versionAttr": "version",           // attribute name to match (default
                                      //   "version"; e.g. "portmasterVersion")
  "revFile": "package.nix",           // file holding the src `rev` literal
                                      //   (default: versionFile)
  "versionScheme": "unstable-date",   // optional; "literal" (default) or
                                      //   "unstable-date" (commit-tracked)
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
  `<attr> ? "x"` default-argument forms — so `portmasterVersion ? "2.1.7"`
  works with `"versionAttr": "portmasterVersion"`.
- **`versionFile`** decouples the version literal's location from
  `packageFile` (e.g. the literal lives in `flake.nix` while `package.nix`
  only takes it as an argument).
- **`revFile`** scopes the `rev` literal bump for commit-tracked upstreams
  (defaults to `versionFile`). Set it explicitly when a repo carries
  several `rev = "..."` literals — e.g. a bundled dependency's `rev` — so
  the updater bumps the package's own src `rev`, not a dependency's.
- **`hashes`** entries list SRI hash fields in evaluation-dependency order
  (source hash first, then vendor hashes). Each entry is either a bare field
  name — auto-located in the first `*.nix` file declaring it — or
  `{"field","file"}` to disambiguate when a name like `hash` appears in
  several files (source `hash` in `flake.nix` vs bundled-wheel `hash`s in
  `package.nix`).
- For commit-tracked packages prefer **`versionFile: "version.json"`**: the
  updater writes `{version, rev, date}` cleanly instead of clobbering a
  semantic version string with a bare SHA.
- **`versionScheme`** controls the written version literal. `literal`
  (default) writes the upstream string verbatim — a bare 7-char SHA for
  commit-tracked types. `unstable-date` writes
  `<versionBase>-unstable-<YYYY-MM-DD>` (the nixpkgs VCS-snapshot
  convention, orderable by `builtins.compareVersions`); the `rev` attr
  still tracks every commit, and update detection compares the `rev`, not
  the date string. `unstable-date` is valid only for commit-tracked
  upstream types.
- **`versionBase`** is the base prefix for `unstable-date` (e.g. the last
  release tag, `"2.0.0"`). If omitted, it is derived by stripping any
  `-unstable-*` suffix from the current version.

### Upstream types

`github-release` · `github-tag` · `github-commit` · `gitlab-tag` ·
`gitlab-commit` · `gitea-commit` · `git-ls-remote` · `none` · `custom`

`none` — module/multi-component repos with nothing to track.
`custom` — the repo ships its own `scripts/update.sh` (multi-channel apps
such as gemini-cli stable/preview/nightly, or non-API sources like OCCT).
Custom repos are sanctioned exceptions: the canonical `update.sh` exits 0
early for them; their bespoke script must honour the same exit contract.

## `update.sh` contract

- **exit 0** — no update needed, or update applied + verified.
- **exit 1** — a real failure (config, version read/write, hash extraction,
  build, verification) → workflow opens an `update-failed` issue.
- **exit 2** — network / API error → no issue, retried next run.
- Outputs (to `$GITHUB_OUTPUT`): `updated`, `old_version`, `new_version`,
  `package_name`, `upstream_url`, `error_type`.
- Flow: read version → fetch upstream → compare → write version (+ rev) →
  extract each hash (build-fail-parse) → verify (eval → build → artifact).

## `update.yml` behaviour

- Success → silent commit + push to the default branch.
- Failure (`exit 1`) → `update-failed` issue with the build log + a recovery
  branch; previous failure issues auto-close on the next success.
- `EXIT_CODE=${PIPESTATUS[0]}` captures `update.sh`'s real exit — **not**
  `tee`'s. (The historic `$?` bug silently swallowed every failure.)

## License

MIT. See `LICENSE`.
