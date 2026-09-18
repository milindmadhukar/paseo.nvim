# paseo.nvim

Read every hunk you ship. Ask an agent when one is opaque. Never leave Neovim.

Two problems, one plugin:

- **Reviewing.** Stage every hunk by hand, fuzzy-find what changed, drive it
  from a quickfix list, and ask an agent "explain this" when a hunk is
  unreadable — without a context switch, and without being tied to one vendor.
- **Writing.** Agents step on each other. Git worktrees are the standard fix,
  but a worktree is *per repo*, and a real unit of work often spans several
  repos under a parent that is not itself a repo (`~/Code/openfin` → `clm`,
  `clm_api`, `fos-pwa`, `hipa-v2`, …). A **workspace** is that unit: one name,
  N worktrees, plus the untracked context they need to run.

Agents run on [Paseo](https://github.com/getpaseo/paseo), which already
abstracts claude / codex / opencode and owns sessions, status and terminals.

## Status

Early. Phase 0 (Neovim config) and the plugin skeleton are done; the review
layer is next. See [Roadmap](#roadmap).

| | |
|---|---|
| ✅ | `repos.lua` — the repo list, workspace-aware |
| ✅ | `:checkhealth paseo` |
| ✅ | `:Paseo` command surface |
| ⬜ | changed-files picker, hunk quickfix, diff panel |
| ⬜ | explain bridge + Paseo sidecar |
| ⬜ | workspace assembly (`ws`) |
| ⬜ | workspace picker with live agent status |

## Install

`lazy.nvim`:

```lua
{
  "milindmadhukar/paseo.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "lewis6991/gitsigns.nvim",
  },
  cmd = "Paseo",
  opts = {},
}
```

Requires Neovim 0.10+ and `git`. The Paseo backend additionally wants the
`paseo` daemon running and `bun` (or node ≥ 22) for the sidecar; without them
the plugin degrades to the `local` backend rather than breaking. Run
`:checkhealth paseo` to see which of those you have.

## Configuration

Defaults, all of which are read by something — a key lands here only once it
does:

```lua
require("paseo").setup {
  backend = "paseo",              -- or "local" (floaterm + nvim_chan_send)

  paseo = {
    url = "ws://127.0.0.1:6767/ws",
    health_url = "http://127.0.0.1:6767/api/health",
    cli = "paseo",
  },

  workspaces = {
    dir = ".workspaces",          -- relative to a project root
  },

  review = {
    context = 0,                  -- `git diff -U0`; see "Delete hunks" below
  },
}
```

## Commands

| | |
|---|---|
| `:Paseo repos` | The repos in the current unit of work |
| `:Paseo health` | `:checkhealth paseo` |

## Architecture

Three layers with clean seams, so each can be replaced without touching the
others.

```
┌ paseo.nvim ──────────────────────────────────────────────────┐
│  pickers · hunk quickfix · diff panel · explain bridge       │
└───────────┬──────────────────────────────┬───────────────────┘
            │ ws --json                    │ stdio JSON-lines
            │ (rare, on demand)            │ (push, ~1–10 ms)
┌───────────▼──────────────┐   ┌───────────▼───────────────────┐
│ ws (Go) — CONDITIONAL    │   │ paseo-bridge.ts (Bun sidecar) │
│ N worktrees + .env copy  │   │ @getpaseo/client              │
│ + heavy-dir links        │   └───────────┬───────────────────┘
│ + shared siblings        │               │ ws://127.0.0.1:6767/ws
│ → registers the assembled│   ┌───────────▼───────────────────┐
│   dir with Paseo         │   │ Paseo daemon                  │
│                          │   │ agents · providers · sessions │
│                          │   │ status · terminals · schedules│
└──────────────────────────┘   └───────────────────────────────┘
```

### The seam that makes multi-repo work

`ws` assembles the composite directory, then registers it with Paseo as an
ordinary **local** workspace:

```sh
paseo project   create ~/Code/openfin --json                   # kind: non_git
paseo workspace create --isolation local \
      --path ~/Code/openfin/.workspaces/otp-rate-limit \
      --project <id> --title "otp rate limit" --json
```

Paseo never learns it is looking at six worktrees; it sees a directory with
agents in it.

### Transport: why a sidecar

Measured against a live daemon:

| Channel | Latency | Verdict |
|---|---|---|
| `paseo … --json` CLI | 2380–2460 ms | Boots Electron per call. Dead for anything interactive. |
| HTTP `GET /api/health` | 8 ms | The only REST endpoint that exists; agents/workspaces all 404. |
| `ws://127.0.0.1:6767/ws` | ~1–10 ms | The real API. |

So: a small Bun sidecar holding one WebSocket, speaking newline-delimited JSON
to Lua over stdio, spawned once per Neovim session.

Not raw WebSocket in Lua — the frame codec is easy, but the actual surface is
subscriptions with server-issued IDs, snapshot-then-update ordering, timeline
epochs and cursors, `replacement` invalidation, and `subscription_restored`
after reconnect. Reimplementing *that* in Lua is where the integration rots.

The win is that the workspace picker's status column becomes **push** rather
than polling: `client.agents.list({ subscribe: {} })` streams `agent_update`,
which is unobtainable at 2.4 s per poll. The same bridge reaches a remote daemon
unchanged (`wss://` + password), so this extends to a VPS later for free.

**The CLI keeps exactly one job:** one-shot writes issued by skills and agents
(`paseo agent send --prompt-file`, `paseo workspace create`), where 2.4 s does
not matter and a stable documented surface does. It is also the degraded
fallback if the sidecar cannot start. No interactive path may call it.

### Backend seam

`paseo.backends.{paseo,local}`. Worktree assembly is ours either way, so the
`local` backend — floaterm plus `nvim_chan_send` — costs little and makes the
plugin usable without Paseo installed. Paseo is the default and gets every
feature.

## Notes from the source

Things that are true of gitsigns and git, checked rather than assumed, and
several of which contradict the obvious approach.

**Delete hunks are the whole problem.** `stage_hunk()` *does* work on a pure
deletion: `hunks.lua:51` sets `vend = added.start + max(added.count - 1, 0)`, so
a delete occupies exactly one line — the line *above* the removed block — and
`find_hunk` special-cases deletions at beginning- and end-of-file. The pain is
visibility, not capability. The consequence for us is sharp: a delete hunk's
quickfix `lnum` must be `c` from `@@ -a,b +c,0 @@`, **not `c + 1`**, or
`stage_hunk()` misses every deletion.

**`setqflist('all')` cannot be merged across repos.** It ends in
`vim.fn.setqflist({}, ' ', …)` — a replace — and collects repos from attached
buffers plus `uv.cwd()` only (`actions/qflist.lua`). At review start, with no
buffers open, it sees one repo. We build the quickfix from `git diff -U0`
instead.

**`:Gitsigns diff` is per-tab and single-repo by design.** It resolves its repo
from `fn.getcwd()` (`actions/diff.lua:1118`) and names its buffer
`gitsigns-diff://<gitdir>//<tab>`. So: one tab per member repo, with `tcd`.

**Always-on deleted lines are not the answer.** `toggle_deleted()` and
`config.show_deleted` are both deprecated (`config.lua:455`, `actions.lua:241`).
Persistent virtual lines also desync a line's visual position from its real
number, which matters precisely because delete-hunk staging is
exactly-one-line sensitive. The supported surfaces are `preview_hunk_inline()`
and `:Gitsigns diff --diff=unified`.

**The public hunk type omits `.vend`.** Recompute it as
`added.start + max(added.count - 1, 0)` or pure-delete hunks are never found.

**`git status --porcelain=v2 -z` rename records carry an extra field.** A `2 `
record is followed by a NUL-separated `origPath`; a naive NUL split desyncs
everything after it.

## Roadmap

- **Phase 0 — Neovim config.** *(done, lives in the nvim config repo)*
  `word_diff`, `diff_opts.linematch`, `nav_hunk`-based motions, the `ih` text
  object, `preview_hunk_inline` and the diff panel on the preview/diff keys,
  and a deduplicated `<leader>g` group.
- **Phase 1 — review layer, single repo.** Changed-files picker, per-hunk
  quickfix, diff panel in a fresh tab with `tcd`.
- **Phase 2 — the explain bridge.** References from cursor / selection / hunk /
  file, the Bun sidecar, and a shared `explain-change` skill whose rubric ends
  in *what the reviewer should push back on*.
- **Phase 3 — `ws`, a Go CLI.** *Conditional.* Buys exactly one thing:
  concurrent isolated agents on a multi-repo project. Single-repo projects
  already get real worktree isolation from Paseo, and multi-repo projects
  already work for one agent at a time. Build it only if serialising agents
  becomes the bottleneck.
- **Phase 4 — workspace layer.** Workspace picker with a live, push-driven
  agent status column; a new Neovide window per workspace.
- **Phase 5 — commit, PR, merge.** Agent-agnostic skills over `ws … --json`.

## Naming

*Paseo* is the walk; this is the plugin that makes you take it. Working
alternates, cheap to change: `atelier.nvim`, `workbench.nvim`, `readback.nvim`.

## Licence

MIT.
