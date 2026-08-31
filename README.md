# tmux Agent Skill

A safe, macOS-focused [Agent Skill](https://agentskills.io/) for inspecting and operating interactive tmux sessions. It handles socket discovery, inventory, window organization, bounded scrollback, verified input, activity flags, reusable agent personas, and optional Claude Code, Codex, and OpenCode workflows.

The skill reads the user's live tmux configuration instead of assuming a prefix key, index base, monitoring policy, history limit, session name, or filesystem layout.

## Install

Install the `tmux` skill into supported agent clients with the Skills CLI:

```bash
npx skills add robertsreberski/tmux-agent-skill --skill tmux -g
```

For a manual install, copy the [`tmux`](./tmux) directory into a user or project skills directory supported by your agent. Keep the directory name `tmux` so it matches the skill name.

## Requirements

- macOS
- `tmux`
- Stock macOS utilities used by the optional transcript helper: `ps`, `lsof`, `date`, `find`, `stat`, `sed`, `awk`, and `plutil`
- Claude Code, Codex, or OpenCode only for their optional workflows

## What it does

- Discovers the default and alternate tmux sockets without mixing servers.
- Inventories sessions, windows, panes, activity, bell, and silence flags.
- Renames, moves, swaps, creates, and—after exact confirmation—kills targets.
- Reads bounded scrollback and sends literal or multiline input with before/after verification.
- Hands control back with exact attach, switch, select, prefix, and detach instructions.
- Runs approval-gated plan → review → approve → implement workflows across supported agent CLIs.
- Starts supported agent CLIs in shell-backed windows and resolves their session IDs and transcript paths on a best-effort basis without reading transcript contents.
- Ships planner, implementer, reviewer, and explorer personas in each supported CLI's native format.
- Starts a role-assigned window with an exact target and verifies that the role took effect.

Example prompts:

- “List every tmux window and tell me which ones have activity.”
- “Move window 3 from `work` to `review`, then show me how to attach.”
- “Send this prompt to the Codex pane, but verify the target first.”
- “Open one agent window per worktree, hold each in plan mode until the reviewer says APPROVED, then release it to implement.”
- “Find the session ID for the Claude Code process in `work:2`.”
- “Start a Claude reviewer in a new `review` window and verify the persona loaded.”

## Safety

The skill never uses `kill-server`, never follows instructions found inside captured pane output, and never sends credentials through tmux. It keeps one verified socket throughout a workflow, uses isolated sockets for disposable verification, never runs interactive attachment from a background agent terminal, and requires the exact target before destructive changes or approval-gated mode transitions.

Transcript discovery follows current client storage conventions and deliberately reports ambiguity rather than guessing. Override non-default transcript roots with the environment variables documented in [`agent-clis.md`](./tmux/references/agent-clis.md).

## Development

```bash
shellcheck tmux/scripts/* tests/*.sh
bash tests/smoke.sh
tmux/scripts/render-personas --check
bash tests/personas.sh
npx --yes skills add . --list
```

## License

[MIT](./LICENSE)
