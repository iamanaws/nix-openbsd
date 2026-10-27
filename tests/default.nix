{ pkgs, source }:
pkgs.writeShellApplication {
  name = "test-openbsd";
  runtimeInputs = with pkgs; [
    python3
    nix.nix-cli
    bash
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    jq
  ];
  text = ''
    exec python3 -B ${./run.py} --source ${source} \
      --host-system ${pkgs.stdenv.hostPlatform.system} "$@"
  '';
}
