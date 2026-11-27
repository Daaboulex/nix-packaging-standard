# Example

An install snippet is the body of an attribute set:

```nix
inputs.example = {
  url = "github:example/example";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

A module is an expression that reads the names the reader's configuration brings:

```nix
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.hello ];
}
```

A block in another language is not read as Nix:

```bash
echo "$(( 1 +"
```

1. A block inside a list item:

   ```nix
   services.example.enable = true;
   ```
