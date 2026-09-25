{
  cross,
  nixbsdSource,
  nativeSystem,
  hostPkgs,
}:
let
  pkgs = cross.buildPackages;
  inherit (pkgs) lib;
  source = nixbsdSource;
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
  layout = pkgs.runCommand "native-system-layout" { } ''
    mkdir -p $out/boot/efi $out/var/db
    install -d -m 700 $out/var/authpf
    install -m 600 /dev/null $out/var/db/host.random
  '';
  devices = cross.openbsd.callPackage (source + "/lib/openbsd-makedev-mtree.nix") { };
  boot = pkgs.runCommand "native-system-boot" { } ''
    mkdir -p $out/nixos
    cat > $out/nixos/default.conf <<CONF
    set tty com0
    set image ${system}/kernel
    set init ${system}/bin/activate-init-native
    CONF
  '';
  esp = pkgs.runCommand "native-system-esp" { } ''
    mkdir -p $out/efi/boot
    cp ${cross.openbsd.stand}/bin/BOOTX64.EFI $out/efi/boot/BOOTX64.EFI
  '';
  root = import (source + "/lib/make-partition-image.nix") {
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
        target = "/nix/var/nix";
        source = database;
      }
      {
        target = "/boot";
        source = boot;
      }
      {
        target = "/dev/MAKEDEV";
        source = lib.getExe cross.openbsd.makedev;
      }
    ];
    extraMtree = "${devices}/mtree";
    extraMtreeContents = "${devices}/dev";
    extraMtreeContentsDest = "/";
  };
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
      qemu-img convert -f raw -O qcow2 "$out/${raw.filename}" "$out/openbsd-native.qcow2"
      rm "$out/${raw.filename}"
      echo "file qcow2-image $out/openbsd-native.qcow2" > "$out/nix-support/hydra-build-products"
    '';
    passthru = old.passthru // {
      filename = "openbsd-native.qcow2";
    };
  });
  launcher = pkgs.writeShellApplication {
    name = "run-openbsd-native-vm";
    runtimeInputs = [
      hostPkgs.qemu_kvm
      pkgs.coreutils
    ];
    text = ''
      state="''${NIX_VM_STATE_DIR:-openbsd-native-vm}"
      mkdir -p "$state"
      state=$(realpath "$state")
      if [ ! -e "$state/disk.qcow2" ]; then
        qemu-img create -f qcow2 -F qcow2 -b ${image}/${image.filename} "$state/disk.qcow2"
      fi
      if [ ! -e "$state/efi.fd" ]; then
        cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd "$state/efi.fd"
        chmod u+w "$state/efi.fd"
      fi
      # Host CPU passthrough caused illegal instructions during native Nix cache downloads.
      exec qemu-system-x86_64 -enable-kvm \
        -name openbsd-native -m "''${NIX_VM_MEMORY:-4096}" -smp "''${NIX_VM_CORES:-8}" \
        -device virtio-rng-pci \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:''${NIX_VM_HTTP_PORT:-8080}-:80,hostfwd=tcp:127.0.0.1:''${NIX_VM_SSH_PORT:-2222}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -drive "file=$state/disk.qcow2,format=qcow2,if=none,id=root" \
        -device virtio-blk-pci,drive=root,bootindex=1 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
        -drive "if=pflash,format=raw,unit=1,file=$state/efi.fd" \
        -nographic "$@"
    '';
  };
in
{
  inherit image launcher;
}
