let
  inherit (builtins) concatStringsSep map toString;

  data = {
    shell = {
      tool = "shellcheck";
      finds = "quoting faults, unreachable code and functions never called, in `.sh` and `.bash`";
      findings = 1;
      options = [ ];
      leftovers = "a `shellcheck disable` directive at the line";
    };
    duplicates-cpp = {
      tool = "PMD CPD";
      finds = "copied C and C++, also with names and values changed";
      findings = 4;
      options = [ "minimumTokens" ];
      leftovers = "`exclude`";
    };
    duplicates-python = {
      tool = "PMD CPD";
      finds = "copied Python, exact copies only";
      findings = 4;
      options = [ "minimumTokens" ];
      leftovers = "`exclude`";
    };
    dead-python = {
      tool = "vulture";
      finds = "functions, classes and variables nothing uses";
      findings = 3;
      options = [ ];
      leftovers = "an allow-list `.py` file under `paths`; `[tool.vulture]` in `pyproject.toml`";
    };
    analysis-cpp = {
      tool = "cppcheck";
      finds = "null dereferences, dangling lifetimes, missing returns; with `unusedFunction`, functions nothing calls";
      findings = 7;
      options = [
        "checks"
        "suppressions"
      ];
      leftovers = "the `suppressions` list";
    };
    types-python = {
      tool = "basedpyright";
      finds = "type errors";
      findings = 1;
      options = [
        "baseline"
        "python"
      ];
      leftovers = "the `baseline` file";
    };
    coverage-python = {
      tool = "coverage.py under pytest";
      finds = "total coverage under a floor";
      findings = 2;
      options = [
        "floor"
        "python"
      ];
      leftovers = "the `floor` file, one whole number";
    };
    mutation-python = {
      tool = "mutmut";
      finds = "tests that run code without checking its result";
      findings = null;
      options = [ ];
      leftovers = "";
    };
  };

  order = [
    "shell"
    "duplicates-cpp"
    "duplicates-python"
    "dead-python"
    "analysis-cpp"
    "types-python"
    "coverage-python"
    "mutation-python"
  ];

  row =
    name:
    let
      detection = data.${name};
    in
    "| `${name}` | ${detection.tool} | ${detection.finds} | ${
      if detection.findings == null then "none: report only" else toString detection.findings
    } | ${
      concatStringsSep ", " (map (option: "`${option}`") detection.options)
    } | ${detection.leftovers} |";
in
{
  inherit data;
  table = concatStringsSep "\n" (
    [
      "| `std.detect.<name>` | Tool | Finds | Exit on findings | Extra options | Judged leftovers live in |"
      "|---|---|---|---|---|---|"
    ]
    ++ map row order
  );
}
