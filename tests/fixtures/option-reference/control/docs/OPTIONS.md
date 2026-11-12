# Options

Every option the modules of this flake declare. This file is generated from the module sources: change a description there, then run `nix run .#std-write-option-reference`.

## Demo module

Declared in [module.nix](../module.nix).

### `demo.enable`

Whether to enable the demo.

- Type: boolean
- Default: `false`

### `demo.greeting`

What the demo says when it starts.

- Type: string
- Default: `"hello"`
- Example: `"good morning"`

### `demo.limits`

How much of each resource the demo may use.

- Type: attribute set of signed integer
- Default:

  ```nix
  {
    cpu = 2;
    memory = 512;
  }
  ```
