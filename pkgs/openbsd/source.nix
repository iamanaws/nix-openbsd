{
  callPackage,
  path,
}:
let
  version = "8.0";
in
{
  inherit version;
  # Use the Nixpkgs recipe with the 8.0 hash until the input is updated.
  source =
    (callPackage (path + "/pkgs/os-specific/bsd/openbsd/pkgs/source.nix") {
      inherit version;
    }).overrideAttrs
      {
        outputHash = "sha256-bA2o0Bco+AsJr3RON8WTzjd0E+hyObNEv0VNzMsr99k=";
      };
}
