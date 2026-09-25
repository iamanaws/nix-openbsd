"""Expose the GPT EFI partition as sd0i in OpenBSD's nested disklabel."""

import struct
import sys
import uuid
from pathlib import Path


def patch(path):
    with path.open("r+b") as disk:
        disk.seek(512)
        header = disk.read(512)
        if header[:8] != b"EFI PART":
            raise ValueError("missing GPT header")
        lba, count, stride = struct.unpack_from("<QII", header, 72)
        if not (1 <= count <= 4096 and 128 <= stride <= 4096):
            raise ValueError("invalid GPT entries")
        partitions = {}
        for index in range(count):
            disk.seek(lba * 512 + index * stride)
            entry = disk.read(stride)
            kind = str(uuid.UUID(bytes_le=entry[:16]))
            if kind != str(uuid.UUID(int=0)):
                if kind in partitions:
                    raise ValueError("ambiguous partition type")
                partitions[kind] = struct.unpack_from("<QQ", entry, 32)
        root = partitions["824cc7a0-36a8-11e3-890a-952519ad3f61"]
        start, end = partitions["c12a7328-f81f-11d2-ba4b-00a0c93ec93b"]
        sectors = path.stat().st_size // 512
        if not (root[0] < root[1] < start <= end < sectors):
            raise ValueError("invalid partition bounds")
        offset = (root[0] + 1) * 512
        disk.seek(offset)
        label = bytearray(disk.read(512))
        for position in (0, 132):
            if struct.unpack_from("<I", label, position)[0] != 0x82564557:
                raise ValueError("missing BSD disklabel")
        if struct.unpack_from("<H", label, 114)[0] != 1:
            raise ValueError("unsupported disklabel version")
        slot = 148 + 8 * 16
        if any(label[slot:slot + 16]):
            raise ValueError("partition i is already occupied")
        # mkimg's nested label covers only the root partition. OpenBSD also
        # needs the outer EFI partition in this label to mount /dev/sd0i.
        struct.pack_into("<I", label, 60, sectors & 0xFFFFFFFF)
        struct.pack_into("<H", label, 112, sectors >> 32)
        size = end - start + 1
        struct.pack_into("<IIHHBBH", label, slot, size & 0xFFFFFFFF,
                         start & 0xFFFFFFFF, start >> 32, size >> 32, 8, 0, 0)
        struct.pack_into("<HH", label, 136, 0, 16)
        checksum = 0
        for word in struct.unpack("<202H", label[:404]):
            checksum ^= word
        struct.pack_into("<H", label, 136, checksum)
        disk.seek(offset)
        disk.write(label)


if __name__ == "__main__":
    patch(Path(sys.argv[1]))
