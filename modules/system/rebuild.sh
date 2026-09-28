set -euo pipefail
usage() {
    cat >&2 <<'USAGE'
Usage: openbsd-rebuild {build|dry-activate|test|switch|boot} --flake PATH#NAME
       openbsd-rebuild {dry-activate|test|switch|boot} --store-path SYSTEM
       openbsd-rebuild {switch|boot} --rollback
       openbsd-rebuild list-generations
USAGE
    exit "${1:-1}"
}
action=
mode=
reference=
while test "$#" -gt 0; do
    case "$1" in
        build|dry-activate|test|switch|boot|list-generations|list)
            test -z "$action" || usage
            action=$1
            if test "$action" = list; then action=list-generations; fi
            shift
            ;;
        --flake|--store-path)
            test -z "$mode" && test "$#" -ge 2 || usage
            mode=$1
            reference=$2
            test -n "$reference" || usage
            shift 2
            ;;
        --rollback)
            test -z "$mode" || usage
            mode=$1
            shift
            ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
if test "$action" = list-generations; then
    test -z "$mode" || usage
    exec "$generation_manager" list
fi
case "$action:$mode" in
    build:--flake|dry-activate:--flake|test:--flake|switch:--flake|boot:--flake) ;;
    dry-activate:--store-path|test:--store-path|switch:--store-path|boot:--store-path) ;;
    switch:--rollback|boot:--rollback) ;;
    *) usage ;;
esac
if test "$action" != build && test "$(id -u)" != 0; then
    echo "Run activation as root, or use 'build' to build without activating." >&2
    exit 1
fi
case "$mode" in
    --rollback)
        if test "$action" = switch; then
            exec "$generation_manager" rollback --live
        else
            exec "$generation_manager" rollback
        fi
        ;;
    --store-path) exec "$generation_manager" "$action" "$reference" ;;
esac
case "$reference" in *\#?*) ;; *) usage ;; esac
flake=${reference%#*}
name=${reference##*#}
# Restrict the attribute name rather than interpreting arbitrary Nix expressions.
[[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || usage
# Keep a GC root after building, including while activation is in progress.
nix build --out-link result-system "$flake#nixosConfigurations.$name.config.system.build.toplevel"
target=$(readlink -f result-system)
if test "$action" = build; then
    echo "$target"
else
    exec "$target/bin/switch-to-configuration" "$action"
fi
