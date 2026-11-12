---
name: paseo-upstream
description: Catch paseo.nvim up with upstream Paseo. Read every changelog entry since the last review, diff the @getpaseo/client SDK, learn how the app uses each new thing, decide what the plugin adopts, implement it, and verify it against a real throwaway daemon in tmux. Use when asked to check for Paseo updates, upgrade the SDK or sidecar, "see what's new in Paseo", or bring the plugin up to date with the app. Not for driving Paseo itself (use `paseo`) or for writing SDK code in general (use `paseo-sdk`).
---

# Catching paseo.nvim up with Paseo

Paseo ships fast: seven minor versions in seven weeks at the last catch-up.
This is the whole loop: **baseline, read, diff, learn, decide, plan, build,
verify, record**. The record is `doc/upstream.md`, the ledger. Every run starts
from it and ends by writing to it.

## 1. Baseline

```bash
sed -n '/## State/,/^## 0/p' doc/upstream.md        # last reviewed version, SDK pin
paseo --version                                     # the daemon actually running
grep '"@getpaseo' sidecar/package.json              # what the sidecar is built on
npm view @getpaseo/client time --json | tail -8     # what has shipped since
```

The target is the **latest stable whose minor matches the running daemon**,
unless the user says otherwise. Ask them if the daemon is behind npm.
Beta-only features get built behind a capability check, or deferred.

## 2. Fetch upstream (temporary, never in the repo, never in /tmp)

```bash
git clone --depth 300 -q https://github.com/getpaseo/paseo.git "$TMPDIR/paseo-upstream"
```

`packages/client` (SDK), `packages/protocol` (wire types),
`packages/server` (daemon behaviour), `packages/app` (how the UI uses it all),
`CHANGELOG.md`. Read-only. Delete it in step 10.

## 3. Read the changelog in full

From the ledger's last reviewed version up, **every bullet**. Read it
yourself rather than delegating: an agent's summary drops exactly the detail
that matters ("question cards no longer auto-advance" is one line). Look for:

- **wire and SDK changes**: an event that changed shape is a silent break
  (0.15's terminal `replay` was);
- **daemon behaviour the plugin works around**: a workaround for an old
  daemon is dead code once the floor moves past it;
- **app features with an editor equivalent**: composer behaviour, timeline
  items, sidebar state;
- **app-only** items (mobile, layouts, wizards, plugin UI surfaces): decline
  them in one line in the ledger, never silently.

## 4. Diff the SDK

Compare `packages/client/src/index.ts` and `daemon-client.ts` at the target
tag against `sidecar/node_modules/@getpaseo/client/dist/*.d.ts`: methods
added, deprecated (note the `COMPAT(...)` removal dates), and changed in
signature. Compare the daemon's advertised capabilities
(`packages/server/src/server/websocket-server.ts`) at the running daemon's
tag with HEAD. Then grep the sidecar for every `raw()` and `connected()` call
and check each against the new types. `references/upgrade-checklist.md`
lists what broke or nearly broke last time. Check each item again.

An Explore agent is fine for this mechanical diff. Give it the paths and ask
for file:line evidence.

## 5. Learn from the app before building

For each candidate, find how `packages/app` does it and copy the
**semantics**, not the UI:

| Need | Where |
|---|---|
| live timeline merging (text, reasoning, tools) | `app/src/types/stream.ts` (`appendThought`, `reduceStreamUpdate`), `app/src/timeline/session-stream-reducers.ts` |
| sending, queue / steer / interrupt | `app/src/composer/index.tsx`, `composer/input/state.ts`, `composer/actions.ts` |
| creating workspaces and first agents | `app/src/screens/new-workspace-screen.tsx` |
| settings defaults | `app/src/hooks/use-settings/storage.ts` |
| what the daemon actually does | `server/src/server/session.ts`, `agent/` |

The daemon is the authority on behaviour. "Workspaces are named from the
first prompt" turned out to mean *only inside the create request, only with
`firstAgentContext`, and never if a title was sent*, which is three separate
conditions found in `session.ts` and `workspace-auto-name.ts`.

## 6. Decide

Adopt only what is:
(a) reachable through the SDK or the raw `DaemonClient`,
(b) useful from inside an editor,
(c) gateable on a capability, if it is not on the target daemon, and
(d) not already covered.

**Breaking changes and dead workarounds come first, always.** Then bugs the
reading turned up. Then features, ranked by how often you would feel them.

## 7. Plan, and get it signed off

Write the plan (plan mode) with the adopt / defer / decline list and the
verification for each. **Never start building on your own triage.** The user
picks the target version and the adopt list.

## 8. Build

Fixes, then the SDK bump, then features. One signed conventional commit per
item, straight to `main` (this is a solo repo). README, `doc/paseo.txt` and a
regenerated `doc/tags` go in the same commit (`doc/tags` is gitignored, so
regenerate it but don't commit it). Live agents edit this repo: re-check a
file before rewriting it, and fetch before pushing.

Write a sidecar test for every wire contract (`sidecar/bridge.test.ts`),
and a mock with the daemon's **real** response shape. A mock that returns
what the code expects is how `project.remove` read a field no daemon has ever
sent.

## 9. Verify against a real daemon, in a terminal

Unit tests stub the daemon and cannot see these bugs. Every fix and feature
gets an e2e scenario; see `references/e2e.md`.

```bash
tests/run.sh                    # headless suite + sidecar tests (run twice before believing a red)
tests/e2e/run.sh                # every scenario against a throwaway daemon on 6797
tests/e2e/run.sh <name>         # one
```

**Make each scenario fail first.** Run it against the parent commit, or with
the fix stashed. A scenario that passes before the fix proves nothing; the
first two written last time passed for the wrong reason. Look at the PNGs in
`$TMPDIR/paseo-e2e/shots/`; tests never say how something looks.

Never point any of this at the live daemon on 6767, and never kill a process
the harness did not start.

## 10. Record and clean up

- Update `doc/upstream.md`: the State table, plus a section for the range
  just reviewed with every relevant bullet marked adopted (sha), deferred
  (what it waits on) or declined (why), and the app-only ones in one line.
- Update `references/upgrade-checklist.md` with anything that broke.
- `tests/e2e/daemon.sh stop`, then delete `$TMPDIR/paseo-upstream` and
  `$TMPDIR/paseo-e2e`.
