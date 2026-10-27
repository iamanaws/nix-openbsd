{
  cross,
  nixbsdSource,
  nativeSystem,
  hostPkgs,
  pkgs ? cross.buildPackages,
}:
let
  inherit (pkgs) lib;
  source = nixbsdSource;
  # Other image builders fetch the same amd64 boot inputs without Linux build dependencies.
  guestInput =
    package:
    if pkgs.stdenv.hostPlatform.system == cross.buildPackages.stdenv.hostPlatform.system then
      package
    else
      let
        path = builtins.unsafeDiscardStringContext package.outPath;
      in
      builtins.appendContext path { "${path}".path = true; };
  # Linux assembles an already-built native closure, fetched from the cache.
  path = builtins.unsafeDiscardStringContext nativeSystem.outPath;
  system = builtins.appendContext path {
    "${path}" = {
      path = true;
    };
  };
  registration = pkgs.closureInfo { rootPaths = [ system ]; };
  database =
    pkgs.runCommand "native-system-database" { nativeBuildInputs = [ hostPkgs.nix.nix-cli ]; }
      ''
        nix-store --store "local?root=$TMP/store" --load-db < ${registration}/registration
        mkdir -p $out
        cp -a "$TMP/store/nix/var/nix/db" $out/db
      '';
  # The image copier rejects overlapping destinations. Keep the database and
  # generation profiles in one tree instead of copying /nix/var/nix twice.
  layout = pkgs.runCommand "native-system-layout" { } ''
    mkdir -p $out/boot/efi $out/var/db $out/etc
    mkdir -p $out/nix/var/nix/profiles
    cp -a ${database}/db $out/nix/var/nix/db
    ln -s ${system} $out/nix/var/nix/profiles/system-1-link
    ln -s system-1-link $out/nix/var/nix/profiles/system
    install -d -m 700 $out/var/authpf
    install -m 600 /dev/null $out/var/db/host.random
    ${pkgs.python3}/bin/python3 ${./seed.py} reserve $out/etc/random.seed
  '';
  devices = guestInput (cross.openbsd.callPackage (source + "/lib/openbsd-makedev-mtree.nix") { });
  bootloader = guestInput cross.openbsd.stand;
  makedev = guestInput cross.openbsd.makedev;
  boot = pkgs.runCommand "native-system-boot" { } ''
    mkdir -p $out/nixos
    cat > $out/nixos/default.conf <<CONF
    set tty com0
    set image ${system}/kernel
    set init ${system}/bin/activate-init-native
    CONF
    cp $out/nixos/default.conf $out/nixos/1.conf
  '';
  esp = pkgs.runCommand "native-system-esp" { } ''
    mkdir -p $out/efi/boot
    cp ${bootloader}/bin/BOOTX64.EFI $out/efi/boot/BOOTX64.EFI
  '';
  rootPartition = import (source + "/lib/make-partition-image.nix") {
    inherit pkgs lib;
    label = "nixos";
    filesystem = "ufs";
    ufsVersion = "1";
    totalSize = "12g";
    makeRootDirs = true;
    nixStorePath = "/nix/store";
    nixStoreClosure = [ system ];
    contents = [
      {
        target = "/";
        source = layout;
      }
      {
        target = "/boot";
        source = boot;
      }
      {
        target = "/dev/MAKEDEV";
        source = "${makedev}/bin/MAKEDEV";
      }
    ];
    extraMtree = "${devices}/mtree";
    extraMtreeContents = "${devices}/dev";
    extraMtreeContentsDest = "/";
  };
  root = rootPartition.overrideAttrs (old: {
    # Avoid writing zeros across the unused space in the 12 GiB filesystem.
    buildCommand = builtins.replaceStrings [ "/bin/makefs " ] [ "/bin/makefs -Z " ] old.buildCommand;
  });
  data = import (source + "/lib/make-disk-image.nix") {
    inherit pkgs lib;
    partitions = [ (root // { tooLargeIntermediate = false; }) ];
    format = "raw";
    partitionTableType = "bsd";
  };
  efi = import (source + "/lib/make-partition-image.nix") {
    inherit pkgs lib;
    label = "ESP";
    filesystem = "efi";
    totalSize = "64m";
    contents = [
      {
        target = "/";
        source = esp;
      }
    ];
  };
  raw = import (source + "/lib/make-disk-image.nix") {
    inherit pkgs lib;
    partitions = [
      data
      efi
    ];
    format = "raw";
    partitionTableType = "efi";
    name = "openbsd-native-system";
  };
  image = raw.overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [
      pkgs.python3
      hostPkgs.qemu_kvm
    ];
    buildCommand = old.buildCommand + ''
      python3 ${./disklabel.py} "$out/${raw.filename}"
      python3 ${./seed.py} locate "$out/${raw.filename}" > "$out/random-seed-offset"
      qemu-img convert -f raw -O qcow2 "$out/${raw.filename}" "$out/openbsd-native.qcow2"
      rm "$out/${raw.filename}"
      echo "file qcow2-image $out/openbsd-native.qcow2" > "$out/nix-support/hydra-build-products"
    '';
    passthru = old.passthru // {
      filename = "openbsd-native.qcow2";
    };
  });
in
{
  inherit image;
}
