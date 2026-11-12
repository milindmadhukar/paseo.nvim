# Upgrade checklist

Check every item on every SDK bump. Add whatever broke this time.

## Pinned for a reason

- `sidecar/bridge-connection.ts` imports `@getpaseo/client/internal/daemon-client`,
  which upstream calls unsupported. **Pin the SDK exactly** and check that
  this export still exists.
- The typed API has no `cancel`, `setMode`, `setModel` or `setThinking`, and
  `terminals.list` strips `title`/`activity`. Those calls stay on `raw()`.

## Broke, or nearly broke

| Bump | What | Where |
|---|---|---|
| 0.9 → 0.15 | Terminal scrollback became `replay` begin/data/end instead of one `restore`. It compiled (events are `any`), and attached to a blank screen. | `bridge-terminals.ts` `receive` |
| 0.9 → 0.15 | Typed `workspaces.create` returns only the handle and drops the created agent. Use raw `createWorkspace`. | `bridge-workspaces.ts` `createWithFirstAgent` |
| — | `removeProject` returns `{ removedWorkspaceIds }`; the code read `removed`, and the mock agreed. | `bridge-workspaces.ts` |
| — | Agent-to-agent messages are tool calls with `agentMessage`; dropping unknown fields in `describeItem` hides them. | `bridge-timeline.ts` |

## Re-verify on each bump

- `describeItem` (`bridge-timeline.ts`): every timeline item type and every
  field the renderer needs. A new field on an existing item is invisible
  until something reads it.
- Live merge rules against `app/src/types/stream.ts`: does the app still
  merge reasoning and text the way `transcript.stream` does?
- Workspace naming (`server/src/server/session.ts` `handleWorkspaceCreate*`,
  `workspace-auto-name.ts`): still create-only, still `firstAgentContext`,
  still skipped by an explicit title?
- Mid-turn send default (`activeTurnBehavior`) and the app's default
  `sendBehavior`.
- Deprecations with COMPAT dates: provider `features` → `controls`/`options`
  (removal 2027-05-01) moves with the 0.16 bump.
- `tests/e2e/run.sh`, every scenario, against the target daemon.
