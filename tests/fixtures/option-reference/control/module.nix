{ lib, ... }:
{
  options.demo = {
    enable = lib.mkEnableOption "the demo";
    greeting = lib.mkOption {
      type = lib.types.str;
      default = "hello";
      example = "good morning";
      description = "What the demo says when it starts.";
    };
    limits = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = {
        cpu = 2;
        memory = 512;
      };
      description = "How much of each resource the demo may use.";
    };
  };
}
