"""Build native tools and packages through Nix in a disposable OpenBSD guest."""

import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def main():
    work = Path(tempfile.mkdtemp(prefix="nixopenbsd-native."))
    (work / "runtime").mkdir()
    success = False
    timeout = int(os.environ.get("OPENBSD_VM_TIMEOUT", "5400"))
    with (work / "console.log").open("wb", buffering=0) as log:
        process = subprocess.Popen(
            [sys.argv[1]], stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
            env=os.environ | {
                "NIX_DISK_IMAGE": str(work / "disk.qcow2"),
                "NIX_EFI_VARS": str(work / "efi.fd"),
                "TMPDIR": str(work / "runtime"), "USE_TMPDIR": "1",
            },
        )
        try:
            with (work / "console.log").open("rb") as reader:
                buffer = b""

                def expect(pattern):
                    nonlocal buffer
                    deadline = time.monotonic() + timeout
                    while time.monotonic() < deadline:
                        data = reader.read()
                        if data:
                            print(data.decode(errors="replace"), end="", flush=True)
                            buffer += data
                        match = re.search(pattern.encode(), buffer)
                        if match:
                            result = buffer[:match.end()]
                            buffer = buffer[match.end():]
                            return result
                        if process.poll() is not None:
                            raise RuntimeError("Guest exited before completing the test")
                        time.sleep(0.1)
                    raise RuntimeError(f"Timeout waiting for {pattern}")

                def send(line):
                    process.stdin.write((line + "\n").encode())
                    process.stdin.flush()

                expect("login:")
                send("root")
                expect("Password:")
                send("toor")
                expect(r"root@[^\r\n]*#")
                send("test-openbsd-native; printf '\\nTEST_%s:%s\\n' DONE \"$?\"")
                result = expect(r"\r?\nTEST_DONE:[0-9]+\r?\n")
                # Flush the guest filesystem and Nix database before retaining the disk.
                send("shutdown -p now")
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    pass  # The cleanup below still handles an unresponsive guest.
                if not result.rstrip().endswith(b"TEST_DONE:0"):
                    raise RuntimeError("Native package test failed")
                success = True
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            if not success or os.environ.get("OPENBSD_VM_KEEP_TMP") == "1":
                print(f"VM logs and disk: {work}", flush=True)
            else:
                shutil.rmtree(work)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
