# Install

1. Add the input:

   ```nix
   inputs.example = {
     url = "github:example/example"
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```
