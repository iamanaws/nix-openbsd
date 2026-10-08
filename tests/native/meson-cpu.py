"""Exercise Meson's OpenBSD launcher, CPU detection, and native C builds."""
import argparse
import platform
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("meson", type=Path, help="Installed Meson Python entry point")
args = parser.parse_args()
meson = str(args.meson.resolve())
assert platform.system() == "OpenBSD"
assert platform.machine().lower() in {"amd64", "x86_64"}

with tempfile.TemporaryDirectory(prefix="meson-cpu-") as directory:
    source = Path(directory)
    build = source / "build"
    (source / "meson.build").write_text('''project('cpu-probe', 'c')
assert(host_machine.cpu_family() == 'x86_64', 'wrong CPU family')
assert(host_machine.cpu() == 'x86_64', 'wrong CPU')
hello = executable('hello', 'hello.c')
test('hello', hello)
''')
    (source / "hello.c").write_text('int main(void) { return 0; }\n')
    subprocess.run([meson, "setup", str(build), str(source)], check=True)
    subprocess.run([meson, "compile", "-C", str(build)], check=True)
    subprocess.run([meson, "test", "-C", str(build), "--print-errorlogs"], check=True)
    # Meson and its consumers also invoke the entry point through Python.
    subprocess.run([sys.executable, meson, "setup", "--reconfigure", str(build), str(source)], check=True)
print("MESON_CPU_PASS")
