# Git worktrees with tmux

Read this reference when the user asks to create, inspect, operate, verify, or remove a Git worktree alongside a tmux session. Follow the main skill first to select exactly one tmux server. Keep using that server for the entire workflow.

## Model and defaults

Treat a worktree, its checked-out branch, and one tmux session as a paired unit:

- The worktree provides the filesystem checkout.
- The branch identifies the line of work. Git normally permits a local branch to be checked out in only one worktree.
- The tmux session hosts windows for roles such as `shell`, `agent`, and `test`. Every window in the pair should start in the worktree directory.

This is a convention, not an invariant enforced by tmux. A moved window or a shell `cd` can break the relationship, so verify Git registration and pane paths instead of trusting names.

Use the main worktree as the source checkout unless the user explicitly names another checkout. From any checkout in the repository, inspect the first `worktree` record to find the main worktree:

```bash
current_checkout=$(git rev-parse --show-toplevel)
git -C "$current_checkout" worktree list --porcelain
```

Set `source_checkout` to the absolute path in that first record. If the user names a source checkout, canonicalize it instead:

```bash
source_checkout=$(git -C "$named_checkout" rev-parse --show-toplevel)
```

If there is no unique non-bare source checkout, ask the user which checkout to use. Do not infer one from similarly named directories.

Choose a short task slug such as `issue-3` for `worktree_name` and `session_name`. Restrict the shared slug to letters, digits, `_`, and `-` so it is one safe path component and an unambiguous tmux target. Preserve the user's exact branch name separately. If a branch such as `feature/search` cannot be used directly as the shared slug, ask the user for a slug rather than silently flattening it.

Unless the user or repository specifies another layout, derive the sibling worktree root by appending `-worktrees` to the source checkout path:

```bash
worktree_root="${source_checkout}-worktrees"
worktree_path="$worktree_root/$worktree_name"
```

For example, source checkout `/srv/project` and name `issue-3` produce `/srv/project-worktrees/issue-3`.

Ask the user to choose a destination instead of applying this default when:

- the user or repository already follows a different worktree layout;
- the source checkout is ambiguous or bare;
- the derived root is a non-directory, a symlink, not safely attributable to this repository, or cannot be created;
- the target path already exists, including an empty directory or broken symlink;
- Git already registers the target or a stale worktree at that path; or
- the requested name is not a safe single path component.

An existing derived root may safely contain other registered worktrees for the same repository. Its existence alone is not a collision; inspect the exact child target and Git's worktree inventory.

## Inspect and name

Perform read-only discovery before creating anything:

```bash
git -C "$source_checkout" status --short --branch
git -C "$source_checkout" worktree list --porcelain
git -C "$source_checkout" branch --list
git -C "$source_checkout" rev-parse --verify "$start_point^{commit}"
git check-ref-format --branch "$branch"
test ! -e "$worktree_path" && test ! -L "$worktree_path"
tmux list-sessions -F '#{session_name} attached=#{session_attached} windows=#{session_windows}'
tmux has-session -t "=$session_name"
```

`tmux has-session` returning nonzero means the name is available; it is not an error in this preflight. When using an alternate socket, pass the selected `-S <path>` or `-L <name>` to every tmux command.

Before creating a new branch, check it exactly rather than relying only on the formatted branch list:

```bash
git -C "$source_checkout" show-ref --verify --quiet "refs/heads/$branch"
```

If a supposedly new branch already exists, ask whether to use the existing branch or choose a new name. If the user explicitly requested an existing branch, find it in `git worktree list --porcelain` and use it only when it is not checked out elsewhere. Never bypass this protection with `-B` or `--force`.

If the source checkout is dirty, explain that a new worktree starts at a commit and does not contain its uncommitted changes. Ask whether to proceed from a named committed start point or postpone while the user handles those changes. Never stash, reset, clean, commit, or copy dirty state without an explicit request.

Treat an existing path or tmux session as load-bearing. Do not adopt, empty, delete, rename, or reuse it merely because its name matches. Inspect it, report the collision, and ask for a different destination or session name. Reusing a verified existing pair requires an explicit user request.

## Create a pair

Resolve `start_point` to a commit before mutation. Use the source checkout's `HEAD` only when the user has not named another committed start point and has accepted the dirty-checkout boundary.

After verifying that the derived root is absent or a real directory dedicated to this repository's worktrees, create it if needed:

```bash
mkdir -p "$worktree_root"
```

For a new branch:

```bash
git -C "$source_checkout" worktree add -b "$branch" "$worktree_path" "$start_point"
```

