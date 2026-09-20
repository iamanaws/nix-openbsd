# Native stdenv status

Status as of 2026-09-18. The stdenv is not finished.

## Verified

- Native libc, compiler builtins, libunwind and libc++ build. C/C++ consumers
  pass with dynamic linking and static PIE.
- Tcl, Expect and DejaGnu build. DejaGnu reports 604 expected passes.
- Libffi's tests report 1,658 passes and no failures after the closure fix.
- Minimal Python supports zlib and ctypes callbacks. Psutil's selected tests
  report 28 passes, five skips and 16 deselections.
- The libc++abi suite reports 58 passes and 22 unsupported tests after fixing
  its OpenBSD futex operation constants. Its test runner still needed manual
  cleanup in those runs.
- Focused libc++ checks report 307 passes, one failure, three unsupported
  tests and one expected failure. The remaining failure expects locale-aware
  number formatting that OpenBSD does not provide.

These are results from individual builds and tests, not a fresh end-to-end run
with every recent change.

## Python worker shutdown

Python worker pools sometimes stopped making progress when jobs combined
timer threads and subprocesses. The problem was reproduced outside LLVM's
test runner.

The `libpthread` fix uses process-private futex operations for unnamed
semaphores. Named semaphores retain their shared behavior.

Validation so far:

- A small C regression fails with the old library and passes with the patch.
- Dynamic and static PIE tests pass for private and shared semaphores,
  timeouts and thread cancellation.
- Three Python runs complete all 18,000 jobs and shut down normally.

The patch is included in the seed and native package definitions. The full
libc++abi runner and the complete bootstrap still need validation with it.
The regression lives in [`semaphore.c`](../tests/native/semaphore.c).

## Remaining work

- Build and test native LLVM, LLD and Clang with `--toolchain`, including
  the LLD `-nopie` compatibility fix.
- Replace the seed compiler and linker with the native outputs.
- Rerun the full C++ suites. Header-visibility, locale and other OpenBSD
  compatibility failures remain; they have not been disabled.
- Run the complete bootstrap and consumer tests in a fresh VM, then check
  which outputs still depend on seed tools or libraries.

See [test instructions](../tests/native/README.md). Tested fixes can be proposed
upstream separately; the complete stdenv is not ready for upstream submission.
