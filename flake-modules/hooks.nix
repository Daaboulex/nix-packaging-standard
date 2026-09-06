{
  pkgs,
  lib,
  ruffConfigArg,
}:
let
  homeProof = pkgs.writeShellApplication {
    name = "std-home-proof";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
    ];
    text = ''
      root=$(git rev-parse --show-toplevel)
      mkdir -p "$root/.devshell"
      probe=$(mktemp -d "$root/.devshell/home-proof.XXXXXX")
      trap 'rm -rf "$probe"' EXIT
      git clone -q --local --no-hardlinks "$root" "$probe/repo"
      mkdir -p "$probe/home"
      flake="$probe/repo"
      ref=$(sed -n 's/^use flake \([^ ]*\).*/\1/p' "$root/.envrc" 2>/dev/null | head -1)
      case "$ref" in
        ../Portable-Builder*)
          ln -s "$(cd "$root/../Portable-Builder" && pwd)" "$probe/Portable-Builder"
          flake="$probe/Portable-Builder''${ref#../Portable-Builder}"
          ;;
      esac
      (
        cd "$probe/repo" && env -i HOME="$probe/home" USER="''${USER:-user}" LOGNAME="''${USER:-user}" PATH="$PATH" TERM=dumb \
          NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
          SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
          nix develop "$flake" -c true
      )
      written=$(cd "$probe/home" && find . -mindepth 1 \
        -not -path './.cache/nix*' -not -path './.local/state/nix*' -not -path './.local/share/nix*' -not -path './.config/nix*' \
        -not -path './.cache' -not -path './.local' -not -path './.local/state' -not -path './.local/share' -not -path './.config' | sort)
      if [ -n "$written" ]; then
        echo "std-home-proof: entered in a fresh clone with an empty HOME, the dev shell wrote there; pin each tool into .devshell:"
        echo "$written"
        exit 1
      fi
      echo "std-home-proof: entered in a fresh clone with an empty HOME, the dev shell wrote nothing there"
    '';
  };
in
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