For an existing local branch that the user explicitly chose and that is not checked out elsewhere:

```bash
git -C "$source_checkout" worktree add "$worktree_path" "$branch"
```

Verify Git before creating tmux state:

```bash
git -C "$source_checkout" worktree list --porcelain
git -C "$worktree_path" status --short --branch
git -C "$worktree_path" rev-parse --show-toplevel
git -C "$worktree_path" branch --show-current
git -C "$worktree_path" rev-parse HEAD
```

Then create a detached, shell-backed tmux session on the selected server:

```bash
target=$(tmux new-session -d -P -F '#{session_name}:#{window_index}' -s "$session_name" -n shell -c "$worktree_path")
tmux display-message -p -t "=$target" '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path} #{pane_current_command}'
```

If Git succeeds but tmux creation fails, preserve the worktree, report the partial state and exact error, and ask how the user wants to resolve the tmux collision or failure. Do not roll back the worktree automatically.

## Operate and verify

Create each additional window with the worktree path explicitly, even when another window already has that current directory:

```bash
tmux new-window -d -P -F '#{session_name}:#{window_index}' -t "=$session_name:" -n agent -c "$worktree_path"
tmux new-window -d -P -F '#{session_name}:#{window_index}' -t "=$session_name:" -n test -c "$worktree_path"
```

Use role names for windows, keep the task slug on the session, and use exact-match targets for later operations. Do not place windows for another worktree in the session unless the user explicitly requests a mixed session.

Inspect the pair before input sends, structural changes, handoff, or cleanup:

```bash
git -C "$source_checkout" worktree list --porcelain
git -C "$worktree_path" status --short --branch
git -C "$worktree_path" rev-parse --show-toplevel
git -C "$worktree_path" branch --show-current
tmux list-windows -t "=$session_name" -F '#{session_name}:#{window_index} #{window_name} panes=#{window_panes}'
tmux list-panes -s -t "=$session_name" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path} #{pane_current_command}'
```

Every initial `#{pane_current_path}` should equal `worktree_path`. A different path may be an intentional shell location, so report it rather than changing it silently. Re-run both Git and tmux inventory after window moves, renames, or new windows.

Hand off with the selected socket and exact session target as described in the main skill. If a client is already attached, provide an attach, switch, or select command rather than changing its view.

## Clean up safely

Cleanup removes live process state before filesystem state. First resolve and inspect the exact pair again:

```bash
git -C "$worktree_path" status --short --branch
git -C "$source_checkout" worktree list --porcelain
tmux list-sessions -F '#{session_name} attached=#{session_attached} windows=#{session_windows}'
tmux list-clients -t "=$session_name" -F '#{client_name} #{client_tty} #{session_name}'
tmux list-windows -t "=$session_name" -F '#{session_name}:#{window_index} #{window_name} panes=#{window_panes}'
tmux list-panes -s -t "=$session_name" -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path} #{pane_current_command}'
```

Stop and ask the user when:

- the worktree has modified, staged, or untracked files;
- the branch, path, or session no longer matches the expected pair;
- any client is attached to the session; or
- a window or process needs a decision before termination.

Never switch, detach, or kill an attached client on the user's behalf. Hand the user the exact detach or handoff command and wait. Killing a detached pre-existing session still requires confirmation of its exact name and all windows. Never remove a worktree while a pane is still using it as a working directory.

Before requesting authorization to kill a window that contains a supported agent CLI, follow [agent-archives.md](agent-archives.md). Archive and verify every agent session reference while each pane-to-process relationship still exists. A review-confidence archive blocks teardown, and a high-confidence archive still does not authorize the kill.

After authorization, remove the tmux session first, then the clean worktree:

```bash
tmux kill-session -t "=$session_name"
git -C "$source_checkout" worktree remove "$worktree_path"
```

Do not add `--force`. Verify the result:

```bash
tmux has-session -t "=$session_name"
git -C "$source_checkout" worktree list --porcelain
test ! -e "$worktree_path" && test ! -L "$worktree_path"
```

The branch is separate retained state. Delete it only when the user explicitly asks and normal merged-branch safety accepts the deletion:

```bash
git -C "$source_checkout" branch -d -- "$branch"
```

Never substitute `-D`. If Git reports stale worktree metadata, diagnose without mutation:

```bash
git -C "$source_checkout" worktree prune --dry-run --verbose
```

Do not prune automatically, manually delete Git administrative files, or remove the shared worktree root just because one child worktree was removed.
