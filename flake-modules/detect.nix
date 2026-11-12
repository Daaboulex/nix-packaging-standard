lintSystem:
{
  lib,
  flake-parts-lib,
  inputs,
  ...
}:
let
  inherit (lib) mkOption types;

  detections = (import ./detections.nix).data;

  detection =
    name:
    {
      modes ? [
        "report"
        "gate"
      ],
      extra ? { },
    }:
    assert builtins.attrNames extra == detections.${name}.options;
    mkOption {
      default = null;
      description = "${detections.${name}.tool}: ${detections.${name}.finds}. Unset is off.";
      type = types.nullOr (
        types.submodule {
          options = {
            mode = mkOption {
              type = types.enum modes;
              description = "report keeps the findings and passes; gate fails on any finding. Both fail when the tool exits with anything but 0 or its findings code.";
            };
            paths = mkOption {
              type = types.nonEmptyListOf types.str;
              description = "Files or directories, relative to the repository root, that hold the code to read.";
            };
            exclude = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Files or directories under paths to leave out, relative to the repository root.";
            };
          }
          // extra;
        }
      );
    };

  minimumTokens = mkOption {
    type = types.ints.positive;
    description = "The shortest run of tokens CPD reports as a copy.";
  };

  python = mkOption {
    type = types.package;
    description = "A Python interpreter that can import the project's dependencies and the tool this detection runs.";
  };
