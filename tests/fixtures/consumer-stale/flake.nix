{
  inputs.std = {
    url = "github:Daaboulex/nix-packaging-standard?ref=v2.42.0";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = _: { };
}
