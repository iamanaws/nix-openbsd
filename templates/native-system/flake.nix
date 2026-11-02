{
  description = "My native OpenBSD system";
  inputs.nix-openbsd.url = "github:iamanaws/nix-openbsd";
  outputs =
    { nix-openbsd, ... }:
    let
      configuration = nix-openbsd.lib.mkNativeSystem {
        modules = [ ./configuration.nix ];
      };
    in
    {
      nixosConfigurations.my-openbsd = configuration;
      packages = builtins.listToAttrs (
        map
          (system: {
            name = system;
            value =
              let
                images = nix-openbsd.lib.mkNativeImages {
                  inherit configuration system;
                  rootSize = "24g";
                };
              in
              {
                native-system-image = images.image;
                native-raw-image = images.rawImage;
              };
          })
          [
            "x86_64-linux"
            "aarch64-linux"
            "aarch64-darwin"
          ]
      );
    };
}
