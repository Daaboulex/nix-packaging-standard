# Options

Every option the modules of this flake declare. This file is generated from the module sources: change a description there, then run `nix run .#std-write-option-reference`.

## Demo module

Declared in [module.nix](../module.nix).

### `demo.entry`

The entry to start. It may not span lines.

Not settable from the command line:

- the timeout
- the resolution

Type: `null or string matching the pattern [^\n\r]+`. Default: `null`.

### `demo.labels`

Labels shown next to the entry.

Type: `list of string`. Default: `[ ]`.

Example:

```nix
[
  "first"
  "second"
]
```
