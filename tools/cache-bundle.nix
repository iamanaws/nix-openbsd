{
  rootsFile,
  name ? "nix-openbsd-cache",
}:
let
  flake = builtins.getFlake (toString ../.);
  pkgs = flake.inputs.nixbsd.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  roots = builtins.fromJSON (builtins.readFile rootsFile);
in
assert builtins.isList roots && roots != [ ];
assert builtins.all (
  path:
  builtins.isString path && pkgs.lib.hasPrefix "/nix/store/" path && !pkgs.lib.hasSuffix ".drv" path
) roots;
pkgs.linkFarm name (
  map (path: {
    name = builtins.baseNameOf path;
    path = builtins.storePath path;
  }) (pkgs.lib.unique roots)
)
