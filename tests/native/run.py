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
    mode.add_argument("--toolchain", action="store_true")
    mode.add_argument("--nix", action="store_true")
    mode.add_argument("--all", action="store_true")
    parser.add_argument("--state-dir", type=Path, help="Keep and reuse a test VM directory")
    args = parser.parse_args()
    work = args.state_dir or Path(tempfile.mkdtemp(prefix="nixopenbsd-native."))
    work = work.resolve()
    (work / "runtime").mkdir(parents=True, exist_ok=True)
    print(f"VM logs and disk: {work}", flush=True)
    success = False
    timeout = int(os.environ.get("OPENBSD_VM_TIMEOUT", "86400"))

    def closure(path):
        return set(subprocess.check_output(
            ["nix-store", "--query", "--requisites", str(path)], text=True,
        ).splitlines())

    recipe_paths = closure(args.recipes)
    launcher_paths = closure(Path(args.launcher).parent.parent)
    missing = recipe_paths - launcher_paths
    known = ("\n".join(sorted(recipe_paths | launcher_paths)) + "\n").encode()

    token = "/" + secrets.token_hex(24)
    export_received = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == token + "/known":
                self.send_response(200)
                self.send_header("Content-Length", str(len(known)))
                self.end_headers()
                self.wfile.write(known)
                return
            if self.path != token:
                self.send_error(404)
                return
            self.send_response(200)
            self.end_headers()
            # HTTP/1.0 closes the response at EOF; stream without a temporary NAR.
            subprocess.run(
                ["nix-store", "--export", *sorted(missing)],
                stdout=self.wfile, check=True,
            )

        def do_PUT(self):
            if not args.all or self.path != token + "/outputs":
                self.send_error(404)
                return
            remaining = int(self.headers.get("Content-Length", "-1"))
            if remaining <= 0:
                self.send_error(411)
                return
            temporary = work / "native-outputs.nar.partial"
            with temporary.open("wb") as output:
                while remaining:
                    data = self.rfile.read(min(1024 * 1024, remaining))
                    if not data:
                        raise ConnectionError("Incomplete native output export")
                    output.write(data)
                    remaining -= len(data)
            temporary.replace(work / "native-outputs.nar")
            export_received.set()
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

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
                # Direct I/O avoids host filesystem stalls during large guest writes.
                "QEMU_OPTS": (
                    "-set drive.drive1.cache.direct=on "
                    "-set drive.drive1.bps_rd=41943040 "
                    "-set drive.drive1.bps_wr=20971520 "
                    + os.environ.get("QEMU_OPTS", "")
                ),
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
                        # The complete output is already in console.log.
                        buffer = buffer[-1024 * 1024:]
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
                flag = (
                    " --prepare-only" if args.prepare_only else
                    " --cxx" if args.cxx else
                    " --toolchain" if args.toolchain else
                    " --nix" if args.nix else ""
                )
                if args.all:
                    flag = " --all"
                export = (
                    f"env NATIVE_EXPORT_URL={shlex.quote(url + '/outputs')} "
                    f"NATIVE_KNOWN_URL={shlex.quote(url + '/known')} "
                    if args.all else ""
                )
                send(
                    "nix-store --realise --add-root /var/lib/native-test --indirect "
                    f"{shlex.quote(args.recipes)} && "
                    f"{export}{shlex.quote(args.recipes)}/bin/test-openbsd-native{flag}; "
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
                if args.all:
                    if not export_received.is_set():
                        raise RuntimeError("Guest did not export native outputs")
                    with (work / "native-outputs.nar").open("rb") as exported:
                        with (work / "imported-paths").open("w") as imported:
                            subprocess.run(["nix-store", "--import"], stdin=exported,
                                           stdout=imported, check=True)
                    roots = work / "outputs"
                    roots.mkdir(exist_ok=True)
                    paths = (work / "imported-paths").read_text().splitlines()
                    if not paths:
                        raise RuntimeError("No native outputs were imported")
                    for path in paths:
                        subprocess.run([
                            "nix-store", "--add-root", str(roots / Path(path).name),
                            "--indirect", "--realise", path,
                        ], stdout=subprocess.DEVNULL, check=True)
                    (work / "native-outputs.nar").unlink()
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
            if args.state_dir or not success or os.environ.get("OPENBSD_VM_KEEP_TMP") == "1":
                print(f"VM logs and disk: {work}", flush=True)
            else:
                shutil.rmtree(work)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
