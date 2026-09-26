"""Reserve and locate the first-boot seed, filled by the launcher per VM."""

import mmap
import sys
from pathlib import Path


SIZE = 512
MARKER = (b"nix-openbsd: per-instance random seed placeholder\n" * 16)[:SIZE]


def reserve(path):
    path.write_bytes(MARKER)
    path.chmod(0o600)


def locate(path):
    # makefs allocates this one-sector file contiguously. Locate it before
    # qcow2 conversion; reject missing, duplicated or unaligned contents.
    with path.open("r+b") as image, mmap.mmap(image.fileno(), 0) as disk:
        offset = disk.find(MARKER)
        if offset < 0 or offset % SIZE or disk.find(MARKER, offset + 1) != -1:
            raise ValueError("cannot uniquely locate the random seed sector")
        disk[offset:offset + SIZE] = bytes(SIZE)
        return offset


if __name__ == "__main__":
    if sys.argv[1] == "reserve":
        reserve(Path(sys.argv[2]))
    elif sys.argv[1] == "locate":
        print(locate(Path(sys.argv[2])))
    else:
        raise SystemExit("usage: seed.py {reserve|locate} PATH")
