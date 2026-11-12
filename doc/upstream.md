# Paseo upstream ledger

What each Paseo release meant for paseo.nvim: what was **adopted** (with the
commit), what is **deferred** (and what it waits on), and what was
**declined** (and why). The next catch-up starts from the last section. The
process is the `paseo-upstream` skill in `.claude/skills/`.

## State

| | |
|---|---|
| Last reviewed | **0.16.0-beta.1** (2026-11-10), upstream `aade09d` |
| SDK pin | `@getpaseo/client` / `@getpaseo/protocol` **0.15.4**, exact |
| Daemon it was verified against | 0.15.3 |
| Reviewed on | 2026-11-11 |

## 0.9.0 → 0.16.0-beta.1 (reviewed 2026-11-11)

### Bugs found while reading, fixed first

| What | Commit |
|---|---|
| Live reasoning drew one block per delta; history (projected) drew it whole | `6c3b13f` |
| `:Paseo image` on the buffer mount dropped you into the float (chat looked up by directory, re-keyed by agent) | `5cd2b60` |
| Workspaces started from the editor stayed `main`: the daemon names a workspace only inside the `workspace.create` that carries `firstAgentContext`, and an explicit title is permanent | `f1f4981`, `4c8829b` |
| A chat opened mid-turn drew live fragments above the history fetched after them | `f1f4981` |
| A chat whose history failed to load opened empty with no word why | `eb60ff1` |
| `project.remove` read `result.removed`; the daemon returns `removedWorkspaceIds` | `0c74195` |

### SDK

| Change | Status |
|---|---|
| Terminal scrollback is `replay` begin/data/end, not `restore` (0.15 client) | **adopted** `0c74195`. It was a silent blank screen on attach |
| `@getpaseo/client` 0.9.0 → 0.15.4, exact pin (internal import) | **adopted** `0c74195` |
| Sidecar's own first-prompt agent naming, an 0.8 workaround | **removed** `0c74195`. The daemon does it (verified on 0.15.3) |
| SDK 0.8 fallbacks: directory list, handle `subscribe`, `subscribeTerminals`/`unsubscribeTerminal` | **removed** `0c74195` |
| `controls` / `options` / `setOptions` replacing `features` / `featureValues` / `setAgentFeature` (COMPAT removal 2027-05-01) | **deferred**: 0.16 client only. On 0.15 `features` is the current API. Migrate with the 0.16 bump |
| `hosts.*` typed namespace, `AgentAddress` | **deferred**: 0.16. The plugin's own multi-host routing covers it |
| `agents.list({ filter: { labels } })` instead of client-side label matching | **deferred**: low value. The client-side match also ranks |
| `observeTimeline` freshness cursors, `wholeTurns` | **deferred**: needs `timelineFreshnessCheck`, which 0.15.3 lacks |

### Features (app → editor)

| Upstream | Status |
|---|---|
| 0.12 messages from another agent steer instead of interrupting; 0.14 queue / send-now; app default `sendBehavior: "steer"` | **adopted** `e4e5908`: `ui.send_behavior`, `g<CR>`, a queue count on the bar. Before this, sending mid-turn *interrupted* (the daemon's default) |
| 0.14 sent-message recall with Up/Down in an empty composer | **adopted** `22d779d` |
| 0.12 sender's name on agent-to-agent messages (`agentMessage` on a tool call) | **adopted** `a1f1eb6`. It drew as an empty "Agent message" card |
| `turn_failed` `code` / `diagnostic` (0.16 fix #8480 makes Claude API errors fail properly) | **adopted** `ef4e653` |
| Workspace pins (`pinnedAt`, `setWorkspacePinned`) | **adopted** `1e07f83`: pinned lead the rail, `P` pins |
| 0.12 background workspaces hidden unless "Show background" | **adopted** `1e07f83`: `ui.float.rail.show_background` |
| Workspace title arriving after create (sidebar fix #7758, 0.13) | **adopted** `f1f4981`: the sidecar follows workspace updates and the rail refetches |
| 0.11 Usage: account quota windows | **already had**: the Usage panel's `providers.usage` |
| 0.14 collapse completed turns into summaries | **deferred**: worth doing with Neovim folds over transcript blocks; not started |
| Workspace scripts (`paseo.json` services): list, start, stop | **deferred**: MCP/CLI have it; needs a panel |
| 0.12 Send feedback from the diff pane to an agent | **already had**: `:Paseo ask` / `explain` on hunks |
| 0.15 agent recovery after restart (opt-in host setting) | **no change needed**: daemon-side |
| 0.15 terminals survive daemon restarts | **no change needed**, and replay above makes reattaching show them |
| 0.15 `.worktreeinclude`, `worktree.create.*` plugin hooks | **no change needed**: daemon-side, applies to worktrees the plugin asks for |
| 0.16 background tasks above the composer, with Stop (`agent.backgroundWork`) | **deferred**: 0.16 host + client |
| 0.16 undo workspace archive (`undoWorkspaceArchive`) | **deferred**: 0.16 |
| 0.16 workspace labels/metadata, change base branch | **deferred**: 0.16 (`entityMetadata`, `setBaseBranch`) |
| 0.16 background agents (`background: true`) | **deferred**: 0.16; the rail already hides background workspaces |
| 0.16 `PASEO_WORKSPACE_ID` in each agent's env | **no change needed**: agent-side |
| 0.16 question cards no longer auto-advance on pick | **to check**: the answer overlay moves with arrows (`6398fda`); whether a pick advances was not verified |
| 0.13 connected hosts / delegation to other machines | **to check**: whether a subagent on another host shows in the subagent list was not verified |
| 0.14 Enter vs Cmd+Enter to send | **already had**: `<CR>` from normal mode, `<M-CR>` from insert |
| 0.13 sidebar sort by created / last prompt / manual | **declined**: the rail follows the daemon's order, with pins first |
| 0.10 OpenCode v2, 0.11 Muse / Antigravity, 0.16 fx, new Claude models (5.2 etc.) | **no change needed**: providers and models arrive through `providers.list` |

### Declined, app-only

Mobile, iPad, Android, foldable and iPhone Duo layouts; the first-run setup
wizard; the theme grid; plugin sidebar views, composer plugin controls, file
panels and screens (app UI surfaces); plugin registry and translations;
Markdown renderer, Mermaid and syntax-highlighting fixes; relay/E2EE and
pairing UI; the desktop window, tray and updater; usage-summary sidebar pins.
None of these has an editor-side equivalent worth building.
