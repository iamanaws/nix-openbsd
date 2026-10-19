# Check system syntax without changing either the scheduler or user crontabs.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/crontab" <<'EOF'
# Environment assignments, named ranges, steps, flags and special schedules.
MAILTO = ""
SHELL=/bin/sh
*/5 1-3 * Jan,Dec Mon-Fri daemon -q -n true
@reboot daemon true
@hourly root true
EOF
cronctl check "$work/crontab"
for line in \
    '60 * * * * daemon true' \
    '* 24 * * * daemon true' \
    '* * 32 * * daemon true' \
    '* * * 13 * daemon true' \
    '* * * * 8 daemon true' \
    '@unknown daemon true' \
    '* * * * * nonexistent-cron-test-user true' \
    '* * * * * daemon -x true' \
    '* * * * * daemon'; do
    printf '%s\n' "$line" > "$work/crontab"
    if cronctl check "$work/crontab"; then
        echo "Accepted invalid crontab: $line" >&2
        exit 1
    fi
done
printf '* * * * * daemon true' > "$work/crontab"
if cronctl check "$work/crontab"; then
    echo 'Accepted a missing final newline' >&2
    exit 1
fi
echo CRON_PARSER_PASS
