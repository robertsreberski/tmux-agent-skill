#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wait_for="$repo_root/tmux/scripts/wait-for"
session_info="$repo_root/tmux/scripts/session-info"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-skill-test.XXXXXX")
socket_path="$test_root/tmux.sock"

cleanup() {
  tmux -S "$socket_path" kill-server >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "smoke: $*" >&2
  exit 1
}

expect_exit() {
  expected=$1
  shift
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  [[ $actual -eq $expected ]] || fail "expected exit $expected, got $actual: $*"
}

tmux -S "$socket_path" new-session -d -s smoke -n shell
shell_target=$(tmux -S "$socket_path" display-message -p -t '=smoke:' '#{session_name}:#{window_index}')
tmux -S "$socket_path" send-keys -t "$shell_target" -l -- "printf '%s\\n' TMUX_SKILL_READY"
tmux -S "$socket_path" send-keys -t "$shell_target" Enter

TMUX_SOCKET_PATH="$socket_path" "$wait_for" "$shell_target" TMUX_SKILL_READY 5 0.1
expect_exit 1 env TMUX_SOCKET_PATH="$socket_path" "$wait_for" "$shell_target" NEVER_PRESENT 0 0.1
expect_exit 2 env TMUX_SOCKET_PATH="$socket_path" "$wait_for" '=missing:99' anything 0 0.1
expect_exit 2 env TMUX_SOCKET_PATH="$socket_path" TMUX_SOCKET_NAME=conflict "$wait_for" "$shell_target" anything
expect_exit 2 env TMUX_SOCKET_PATH="$socket_path" "$session_info" "$shell_target"

mkdir -p "$test_root/project" "$test_root/codex-sessions/2026/08/31"
fake_codex="$test_root/codex"
printf '#!/bin/bash\nsleep 60\n' >"$fake_codex"
chmod +x "$fake_codex"
agent_target=$(tmux -S "$socket_path" new-window -d -P -F '#{session_name}:#{window_index}' -t '=smoke:' -n codex -c "$test_root/project" "$fake_codex")
sleep 1
session_id=00000000-0000-4000-8000-000000000001
stamp=$(date +%Y-%m-%dT%H-%M-%S)
touch "$test_root/codex-sessions/2026/08/31/rollout-$stamp-$session_id.jsonl"

result=$(TMUX_SOCKET_PATH="$socket_path" TMUX_SKILL_CODEX_SESSIONS_DIR="$test_root/codex-sessions" "$session_info" "$agent_target")
printf '%s\n' "$result" | grep -q '^cli=codex$' || fail "session-info did not detect fake Codex process"
printf '%s\n' "$result" | grep -q "^session_id=$session_id$" || fail "session-info did not resolve fixture session id"
printf '%s\n' "$result" | grep -q '^transcript=' || fail "session-info did not report transcript path"

echo "smoke: ok"
