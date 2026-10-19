set -euo pipefail
socket="$PWD/tmux.sock"
trap 'tmux -S "$socket" kill-server 2>/dev/null || true' EXIT
tmux -S "$socket" -f /dev/null new-session -d -s native "$BASH --noprofile --norc"
printf -v command 'printf "tmux-native-ok\\n"; tmux -S %q wait-for -S ready' "$socket"
tmux -S "$socket" send-keys -t native "$command" Enter
tmux -S "$socket" wait-for ready
tmux -S "$socket" capture-pane -p -t native | grep -Fx tmux-native-ok
tmux -S "$socket" split-window -t native "$BASH --noprofile --norc"
test "$(tmux -S "$socket" list-panes -t native | wc -l)" -eq 2
echo 'PASS tmux: private server, PTY, shell input, captured output and split panes'
