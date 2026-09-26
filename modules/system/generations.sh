# Manage native OpenBSD configurations and their boot generations.
set -euo pipefail
umask 022
profile=/nix/var/nix/profiles/system
boot=/boot/nixos

die() { echo "openbsd-system: $*" >&2; exit 1; }
usage() {
    echo "Usage: openbsd-system list | {boot|test|switch|dry-activate} SYSTEM | rollback [--live] [GENERATION]" >&2
    exit 1
}
action=${1:-}
shift || usage
case "$action" in
    list) test "$#" = 0 || usage; exec nix-env --profile "$profile" --list-generations ;;
    boot|test|switch|dry-activate) test "$#" = 1 || usage ;;
    rollback) test "$#" -le 2 || usage ;;
    *) usage ;;
esac
test "$(id -u)" = 0 || die "run as root"
test -d "$boot" || die "missing $boot; this is not a native VM installation"
mkdir -p /run /nix/var/nix/profiles /nix/var/nix/gcroots
mkdir /run/openbsd-system.lock || die "another operation is running"
temporary=
transaction_roots=
old_generation=
committed=false
profile_changed=false
recording=false
record() {
    if $recording; then
        printf '%s %s: %s\n' "$(date -u +%FT%TZ)" "$action" "$*" >> /var/log/openbsd-system.log
    fi
}
cleanup() {
    status=$?
    trap - EXIT
    set +e
    if $profile_changed && ! $committed; then
        nix-env --profile "$profile" --switch-generation "$old_generation" ||
            echo "Could not restore the profile; the boot default is unchanged." >&2
    fi
    if ${live_started:-false} && ! ${live_done:-false}; then
        live_recover || status=1
    fi
    record "finished with status $status"
    if test -n "$transaction_roots"; then
        for root in "$transaction_roots"/*; do
            if test -L "$root"; then rm "$root"; fi
        done
        rmdir "$transaction_roots"
    fi
    if test -n "$temporary" && test -e "$temporary"; then rm "$temporary"; fi
    rmdir /run/openbsd-system.lock
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Adopt images made before generation management was available.
if ! test -e "$profile"; then
    case "$action" in test|dry-activate) die "boot into a managed generation first" ;; esac
    current=$(readlink -f /run/current-system)
    test -f "$current/system" || die "cannot identify the running system"
    nix-env --profile "$profile" --set "$current"
fi
old_generation=$(basename "$(readlink "$profile")")
old_generation=${old_generation#system-}
old_generation=${old_generation%-link}
case "$old_generation" in ''|*[!0-9]*) die "invalid system profile" ;; esac

rollback_live=false
if test "$action" != rollback; then
    target=$(readlink -f "$1")
else
    if test "${1:-}" = --live; then rollback_live=true; shift; fi
    test "$#" -le 1 || usage
    generation=${1:-}
    if test -z "$generation"; then
        # Roll back relative to the selected generation, not the highest retained one.
        for link in "$profile"-*-link; do
            number=${link#"$profile"-}; number=${number%-link}
            case "$number" in ''|*[!0-9]*) continue ;; esac
            if test "$number" -lt "$old_generation" && test "$number" -gt "${generation:-0}"; then
                generation=$number
            fi
        done
    fi
    case "$generation" in ''|*[!0-9]*) die "no previous generation; specify a retained generation" ;; esac
    target=$(readlink -f "$profile-$generation-link")
fi
case "$target" in /nix/store/*) ;; *) die "target must be a system in the Nix store" ;; esac
test "$(cat "$target/system")" = x86_64-openbsd || die "target is not an x86_64-openbsd system"
test -f "$target/kernel" && test -x "$target/bin/activate-init-native" || die "target is not bootable"
# A temporary running generation may have no profile link. Keep both sides alive
# while activation changes /run/current-system and while recovery is possible.
transaction_roots=$(mktemp -d /nix/var/nix/gcroots/openbsd-system.XXXXXXXX)
nix-store --add-root "$transaction_roots/current" --realise "$(readlink -f /run/current-system)" >/dev/null
nix-store --add-root "$transaction_roots/target" --realise "$target" >/dev/null
nix-store --query --requisites "$target" | xargs -r nix-store --check-validity

if test "$action" = test || test "$action" = switch || test "$action" = dry-activate || $rollback_live; then
    live_prepare
    if test "$action" = dry-activate; then exit 0; fi
fi
mkdir -p /var/log
recording=true
record "target $target; running $(readlink -f /run/current-system)"
if test "$action" = test || test "$action" = switch || $rollback_live; then
    live_apply
    if test "$action" = test; then
        live_done=true
        echo "Activated for this boot; the boot default is unchanged."
        exit 0
    fi
fi

# Protect the boot default even if profile selection is interrupted or generations are pruned.
while read -r command setting value; do
    if test "$command $setting" = 'set image'; then
        selected=${value%/kernel}
        test -f "$selected/system" || die "invalid existing boot default"
        ln -sfn "$selected" /nix/var/nix/gcroots/boot-default
    fi
done < "$boot/default.conf"

write_entry() {
    printf '# system: %s\nset tty com0\nset image %s/kernel\nset init %s/bin/activate-init-native\n' "$1" "$1" "$1"
}
# Stage boot files on the same filesystem so replacing the default is atomic.
temporary=$(mktemp "$boot/.default.XXXXXXXX")
write_entry "$target" > "$temporary"
chmod 644 "$temporary"
if test "$action" != rollback; then
    nix-env --profile "$profile" --set "$target"
else
    nix-env --profile "$profile" --switch-generation "$generation"
fi
profile_changed=true
for link in "$profile"-*-link; do
    test -e "$link" || continue
    number=${link#"$profile"-}; number=${number%-link}
    case "$number" in ''|*[!0-9]*) continue ;; esac
    entry=$(readlink -f "$link")
    write_entry "$entry" > "$boot/$number.conf"
done
sync
record "selecting boot default $target"
mv -T "$temporary" "$boot/default.conf"
committed=true
live_done=true
ln -sfn "$target" /nix/var/nix/gcroots/boot-default
sync
echo "Next boot: $target"
if test "$action" = switch || $rollback_live; then
    echo "Activated and selected for the next boot."
else
    echo "The running system is unchanged. Reboot to use the selected generation."
fi
