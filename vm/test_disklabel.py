import functools
import operator
import struct
import tempfile
import unittest
import uuid
from pathlib import Path

from disklabel import patch


class DisklabelTest(unittest.TestCase):
    def test_efi_entry_and_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "disk.img"
            data = bytearray(512 * 256)
            data[512:520] = b"EFI PART"
            struct.pack_into("<QII", data, 512 + 72, 2, 2, 128)
            for index, (kind, start, end) in enumerate([
                ("824cc7a0-36a8-11e3-890a-952519ad3f61", 34, 199),
                ("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", 200, 239),
            ]):
                offset = 1024 + index * 128
                data[offset:offset + 16] = uuid.UUID(kind).bytes_le
                struct.pack_into("<QQ", data, offset + 32, start, end)
            offset = 35 * 512
            for position in (0, 132):
                struct.pack_into("<I", data, offset + position, 0x82564557)
            struct.pack_into("<H", data, offset + 114, 1)
            path.write_bytes(data)
            patch(path)
            result = path.read_bytes()
            label = result[offset:offset + 512]
            self.assertEqual(struct.unpack_from("<IIHHBBH", label, 276),
                             (40, 200, 0, 0, 8, 0, 0))
            self.assertEqual(struct.unpack_from("<I", label, 60)[0], 256)
            self.assertEqual(functools.reduce(operator.xor,
                             struct.unpack("<202H", label[:404])), 0)
            self.assertEqual(result[:offset], data[:offset])
            self.assertEqual(result[offset + 512:], data[offset + 512:])
            with self.assertRaisesRegex(ValueError, "already occupied"):
                patch(path)
            self.assertEqual(path.read_bytes(), result)

    def test_rejects_non_gpt_without_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "disk.img"
            path.write_bytes(bytes(1024))
            with self.assertRaisesRegex(ValueError, "missing GPT"):
                patch(path)
            self.assertEqual(path.read_bytes(), bytes(1024))


if __name__ == "__main__":
    unittest.main()
