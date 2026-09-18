---
name: workspace
description: Find your way around a ws workspace — one named unit of work spanning several git worktrees under a parent directory that is not itself a repository. Use when the working directory looks like `<project>/.workspaces/<name>/`, when a task spans more than one repo, or when asked what repos are in play, where a workspace lives, or what state its members are in. Read this before running git commands in a multi-repo checkout.
---

# Working inside a ws workspace

A **workspace** is one named unit of work spanning N git worktrees plus the
untracked context they need. It is a directory:

```
<project>/.workspaces/<name>/
├── clm/        ← a worktree of <project>/clm, on branch ws/<name>
├── clm_api/    ← a worktree of <project>/clm_api, on branch ws/<name>
└── Docs/       ← a symlink to <project>/Docs, shared
```

The parent, `<project>`, is usually **not a git repository** — it is a plain
directory holding several. That is the whole reason workspaces exist: a git
worktree is per-repo, so it cannot express "this one task, across these six
repos".

## Find out where you are

Everything is JSON. Do not parse the human output.

```bash
ws ls --json            # workspaces in this project
ws ls --json --all      # every project
ws status --json        # per-repo branch, dirty count, ahead/behind
ws path <name>          # a workspace root, for cd
```

`ws status` runs every repo concurrently, so asking for all of them is as cheap
as asking for one. Prefer one `ws status --json` over a loop of `git status`.

## The things that will catch you out

**Each member is a separate repository.** `git status` at the workspace root
tells you nothing — the root is not a repo. Run git inside a member, or read
`ws status --json`.

**They are all on the same branch name**, `ws/<name>`, but those are unrelated
branches in unrelated repositories. A commit in `clm` does not exist in
`clm_api`.

**The base branch is per repo and is not necessarily `main`.** It is recorded
as `base` in `<project>/.ws/workspace.toml`. Read it; do not assume. In some
projects every repo sits on `dev` while `origin/HEAD` still says `main`, and
branching from the wrong one silently bases the work on the wrong history.

**Some paths are symlinks into the primary checkout** — `node_modules`, build
caches, sometimes a docs folder. Editing through them edits the primary
checkout and every sibling workspace. `.env` files are *copies*, so those are
safe to change.

**A member may be `declared` rather than `active`**: named in the workspace but
with no worktree yet. `ws status --json` reports the state; `declared` members
have no path to work in.

## Assembling and dismantling

```bash
ws create <name>                       # the manifest's default repos
ws create <name> --repos clm,clm_api   # exactly these
ws create <name> --with hipa-v2        # the defaults plus an opt-in one
ws rm <name>                           # refuses if there is unsaved work
```

`ws rm` refuses when a member has uncommitted changes or commits that exist
nowhere else. That refusal is a feature — read what it says before reaching for
`--force`, which discards the work it named.

**Never `rm -rf` a workspace directory.** It leaves stale entries in every
member repo's `.git/worktrees`, which then break later worktree operations in
ways that look unrelated. `ws rm` uses `git worktree remove` and prunes.

## Related

Committing across members: the `workspace-commit` skill. Opening pull requests
across members: `workspace-pr`.
