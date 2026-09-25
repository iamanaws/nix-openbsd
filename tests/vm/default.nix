{ pkgs, source }:
pkgs.writeShellApplication {
  name = "test-openbsd-native-vm";
  runtimeInputs = [
    pkgs.python3
    pkgs.nix.nix-cli
  ];
  text = ''
    exec python3 ${./run.py} ${source} "$@"
  '';
}
