"""Reproduce the exclude test's timestamp race without sleeps or a VM."""
import argparse
import itertools
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from unittest.mock import patch

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Unpatched rsync source directory")
parser.add_argument("--rsync", default="rsync", help="An installed rsync executable")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
relative = Path("testsuite/exclude_test.py")
original = (args.source / relative).read_text()


def run(source, work):
    # Execute the upstream setup, forcing each touch across a whole-second boundary.
    setup = source.split("# Pre-build an --update test pair.\n", 1)[1]
    setup = setup.split("# Build CHKDIR", 1)[0]
    clock = itertools.count(1_700_000_000)
    touch = Path.touch

    def tick(path, *args, **kwargs):
        touch(path, *args, **kwargs)
        timestamp = next(clock) * 1_000_000_000
        os.utime(path, ns=(timestamp, timestamp))

    with patch.object(Path, "touch", tick):
        exec(
            compile(setup, "exclude_test.py setup", "exec"),
            {"SCRATCHDIR": work, "os": os, "shutil": shutil},
        )
        # These two touches occur later in the upstream test.
        (work / "up1/src-newness").touch()
        (work / "up2/dst-newness").touch()

    output = subprocess.check_output([
        args.rsync, "-aiiO", "--update", "--info=skip",
        str(work / "up1") + "/", str(work / "up2") + "/",
    ], text=True)
    assert "dst-newness is newer" in output
    assert any(line.startswith(">f") and line.endswith("src-newness") for line in output.splitlines())
    return next(line for line in output.splitlines() if "same-newness" in line)


with tempfile.TemporaryDirectory(prefix="rsync-timestamp-check-") as directory:
    work = Path(directory)
    target = work / relative
    target.parent.mkdir()
    target.write_text(original)
    subprocess.run([
        "git", "apply", str(root / "pkgs/openbsd/rsync-exclude-timestamps.patch"),
    ], cwd=work, check=True)
    for name, source in [("original", original), ("patched", target.read_text())]:
        case = work / name
        case.mkdir()
        result = run(source, case)
        if name == "original":
            assert result == "same-newness is newer", result
        else:
            assert result.startswith(".f") and "is newer" not in result, result
            assert (case / "up1/same-newness").stat().st_mtime_ns == (
                case / "up2/same-newness"
            ).stat().st_mtime_ns
        print(f"PASS {name}: {result}")
