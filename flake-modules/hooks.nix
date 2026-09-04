{
  pkgs,
  lib,
  ruffConfigArg,
}:
{
  # Use pkgs.nixfmt directly: pkgs.nixfmt-rfc-style is now an alias of it
  # and emits a deprecation warning on every eval. Same formatter, no noise.
  nixfmt-rfc-style = {
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
}
