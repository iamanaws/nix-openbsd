"""Check zlib's shared-library probe with strict symbol-version handling."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Unpatched zlib source directory")
parser.add_argument("--cc", default="cc", help="Compiler command, including linker-selection flags")
parser.add_argument("--make", default="make")
args = parser.parse_args()
source = args.source.resolve()
env = os.environ.copy()
for variable in ["LDSHARED", "CFLAGS", "CPPFLAGS", "LDFLAGS", "CHOST", "CROSS_PREFIX", "NIX_LDFLAGS"]:
    env.pop(variable, None)
env.update(CC=args.cc, CFLAGS="-O2")

with tempfile.TemporaryDirectory(prefix="zlib-shared-check-") as directory:
    for name, flags in [
        ("strict", "-Wl,--no-undefined-version"),
        ("workaround", "-Wl,--no-undefined-version -Wl,--undefined-version"),
    ]:
        work = Path(directory) / name
        work.mkdir()
        result = subprocess.run(
            ["sh", str(source / "configure")], cwd=work,
            env=env | {"LDFLAGS": flags}, capture_output=True, text=True,
        )
        log = (work / "configure.log").read_text()
        assert result.returncode == 0, log
        if name == "strict":
            assert "No shared library support" in result.stdout, result.stdout
            assert "version" in log and "not defined" in log, log
            print("PASS: strict version checking reproduces silent shared-library disabling", flush=True)
        else:
            assert "Building shared library" in result.stdout, result.stdout
            test = subprocess.run(
                [args.make, "-j2", "test"], cwd=work,
                env=env | {"LDFLAGS": flags}, capture_output=True, text=True,
            )
            assert test.returncode == 0, test.stdout + test.stderr
            assert list(work.glob("libz.so.*")), "Shared library was not built"
            assert "zlib shared test OK" in test.stdout, test.stdout
            print("PASS: workaround builds libz.so and passes zlib's tests", flush=True)
