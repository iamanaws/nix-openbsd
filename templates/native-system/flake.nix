{
  description = "My native OpenBSD VM";
  inputs.nix-openbsd.url = "github:iamanaws/nix-openbsd";
  outputs = { nix-openbsd, ... }: {
    nixosConfigurations.my-openbsd = nix-openbsd.lib.mkNativeSystem {
      modules = [ ./configuration.nix ];
    };
  };
}
