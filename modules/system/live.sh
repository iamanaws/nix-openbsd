# Sourced by openbsd-system; no changes happen until live_apply is called.
live_started=false
live_done=false
live_activated=false
declare -a live_changed=() live_was_running=() live_start=()

live_prepare() {
    old=$(readlink -f /run/current-system)
    old_meta=$old/openbsd-system.json
    new_meta=$target/openbsd-system.json
    test -f "$old_meta" && test -f "$new_meta" || die "boot into a generation with live-switch support first"
    test "$(readlink -f "$old/kernel")" = "$(readlink -f "$target/kernel")" || die "kernel changes require boot and reboot"
    test "$(readlink -f "$old/init")" = "$(readlink -f "$target/init")" || die "init changes require boot and reboot"
    jq -e -s '.[0].version == 1 and .[1].version == 1 and .[0].boot == .[1].boot' "$old_meta" "$new_meta" >/dev/null ||
        die "boot or network settings changed; use boot and reboot"
    # Compare configuration dependencies as well as the generated rc scripts.
    mapfile -t live_changed < <(jq -r -s '
      .[0] as $a | .[1] as $b | ($a.services + $b.services) | keys[] as $name |
      select($a.services[$name] != $b.services[$name] or
        any((($a.services[$name].files // []) + ($b.services[$name].files // []))[];
          . as $file | $a.etc[$file] != $b.etc[$file])) | $name
    ' "$old_meta" "$new_meta")
    for name in "${live_changed[@]}"; do
        jq -e -s --arg name "$name" 'all(.[]; .services[$name] == null or .services[$name].live)' "$old_meta" "$new_meta" >/dev/null ||
            die "$name cannot be switched live yet; use boot and reboot"
    done
    # Reject configuration changes for which no live handler exists.
    while IFS= read -r file; do
        case "$file" in profile|bashrc|shells|set-environment|terminfo|rc.conf|rc.order) continue ;; esac
        if [[ "$file" == rc.d/* ]]; then
            name=${file#rc.d/}
            [[ " ${live_changed[*]} " == *" $name "* ]] && continue
        fi
        jq -e -s --arg file "$file" 'any(.[] | .services[]; .live and (.files | index($file)) != null)' "$old_meta" "$new_meta" >/dev/null ||
            die "/etc/$file has no live update handler; use boot and reboot"
    done < <(jq -r -s '.[0].etc as $a | .[1].etc as $b | ($a + $b) | keys[] | select($a[.] != $b[.])' "$old_meta" "$new_meta")
    for name in "${live_changed[@]}"; do
        check=$(jq -r --arg name "$name" '.services[$name].check // ""' "$new_meta")
        if test -n "$check"; then
            export target
            bash -euc "$check" || die "$name configuration check failed"
        fi
        if test -x "$old/etc/rc.d/$name" && "$old/etc/rc.d/$name" check >/dev/null 2>&1; then
            live_was_running+=("$name")
        fi
        if test -x "$target/etc/rc.d/$name"; then
            # New services start; previously stopped services stay stopped.
            if ! test -x "$old/etc/rc.d/$name" || [[ " ${live_was_running[*]} " == *" $name "* ]]; then
                live_start+=("$name")
            fi
        fi
        echo "Update service: $name"
    done
    echo "Activate: $target"
}

service_order() {
    for phase in "$1"/etc/rc.order/*; do
        while read -r command name; do
            test "$command" != start_daemon || echo "$name"
        done < "$phase"
    done
}

live_apply() {
    live_started=true
    record "stopping changed services"
    mapfile -t order < <(service_order "$old")
    for ((i=${#order[@]}-1; i>=0; i--)); do
        name=${order[i]}
        if [[ " ${live_was_running[*]} " == *" $name "* ]]; then
            "$old/etc/rc.d/$name" stop || return $?
            if "$old/etc/rc.d/$name" check >/dev/null 2>&1; then
                echo "$name did not stop" >&2
                return 1
            fi
        fi
    done
    live_activated=true
    record "activating $target"
    NIXOS_ACTION=$action "$target/activate" || return $?
    while IFS= read -r name; do
        if [[ " ${live_start[*]} " == *" $name "* ]]; then
            "$target/etc/rc.d/$name" start || return $?
            "$target/etc/rc.d/$name" check || return $?
        fi
    done < <(service_order "$target")
}

live_recover() {
    local failed=0 name
    record "recovering $old"
    echo "Restoring running configuration: $old" >&2
    if $live_activated; then
        mapfile -t order < <(service_order "$target")
        for ((i=${#order[@]}-1; i>=0; i--)); do
            name=${order[i]}
            if [[ " ${live_start[*]} " == *" $name "* ]]; then
                "$target/etc/rc.d/$name" stop || failed=1
            fi
        done
        NIXOS_ACTION=rollback "$old/activate" || failed=1
    fi
    while IFS= read -r name; do
        if [[ " ${live_was_running[*]} " == *" $name "* ]]; then
            "$old/etc/rc.d/$name" start || failed=1
            "$old/etc/rc.d/$name" check || failed=1
        fi
    done < <(service_order "$old")
    if test "$failed" != 0; then
        echo "Recovery incomplete. Check services from the console; the previous boot remains available." >&2
    fi
    return "$failed"
}
