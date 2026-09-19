"""Build native tools and packages through Nix in a disposable OpenBSD guest."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("launcher")
    parser.add_argument("recipes")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-only", action="store_true")
    mode.add_argument("--cxx", action="store_true")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="nixopenbsd-native."))
    (work / "runtime").mkdir()
    print(f"VM logs and disk: {work}", flush=True)
    success = False
    timeout = int(os.environ.get("OPENBSD_VM_TIMEOUT", "86400"))

    def closure(path):
        return set(subprocess.check_output(
            ["nix-store", "--query", "--requisites", str(path)], text=True,
        ).splitlines())

    bundle = work / "recipes.nar"
    missing = closure(args.recipes) - closure(Path(args.launcher).parent.parent)
    with bundle.open("wb") as output:
        subprocess.run(["nix-store", "--export", *sorted(missing)], stdout=output, check=True)

    token = "/" + secrets.token_hex(24)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != token:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(bundle.stat().st_size))
            self.end_headers()
            with bundle.open("rb") as source:
                shutil.copyfileobj(source, self.wfile)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://10.0.2.2:{server.server_port}{token}"
    with (work / "console.log").open("wb", buffering=0) as log:
        process = subprocess.Popen(
            [args.launcher], stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT,
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
                send(
                    "set -o pipefail; "
                    f"curl --noproxy '*' --fail --silent --show-error {shlex.quote(url)} "
                    "| nix-store --import; printf '\\nIMPORT_%s:%s\\n' DONE \"$?\""
                )
                result = expect(r"\r?\nIMPORT_DONE:[0-9]+\r?\n")
                if not result.rstrip().endswith(b"IMPORT_DONE:0"):
                    raise RuntimeError("Could not import native recipes")
                flag = " --prepare-only" if args.prepare_only else " --cxx" if args.cxx else ""
                send(
                    "nix-store --realise --add-root /var/lib/native-test --indirect "
                    f"{shlex.quote(args.recipes)} && "
                    f"{shlex.quote(args.recipes)}/bin/test-openbsd-native{flag}; "
                    "printf '\\nTEST_%s:%s\\n' DONE \"$?\""
                )
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
            server.shutdown()
            server.server_close()
            thread.join()
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
