"""Check libc++'s mbstate_t headers and Clang modules, including frozen C++03 headers."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("headers", type=Path, help="Configured libc++ include directory")
parser.add_argument("--cxx", default="clang++", help="Native compiler or cross-compiler wrapper")
args = parser.parse_args()
headers = args.headers.resolve(strict=True)
cxx03_map = headers / "__cxx03/module.modulemap"
cxx03_module = re.search(
    r"^module (cxx03_std_private_(?:fwd_)?mbstate_t)\s", cxx03_map.read_text(), re.M,
).group(1)
failed = False

with tempfile.TemporaryDirectory(prefix="libcxx-mbstate-") as directory:
    work = Path(directory)
    for standard in ("c++03", "c++17", "c++20"):
        for modules in (False, True):
            source = work / "probe.cc"
            imports = f"#pragma clang module import {cxx03_module}\n" if standard == "c++03" and modules else ""
            body = """
#if __cplusplus >= 201103L
#include <cuchar>
#endif
#include <cwchar>
#include <iosfwd>
int main() {
  std::mbstate_t state = {};
  wchar_t* (*mutable_find)(wchar_t*, wchar_t) = std::wcschr;
  const wchar_t* (*const_find)(const wchar_t*, wchar_t) = std::wcschr;
  (void)mutable_find;
  (void)const_find;
  return std::mbsinit(&state) ? 0 : 1;
}
"""
            if standard == "c++03" and modules:
                body = "int main() { std::mbstate_t state = {}; return sizeof(state) == 0; }\n"
            source.write_text(imports + body)
            command = [args.cxx, f"-std={standard}", "-nostdinc++", "-isystem", str(headers)]
            if standard == "c++03":
                command += ["-D_LIBCPP_USE_FROZEN_CXX03_HEADERS"]
            if modules:
                command += ["-fmodules", "-fcxx-modules", "-fimplicit-module-maps",
                            f"-fmodules-cache-path={work / standard}"]
                if standard == "c++03":
                    command += [f"-fmodule-map-file={cxx03_map}"]
            result = subprocess.run(command + ["-fsyntax-only", str(source)], capture_output=True, text=True)
            label = f"{standard} {'modules' if modules else 'plain'}"
            print(f"{'PASS' if result.returncode == 0 else 'FAIL'} {label}", flush=True)
            if result.returncode:
                print(result.stderr, flush=True)
                failed = True

raise SystemExit(1 if failed else 0)
