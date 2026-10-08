"""Compile gzip/tar's fseeko backport against actual OpenBSD headers."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Unpatched gzip or tar source tree")
parser.add_argument("--headers", type=Path, required=True, help="OpenBSD 7.9 libc include directory")
parser.add_argument("--cc", default="clang", help="Host-runnable Clang executable")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
subdir = "lib" if (args.source / "lib/fseeko.c").exists() else "gnu"

with tempfile.TemporaryDirectory(prefix="gnulib-fseeko-check-") as directory:
    work = Path(directory)
    for variant in ["original", "patched"]:
        tree = work / variant
        code = tree / subdir
        code.mkdir(parents=True)
        for name in ["fseeko.c", "stdio-impl.h"]:
            shutil.copyfile(args.source / subdir / name, code / name)
        if variant == "patched":
            subprocess.run([
                "patch", "--batch", "--fuzz=0", "-p1" if subdir == "lib" else "-p2",
                "-i", str(root / "pkgs/openbsd/gnulib-openbsd-fseeko.patch"),
            ], cwd=tree if subdir == "lib" else code, check=True, capture_output=True)
        for mode, fflush in [("native", 1), ("cross-fallback", -1)]:
            # Preserve the real libc declaration before naming gnulib's replacement.
            (tree / "config.h").write_text(
                "#include <stdio.h>\n#define HAVE_FSEEKO 1\n"
                f"#define FUNC_FFLUSH_STDIN {fflush}\n#define fseeko rpl_fseeko\n"
            )
            result = subprocess.run([
                args.cc, "--target=x86_64-unknown-openbsd", "-O2",
                "-isystem", str(args.headers.resolve()), "-I", str(tree),
                "-c", str(code / "fseeko.c"), "-o", str(tree / f"{mode}.o"),
            ], capture_output=True, text=True)
            if variant == "original" and mode == "native":
                assert result.returncode != 0 and "Please port gnulib fseeko.c" in result.stderr, result.stderr
                print("PASS: unpatched native configuration reproduces the compile failure")
            else:
                assert result.returncode == 0, result.stderr
                print(f"PASS: {variant} {mode} compiles against OpenBSD headers")
