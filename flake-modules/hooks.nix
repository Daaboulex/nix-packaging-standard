{
  pkgs,
  lib,
  ruffConfigArg,
}:
let
  homeProof = import ./home-proof.nix { inherit pkgs; };
in
{
  nixfmt = {
    enable = true;
    package = pkgs.nixfmt;
  };
  typos = {
    enable = true;
    settings.config = {
      default = {
        extend-words = {
          hda = "hda";
          zink = "zink";
          rto = "rto";
          uncorrect = "uncorrect";
          ue = "ue";
          hsa = "hsa";
          daita = "daita";
          certifi = "certifi";
          scx = "scx";
          lavd = "lavd";
          bpfland = "bpfland";
          rustland = "rustland";
          flatcg = "flatcg";
          rlfifo = "rlfifo";
          aci = "aci";
          mch = "mch";
          ths = "ths";
          Pn = "Pn";
        };
        extend-identifiers = {
          UE = "UE";
          BARs = "BARs";
        };
      };
    };
  };
  # rumdl config lives HERE, not in a per-repo .rumdl.toml: MD013
  # (line length) is impractical for prose, links, and tables.
  # Its jemalloc aborts on a 16K-page host unless built for that page size, so
  # aarch64 builds it for 16K; drop the branch when nixpkgs' own rumdl runs
  # there unpatched.
  rumdl = {
    enable = true;
    package =
      if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
        pkgs.rumdl.overrideAttrs (o: {
          env = (o.env or { }) // {
            JEMALLOC_SYS_WITH_LG_PAGE = "14";
          };
        })
      else
        pkgs.rumdl;
    settings.configuration = {
      MD013.enabled = false;
    };
  };
  # The README-section linter is the standard's own script (no per-repo
  # scripts/check-readme-sections.sh to copy and let drift).
  check-shell-pipelines = {
    enable = true;
    name = "check-shell-pipelines";
    entry = "bash ${../scripts/check-shell-pipelines.sh}";
    language = "system";
    pass_filenames = false;
  };

  check-readme-sections = {
    enable = true;
    name = "check-readme-sections";
    entry = "bash ${../scripts/check-readme-sections.sh}";
    files = "README\\.md$";
    language = "system";
  };
  lychee = {
    enable = true;
    files = "\\.md$";
    entry = lib.mkForce "${pkgs.coreutils}/bin/env SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${lib.getExe pkgs.lychee} --offline --no-progress";
  };
  check-assistant-files = {
    enable = true;
    name = "check-assistant-files";
    entry = "bash ${../scripts/check-assistant-files.sh}";
    files = "(^|/)(CLAUDE|AGENTS|GEMINI)\\.md$";
    language = "system";
  };
  check-commit-message = {
    enable = true;
    name = "check-commit-message";
    entry = "bash ${../scripts/check-commit-message.sh}";
    language = "system";
    stages = [ "commit-msg" ];
  };
  check-pushed-commits = {
    enable = true;
    name = "check-pushed-commits";
    entry = "${pkgs.writeShellScript "check-pushed-commits" ''
      exec bash ${../scripts/check-commit-range.sh} "''${PRE_COMMIT_FROM_REF:-}" "''${PRE_COMMIT_TO_REF:-HEAD}" bash ${../scripts/check-commit-message.sh}
    ''}";
    language = "system";
    pass_filenames = false;
    always_run = true;
    stages = [ "pre-push" ];
  };
  deadnix = {
    enable = true;
    settings.noLambdaPatternNames = true;
  };
  statix = {
    enable = true;
    settings.config = "${../statix.toml}";
  };
  shfmt = {
    enable = true;
    settings = {
      simplify = false;
      language-dialect = null;
      indent = null;
    };
  };
  taplo.enable = true;
  end-of-file-fixer = {
    enable = true;
    excludes = [ "^LICENSE$" ];
  };
  trim-trailing-whitespace = {
    enable = true;
    excludes = [
      "^LICENSE$"
      "\\.md$"
    ];
  };
  mixed-line-endings.enable = true;
  check-merge-conflicts.enable = true;
  ruff = {
    enable = true;
    entry = lib.mkForce "${pkgs.ruff}/bin/ruff check --fix${ruffConfigArg}";
  };
  ruff-format = {
    enable = true;
    entry = lib.mkForce "${pkgs.ruff}/bin/ruff format${ruffConfigArg}";
  };
  actionlint.enable = true;
  # The proof behind the dev-state rule, run once per push: enter this
  # flake's dev shell with an EMPTY home and fail on anything a tool
  # wrote there. A pin that is missing or runs too late shows up as the
  # path it left, so the fix is named by the failure.
  std-home-proof = {
    enable = true;
    name = "std-home-proof";
    entry = "${homeProof}/bin/std-home-proof";
    language = "system";
    pass_filenames = false;
    always_run = true;
    stages = [ "pre-push" ];
  };
}
