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
}