in
{
  _file = ./detect.nix;

  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options.std.detect = {
      shell = detection "shell" {
      };
      duplicates-cpp = detection "duplicates-cpp" {
        extra = { inherit minimumTokens; };
      };
      duplicates-python = detection "duplicates-python" {
        extra = { inherit minimumTokens; };
      };
      dead-python = detection "dead-python" {
      };
      analysis-cpp = detection "analysis-cpp" {
        extra = {
          checks = mkOption {
            type = types.nonEmptyListOf (
              types.enum [
                "warning"
                "style"
                "performance"
                "portability"
                "unusedFunction"
              ]
            );
            description = "The cppcheck check groups to enable beyond its errors.";
          };
          suppressions = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "A cppcheck suppressions list, relative to the repository root, holding the judged findings.";
          };
        };
      };
      types-python = detection "types-python" {
        extra = {
          python = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "A Python interpreter that can import the project's dependencies, so their types resolve.";
          };
          baseline = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "A basedpyright baseline file, relative to the repository root, holding the judged findings.";
          };
        };
      };
      coverage-python = detection "coverage-python" {
        extra = {
          inherit python;
          floor = mkOption {
            type = types.str;
            description = "A file, relative to the repository root, holding the lowest total coverage accepted, as one whole number.";
          };
        };
      };
      mutation-python = detection "mutation-python" {
        modes = [ "report" ];
      };
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
      cfg = lib.filterAttrs (_: detection: detection != null) config.std.detect;

      cSources = [
        "c"
        "cc"
        "cpp"
        "cxx"
      ];
      cHeaders = [
        "h"
        "hh"
        "hpp"
        "hxx"
      ];

      tools = {
        shell = _: {
          packages = [ pkgs.shellcheck ];
          extensions = [
            "sh"
            "bash"
          ];
          run = ''timeout 600 shellcheck "''${files[@]}"'';
        };
        duplicates-cpp = on: {
          packages = [ pkgs.pmd ];
          extensions = cSources ++ cHeaders;
          run = ''timeout 600 pmd cpd --language cpp --minimum-tokens ${toString on.minimumTokens} --ignore-identifiers --ignore-literals --file-list "$TMPDIR/files"'';
        };
        duplicates-python = on: {
          packages = [ pkgs.pmd ];
          extensions = [ "py" ];
          run = ''timeout 600 pmd cpd --language python --minimum-tokens ${toString on.minimumTokens} --file-list "$TMPDIR/files"'';
        };
        dead-python = _: {
          packages = [ pkgs.python3Packages.vulture ];
          extensions = [ "py" ];
          run = ''timeout 600 vulture "''${files[@]}"'';
        };
        analysis-cpp = on: {
          packages = [ pkgs.cppcheck ];
          extensions = cSources;
          requires = lib.optional (on.suppressions != null) on.suppressions;
          run = ''timeout 600 cppcheck --enable=${lib.concatStringsSep "," on.checks} --inline-suppr --quiet --error-exitcode=7 ${
            lib.optionalString (
              on.suppressions != null
            ) "--suppressions-list=${lib.escapeShellArg on.suppressions}"
          } --file-list="$TMPDIR/files"'';
        };
        types-python = on: {
          packages = [ pkgs.basedpyright ];
          extensions = [ "py" ];
          requires = lib.optional (on.baseline != null) on.baseline;
          writable = true;
          run = ''timeout 600 basedpyright ${
            lib.optionalString (on.python != null) "--pythonpath ${on.python}/bin/python"
          } ${
            lib.optionalString (on.baseline != null) "--baselinefile ${lib.escapeShellArg on.baseline}"
          } "''${files[@]}"'';
        };
        coverage-python = on: {
          packages = [ on.python ];
          extensions = [ "py" ];
          requires = [ on.floor ];
          writable = true;
          prepare = ''
            floor=$(cat ${lib.escapeShellArg on.floor})
            case "$floor" in
            "" | *[!0-9]*)
              echo "::error::std.detect.coverage-python: ${on.floor} must hold one whole number, and holds '$floor'"
              exit 1
              ;;
            esac
            export COVERAGE_FILE="$TMPDIR/coverage"
            timeout 1800 python -m coverage run --source=${lib.escapeShellArg (lib.concatStringsSep "," on.paths)} -m pytest -q -p no:cacheprovider
          '';
          run = ''python -m coverage report --fail-under="$floor"'';
        };
        mutation-python = _: {
          packages = [ pkgs.mutmut ];
          extensions = [ "py" ];
          writable = true;
          prepare = ''
            timeout 3000 mutmut run
            mutmut export-cicd-stats
            test -s mutants/mutmut-cicd-stats.json
          '';
          run = "sh -c 'cat mutants/mutmut-cicd-stats.json && echo && mutmut results'";
        };
      };

      check =
        name: on:
        let
          tool = {
            requires = [ ];
            writable = false;
            prepare = "";
            inherit (detections.${name}) findings;
          }
          // tools.${name} on;
          named = lib.concatMapStringsSep " -o " (extension: "-name '*.${extension}'") tool.extensions;
          kinds = lib.concatMapStringsSep ", " (extension: ".${extension}") tool.extensions;
          verdict = {
            gate = ''
              if [ "$status" != 0 ]; then
                echo "::error::std-detect-${name}: the tool exited $status"
                exit 1
              fi
            '';
            report = ''
              case "$status" in
              0) ;;
              ${lib.optionalString (tool.findings != null) ''
                ${toString tool.findings}) echo "std-detect-${name}: findings kept in the report, not failing (mode = report)" ;;
              ''}
              *)
                echo "::error::std-detect-${name}: the tool exited $status, which is neither clean nor its findings code"
                exit 1
                ;;
              esac
            '';
          };
        in
        pkgs.runCommand "std-detect-${name}" { nativeBuildInputs = tool.packages ++ [ pkgs.findutils ]; } ''
          ${
            if tool.writable then
              ''
                cp -r ${inputs.self} "$TMPDIR/tree"
                chmod -R u+w "$TMPDIR/tree"
                cd "$TMPDIR/tree"
              ''
            else
              "cd ${inputs.self}"
          }
          export HOME="$TMPDIR/home"
          mkdir "$HOME"
          excluded() {
            local file=''${1#./} entry
            for entry in ${lib.escapeShellArgs on.exclude}; do
              case "$file" in
              "$entry" | "$entry"/*) return 0 ;;
              esac
            done
            return 1
          }
          for path in ${lib.escapeShellArgs (on.paths ++ tool.requires)}; do
            if [ ! -e "$path" ]; then
              echo "::error::std.detect.${name}: path '$path' does not exist in this repository"
              exit 1
            fi
          done
          files=()
          for path in ${lib.escapeShellArgs on.paths}; do
            while IFS= read -r -d "" file; do
              excluded "$file" || files+=("$file")
            done < <(find "$path" -type f \( ${named} \) -print0 | sort -z)
          done
          if [ "''${#files[@]}" -eq 0 ]; then
            echo "::error::std.detect.${name} is on but its paths hold no ${kinds} file"
            exit 1
          fi
          printf '%s\n' "''${files[@]}" > "$TMPDIR/files"
          ${tool.prepare}
          status=0
          ${tool.run} > "$TMPDIR/report" 2>&1 || status=$?
          cat "$TMPDIR/report"
          ${verdict.${on.mode}}
          mkdir "$out"
          cp "$TMPDIR/report" "$out/report"
        '';
    in
    {
      checks = lib.optionalAttrs (system == lintSystem) (
        lib.mapAttrs' (name: on: lib.nameValuePair "std-detect-${name}" (check name on)) cfg
      );
    };
}
