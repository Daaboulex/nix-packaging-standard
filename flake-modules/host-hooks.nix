# The consumer's hook set, built for the machine you are on rather than for
# the flake's own systems. A consumer that declares no output for the host
# (an x86_64-only package on an aarch64 host) has no dev shell here, so its hooks
# cannot be regenerated and a commit cannot run its gate. The hooks are the
# standard's, architecture-independent, taken from the standard the consumer
# pins in its own flake.lock so the gate is the one its next dev shell would
# install; CI runs the same set again as its pre-commit check, and only the
# build is the foreign system's. Enter it from inside the consumer's checkout:
#
#   nix develop --impure --expr 'import <std>/flake-modules/host-hooks.nix {
#     consumer = /path/to/consumer; system = builtins.currentSystem; }' -c true
#
# git-hooks installs into the repository holding the current directory.
{ consumer, system }:
let
  std = (builtins.getFlake (toString consumer)).inputs.std;
  pkgs = std.inputs.nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib;
  hooks = import (std.outPath + "/flake-modules/hooks.nix") {
    inherit pkgs lib;
    ruffConfigArg = " --config ${std.outPath}/ruff.toml";
  };
  pc = std.inputs.git-hooks.lib.${system}.run {
    src = consumer;
    inherit hooks;
  };
in
pkgs.mkShell {
  packages = [ pkgs.nil ] ++ pc.enabledPackages;
  shellHook = (import (std.outPath + "/lib.nix")).devStateHook + pc.shellHook;
}
