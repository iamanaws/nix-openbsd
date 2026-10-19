#!/bin/sh
set -eu
: "${CXX:?Set CXX to the native C++ compiler}"
if [ "${LIBCXX_COMPILE_ONLY:-0}" != 1 ]; then
    : "${LIBCXX:?Set LIBCXX to the libc++ library output}"
fi

source=$(dirname "$0")/libcxx-headers.cc
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() {
    name=$1
    shift
    set -- "$CXX" -std="$standard" "$@" "$source"
    if [ -n "${LIBCXX_HEADERS:-}" ]; then
        set -- "$@" -nostdinc++ -isystem "$LIBCXX_HEADERS"
    fi
    if [ "${LIBCXX_COMPILE_ONLY:-0}" = 1 ]; then
        "$@" -fsyntax-only
    else
        "$@" -L"$LIBCXX/lib" -Wl,-rpath,"$LIBCXX/lib" -o "$work/probe"
        "$work/probe"
    fi
    echo "PASS $standard $order $name"
}

for standard in c++17 c++20; do
    for order in cxx-first c-first uchar-first; do
        set --
        if [ "$order" = c-first ]; then set -- -DC_HEADERS_FIRST; fi
        if [ "$order" = uchar-first ]; then set -- -DUCHAR_HEADER_FIRST; fi
        check default "$@"
        for level in 500 600 700; do
            check "xopen-$level" "$@" -D_XOPEN_SOURCE="$level" -DEXPECT_XOPEN_SOURCE="$level"
        done
        for level in 200112L 200809L; do
            check "posix-$level" "$@" -D_POSIX_C_SOURCE="$level" -DEXPECT_POSIX_C_SOURCE="$level"
        done
        check modules "$@" -fmodules -fcxx-modules -fimplicit-module-maps \
            -fmodules-cache-path="$work/modules-$standard-$order"
    done
done
