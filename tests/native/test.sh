set -euo pipefail

if [[ ${1:-} == --cxx ]]; then
    export NIX_REMOTE=daemon
    exec nix-build "$NATIVE_RECIPE" -A cxxChecks \
        --argstr environment "$NATIVE_ENVIRONMENT" \
        --argstr packageSetSource "$NATIVE_PACKAGES" \
        --argstr consumerSource "$NATIVE_CONSUMER" \
        --argstr nonce upstream-cxx \
        --no-out-link --keep-failed --max-jobs 1 --cores "$NATIVE_BUILD_CORES" \
        --option substituters ''
fi

if [[ ${1:-} != --client ]]; then
    test "$EUID" -eq 0
    sysctl hw.ncpuonline
    test "$(sysctl -n hw.ncpuonline)" -eq "$NATIVE_BUILD_CORES"
    cd /
    "$0" --client root
    su -m bestie -c "$0 --client user"
    echo 'OpenBSD native package tests passed'
    exit
fi

export NIX_REMOTE=daemon
mode=$2
if [[ $mode == root ]]; then
    test "$EUID" -eq 0
else
    test "$EUID" -ne 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
nonce="$mode-$(date +%s)-$$"
args=(
    --argstr environment "$NATIVE_ENVIRONMENT"
    --argstr packageSetSource "$NATIVE_PACKAGES"
    --argstr consumerSource "$NATIVE_CONSUMER"
    --argstr nonce "$nonce"
)
# Exercise the compiler and linker overrides used while bootstrapping libc.
nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A noLibc > "$work/no-libc.drv"
# Bootstrap source fetchers must evaluate without Linux-only dependencies.
nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A pkgs.netbsd.source.drvPath \
    --eval --strict > /dev/null
nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A libraries > "$work/libraries.drv"
libraries=$(nix-store --realise "$(cat "$work/libraries.drv")" --keep-failed --option substituters '')
for binary in dynamic static builtins tls cxx-dynamic cxx-static; do
    "$libraries/bin/$binary"
done
nix-store --verify-path "$libraries"
nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A fetched > "$work/fetched.drv"
fetched=$(nix-store --realise "$(cat "$work/fetched.drv")" --keep-failed --option substituters '')
test "$(cat "$fetched")" = "native fetchurl $nonce"
nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A testPython > "$work/python.drv"
test_python=$(nix-store --realise "$(cat "$work/python.drv")" --keep-failed --option substituters '')
"$test_python/bin/python3" -B <<'PY'
import ctypes
import os
import psutil
import zlib

callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int)(lambda value: value + 1)
assert callback(41) == 42
assert zlib.decompress(zlib.compress(b"native Python")) == b"native Python"
assert psutil.Process().pid == os.getpid()
swap = psutil.swap_memory()
assert 0 <= swap.used <= swap.total
print("native test Python checks passed")
PY

nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A smoke > "$work/smoke.drv"
smoke=$(nix-store --realise "$(cat "$work/smoke.drv")" --keep-failed --option substituters '')
"$smoke/bin/hello"
"$smoke/bin/hello-cxx"
nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A consumer > "$work/consumer.drv"
drv=$(cat "$work/consumer.drv")
consumer=$(nix-store --realise "$drv" --keep-failed --option substituters '')
library=$(nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A library.outPath --eval --strict --json \
    | tr -d '"')
for output in "$smoke" "$library" "$consumer" "$libraries"; do
    uid=$(cat "$output/build-uid")
    test "$uid" -ne 0
    test "$(id -gn "$uid")" = nixbld
done
nix-store --query --references "$consumer" | grep -Fx "$library"
nix-store --verify-path "$library" "$consumer"
"$consumer/bin/agentx-shared"
"$consumer/bin/agentx-archive"
echo "$mode daemon client: native libagentx and consumers passed"

for package in hello zlib pigz; do
    nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A "pkgs.$package" > "$work/$package.drv"
    nix-store --realise "$(cat "$work/$package.drv")" --keep-failed \
        --option substituters '' > /dev/null
    nix-instantiate "$NATIVE_RECIPE" "${args[@]}" -A "pkgs.$package.outPath" \
        --eval --strict --json | tr -d '"' > "$work/$package.out"
done
hello=$(cat "$work/hello.out")
pigz=$(cat "$work/pigz.out")
zlib=$(cat "$work/zlib.out")
test "$("$hello/bin/hello")" = 'Hello, world!'
printf 'native zlib and pigz\n' > "$work/plain"
"$pigz/bin/pigz" -c "$work/plain" > "$work/plain.gz"
"$pigz/bin/pigz" -dc "$work/plain.gz" > "$work/roundtrip"
cmp "$work/plain" "$work/roundtrip"
nix-store --query --references "$pigz" | grep -Fx "$zlib"
echo "$mode daemon client: Nixpkgs hello, zlib and pigz passed"
