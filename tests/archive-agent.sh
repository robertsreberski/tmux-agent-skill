#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
archive_agent="$repo_root/tmux/scripts/archive-agent"
session_info="$repo_root/tmux/scripts/session-info"
test_root=$(mktemp -d /tmp/tmux-archive-agent-test.XXXXXX)
test_root=$(cd "$test_root" && pwd -P)
socket_root="$test_root/socket"
socket_name="archive-agent-$$"
main_repo="$test_root/repo"
worktree="$test_root/worktree"
sessions_root="$test_root/codex-sessions"
fake_codex="$test_root/codex"
session_name=archive-agent-test

cleanup() {
  TMUX_TMPDIR="$socket_root" tmux -L "$socket_name" kill-session -t "=$session_name" >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "archive-agent-test: $*" >&2
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

field() {
  key=$1
  file=$2
  plutil -extract "$key" raw -o - -- "$file"
}

write_rollout() {
  file=$1
  session_id=$2
  cwd=$3
  started=$4
  body=$5
  printf '{"timestamp":"%s","type":"session_meta","payload":{"id":"%s","session_id":"%s","cwd":"%s","timestamp":"%s","cli_version":"0.151.0"}}\n' \
    "$started" "$session_id" "$session_id" "$cwd" "$started" > "$file"
  printf '{"type":"response_item","payload":{"content":"%s"}}\n' "$body" >> "$file"
}

mkdir -p "$socket_root" "$sessions_root/2026/08/31"
git init -q -b main "$main_repo"
git -C "$main_repo" config user.name 'Archive Test'
git -C "$main_repo" config user.email archive-test@example.invalid
git -C "$main_repo" remote add origin git@github.com:example/archive-test.git
printf '.tmux-agents/\n' > "$main_repo/.gitignore"
printf 'fixture\n' > "$main_repo/fixture.txt"
git -C "$main_repo" add .gitignore fixture.txt
git -C "$main_repo" commit -q -m 'fixture'
git -C "$main_repo" worktree add -q -b issue-8 "$worktree"

# shellcheck disable=SC2016 # The generated fixture expands these variables at runtime.
printf '#!/bin/bash\nif [[ ${1:-} == resume ]]; then printf "%%s\\n" "RESUMED_${2:-missing}"; else printf "%%s\\n" "${1:-NO_MARKER}"; fi\nsleep 60\n' > "$fake_codex"
chmod +x "$fake_codex"

old_id=00000000-0000-4000-8000-000000000001
first_id=00000000-0000-4000-8000-000000000002
second_id=00000000-0000-4000-8000-000000000003
marker_one=TMUX_ARCHIVE_DISTINCTIVE_ONE_$$
marker_two=TMUX_ARCHIVE_DISTINCTIVE_TWO_$$
sensitive_body=UNTRUSTED_TRANSCRIPT_BODY_$$

old_file="$sessions_root/2026/08/31/rollout-2026-08-31T10-00-00-$old_id.jsonl"
write_rollout "$old_file" "$old_id" "$worktree" '2026-08-31T08:00:00.000Z' 'older session'
sleep 1

TMUX_TMPDIR="$socket_root" tmux -L "$socket_name" new-session -d -s "$session_name" -n control -c "$main_repo"
agent_target=$(TMUX_TMPDIR="$socket_root" tmux -L "$socket_name" new-window -d -P -F '#{session_name}:#{window_index}' -t "=$session_name:" -n agent -c "$worktree" "$fake_codex" "$marker_one")
exact_agent_target="=$agent_target"
sleep 1

stamp=$(date +%Y-%m-%dT%H-%M-%S)
first_file="$sessions_root/2026/08/31/rollout-$stamp-$first_id.jsonl"
write_rollout "$first_file" "$first_id" "$worktree" '2026-08-31T08:00:02.000Z' "$marker_one $sensitive_body"
for number in 4 5 6 7 8 9; do
  candidate_id="00000000-0000-4000-8000-00000000000$number"
  candidate_file="$sessions_root/2026/08/31/rollout-$stamp-$candidate_id.jsonl"
  write_rollout "$candidate_file" "$candidate_id" "$test_root/other-$number" "2026-08-31T08:00:0$number.000Z" "other candidate $number"
done

fanout_result=$(TMUX_TMPDIR="$socket_root" TMUX_SOCKET_NAME="$socket_name" TMUX_SKILL_CODEX_SESSIONS_DIR="$sessions_root" "$session_info" "$agent_target")
printf '%s\n' "$fanout_result" | grep -q "^session_id=$first_id$" || fail "session-info did not resolve the worktree-specific fan-out session"
printf '%s\n' "$fanout_result" | grep -q '^note=matched rollout filename timestamp and working directory to process$' || fail "session-info did not use its filename/cwd resolver"

set +e
review_output=$(TMUX_TMPDIR="$socket_root" TMUX_SOCKET_NAME="$socket_name" TMUX_SKILL_CODEX_SESSIONS_DIR="$sessions_root" \
  "$archive_agent" --record-name review "$exact_agent_target" 2>&1)
review_exit=$?
set -e
[[ $review_exit -eq 3 ]] || fail "unverified archive did not exit 3: $review_output"
review_record="$main_repo/.tmux-agents/review.json"
[[ -f "$review_record" ]] || fail "review record was not written to the main worktree"
[[ $(field archive_status "$review_record") == review ]] || fail "unverified record was not marked review"
[[ $(field resolution_confidence "$review_record") == review ]] || fail "unverified confidence was not review"
grep -Eq '"session_id"[[:space:]]*:[[:space:]]*null' "$review_record" || fail "review record asserted a session ID"
grep -Eq '"transcript"[[:space:]]*:[[:space:]]*null' "$review_record" || fail "review record asserted a transcript"
review_candidate_count=$(field candidates "$review_record")
[[ $review_candidate_count -eq 1 ]] || fail "review record retained $review_candidate_count candidates instead of the session-info result"

result=$(printf '%s\n' "$marker_one" | env TMUX_TMPDIR="$socket_root" TMUX_SOCKET_NAME="$socket_name" \
  TMUX_SKILL_CODEX_SESSIONS_DIR="$sessions_root" "$archive_agent" --verify-phrase-file - "$exact_agent_target")
printf '%s\n' "$result" | grep -q '^resolution_confidence=high$' || fail "verified archive was not high confidence"
record="$main_repo/.tmux-agents/issue-8.json"
[[ -f "$record" ]] || fail "branch record was not written"
[[ $(field schema_version "$record") -eq 1 ]] || fail "schema version is not 1"
[[ $(field issue "$record") -eq 8 ]] || fail "issue number was not derived"
[[ $(field issue_url "$record") == 'https://github.com/example/archive-test/issues/8' ]] || fail "issue URL was not derived"
[[ $(field worktree "$record") == "$worktree" ]] || fail "worktree path is wrong"
[[ $(field session_id "$record") == "$first_id" ]] || fail "wrong session selected"
[[ $(field transcript "$record") == "$first_file" ]] || fail "wrong transcript selected"
[[ $(field resolution_confidence "$record") == high ]] || fail "record confidence is not high"
verified_candidate_count=$(field candidates "$record")
[[ $verified_candidate_count -eq 1 ]] || fail "verified record retained $verified_candidate_count candidates instead of the session-info result"
[[ $(field superseded_sessions "$record") -eq 1 ]] || fail "older same-cwd session was not retained"
[[ $(field superseded_sessions.0.session_id "$record") == "$old_id" ]] || fail "wrong superseded session"
[[ $(stat -f '%Lp' "$main_repo/.tmux-agents") == 700 ]] || fail "archive directory mode is not 0700"
[[ $(stat -f '%Lp' "$record") == 600 ]] || fail "archive record mode is not 0600"
grep -Fq -- "$marker_one" "$record" && fail "verification phrase leaked into record"
grep -Fq -- "$sensitive_body" "$record" && fail "transcript contents leaked into record"
git -C "$main_repo" check-ignore -q .tmux-agents/issue-8.json || fail "archive directory is not ignored"

ambiguous_id=00000000-0000-4000-8000-000000000014
ambiguous_file="$sessions_root/2026/08/31/rollout-$stamp-$ambiguous_id.jsonl"
write_rollout "$ambiguous_file" "$ambiguous_id" "$worktree" '2026-08-31T08:00:02.500Z' "$marker_one"
# shellcheck disable=SC2016 # Positional parameters belong to the nested shell.
expect_exit 3 sh -c 'printf "%s\n" "$1" | env TMUX_TMPDIR="$2" TMUX_SOCKET_NAME="$3" TMUX_SKILL_CODEX_SESSIONS_DIR="$4" "$5" --verify-phrase-file - --record-name duplicate "$6"' \
  sh "$marker_one" "$socket_root" "$socket_name" "$sessions_root" "$archive_agent" "$exact_agent_target"
[[ $(field resolution_confidence "$main_repo/.tmux-agents/duplicate.json") == review ]] || fail "duplicate phrase was not marked review"
[[ $(field candidates "$main_repo/.tmux-agents/duplicate.json") -eq 2 ]] || fail "ambiguous session-info candidates were not retained"
rm -f "$ambiguous_file"

TMUX_TMPDIR="$socket_root" tmux -L "$socket_name" kill-window -t "=$agent_target"
expect_exit 2 env TMUX_TMPDIR="$socket_root" TMUX_SOCKET_NAME="$socket_name" TMUX_SKILL_CODEX_SESSIONS_DIR="$sessions_root" \
  "$archive_agent" --record-name missing "$exact_agent_target"
[[ ! -e "$main_repo/.tmux-agents/missing.json" ]] || fail "missing pane created an archive record"

second_target=$(TMUX_TMPDIR="$socket_root" tmux -L "$socket_name" new-window -d -P -F '#{session_name}:#{window_index}' -t "=$session_name:" -n agent-2 -c "$worktree" "$fake_codex" "$marker_two")
exact_second_target="=$second_target"
sleep 1
second_stamp=$(date +%Y-%m-%dT%H-%M-%S)
second_file="$sessions_root/2026/08/31/rollout-$second_stamp-$second_id.jsonl"
write_rollout "$second_file" "$second_id" "$worktree" '2026-08-31T08:00:03.000Z' "$marker_two"

printf '%s\n' "$marker_two" | env TMUX_TMPDIR="$socket_root" TMUX_SOCKET_NAME="$socket_name" \
  TMUX_SKILL_CODEX_SESSIONS_DIR="$sessions_root" "$archive_agent" --verify-phrase-file - "$exact_second_target" >/dev/null
[[ $(field session_id "$record") == "$second_id" ]] || fail "relaunch did not replace the current session"
[[ $(field superseded_sessions "$record") -eq 2 ]] || fail "relaunch did not retain both superseded sessions"
old_ids=$(plutil -convert json -o - -- "$record" | grep -o '00000000-0000-4000-8000-00000000000[12]' | sort -u | tr '\n' ' ')
[[ "$old_ids" == "$old_id $first_id " ]] || fail "superseded session IDs are incomplete"

printf '{}\n' > "$main_repo/.tmux-agents/incompatible.json"
# shellcheck disable=SC2016 # Positional parameters belong to the nested shell.
expect_exit 2 sh -c 'printf "%s\n" "$1" | env TMUX_TMPDIR="$2" TMUX_SOCKET_NAME="$3" TMUX_SKILL_CODEX_SESSIONS_DIR="$4" "$5" --verify-phrase-file - --record-name incompatible "$6"' \
  sh "$marker_two" "$socket_root" "$socket_name" "$sessions_root" "$archive_agent" "$exact_second_target"
[[ $(plutil -convert json -o - -- "$main_repo/.tmux-agents/incompatible.json") == '{}' ]] || fail "incompatible record was overwritten"
expect_exit 2 env TMUX_TMPDIR="$socket_root" TMUX_SOCKET_NAME="$socket_name" TMUX_SKILL_CODEX_SESSIONS_DIR="$sessions_root" \
  "$archive_agent" --record-name '../unsafe' "$exact_second_target"

TMUX_TMPDIR="$socket_root" tmux -L "$socket_name" kill-window -t "=$second_target"
resume_target=$(TMUX_TMPDIR="$socket_root" tmux -L "$socket_name" new-window -d -P -F '#{session_name}:#{window_index}' -t "=$session_name:" -n resumed -c "$worktree" "$fake_codex" resume "$second_id")
sleep 1
resumed=$(TMUX_TMPDIR="$socket_root" TMUX_SOCKET_NAME="$socket_name" TMUX_SKILL_CODEX_SESSIONS_DIR="$sessions_root" "$session_info" "$resume_target")
printf '%s\n' "$resumed" | grep -q "^session_id=$second_id$" || fail "archived Codex session ID did not resume"

echo "archive-agent-test: ok"
