# Sourced by the VM probes. Loopback peers need no public server or clock changes.
ntpd_process() {
    ps -ax -o pid=,ppid=,comm= | awk '
        $2 == 1 && $3 == "ntpd" { pid=$1; count++ }
        END { if (count != 1) exit 1; print pid }
    '
}

ntpd_check() {
    local attempt
    /etc/rc.d/ntpd check
    ntpd_process >/dev/null
    for ((attempt=0; attempt<10; attempt++)); do
        if ntpctl -s peers | grep -F "$1"; then
            ntpctl -s status
            return 0
        fi
        sleep 1
    done
    echo "ntpd did not load peer $1" >&2
    return 1
}

ntpd_stopped() {
    local attempt
    if /etc/rc.d/ntpd check; then
        echo 'ntpd is still running' >&2
        return 1
    fi
    for ((attempt=0; attempt<10; attempt++)); do
        if ! ps -ax -o comm= | grep -Eq '^[[:space:]]*ntpd$'; then
            return 0
        fi
        sleep 1
    done
    echo 'ntpd child processes survived stop' >&2
    return 1
}
