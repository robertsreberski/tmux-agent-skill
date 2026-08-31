#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
renderer="$repo_root/tmux/scripts/render-personas"
start_agent="$repo_root/tmux/scripts/start-agent"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/tmux-personas-test.XXXXXX")
socket_path="$test_root/tmux.sock"
fake_bin="$test_root/bin"

cleanup() {
  tmux -S "$socket_path" kill-server >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "personas: $*" >&2
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

"$renderer" --check

for role in planner implementer reviewer explorer; do
  codex_file="$repo_root/tmux/personas/codex/$role.toml"
  claude_file="$repo_root/tmux/personas/claude/$role.md"
  grep -q "^name = \"$role\"$" "$codex_file" || fail "Codex $role name is missing"
  grep -q '^description = ' "$codex_file" || fail "Codex $role description is missing"
  grep -q '^model_reasoning_effort = ' "$codex_file" || fail "Codex $role effort is missing"
  grep -q '^developer_instructions = ' "$codex_file" || fail "Codex $role instructions are missing"
  grep -q "TMUX_PERSONA_ACTIVE=$role" "$codex_file" || fail "Codex $role marker is missing"

  grep -q "^name: $role$" "$claude_file" || fail "Claude $role name is missing"
  grep -q '^description: ' "$claude_file" || fail "Claude $role description is missing"
  grep -q '^model: inherit$' "$claude_file" || fail "Claude $role model is not inherited"
  grep -q '^tools: ' "$claude_file" || fail "Claude $role tools are missing"
  grep -q "TMUX_PERSONA_ACTIVE=$role" "$claude_file" || fail "Claude $role marker is missing"
done

node - "$repo_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const roles = ["planner", "implementer", "reviewer", "explorer"];
const claude = JSON.parse(fs.readFileSync(path.join(root, "tmux/personas/claude/agents.json")));
const opencode = JSON.parse(fs.readFileSync(path.join(root, "tmux/personas/opencode/opencode.json")));
for (const role of roles) {
  if (!claude[role] || !claude[role].prompt.includes(`TMUX_PERSONA_ACTIVE=${role}`)) process.exit(1);
  if (!opencode.agent[role] || opencode.agent[role].mode !== "all") process.exit(1);
  if (!opencode.agent[role].prompt.includes(`TMUX_PERSONA_ACTIVE=${role}`)) process.exit(1);
}
for (const role of ["planner", "reviewer", "explorer"]) {
  if (opencode.agent[role].permission?.edit !== "deny") process.exit(1);
}
NODE

mkdir -p "$fake_bin" "$test_root/project"
fake_agent="$fake_bin/fake-agent"
# These single-quoted strings are the source of the generated fixture, so their
# parameter expansions must be preserved for the fixture process.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -u' \
  'cli=${0##*/}' \
  'role='"''" \
  'args=("$@")' \
  'for ((i=0; i<${#args[@]}; i++)); do' \
  '  if [[ ${args[i]} == --agent && $((i + 1)) -lt ${#args[@]} ]]; then role=${args[i + 1]}; fi' \
  '  case ${args[i]} in' \
  '    *TMUX_PERSONA_ACTIVE=planner*) role=planner ;;' \
  '    *TMUX_PERSONA_ACTIVE=implementer*) role=implementer ;;' \
  '    *TMUX_PERSONA_ACTIVE=reviewer*) role=reviewer ;;' \
  '    *TMUX_PERSONA_ACTIVE=explorer*) role=explorer ;;' \
  '  esac' \
  'done' \
  'case "$cli" in' \
  '  codex) printf "%s\n" "Ask Codex to do anything"; [[ $role == planner ]] && printf "%s\n" "Plan mode" ;;' \
  '  claude) printf "%s\n" "$role" "❯" ;;' \
  '  opencode) printf "%s\n" "$role" "tab agents" ;;' \
  'esac' \
  'while IFS= read -r line; do' \
  '  if [[ $line == *"Report your tmux persona activation marker and nothing else."* ]]; then' \
  '    printf "TMUX_PERSONA_ACTIVE=%s\n" "$role"' \
  '  fi' \
  'done' >"$fake_agent"
chmod +x "$fake_agent"
ln -s "$fake_agent" "$fake_bin/codex"
ln -s "$fake_agent" "$fake_bin/claude"
ln -s "$fake_agent" "$fake_bin/opencode"

PATH="$fake_bin:$PATH" tmux -S "$socket_path" new-session -d -s personas -n shell -c "$test_root/project"
tmux -S "$socket_path" set-option -g default-shell /bin/bash
tmux -S "$socket_path" set-environment -g PATH "$fake_bin:$PATH"

for cli in codex claude opencode; do
  for role in planner implementer reviewer explorer; do
    result=$(PATH="$fake_bin:$PATH" TMUX_SOCKET_PATH="$socket_path" "$start_agent" \
      --session personas \
      --window "$cli-$role" \
      --cwd "$test_root/project" \
      --cli "$cli" \
      --persona "$role" \
      --model test/model \
      --effort high)
    printf '%s\n' "$result" | grep -q "^persona=$role$" || fail "$cli/$role did not report its persona"
    printf '%s\n' "$result" | grep -q "^marker=TMUX_PERSONA_ACTIVE=$role$" || fail "$cli/$role did not verify its marker"
    printf '%s\n' "$result" | grep -q '^status=verified$' || fail "$cli/$role did not verify"
  done
done

expect_exit 2 env PATH="$fake_bin:$PATH" TMUX_SOCKET_PATH="$socket_path" "$start_agent" \
  --session personas --window codex-planner --cwd "$test_root/project" \
  --cli codex --persona planner --model test/model --effort high
expect_exit 2 env PATH="$fake_bin:$PATH" TMUX_SOCKET_PATH="$socket_path" TMUX_SOCKET_NAME=conflict "$start_agent" \
  --session personas --window conflict --cwd "$test_root/project" \
  --cli claude --persona planner --model test/model --effort high
expect_exit 2 env PATH="$fake_bin:$PATH" TMUX_SOCKET_PATH="$socket_path" "$start_agent" \
  --session personas --window invalid --cwd "$test_root/project" \
  --cli claude --persona invalid --model test/model --effort high

printf '%s\n' \
  '#!/bin/bash' \
  'printf "%s\n" "Do you trust the contents of this directory?" "❯"' \
  'sleep 60' >"$fake_bin/claude"
chmod +x "$fake_bin/claude"
expect_exit 3 env PATH="$fake_bin:$PATH" TMUX_SOCKET_PATH="$socket_path" "$start_agent" \
  --session personas --window blocked-dialog --cwd "$test_root/project" \
  --cli claude --persona reviewer --model test/model --effort high

echo "personas: ok"
