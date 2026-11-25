# Paseo upstream ledger

What each Paseo release meant for paseo.nvim: what was **adopted** (with the
commit), what is **deferred** (and what it waits on), and what was
**declined** (and why). The next catch-up starts from the last section. The
process is the `paseo-upstream` skill in `.claude/skills/`.

## State

| | |
|---|---|
| Last reviewed | **0.17.4** (2026-11-23) |
| SDK pin | `@getpaseo/client` / `@getpaseo/protocol` **0.17.4**, exact |
| Daemon it was verified against | 0.17.4 (`@getpaseo/cli` from npm via `PASEO_BIN`, isolated e2e daemon; the desktop daemon was still 0.16.2) |
| Reviewed on | 2026-11-25 |

## 0.16.0-beta.1 → 0.17.4 (reviewed 2026-11-25)

### SDK

| Change | Status |
|---|---|
| `@getpaseo/client` 0.15.4 → 0.17.4, exact pin; `internal/daemon-client` export still there | **adopted** `e186ccc` |
| `features` / `featureValues` / `setAgentFeature` → `controls` + `options` / `setAgentOptions` / `listControls` (COMPAT removal 2027-05-01) | **adopted** `e186ccc`: sidecar only; `featuresOf` joins controls and options into the shape the Lua reads, and falls back to `features` on an older daemon |
| `sendMessage` returns `AgentMessageReceipt`; `activeTurnBehavior` gained `"queue"` (throws without `sourceAgentId`) | **no change needed**: the plugin never sends `"queue"`; its queue is client-side. In the upgrade checklist |
| `agent.background_work.{list,stop,update}`, `backgroundWork {count, runningCount?}` on the snapshot | **adopted** `b69b02d` |
| `undoWorkspaceArchive` (`workspaceArchiveUndo`) | **adopted** `fef546f` |
| `listCheckoutWorktrees` (`checkoutWorktreeList`) | **adopted** `0e9eff6` |
| `turnMetrics` on timeline entries, `metrics` on `turn_completed`, `sessionMetrics` on the snapshot | **adopted** `2509ecd` |
| `setWorkspaceBaseBranch`, `entityMetadata`, `setLabel` | **deferred**: no editor surface asks for them yet (the Changes panel diffs against the checkout) |
| provider installation / update RPCs (`providerInstallation`) | **deferred**: `:checkhealth paseo` could show versions; low value |
| `observeDiff` / `readDiff` | **deferred**: the Changes panel reads git itself |
| `observeTimeline` freshness cursors, `wholeTurns` | **deferred** still: the history path works; revisit if reopen gets slow |

### Features (app → editor)

| Upstream | Status |
|---|---|
| 0.16 background tasks above the composer, with Stop; 0.17.1 heartbeats and PR watches in the same list | **adopted** `e4a22bc`, `1632d0b`: an idle agent with running work spins (heartbeats count, do not run), `&N` on its rail row, ` N background gb` on the bar, `gb` lists it live, `x` stops (a heartbeat asks first: stopping deletes its schedule). Verified on a real Claude `run_in_background` shell and on a heartbeat |
| 0.16 background agents (`background: true`) | **adopted** `3cdb267`: out of `agents.all` / `for_root`, so out of the rail, lists, subagents and workspace status; `ui.float.rail.show_background` shows them |
| 0.16 undo workspace archive (six-second toast) | **adopted** `fef546f`: `u` on the rail, `require("paseo").undo_archive()`; not for `:Paseo ws` workspaces |
| 0.17.2 turn and session stats | **adopted** `2509ecd`: a dim footer under each finished turn (live and from history), a Session section on Usage |
| 0.17.1 use existing worktrees | **adopted** `0e9eff6`: "Existing worktree" on the new-session screen, `:Paseo new existing` |
| 0.17.1 create a workspace from a branch or pull request | **deferred**: `worktreeRefActions`; the base-branch chooser covers branches |
| 0.16 Change base picker | **deferred**: `setBaseBranch`; the Changes panel has no base of its own yet |
| 0.17.1 Rewind the latest turn | **deferred**: no SDK call reviewed yet; `f` forks |
| 0.17.1 provider quota forecasts, OpenRouter / Antigravity / Copilot usage | **no change needed** for the data (it rides `providers.usage`); the forecast line is **deferred** |
| 0.17.2 automatic model list refresh; 0.17.1/0.17.2 agents steer and queue other agents' turns | **no change needed**: daemon-side |
| 0.16 question cards wait for Next/Submit; 0.16 `/exit` no longer default in the slash menu | **to check**: the answer overlay and the composer's `/` completion were not re-verified |
| fx, goose, Hermes, Antigravity approvals, Codex Flex speed, Claude Ultracode toggle | **no change needed**: providers, models and controls arrive through `providers.list` and `controls` |
| 0.14 collapse completed turns | **deferred** still (Neovim folds over transcript blocks) |
| Workspace scripts (`paseo.json` services) | **deferred** still: needs a panel |

### Declined, app-only

Plugin gallery and plugin settings pages; plugin sidebar views, composer
controls, screens and badges; command center tabs and Rewind in it; content
width presets; arranging Usage cards and sidebar usage summary; mobile, iPad,
Android, iPhone Duo and touch-sized controls; the rebuilt mobile chat; desktop
updater, window and dock badge; Mermaid, Markdown and syntax-highlighting
fixes; Hub and relay connection fixes. None has an editor-side equivalent
worth building.

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
