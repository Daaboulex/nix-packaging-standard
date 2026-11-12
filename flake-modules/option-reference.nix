lintSystem:
{
  lib,
  flake-parts-lib,
  inputs,
  ...
}:
let
  target = "docs/OPTIONS.md";
  writer = "std-write-option-reference";
  rewrite = "nix run .#${writer}";

  indented =
    text:
    lib.concatMapStringsSep "\n" (line: if line == "" then "" else "  ${line}") (
      lib.splitString "\n" text
    );

  value =
    label: rendered:
    if rendered._type or "" == "literalMD" then
      "- ${label}: ${rendered.text}"
    else if lib.hasInfix "\n" rendered.text then
      "- ${label}:\n\n  ```nix\n${indented rendered.text}\n  ```"
    else
      "- ${label}: `${rendered.text}`";

  entry =
    option:
    lib.concatStringsSep "\n" (
      [
        "### `${option.name}`"
        ""
        (lib.trim option.description)
        ""
        "- Type: ${option.type}"
      ]
      ++ lib.optional (option ? default) (value "Default" option.default)
      ++ lib.optional (option ? example && option.type != "boolean") (value "Example" option.example)
      ++ lib.optional option.readOnly "- Read only"
    );

  switchesFirst =
    option:
    map (
      part:
      if part == "enable" then
        " 0"
      else if part == "package" then
        " 1"
      else
        part
    ) (lib.splitString "." option.name);

  unstable =
    option:
    lib.any
      (
        field:
        option ? ${field}
        && (
          lib.hasInfix "/nix/store/" option.${field}.text || lib.hasInfix "<derivation" option.${field}.text
        )
      )
      [
        "default"
        "example"
      ];
in
{
  _file = ./option-reference.nix;

  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options.std.option-reference = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      description = "The modules this flake exports, each under the heading its options are listed under in ${target}. Empty is off.";
    };
  };

  config.perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      src = inputs.self;
      root = toString src + "/";
      modules = config.std.option-reference;

      documented =
        module:
        lib.sort (a: b: lib.compareLists lib.compare (switchesFirst a) (switchesFirst b) < 0) (
          described module
        );

      described =
        module:
        lib.filter (option: option.visible != false && !option.internal) (
          lib.optionAttrSetToDocList (
            builtins.removeAttrs
              (lib.evalModules {
                modules = [
                  module
                  {
                    _module.check = false;
                    _module.args.pkgs = pkgs;
                  }
                ];
              }).options
              [ "_module" ]
          )
        );

      sections = lib.mapAttrs (_: documented) modules;

      declarationFaults = lib.concatLists (
        lib.mapAttrsToList (
          heading: options:
          lib.optional (options == [ ]) "${heading}: the module declares no option"
          ++ lib.concatMap (
            option:
            lib.optional (
              option.description == null
            ) "${heading}: ${option.name} has no description, so a reader cannot tell what it does"
            ++ lib.optional (unstable option) "${heading}: ${option.name} shows a store path or a derivation as its default or example, which changes with every lock update; give it a defaultText or example written with lib.literalExpression"
          ) options
        ) sections
      );

      section =
        heading: options:
        let
          files = lib.unique (
            lib.concatMap (
              option:
              lib.filter (file: builtins.pathExists (src + "/${file}")) (
                map (lib.removePrefix root) (lib.filter (lib.hasPrefix root) (map toString option.declarations))
              )
            ) options
          );
        in
        lib.concatStringsSep "\n\n" (
          [ "## ${heading}" ]
          ++
            lib.optional (files != [ ])
              "Declared in ${lib.concatMapStringsSep ", " (file: "[${file}](../${file})") files}."
          ++ map entry options
        );

      rendered =
        if declarationFaults != [ ] then
          throw "the option reference cannot be written:\n${lib.concatStringsSep "\n" declarationFaults}"
        else
          lib.concatStringsSep "\n\n" (
            [
              "# Options"
              "Every option the modules of this flake declare. This file is generated from the module sources: change a description there, then run `${rewrite}`."
            ]
            ++ lib.mapAttrsToList section sections
          )
          + "\n";

      treeFaults =
        lib.optional (
          !builtins.pathExists (src + "/${target}")
        ) "${target} is missing; write it with: ${rewrite}"
        ++ lib.optional (
          !builtins.pathExists (src + "/README.md")
          || !lib.any (link: lib.hasInfix link (builtins.readFile (src + "/README.md"))) [
            "](${target})"
            "](./${target})"
          ]
        ) "README.md does not link to ${target}, so a reader of the README cannot find the options";

      faults = declarationFaults ++ treeFaults;
    in
    lib.mkIf (modules != { }) {
      apps.${writer} = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = writer;
            runtimeInputs = [
              pkgs.coreutils
              pkgs.git
            ];
            text = ''
              install -Dm644 ${pkgs.writeText "OPTIONS.md" rendered} "$(git rev-parse --show-toplevel)/${target}"
            '';
          }
        );
        meta.description = "Write ${target} from the modules this flake declares under std.option-reference";
      };

      checks = lib.optionalAttrs (system == lintSystem) {
        std-option-reference =
          if faults != [ ] then
            pkgs.runCommand "std-option-reference" { } (
              lib.concatMapStringsSep "\n" (fault: "echo ${lib.escapeShellArg "::error::${fault}"}") faults
              + "\nexit 1\n"
            )
          else
            pkgs.runCommand "std-option-reference"
              {
                inherit rendered;
                committed = builtins.readFile (src + "/${target}");
                passAsFile = [
                  "rendered"
                  "committed"
                ];
              }
              ''
                if ! diff -u "$committedPath" "$renderedPath"; then
                  echo "::error::${target} is not what the modules declare; rewrite it with: ${rewrite}"
                  exit 1
                fi
                touch "$out"
              '';
      };
    };
}
