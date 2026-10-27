{
  pkgs,
  image ? null,
  firmware,
}:
let
  inherit (pkgs) lib;
  platform = pkgs.stdenv.hostPlatform;
  qemu = if platform.isx86_64 then pkgs.qemu_kvm else pkgs.qemu;
in
pkgs.writeShellApplication {
  name = "run-openbsd-native-vm";
  runtimeInputs = [
    qemu
    pkgs.nix.nix-cli
    pkgs.coreutils
  ];
  text = ''
    accel="''${NIX_VM_ACCEL:-auto}"
    case "$accel" in
      auto)
        ${
          if platform.isLinux && platform.isx86_64 then
            ''
              if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
                accel=kvm
              else
                accel=tcg
              fi
            ''
          else
            ''
              accel=tcg
            ''
        }
        ;;
      tcg) ;;
      ${lib.optionalString (platform.isLinux && platform.isx86_64) "kvm) ;;"}
      *)
        echo "Unsupported accelerator '$accel' for an amd64 guest on ${platform.system}." >&2
        exit 1
        ;;
    esac
    if [ "$accel" = tcg ]; then
      echo "Running amd64 OpenBSD with software emulation; builds will be slower." >&2
    fi

    state="''${NIX_VM_STATE_DIR:-openbsd-native-vm}"
    mkdir -p "$state"
    state=$(realpath "$state")
    ${
      if image == null then
        ''
          if [ ! -e "$state/disk.qcow2" ]; then
            echo "A prepared VM disk is required in $state." >&2
            exit 1
          fi
        ''
      else
        ''
          if [ ! -e "$state/disk.qcow2" ]; then
            nix-store --add-root "$state/base-image" --realise ${image} >/dev/null
            # Never boot the shared template seed. Write host entropy into the
            # private overlay before making the new disk available to QEMU.
            seed=$(mktemp "$state/.random-seed.XXXXXX")
            trap 'rm -f "$seed" "$state/disk.qcow2.tmp"' EXIT
            dd if=/dev/urandom of="$seed" bs=512 count=1 status=none
            qemu-img create -f qcow2 -F qcow2 -b ${image}/${image.filename} "$state/disk.qcow2.tmp"
            (cd "$state"; qemu-io -f qcow2 \
              -c "write -q -s ''${seed##*/} $(cat ${image}/random-seed-offset) 512" disk.qcow2.tmp)
            mv "$state/disk.qcow2.tmp" "$state/disk.qcow2"
            rm "$seed"
            trap - EXIT
          elif [ "$(readlink -f "$state/base-image")" != "${image}" ]; then
            echo "Using existing VM disk in $state, created from an older image." >&2
            echo "Update the guest, or set NIX_VM_STATE_DIR to a new directory for a fresh VM." >&2
          fi
        ''
    }
    if [ ! -e "$state/efi.fd" ]; then
      cp ${firmware}/FV/OVMF_VARS.fd "$state/efi.fd"
      chmod u+w "$state/efi.fd"
    fi
    # Keep the portable CPU model: host passthrough caused illegal instructions in Nix.
    exec qemu-system-x86_64 -accel "$accel" \
      -name openbsd-native -m "''${NIX_VM_MEMORY:-4096}" -smp "''${NIX_VM_CORES:-2}" \
      -device virtio-rng-pci \
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:''${NIX_VM_HTTP_PORT:-8080}-:80,hostfwd=tcp:127.0.0.1:''${NIX_VM_SSH_PORT:-2222}-:22" \
      -device virtio-net-pci,netdev=net0 \
      -drive "file=$state/disk.qcow2,format=qcow2,if=none,id=root,cache=none,bps_rd=''${NIX_VM_DISK_READ_BPS:-41943040},bps_wr=''${NIX_VM_DISK_WRITE_BPS:-20971520}" \
      -device virtio-blk-pci,drive=root,bootindex=1 \
      -drive if=pflash,format=raw,unit=0,readonly=on,file=${firmware}/FV/OVMF_CODE.fd \
      -drive "if=pflash,format=raw,unit=1,file=$state/efi.fd" \
      -nographic "$@"
  '';
}
