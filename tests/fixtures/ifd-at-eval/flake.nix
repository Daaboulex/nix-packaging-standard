{
  outputs =
    _:
    let
      system = "@system@";
      written = builtins.derivation {
        name = "written";
        inherit system;
        builder = "/bin/sh";
        args = [
          "-c"
          "echo hello > $out"
        ];
      };
    in
    {
      checks.${system}.reads-at-eval = builtins.derivation {
        name = "reads-at-eval";
        inherit system;
        builder = "/bin/sh";
        args = [
          "-c"
          "echo ${builtins.readFile written} > $out"
        ];
      };
    };
}
