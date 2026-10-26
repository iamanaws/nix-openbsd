set -euo pipefail

test "$EUID" -eq 0
native_nix=$1
package_test=$2
export NATIVE_NIX_BIN="$native_nix/bin"
export PATH="$NATIVE_NIX_BIN:$PATH"
work=$(mktemp -d /var/tmp/native-nix-checks.XXXXXXXX)
chmod 755 "$work"
echo "Native Nix runtime logs: $work"
cd /
daemon_pid=
cache_pid=
restore_daemon=false
cleanup() {
    if [[ -n $cache_pid ]]; then
        kill -TERM "$cache_pid" 2>/dev/null || true
        wait "$cache_pid" 2>/dev/null || true
    fi
    if [[ -n $daemon_pid ]]; then
        kill -TERM "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    if $restore_daemon; then
        env -u NIX_DAEMON_SOCKET_PATH -u NIX_REMOTE /etc/rc.d/nix_daemon start
    fi
}
trap cleanup EXIT
if /etc/rc.d/nix_daemon check; then
    restore_daemon=true
    /etc/rc.d/nix_daemon stop
fi
export NIX_DAEMON_SOCKET_PATH="$work/socket"
export NIX_REMOTE=daemon
NIX_REMOTE=local "$native_nix/bin/nix-daemon" --option cores "$NATIVE_BUILD_CORES" \
    > "$work/daemon.log" 2>&1 &
daemon_pid=$!
for ((attempt = 0; attempt < 30; attempt++)); do
    kill -0 "$daemon_pid"
    if [[ -S $NIX_DAEMON_SOCKET_PATH ]]; then break; fi
    sleep 1
done
test -S "$NIX_DAEMON_SOCKET_PATH"
nix --version
test "$(nix-instantiate --eval --expr builtins.currentSystem)" = '"x86_64-openbsd"'
nix-store --query --requisites "$native_nix" > "$work/closure"
nix-store --verify-path "$native_nix"
export NATIVE_NIX_CLOSURE="$work/closure"
nix-instantiate --eval --strict --expr '
    let
      env = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile (builtins.getEnv "NATIVE_ENVIRONMENT")));
      closure = builtins.filter builtins.isString
        (builtins.split "\n" (builtins.readFile (builtins.getEnv "NATIVE_NIX_CLOSURE")));
      seeds = builtins.concatMap (p: builtins.filter
        (v: builtins.isString v && builtins.substring 0 11 v == "/nix/store/")
        (builtins.attrValues p))
        (builtins.attrValues env.bootstrap);
    in assert builtins.all (p: !(builtins.elem p closure)) seeds; true
'
echo 'Native Nix closure contains no declared bootstrap outputs'
"$package_test" --client root
su -m bestie -c "$package_test --client user"
kill -0 "$daemon_pid"
echo 'Native daemon: root and regular-user package checks passed'

# Exercise downloads and GC without deleting anything from the VM's build store.
gc_store="local?root=$work/gc"
cache_path=$(nix-instantiate --eval --strict --json --expr \
    '(builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile (builtins.getEnv "NATIVE_ENVIRONMENT")))).bootstrap.gnused.path' | tr -d '"')
# Test unpublished releases without requiring their seed tools on Cachix.
nix-store --generate-binary-cache-key native-test-1 "$work/cache.sec" "$work/cache.pub"
nix --extra-experimental-features nix-command copy \
    --to "file://$work/cache?secret-key=$work/cache.sec" "$cache_path"
test_python=$(nix-build "$NATIVE_RECIPE" --no-out-link -A testPython \
    --argstr environment "$NATIVE_ENVIRONMENT" \
    --argstr packageSetSource "$NATIVE_PACKAGES" \
    --argstr consumerSource "$NATIVE_CONSUMER" --argstr nonce cache \
    --max-jobs 1 --cores "$NATIVE_BUILD_CORES")
"$test_python/bin/python3" -B - "$work" <<'PY' > "$work/cache.log" 2>&1 &
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

work = Path(sys.argv[1])
handler = partial(SimpleHTTPRequestHandler, directory=str(work / "cache"))
with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
    (work / "cache.url").write_text(f"http://127.0.0.1:{server.server_port}")
    server.serve_forever()
PY
cache_pid=$!
for ((attempt = 0; attempt < 30; attempt++)); do
    kill -0 "$cache_pid"
    if [[ -s $work/cache.url ]]; then break; fi
    sleep 1
done
test -s "$work/cache.url"
cache_url=$(cat "$work/cache.url")
if nix --extra-experimental-features nix-command copy \
    --option trusted-public-keys '' --option substituters '' \
    --from "$cache_url" --to "$gc_store" "$cache_path" > "$work/untrusted.log" 2>&1; then
    echo 'Cache download accepted an untrusted signature' >&2
    exit 1
fi
grep -E 'signature|trusted' "$work/untrusted.log"
nix --extra-experimental-features nix-command copy \
    --option trusted-public-keys "$(cat "$work/cache.pub")" --option substituters '' \
    --from "$cache_url" --to "$gc_store" "$cache_path"
nix --extra-experimental-features nix-command store verify \
    --option trusted-public-keys "$(cat "$work/cache.pub")" --store "$gc_store" --all
printf 'keep this path\n' > "$work/keep"
printf 'collect this path\n' > "$work/garbage"
kept=$(nix-store --store "$gc_store" --add "$work/keep")
garbage=$(nix-store --store "$gc_store" --add "$work/garbage")
nix-store --store "$gc_store" --realise "$kept" --add-root "$work/gc-root"
nix-store --store "$gc_store" --gc > "$work/gc.log"
nix-store --store "$gc_store" --check-validity "$kept"
if nix-store --store "$gc_store" --check-validity "$garbage" 2>/dev/null; then
    echo 'GC retained the unrooted test path' >&2
    exit 1
fi
echo 'Native Nix: signed cache download, store verification and isolated GC passed'
echo NATIVE_NIX_RUNTIME_PASS
