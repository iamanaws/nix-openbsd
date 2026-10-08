# Native OpenBSD package test

Run from the project root, with `nixbsd` beside it:

```sh
nix build --impure --max-jobs 1 --cores 8 --out-link result-native-test \
  --extra-substituters https://nix-openbsd.cachix.org \
  --extra-trusted-public-keys 'nix-openbsd.cachix.org-1:IbN25q8l3NyIq8L16AWaJ1MNTxZRiYdzO5eYFQv1J+4=' \
  --expr '(import ./tests/native { nixbsd = builtins.getFlake ("path:" + toString ../nixbsd); }).test'
./result-native-test/bin/test-openbsd-native
```

The host supplies cross-built seed tools and sources to an OpenBSD 7.9 VM.
The guest builds the native stdenv and test packages, using the
[binary cache](../../docs/vm.md#binary-cache) when available.
See the [stdenv status](../../docs/status.md) for results and limitations.

The runner imports recipes and tests after boot over a local connection.
Rerun the build command after editing them. Changes to seed tools, preloaded
sources or VM configuration rebuild the base image. Recipe changes reuse it.

Use `--prepare-only` to check recipe transfer and evaluation without building
packages, `--cxx` to run the full C++ suites, or `--toolchain` to build and test
native LLVM, Clang and LLD. Use `--nix` to build the native Nix CLI and daemon,
then run the package checks through that daemon as root and `bestie`. It also
checks for bootstrap references, downloads from Cachix, and tests garbage
collection in a disposable store. The original daemon is restored afterward.

The VM has eight vCPUs, 16 GiB of RAM and a 64 GiB root filesystem. Host and
guest builds run one package at a time, with eight cores per build.

Failed runs keep the log, disk and failed build directories. Set
`OPENBSD_VM_KEEP_TMP=1` to keep successful runs too. The timeout is 24 hours.
Change it with `OPENBSD_VM_TIMEOUT`, in seconds. The runner requests a clean
guest shutdown after the test.

## Checks

Root and `bestie` request builds through the daemon. The test checks:

- Non-root `nixbld` builders and use of the rebuilt tools.
- A final stdenv closure without bootstrap seed outputs.
- C/C++ compilation, response files, compression and coreutils operations.
- Dynamic and static PIE libc consumers, compiler builtins and C++ thread-local storage.
- Private and shared semaphores, timed waits and thread cancellation.
- Libunwind's upstream tests and C++ exception cleanup across a shared library.
- Dynamic and static PIE C++ consumers using the rebuilt runtimes.
- Archive extraction, patching and awk's in-place editing extension.
- Native Perl threads, subsecond timestamps and zlib extensions.
- Native Python hashing, file I/O, subprocesses, compression, ctypes callbacks and psutil.
- UTF-8 locales, character case conversion and display widths.
- Native ncurses tools and the generated terminfo database.
- Libagentx shared-library and static-archive consumers, including store
  references and RPATH.
- Nixpkgs' hello, zlib and pigz recipes, plus local-file fetching.

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

This checks C++17/20, both C/C++ header orders, `_XOPEN_SOURCE` 500/600/700,
`_POSIX_C_SOURCE` 200112/200809, and Clang header modules with default feature
macros. It also checks that feature macros and wide-character overloads remain
intact, then runs locale parsing and multibyte conversion checks.

Test LLVM's child waits with `LLVM_DEV` and `LLVM_LIB` set to its development
and library outputs:

```sh
"$CXX" -std=c++17 -pthread tests/native/llvm-wait.cc -I"$LLVM_DEV/include" \
  -L"$LIBCXX/lib" -Wl,-rpath,"$LIBCXX/lib" \
  -L"$LLVM_LIB/lib" -Wl,-rpath,"$LLVM_LIB/lib" -lLLVM -o /tmp/llvm-wait
timeout 30 /tmp/llvm-wait
```

This checks exit status, polling, concurrent timeouts, child reaping and caller
alarm preservation. It requires LLVM rebuilt with the updated timeout patch;
the previously built library fails the child-ownership check.
