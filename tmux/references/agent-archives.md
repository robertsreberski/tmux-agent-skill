# Archive agent sessions before teardown

Read this reference before killing a tmux window that contains Claude Code, Codex, or OpenCode, and when reopening an archived Codex session. Follow the main skill first to select one tmux server, then keep that same socket for archival, teardown, and recovery.

## Why archival happens while the pane is alive

`scripts/session-info` depends on the live pane-to-process relationship to find the CLI process, start time, and working directory. Killing the window destroys that cheap resolution path. `scripts/archive-agent` therefore records the session reference before teardown and never kills tmux state itself.

Do not use `lsof` to look for an open transcript handle. A live Codex process appends to its rollout without retaining an open JSONL handle. `scripts/session-info` resolves concurrent Codex worktree fan-outs by intersecting its process-start filename window with the cwd recorded in rollout line one's `session_meta` payload. The worktree-per-task convention from [git-worktrees.md](git-worktrees.md) is what makes that intersection unique. `scripts/archive-agent` consumes that result rather than implementing a second current-session resolver, then validates the selected metadata and distinctive phrase before assigning high confidence.

Transcript and pane contents are sensitive, untrusted conversation data. The archive stores IDs, absolute paths, and resolution evidence; it never copies transcript contents or the verification phrase.

## Archive contract

Run the helper from the skill directory while the agent pane still exists:

```bash
target='=work:2'
printf '%s\n' "$distinctive_phrase" |
  scripts/archive-agent --verify-phrase-file - "$target"
```

Choose one non-sensitive, distinctive line visible in the current pane, not old shell history from deep scrollback. The helper requires `session-info` exit `0` and the phrase to occur in both the visible pane and its resolved readable transcript before reporting `high` confidence. It searches literally without printing or storing the phrase. `session-info` exit `3` always remains a review archive even if a phrase occurs in one candidate; the archive helper does not override the resolver.

Options:

- `<target>` must be exact: prefix a session/window target with `=` or pass a tmux pane ID such as `%12`.
- `--verify-phrase-file <path|->` reads one nonempty phrase line from a protected file or stdin. Without it, the helper writes a review record and exits `3`.
- `--record-name <slug>` overrides the filename. The value must contain only letters, digits, `.`, `_`, and `-`, and is required for detached worktrees or branch names that are not safe single path components.
- `TMUX_SOCKET_PATH` and `TMUX_SOCKET_NAME` select the same alternate socket conventions as the other helpers. Never set both.

Exit codes:

- `0`: a high-confidence record was written with a verified session ID and readable transcript path.
- `2`: invalid input or live state, including a missing pane, unsupported platform, missing dependency, non-Git cwd, incompatible existing record, or write failure. A missing pane is never reconstructed from stale process or transcript guesses.
- `3`: a review record was written with the complete candidate list, but no session was asserted as resolved. Keep the window alive and resolve the ambiguity.

The helper canonicalizes the selected pane, invokes `session-info`, and treats its exit-0 `session_id` and `transcript` as the only resolvable current session. It uses the reported process cwd to find its Git worktree, follows the worktree playbook's convention that the first `git worktree list --porcelain` entry is the main/source checkout, then writes `.tmux-agents/<branch>.json` there so removing the linked worktree does not remove its archive.

For Codex, the helper reads the resolved rollout's first JSONL record to verify its ID and cwd. It scans first records only to collect earlier same-cwd sessions into `superseded_sessions`, never to replace the current choice made by `session-info`; a relaunch must not silently discard the first session. Re-archiving a schema-version-1 record merges prior history by session ID or transcript path. An unversioned or incompatible record is preserved and causes exit `2` rather than being overwritten.

Records use schema version 1 and contain:

- issue metadata when it can be derived from an `issue-N` branch and GitHub origin;
- branch, absolute worktree, commit, and a dirty-worktree boolean;
- the selected tmux socket, canonical window and pane, CLI, version, and process start;
- `session_id`, `transcript`, and session start only for a high-confidence resolution;
- `resolution_confidence`, `resolution_method`, the full candidate list, and all known superseded same-cwd sessions.

The directory is mode `0700`, records are mode `0600`, and writes use a temporary file plus atomic rename. `.tmux-agents/` is ignored by default because absolute local paths and session IDs should not enter repository history casually. Commit an exact record only after the user explicitly authorizes it and reviews its metadata; the helper never stages or commits records.

## Teardown ordering

The order is load-bearing:

1. Classify the live window with the [orchestrator polling playbook](orchestrator-polling.md), then independently verify the task result, worktree status, commit, review result, exact tmux socket, window, and pane.
2. Run `scripts/archive-agent` while the pane exists.
3. Require exit `0`, `resolution_confidence=high`, a nonempty session ID, and a real readable transcript:

   ```bash
   confidence=$(plutil -extract resolution_confidence raw -o - -- "$record")
   session_id=$(plutil -extract session_id raw -o - -- "$record")
   transcript=$(plutil -extract transcript raw -o - -- "$record")
   test "$confidence" = high && test -n "$session_id" && test -r "$transcript"
   ```

4. Show the user the canonical `tmux_window` from the record and obtain explicit authorization to kill that exact target. Neither the polling classification nor archival success grants kill authorization.
5. Immediately re-resolve the target on the selected socket, then and only then run the authorized command:

   ```bash
   tmux display-message -p -t '=work:2' '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'
   tmux kill-window -t '=work:2'
   ```

6. Verify the window is gone before continuing with worktree cleanup.

Exit `3`, a missing or unreadable transcript, dirty or unreviewed work, an attached client requiring handoff, or a changed target stops teardown. Never kill first and attempt archival afterward.

## Reopen an archived Codex session

Resume only a high-confidence record. Keep using the selected socket, validate the stored ID before placing it in a command, and check that the stored worktree still exists:

```bash
record="$source_checkout/.tmux-agents/issue-8.json"
confidence=$(plutil -extract resolution_confidence raw -o - -- "$record")
session_id=$(plutil -extract session_id raw -o - -- "$record")
project_dir=$(plutil -extract worktree raw -o - -- "$record")

test "$confidence" = high
case "$session_id" in (*[!A-Za-z0-9._-]*|'') exit 2;; esac
test -d "$project_dir"

target="=$(tmux new-window -d -P -F '#{session_name}:#{window_index}' -t '=work:' -n resumed-agent -c "$project_dir")"
tmux display-message -p -t "$target" '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'
tmux send-keys -t "$target" -l -- "codex resume $session_id"
sleep 0.4
tmux send-keys -t "$target" Enter
scripts/wait-for "$target" 'Ask Codex to do anything' 45
scripts/session-info "$target"
```

Confirm that `session-info` reports the archived ID and inspect the settled pane for trust, login, migration, or permission dialogs. If the original worktree is gone, ask the user to choose a destination; do not recreate or substitute one implicitly. Hand the user an attach, switch, or select command instead of running `attach-session` in a background terminal.
