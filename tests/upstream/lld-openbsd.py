"""Check OpenBSD library lookup without running target binaries."""

import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--clang", required=True)
parser.add_argument("--lld", required=True)
parser.add_argument("--ar", required=True)
parser.add_argument("--readelf", required=True)
parser.add_argument("--skip-driver", action="store_true", help="Test LLD without a rebuilt Clang")
args = parser.parse_args()


def run(*command, success=True):
    result = subprocess.run(command, text=True, capture_output=True)
    if (result.returncode == 0) != success:
        raise RuntimeError(f"{command!r}:\n{result.stdout}{result.stderr}")
    return result.stdout + result.stderr


with tempfile.TemporaryDirectory(prefix="lld-openbsd-") as temporary:
    work = Path(temporary)
    source = work / "library.c"
    source.write_text("int answer(void) { return 42; }\n")
    obj = work / "library.o"
    run(args.clang, "--target=x86_64-unknown-openbsd", "-fPIC", "-c", str(source), "-o", str(obj))
    first, second = work / "first", work / "second"
    first.mkdir()
    second.mkdir()

    def library(directory, suffix):
        path = directory / f"libanswer.so{suffix}"
        run(args.lld, "-m", "elf_x86_64_obsd", "-shared", str(obj), "-soname", path.name, "-o", str(path))
        return path

    def link(*options, expected=None, success=True):
        output = work / "linked.so"
        result = run(args.lld, "-shared", "-m", "elf_x86_64_obsd", str(obj), *map(str, options), "-o", str(output), success=success)
        if success:
            dynamic = run(args.readelf, "-d", str(output))
            if expected is None:
                assert "NEEDED" not in dynamic, dynamic
            else:
                needed = [line for line in dynamic.splitlines() if "NEEDED" in line]
                assert len(needed) == 1 and f"[{expected}]" in needed[0], dynamic
        return result

    for suffix in (".2.9", ".2.10", ".10.0"):
        library(first, suffix)
    for suffix in (".99", ".99.bad", ".99.0.extra", ".-1.0", ".2147483648.0"):
        (first / f"libanswer.so{suffix}").write_text("invalid library\n")
    (first / "libanswer.so.999.0").mkdir()
    (first / "libanswer.so.998.0").symlink_to("missing")
    link("-L", first, "-lanswer", expected="libanswer.so.10.0")
    (first / "libanswer.so.10.0").unlink()
    link("-L", first, "-lanswer", expected="libanswer.so.2.10")
    library(second, ".100.0")
    link("-L", first, "-L", second, "-lanswer", expected="libanswer.so.2.10")
    library(first, "")
    link("-L", first, "-lanswer", expected="libanswer.so")
    (first / "libanswer.so").unlink()
    link("-L", first, "-l:libanswer.so.2.9", expected="libanswer.so.2.9")
    link("-L", first, "-l:libanswer.so", success=False)
    # Other target emulations must retain their original library lookup.
    for emulation in ("elf_x86_64", "elf_x86_64_fbsd"):
        run(args.lld, "-shared", "-m", emulation, str(obj), "-L", str(first), "-lanswer", "-o", str(work / "other.so"), success=False)
    archive = first / "libanswer.a"
    run(args.ar, "rcs", str(archive), str(obj))
    link("-Bstatic", "-L", first, "-lanswer")
    link("-L", second, "-L", first, "-lanswer", expected="libanswer.so.100.0")
    for path in first.glob("libanswer.so*"):
        if not path.is_dir():
            path.unlink()
    # An archive in an earlier directory wins over a later shared library.
    link("-L", first, "-L", second, "-lanswer")
    sysroot = work / "sysroot"
    (sysroot / "lib").mkdir(parents=True)
    library(sysroot / "lib", ".3.0")
    link("--sysroot", sysroot, "-L=/lib", "-lanswer", expected="libanswer.so.3.0")
    # Clang must opt into the emulation only for LLD on OpenBSD.
    for target in (() if args.skip_driver else ("x86_64-unknown-openbsd", "i686-unknown-openbsd")):
        command = run(args.clang, "--target=" + target, "-fuse-ld=lld", "--ld-path=" + args.lld, "-nostdlib", "-shared", str(obj), "-###")
        expected = "elf_x86_64_obsd" if target.startswith("x86_64") else "elf_i386_obsd"
        assert expected in command, command
    if not args.skip_driver:
        command = run(args.clang, "--target=x86_64-unknown-openbsd", "-fuse-ld=bfd", "--ld-path=" + args.lld, "-nostdlib", "-shared", str(obj), "-###")
        assert "_obsd" not in command, command
        command = run(args.clang, "--target=x86_64-unknown-linux-gnu", "-fuse-ld=lld", "--ld-path=" + args.lld, "-nostdlib", "-shared", str(obj), "-###")
        assert "_obsd" not in command, command

print("OpenBSD LLD lookup checks passed" + ("" if args.skip_driver else "; Clang driver checks passed"))
