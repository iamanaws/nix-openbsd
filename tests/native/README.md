# Native package and toolchain tests

From the project root on x86_64 Linux with KVM:

```sh
nix run .#test -- --suite native
```

The host transfers recipes, sources and seed tools after boot. The guest builds
the stdenv and packages, then imports outputs into the host store.
Recipe/source edits need another run; installed-tool or configuration changes
rebuild the base image.

| Suite | Work |
| --- | --- |
| `native` | Toolchain, C++, Nix, package checks and a native system build in one VM. |
| `bootstrap` | Stdenv and package builds. |
| `toolchain` | LLVM, Clang and LLD. |
| `cxx` | libc++ and libc++abi. |
| `nix` | Native CLI/daemon builds as root and bestie, closure checks, signed local-cache downloads and disposable-store GC. Restores the original daemon afterward. |

Resources, retention and reports are in the [testing guide](../../docs/testing.md).
The lower-level runner supports `--prepare-only` and
`--all --state-dir DIR` for recipe debugging and build reuse.

## Package checks

- Non-root builders, rebuilt tools and closures without bootstrap seed outputs.
- C/C++ compilation, response files, dynamic/static PIE, builtins, TLS,
  exceptions across shared libraries and upstream libunwind tests.
- Private/shared semaphores, timed waits and cancellation.
- Compression, coreutils, archives, patches, awk extensions and UTF-8 conversion.
- Perl threads, precise timestamps and zlib; Python files, subprocesses,
  hashing, compression, ctypes callbacks and psutil.
- Ncurses tools/terminfo, libagentx shared/static consumers, references and RPATH.
- Nixpkgs hello/zlib/pigz recipes and local-file fetching.

## Focused runtime probes

These manual probes run inside OpenBSD/amd64 without rebuilding Nix. Set `CXX`
to the native compiler, `LIBCXX` and `NIX_UTIL` to its libc++ and Nix utility
library outputs, and `MESON` to the Meson output. Put the native C compiler and
Ninja on `PATH` and use the native Python matching Meson's Python version.

```sh
"$CXX" -std=c++20 -pthread tests/native/nix-ptsname.cc \
  -L"$LIBCXX/lib" -Wl,-rpath,"$LIBCXX/lib" \
  -L"$NIX_UTIL/lib" -Wl,-rpath,"$NIX_UTIL/lib" \
  -lnixutil -lutil -o /tmp/nix-ptsname
/tmp/nix-ptsname
python3 tests/native/meson-cpu.py "$MESON/bin/meson"
```

The PTY probe tests the installed library, including concurrent lookups and an
invalid descriptor. The Meson probe checks CPU detection, compiles and runs a C
program, and reconfigures through Python. Start with GNU coreutils on `PATH` to
check that Meson's launcher selects OpenBSD's `uname`.
These probes are separate from the full `--nix` runner.

Check the installed libc's `difftime` across negative timestamps, zero and
32-/53-/64-bit boundaries with the native C compiler:

```sh
"$CC" -std=c11 tests/native/difftime.c -o /tmp/difftime
/tmp/difftime
```

The probe checks 289 pairs and requires signed 64-bit `time_t` and at least
64 bits of `long double` precision, as provided on OpenBSD/amd64.

For the libc++abi futex fix, set `LLVM_SRC` to the LLVM 21.1.8 source tree with
`libcxxabi-openbsd-futex.patch` applied. Reuse the upstream guard tests with:

```sh
"$CXX" -std=c++17 -pthread \
  -I"$LLVM_SRC/libcxxabi/test" -I"$LLVM_SRC/libcxxabi/include" \
  -I"$LLVM_SRC/libcxx/src" -I"$LLVM_SRC/libcxx/test/support" \
  tests/native/libcxxabi-futex.cc \
  -L"$LIBCXX/lib" -Wl,-rpath,"$LIBCXX/lib" -o /tmp/libcxxabi-futex
/tmp/libcxxabi-futex
```

This tests the source implementation, explicitly selecting futex guards.
It covers waiting, aborted and completed initialization with 32- and 64-bit
guards, using reduced concurrency and ten repetitions instead of the full stress
suite. A 60-second alarm bounds hangs.

Check the libc++ header fixes against the compiler's installed headers with:

```sh
CXX="$CXX" LIBCXX="$LIBCXX" sh tests/native/libcxx-headers.sh
```

This checks C++17/20, C headers first, `<cuchar>` first, `_XOPEN_SOURCE` 500/600/700,
`_POSIX_C_SOURCE` 200112/200809, and Clang header modules with default feature
macros. It also checks that feature macros and wide-character overloads remain
intact, then runs locale parsing and multibyte conversion checks.

To compare configured upstream headers, set `LIBCXX_HEADERS` to their include
directory and `LIBCXX_COMPILE_ONLY=1` to check compilation without linking them
to a different runtime. The focused probe also checks the frozen C++03 module:

```sh
python3 tests/upstream/llvm-mbstate.py "$LIBCXX_HEADERS" --cxx "$CXX"
```

Test LLVM's child waits and interpreter with `LLVM_DEV` and `LLVM_LIB` set to
its development and library outputs:

```sh
for probe in llvm-wait llvm-roundeven; do
  "$CXX" -std=c++17 -pthread "tests/native/$probe.cc" -I"$LLVM_DEV/include" \
    -L"$LIBCXX/lib" -Wl,-rpath,"$LIBCXX/lib" \
    -L"$LLVM_LIB/lib" -Wl,-rpath,"$LLVM_LIB/lib" -lLLVM -o "/tmp/$probe"
done
timeout 30 /tmp/llvm-wait
/tmp/llvm-roundeven "$LLVM_SRC/llvm/test/ExecutionEngine/Interpreter/roundeven.ll"
```

The wait probe checks exit status, polling, concurrent timeouts, child reaping
and caller alarm preservation. The interpreter probe runs the patched
`roundeven.ll` regression under all four host rounding modes and checks that
the interpreter preserves the mode. Both require the corresponding LLVM patches.
