# git-cow-worktree

Git worktrees that share disk blocks with the checkout they came from, and bring
its build caches along.

`git worktree add` writes every tracked file fresh from the object store and
leaves ignored files behind. On a copy-on-write filesystem that wastes space,
and every new worktree starts with a cold build: no `target/`, no
`node_modules/`, no `.venv/`. That cost adds up when an agent such as Claude
Code creates a worktree for every subagent.

`git cow-worktree` copies the source checkout with `cp --reflink=always`, then
makes git agree with the result. Nothing is shared at the git level: each
worktree is an ordinary linked worktree with its own branch and index. Shared
blocks are copied only when one side writes to them.

Measured on a Rust workspace with 4,264 tracked files and a 1.3 GB `target/`,
on btrfs:

|                      | `git worktree add` | `git cow-worktree` |
|----------------------|--------------------|--------------------|
| time to create       | 1.5 s              | 2.6 s              |
| exclusive disk usage | 234 MiB            | 0 B                |
| `target/` present    | no                 | yes, 1.3 GB shared |

Creating a worktree is not faster. Copying the metadata for a large build
directory costs time. What you get is zero extra disk and a populated build
directory.

## Requirements

- Linux, with GNU coreutils `cp` (uses `--reflink=always` and `--parents`)
- A filesystem with reflink support. Tested on btrfs; XFS (created with
  `reflink=1`) and bcachefs also support reflinks
- git 2.31+ and bash; `jq` for the Claude Code hooks

The source and the new worktree must be on the same filesystem. A
cross-device copy fails instead of silently falling back to a full copy.

## Install

```sh
git clone https://github.com/igouss/git-cow-worktree.git
cd git-cow-worktree
ln -s "$PWD"/bin/* ~/.local/bin/
```

Any directory on `PATH` works. Because the command is named `git-cow-worktree`,
git runs it as `git cow-worktree`.

## Usage

```sh
git cow-worktree <branch> <path> [<start-point>]
```

Run it from anywhere inside the repository.

- **Branch exists locally:** the worktree checks it out.
- **Exactly one remote has the branch:** a local tracking branch is created,
  as with `git worktree add`.
- **Otherwise:** a new branch is created at `<start-point>` (default `HEAD`).
- **What's copied:** tracked files and ignored files. Untracked files that
  aren't ignored stay behind.
- **What the new worktree contains:** the branch's commit exactly, so
  uncommitted edits in the source are not carried over. Only files whose
  content differs from the source are rewritten, so everything else stays
  shared.
- **Skipped:** worktrees nested inside the source, such as
  `.claude/worktrees/*`, and submodule directories.
- **On failure:** the half-made worktree is removed, along with the branch if
  the command created it.

## Claude Code

A Claude Code
[`WorktreeCreate` hook](https://code.claude.com/docs/en/hooks#worktreecreate)
replaces Claude's own `git worktree add`. That covers `claude --worktree`, the
`EnterWorktree` tool, subagents with `isolation: "worktree"`, workflows, and
background sessions. Add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "WorktreeCreate": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/claude-cow-worktree-create\"", "timeout": 600 }] }
    ],
    "WorktreeRemove": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/claude-cow-worktree-remove\"", "timeout": 120 }] }
    ]
  }
}
```

`claude-cow-worktree-create` keeps Claude's conventions:

- **Location:** worktrees go in `<repo>/.claude/worktrees/<name>` on branch
  `worktree-<name>`.
- **Base:** the branch starts from `origin/HEAD`. If `worktree.baseRef` is
  `"head"` in user, project or local settings, or the repository has no
  `origin/HEAD`, it starts from the current `HEAD`.
- **Reuse:** if a worktree with that name already exists, the hook reuses it.
- **Names:** anything that isn't a simple slug is refused.

`claude-cow-worktree-remove` runs `git worktree remove --force` and deletes
the `worktree-<name>` branch. If the path isn't a git worktree, it refuses and
deletes nothing.

Differences from Claude's built-in worktrees:

- **No fetch:** the hook uses the locally cached `origin/HEAD` and doesn't
  fetch.
- **No `.worktreeinclude`:** the hook doesn't read it, because it already
  copies every ignored file.
- **Subagent worktrees aren't removed:** Claude keeps worktrees created by a
  `WorktreeCreate` hook when a subagent or workflow agent finishes
  ([docs](https://code.claude.com/docs/en/hooks#worktreeremove)). Remove them
  with `git worktree remove` or the remove hook. Because they share blocks with
  the main checkout, they take little space while they wait.
- **Build caches move paths:** a copied cache is only as useful as your build
  tool's tolerance for the directory moving. Caches keyed on absolute paths
  may rebuild some or all of their contents.

## Tests

```sh
tests/run.sh
```

The tests run against throwaway repositories in `tests/.work`, so they need a
reflink-capable filesystem there. The cross-device case uses `/dev/shm`.

## License

MIT
