# Agent personas

This directory ships four reusable roles—`planner`, `implementer`, `reviewer`, and `explorer`—for Codex, Claude Code, and OpenCode. The source of truth is `source/common.md` plus the matching role file. Run `../scripts/render-personas --write` after changing source and `../scripts/render-personas --check` in verification.

For CLI discovery, launch flags, model and effort controls, permissions, startup prompts, and recovery, use `../references/agent-clis.md`; its per-CLI sections are authoritative. This file covers only the persona artifacts and installation boundary.

Generated artifacts:

- `codex/*.toml`: native Codex subagent definitions for `~/.codex/agents/`.
- `claude/*.md`: native Claude Code agent definitions for `~/.claude/agents/`.
- `claude/agents.json`: the same Claude definitions in the session-scoped `--agents` form.
- `opencode/opencode.json`: an OpenCode configuration layer containing all four agents.

Inspect existing destination files before installing persistent copies. Do not overwrite a user-authored persona with the same name. The bundled `scripts/start-agent` path uses the session bundles directly and does not need to modify the user's CLI configuration.

For persistent Codex or Claude Code discovery, copy only absent files after reviewing them:

```bash
mkdir -p "$HOME/.codex/agents" "$HOME/.claude/agents"
for source in /path/to/tmux/personas/codex/*.toml; do
  destination="$HOME/.codex/agents/${source##*/}"
  [[ ! -e "$destination" ]] || { echo "refusing to overwrite $destination" >&2; continue; }
  cp "$source" "$destination"
done
for source in /path/to/tmux/personas/claude/*.md; do
  destination="$HOME/.claude/agents/${source##*/}"
  [[ ! -e "$destination" ]] || { echo "refusing to overwrite $destination" >&2; continue; }
  cp "$source" "$destination"
done
```

OpenCode can consume the canonical bundle without modifying global configuration:

```bash
OPENCODE_CONFIG=/path/to/tmux/personas/opencode/opencode.json opencode agent list
```

`opencode agent create` remains the native interactive path for creating additional user- or project-scoped agents. The committed bundle is deterministic output from the canonical sources, so do not regenerate these four roles interactively. The launch-time `--agent NAME` path and activation verification are documented in `../references/agent-clis.md`.

## Codex activation boundary

Codex discovers the generated TOML files as named subagents, but Codex 0.151.0 has no flag that selects one as the root persona at launch. The launcher therefore labels its root-session path `codex-adapter` and injects the same canonical text as developer instructions.

This is not equivalent to `claude --agent NAME` or `opencode --agent NAME`. For the planner adapter, follow the authoritative Codex plan workflow in `../references/agent-clis.md`; its launch sequence, effort override, status check, and trust boundary are not repeated here. Persona activation never substitutes for plan-mode verification.

## OpenCode built-ins

OpenCode already ships `build` and `plan` as primary agents and `general` and `explore` as subagents. The bundled names are deliberately distinct: `implementer`, `planner`, `reviewer`, and `explorer`. They use `mode: all` so each canonical role can be selected as a session's primary agent or invoked as a subagent without replacing the built-ins.
