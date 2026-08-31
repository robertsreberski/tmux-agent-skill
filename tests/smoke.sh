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

expect_session_info_exit() {
  expected=$1
  shift
  set +e
  result=$("$@")
  actual=$?
  set -e
  [[ $actual -eq $expected ]] || fail "expected session-info exit $expected, got $actual"
}

assert_result_line() {
  expected=$1
  printf '%s\n' "$result" | grep -qxF -- "$expected" || fail "missing result line: $expected"
}

assert_result_has_candidate() {
  printf '%s\n' "$result" | grep -q '^candidate=' || fail "ambiguous result did not list candidates"
}

write_codex_rollout() {
  file=$1
  session_id=$2
  project_dir=$3
  printf '{"type":"session_meta","payload":{"session_id":"%s","cwd":"%s","cli_version":"fixture"}}\n' "$session_id" "$project_dir" >"$file"
}

write_opencode_session() {
  file=$1
  session_id=$2
  project_dir=$3
  printf '{"id":"%s","directory":"%s"}\n' "$session_id" "$project_dir" >"$file"
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

project_a="$test_root/project-a"
project_b="$test_root/project-b"
mkdir -p "$project_a" "$project_b"
project_a_cwd=$(cd "$project_a" && pwd -P)
project_b_cwd=$(cd "$project_b" && pwd -P)
codex_day=$(date +%Y/%m/%d)
codex_fanout_root="$test_root/codex-fanout-sessions/$codex_day"
mkdir -p "$codex_fanout_root" "$test_root/codex-a-bin" "$test_root/codex-b-bin"
fake_codex_a="$test_root/codex-a-bin/codex"
fake_codex_b="$test_root/codex-b-bin/codex"
printf '#!/bin/bash\nsleep 60\n' >"$fake_codex_a"
printf '#!/bin/bash\nsleep 60\n' >"$fake_codex_b"
chmod +x "$fake_codex_a" "$fake_codex_b"

codex_a_target=$(tmux -S "$socket_path" new-window -d -P -F '#{session_name}:#{window_index}' -t '=smoke:' -n codex-a -c "$project_a" "$fake_codex_a")
codex_b_target=$(tmux -S "$socket_path" new-window -d -P -F '#{session_name}:#{window_index}' -t '=smoke:' -n codex-b -c "$project_b" "$fake_codex_b")
sleep 1
codex_stamp=$(date +%Y-%m-%dT%H-%M-%S)
codex_stale_stamp=$(date -v-5M +%Y-%m-%dT%H-%M-%S)
codex_a_id=00000000-0000-4000-8000-000000000010
codex_b_id=00000000-0000-4000-8000-000000000011
codex_stale_id=00000000-0000-4000-8000-000000000012
codex_ambiguous_id=00000000-0000-4000-8000-000000000013
write_codex_rollout "$codex_fanout_root/rollout-$codex_stamp-$codex_a_id.jsonl" "$codex_a_id" "$project_a_cwd"
write_codex_rollout "$codex_fanout_root/rollout-$codex_stamp-$codex_b_id.jsonl" "$codex_b_id" "$project_b_cwd"
write_codex_rollout "$codex_fanout_root/rollout-$codex_stale_stamp-$codex_stale_id.jsonl" "$codex_stale_id" "$project_a_cwd"

expect_session_info_exit 0 env TMUX_SOCKET_PATH="$socket_path" TMUX_SKILL_CODEX_SESSIONS_DIR="$test_root/codex-fanout-sessions" "$session_info" "$codex_a_target"
assert_result_line 'cli=codex'
assert_result_line "session_id=$codex_a_id"
assert_result_line 'note=matched rollout filename timestamp and working directory to process'
codex_a_result=$result

expect_session_info_exit 0 env TMUX_SOCKET_PATH="$socket_path" TMUX_SKILL_CODEX_SESSIONS_DIR="$test_root/codex-fanout-sessions" "$session_info" "$codex_b_target"
assert_result_line 'cli=codex'
assert_result_line "session_id=$codex_b_id"
assert_result_line 'note=matched rollout filename timestamp and working directory to process'
codex_b_result=$result
[[ "$codex_a_result" != "$codex_b_result" ]] || fail "Codex fan-out windows resolved the same session"

write_codex_rollout "$codex_fanout_root/rollout-$codex_stamp-$codex_ambiguous_id.jsonl" "$codex_ambiguous_id" "$project_a_cwd"
expect_session_info_exit 3 env TMUX_SOCKET_PATH="$socket_path" TMUX_SKILL_CODEX_SESSIONS_DIR="$test_root/codex-fanout-sessions" "$session_info" "$codex_a_target"
assert_result_has_candidate

mkdir -p "$test_root/opencode-fanout-sessions/global" "$test_root/opencode-a-bin" "$test_root/opencode-b-bin"
fake_opencode_a="$test_root/opencode-a-bin/opencode"
fake_opencode_b="$test_root/opencode-b-bin/opencode"
printf '#!/bin/bash\nsleep 60\n' >"$fake_opencode_a"
printf '#!/bin/bash\nsleep 60\n' >"$fake_opencode_b"
chmod +x "$fake_opencode_a" "$fake_opencode_b"

opencode_a_target=$(tmux -S "$socket_path" new-window -d -P -F '#{session_name}:#{window_index}' -t '=smoke:' -n opencode-a -c "$project_a" "$fake_opencode_a")
opencode_b_target=$(tmux -S "$socket_path" new-window -d -P -F '#{session_name}:#{window_index}' -t '=smoke:' -n opencode-b -c "$project_b" "$fake_opencode_b")
sleep 1
opencode_a_id=ses_fixture_a
opencode_b_id=ses_fixture_b
opencode_ambiguous_id=ses_fixture_ambiguous
write_opencode_session "$test_root/opencode-fanout-sessions/global/$opencode_a_id.json" "$opencode_a_id" "$project_a_cwd"
write_opencode_session "$test_root/opencode-fanout-sessions/global/$opencode_b_id.json" "$opencode_b_id" "$project_b_cwd"

expect_session_info_exit 0 env TMUX_SOCKET_PATH="$socket_path" TMUX_SKILL_OPENCODE_SESSIONS_DIR="$test_root/opencode-fanout-sessions" "$session_info" "$opencode_a_target"
assert_result_line 'cli=opencode'
assert_result_line "session_id=$opencode_a_id"
assert_result_line 'note=matched OpenCode session working directory to process'
opencode_a_result=$result

expect_session_info_exit 0 env TMUX_SOCKET_PATH="$socket_path" TMUX_SKILL_OPENCODE_SESSIONS_DIR="$test_root/opencode-fanout-sessions" "$session_info" "$opencode_b_target"
assert_result_line 'cli=opencode'
assert_result_line "session_id=$opencode_b_id"
assert_result_line 'note=matched OpenCode session working directory to process'
opencode_b_result=$result
[[ "$opencode_a_result" != "$opencode_b_result" ]] || fail "OpenCode fan-out windows resolved the same session"

write_opencode_session "$test_root/opencode-fanout-sessions/global/$opencode_ambiguous_id.json" "$opencode_ambiguous_id" "$project_a_cwd"
expect_session_info_exit 3 env TMUX_SOCKET_PATH="$socket_path" TMUX_SKILL_OPENCODE_SESSIONS_DIR="$test_root/opencode-fanout-sessions" "$session_info" "$opencode_a_target"
assert_result_has_candidate

echo "smoke: ok"
