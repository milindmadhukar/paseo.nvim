---
name: workspace-pr
description: Push a ws workspace's branches and open one pull request per member repository, cross-linked, each against that repo's own base branch. Use when a multi-repo workspace is ready for review, when asked to open PRs across repos, or when merging a change that spans repositories.
---

# Pull requests across a workspace

Each member repository gets its own pull request. They are separate PRs in
separate repos that happen to describe one piece of work, so each must be
reviewable on its own AND point at its siblings.

Read `workspace` first for the layout, and commit with `workspace-commit`
before starting here.

## The two rules that break things

**The base branch is per repo, and it is often not `main`.** Read `base` from
`<project>/.ws/workspace.toml` for each member. In some projects every repo
sits on `dev` while `origin/HEAD` still reports `main` — opening a PR against
`main` there targets the wrong branch and the diff will look enormous and
wrong.

**Push over HTTPS with the gh credential helper**, not over SSH:

```bash
git -c credential.helper='!gh auth git-credential' \
    push https://github.com/<owner>/<repo>.git <branch>
```

The SSH key is passphrase-protected and no agent is running, so an SSH push
hangs or fails with a misleading `Permission denied (publickey)`.

## Procedure

1. `ws status --json` — find the members with commits to push. Skip the rest.

2. Per member, confirm the base:

   ```bash
   grep -A5 "\[repos\.<name>\]" <project>/.ws/workspace.toml
   ```

3. Push that member's branch over HTTPS, as above.

4. Open the PR against that repo's base:

   ```bash
   gh pr create --repo <owner>/<repo> --base <base> --head ws/<name> \
     --title "..." --body "..."
   ```

5. **Cross-link, in a second pass.** You cannot link to a PR that does not
   exist yet, so open them all first, collect the URLs, then edit each body to
   list its siblings:

   ```
   Part of a change spanning several repositories:
   - clm      #123
   - clm_api  #456   ← you are here
   ```

   `gh pr edit <number> --repo <owner>/<repo> --body "..."`.

6. Report every URL.

## Merging

Merge in dependency order — the side that provides an interface before the side
that consumes it — or CI on the consumer will fail against an API that is not
deployed. State the order you chose and why.

On a conflict: rebase that member onto its own base, resolve inside that repo
only, re-push, and say what you resolved. A conflict in one member says nothing
about the others.

## Afterwards

`ws rm <name>` once every PR is merged. It refuses if any member still holds
work that exists nowhere else, which is the check you want at this point.
