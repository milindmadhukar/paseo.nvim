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

There is no `ws` command. Workspaces are assembled by paseo.nvim (`:Paseo
wcreate`), and everything you need to read is plain git plus one TOML file.

## Find out where you are

**The project root** is the nearest ancestor holding `.ws/workspace.toml`. This
walks up from anywhere inside a workspace or a member:

```bash
root=$PWD
while [ "$root" != / ] && [ ! -f "$root/.ws/workspace.toml" ]; do
  root=$(dirname "$root")
done
```

**The manifest is the source of truth** for what a workspace *should* contain.
`<project>/.ws/workspace.toml` has a `[repos.<name>]` table per member, keyed by
path relative to the project root — so a name may contain `/`, as in
`[repos.archive/broker-portal]`.

```bash
cat "$root/.ws/workspace.toml"
```

**The members on disk** are the directories under the workspace that are git
worktrees. A worktree has a `.git` **file** (pointing into the primary repo's
`.git/worktrees/`), not a `.git` directory:

```bash
ws=$root/.workspaces/<name>
find "$ws" -maxdepth 3 -name .git -not -path '*/node_modules/*' | sed 's:/\.git$::' | sort
```

Anything else directly under the workspace is a **symlink to a shared sibling**,
not a member. `find` does not follow symlinks by default, which is what keeps
them out of that list.

**Per-member state**, in one pass:

```bash
for m in $(find "$ws" -maxdepth 3 -name .git -not -path '*/node_modules/*' | sed 's:/\.git$::' | sort); do
  printf '=== %s\n' "${m#$ws/}"
  git -C "$m" status --porcelain=v2 --branch
done
```

`--porcelain=v2 --branch` gives you `# branch.head` and `# branch.ab +N -M`
(ahead/behind) before the per-file lines, so one call answers "which branch,
how dirty, how far ahead" for that member.

## The things that will catch you out

**Each member is a separate repository.** `git status` at the workspace root
tells you nothing — the root is not a repo. Run git inside a member with
`git -C <member>`.

**They are all on the same branch name**, `ws/<name>`, but those are unrelated
branches in unrelated repositories. A commit in `clm` does not exist in
`clm_api`.

**The base branch is per repo and is not necessarily `main`.** It is recorded
as `base` in `<project>/.ws/workspace.toml`. Read it; do not assume. In some
projects every repo sits on `dev` while `origin/HEAD` still says `main`, and
branching from the wrong one silently bases the work on the wrong history.

**Some paths are symlinks into the primary checkout** — `node_modules`, build
caches, sometimes a docs folder. These are the manifest's `link` entries.
Editing through them edits the primary checkout and every sibling workspace.
The `copy` entries — `.env` and friends — are real copies, so those are safe to
change.

**A member may be declared rather than active**: named in the manifest but with
no directory in the workspace, because it was not selected when the workspace
was created (often `default = false` in its `[repos.<name>]` table). Declared
members have no path to work in. The difference is exactly "in the manifest,
absent from the `find` above".

## Assembling and dismantling

From inside Neovim:

```vim
:Paseo wcreate <name>                 " whatever this project needs, decided for you
:Paseo ws create <name> clm,clm_api   " exactly these members
:Paseo ws rm <name>                   " refuses if there is unsaved work
:Paseo ws ls
:Paseo ws status
```

`:Paseo ws rm` refuses when a member has uncommitted changes or commits that
exist nowhere else. That refusal is a feature — read what it says before
reaching for `force`, which discards the work it named.

**Never `rm -rf` a workspace directory.** It leaves stale entries in every
member repo's `.git/worktrees`, which then break later worktree operations in
ways that look unrelated. If you must dismantle one outside Neovim, do it the
way git wants:

```bash
git -C "$root/<repo>" worktree remove "$ws/<repo>"   # per member
git -C "$root/<repo>" worktree prune
```

## Related

Committing across members: the `workspace-commit` skill. Opening pull requests
across members: `workspace-pr`.
