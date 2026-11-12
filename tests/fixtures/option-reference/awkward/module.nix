{ lib, ... }:
{
  options.demo = {
    entry = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[^\n\r]+");
      default = null;
      description = ''
        The entry to start. It may not span lines.

        Not settable from the command line:

        - the timeout
        - the resolution
      '';
    };
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''
        [
          "first"
          "second"
        ]
      '';
      description = "Labels shown next to the entry.";
    };
  };
}
