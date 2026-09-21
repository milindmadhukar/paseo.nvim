---
name: workspace-commit
description: Commit work that spans several repositories in a ws workspace — one conventional commit per repo, each standing on its own. Use when changes in a multi-repo workspace are ready to commit, when asked to commit across repos, or when a single task has touched more than one member repo. Extends the ordinary git-commit skill with the multi-repo rules.
---

# Committing across a workspace

A workspace spans N repositories. There is no such thing as a commit across
them — each member gets its own, and each has to make sense to someone reading
only that repository's history.

Read the `workspace` skill first if you do not know which repos are in play —
it defines `$ws` (the workspace root) and how to list its members.

## Hard rules

**Never pass `-c user.email=` or `-c user.name=` to `git commit`.** The repos
are configured correctly. Overriding this once meant reauthoring 22 commits and
force-pushing nine branches. If authorship looks wrong, stop and say so rather
than correcting it on the command line.

**One repo at a time, from inside it.** `git -C <member> …`, or `cd` into it.
The workspace root is not a repository.

**Never `git add -A` across members.** Stage within one repo, commit, move on.

## Procedure

1. Find the dirty members. Skip the clean ones rather than making empty
   commits:

   ```bash
   for m in $(find "$ws" -maxdepth 3 -name .git -not -path '*/node_modules/*' | sed 's:/\.git$::' | sort); do
     if [ -n "$(git -C "$m" status --porcelain)" ]; then printf '%s\n' "$m"; fi
   done
   ```

2. For each dirty member, read its diff before writing anything:
   `git -C <member> diff HEAD`. The commit message has to describe what
   changed, which means reading what changed.

3. Stage deliberately. Unrelated changes that happen to be in the same repo get
   separate commits. Watch for files the workspace manages — `node_modules` and
   other linked directories are excluded via `.git/info/exclude`, but a copied
   `.env` is a real untracked file and must not be committed.

4. Write a conventional commit: `type(scope): summary`. The scope is a
   component *within that repo*, not the repo's own name — the repo is already
   obvious from where the commit lives.

5. In the body, explain **why**, and say what the change assumed or altered. If
   the change only makes sense alongside a sibling repo's change, say so in
   prose: "the API side of this is in clm_api". Do not invent a cross-repo
   identifier; there isn't one until the PRs exist.

6. Repeat per member. Report at the end what was committed where, and what was
   left alone.

## What not to do

- Do not commit the same message into every repo. If the summary is identical
  across members, at least one of them is under-described.
- Do not commit a member you have not read the diff of.
- Do not push. Pushing is `workspace-pr`'s job, and it has the base-branch
  rules.
