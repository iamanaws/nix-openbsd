#!/usr/bin/env bash

# Run through the VM console so DHCP can stop without losing the test connection.
if bash -eu <<'OPENBSD_BASE_PROBE'
    test "$(id -u)" -eq 0
    test ! -e /run/current-system/bin/switch-to-configuration
    /etc/rc.d/dhcpcd check
    /etc/rc.d/dhcpcd stop
    if /etc/rc.d/dhcpcd check; then
        echo 'dhcpcd still runs after stop' >&2
        exit 1
    fi
    if pgrep -f '^dhcpcd: \[manager\]'; then
        echo 'dhcpcd manager survived stop' >&2
        exit 1
    fi
    /etc/rc.d/dhcpcd start
    /etc/rc.d/dhcpcd check
    curl --noproxy '*' --fail --silent --show-error --retry 5 \
        --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 \
        https://nix-openbsd.cachix.org/nix-cache-info | grep -Fx 'StoreDir: /nix/store'
OPENBSD_BASE_PROBE
then
    printf '\nOPENBSD_BASE_%s\n' PASS
else
    printf '\nOPENBSD_BASE_%s\n' FAIL
fi
