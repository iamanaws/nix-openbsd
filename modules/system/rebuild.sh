set -euo pipefail
usage() {
    echo 'Usage: openbsd-rebuild {build|dry-activate|test|switch|boot} --flake PATH#NAME' >&2
    exit 1
}
test "$#" = 3 && test "$2" = --flake || usage
action=$1
case "$action" in build|dry-activate|test|switch|boot) ;; *) usage ;; esac
reference=$3
case "$reference" in *\#?*) ;; *) usage ;; esac
flake=${reference%#*}
name=${reference##*#}
# Restrict the attribute name rather than interpreting arbitrary Nix expressions.
[[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || usage
if test "$action" != build && test "$(id -u)" != 0; then
    echo "Run activation as root, or use 'build' to build without activating." >&2
    exit 1
fi
# Keep a GC root after building, including while activation is in progress.
nix build --out-link result-system "$flake#nixosConfigurations.$name.config.system.build.toplevel"
target=$(readlink -f result-system)
if test "$action" = build; then
    echo "$target"
else
    exec "$target/bin/switch-to-configuration" "$action"
fi
