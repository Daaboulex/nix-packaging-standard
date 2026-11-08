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
      checks.${system}.reads-at-build = builtins.derivation {
        name = "reads-at-build";
        inherit system;
        builder = "/bin/sh";
        args = [
          "-c"
          "cat ${written} > $out"
        ];
      };
    };
}
