{ pkgs }:
pkgs.writeShellApplication {
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
    mkdir -p "$probe/home" "$probe/tmp" "$probe/run"
    flake="$probe/repo"
    ref=$(sed -n 's/^use flake \([^ ]*\).*/\1/p' "$root/.envrc" 2>/dev/null | head -1)
    case "$ref" in
      ../Portable-Builder*)
        ln -s "$(cd "$root/../Portable-Builder" && pwd)" "$probe/Portable-Builder"
        flake="$probe/Portable-Builder''${ref#../Portable-Builder}"
        ;;
    esac
    system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
    if nix eval --raw "$flake#devShells.$system.default.drvPath" >/dev/null 2>&1; then
      shell=("$flake")
      entered="the dev shell"
    else
      shell=(--impure --expr "import ${./host-hooks.nix} { consumer = $probe/repo; system = builtins.currentSystem; }")
      entered="the hook set built for $system, since the flake declares no dev shell for it"
    fi
    (
      cd "$probe/repo" && env -i HOME="$probe/home" TMPDIR="$probe/tmp" XDG_RUNTIME_DIR="$probe/run" USER="''${USER:-user}" LOGNAME="''${USER:-user}" PATH="$PATH" TERM=dumb \
        NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
        SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
        nix develop "''${shell[@]}" -c true
    )
    written=$(cd "$probe/home" && find . -mindepth 1 \
      -not -path './.cache/nix*' -not -path './.local/state/nix*' -not -path './.local/share/nix*' -not -path './.config/nix*' \
      -not -path './.cache' -not -path './.local' -not -path './.local/state' -not -path './.local/share' -not -path './.config' | sort)
    left=$(cd "$probe/tmp" && find . -mindepth 1 \( -path './nix-develop-*' -o -path './nix-shell.*' \) -prune -o -print | sort)
    if [ -n "$written" ]; then
      echo "std-home-proof: entered $entered in a fresh clone with an empty HOME, and it wrote there; pin each tool into .devshell:"
      echo "$written"
    fi
    if [ -n "$left" ]; then
      echo "std-home-proof: entered $entered with an empty TMPDIR of its own, and it left this there beside Nix's own nix-develop-* and nix-shell.* folders; keep scratch files under the TMPDIR devStateHook sets:"
      echo "$left"
    fi
    if [ -n "$written$left" ]; then
      exit 1
    fi
    echo "std-home-proof: entered $entered in a fresh clone with an empty HOME and an empty TMPDIR of its own, and it wrote nothing in HOME and left nothing in TMPDIR beside Nix's own folders"
  '';
}
