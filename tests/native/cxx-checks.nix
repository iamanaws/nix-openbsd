{
  libcxx,
  llvmSrc,
  python3,
}:
(libcxx.override { inherit python3; }).overrideAttrs (old: {
  doCheck = true;
  postUnpack = (old.postUnpack or "") + ''
    # The ABI tests compare demanglers; Nixpkgs' source subset omits these files.
    mkdir -p "$sourceRoot/llvm/include/llvm/Testing"
    cp -r ${llvmSrc}/llvm/include/llvm/Demangle "$sourceRoot/llvm/include/llvm/"
    cp -r ${llvmSrc}/llvm/include/llvm/Testing/Demangle "$sourceRoot/llvm/include/llvm/Testing/"
  '';
  postPatch = (old.postPatch or "") + ''
    # OpenBSD accepts arbitrary bare locale names, but rejects unknown encodings.
    substituteInPlace ../libcxx/test/selftest/dsl/dsl.sh.py \
      --replace-fail '"forsurethisisnotanexistinglocale"' \
        '"forsurethisisnotanexistinglocale.INVALID"'
    substituteInPlace ../libcxx/test/std/localization/locales/locale/locale.cons/char_pointer.pass.cpp \
      --replace-fail '"spazbot"' '"spazbot.INVALID"'
    # OpenBSD's pthread_t is a pointer, as on FreeBSD and macOS.
    substituteInPlace \
      ../libcxx/test/std/thread/thread.threads/thread.thread.class/thread.thread.id/format.pass.cpp \
      ../libcxx/test/std/thread/thread.threads/thread.thread.class/thread.thread.id/format.functions.tests.h \
      --replace-fail '!defined(__APPLE__) && !defined(__FreeBSD__)' \
        '!defined(__APPLE__) && !defined(__FreeBSD__) && !defined(__OpenBSD__)'
    # fchmodat can change symlink permissions without following the link.
    substituteInPlace ../libcxx/test/std/input.output/filesystems/fs.op.funcs/fs.op.permissions/permissions.pass.cpp \
      --replace-fail 'defined(__NetBSD__) || defined(_AIX)' \
        'defined(__NetBSD__) || defined(__OpenBSD__) || defined(_AIX)'
  '';
  cmakeFlags = old.cmakeFlags ++ [
    "-DLIBCXX_INSTALL_INCLUDE_DIR=include/c++/v1"
    "-DLIBCXXABI_INSTALL_INCLUDE_DIR=include/c++/v1"
  ];
  preConfigure = (old.preConfigure or "") + ''
    # run.py clears the environment; filesystem tests need mkdir, chmod and rm.
    executor="${python3}/bin/python3 $PWD/../libcxx/utils/run.py --env PATH=$PATH"
    cmakeFlagsArray+=(
      "-DLLVM_LIT_ARGS=-sv -j$NIX_BUILD_CORES --timeout=1800"
      "-DLIBCXX_TEST_PARAMS=executor=$executor"
      "-DLIBCXXABI_TEST_PARAMS=executor=$executor"
    )
  '';
  checkPhase = ''
    runHook preCheck
    # Tests select their own hardening modes; keep the other hardening flags.
    for flagVar in "''${!NIX_HARDENING_ENABLE@}"; do
      flags=''${!flagVar}
      flags=''${flags//libcxxhardeningfast/}
      flags=''${flags//libcxxhardeningextensive/}
      export "$flagVar=$flags"
    done
    failed=0
    for target in check-cxxabi check-cxx; do
      ninja -j"$NIX_BUILD_CORES" "$target" || failed=1
    done
    test "$failed" -eq 0
    runHook postCheck
  '';
})
