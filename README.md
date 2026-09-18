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

Early. The Neovim-config groundwork and the plugin skeleton are done; the
review loop is being built now. See [Roadmap](#roadmap).

| | |
|---|---|
| ✅ | `repos.lua` — the repo list, workspace-aware |
| ✅ | `:checkhealth paseo` |
| ✅ | `:Paseo` command surface |
| ✅ | `git.lua` — status/diff parsing and hunk staging |
| ✅ | changed-files picker, hunk quickfix, diff panel |
| ✅ | 48-assertion test suite (`tests/run.sh`) |
| 🔨 | explain bridge + Paseo sidecar |
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
    -- url and home are absent by default: absent means "discover the daemon".
    -- Set url to pin it, e.g. "ws://127.0.0.1:6767/ws".
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
| `:Paseo changes` | Changed-files picker; `<C-q>` expands into hunks |
| `:Paseo hunks` | Every hunk in the unit of work, as a quickfix list |
| `:Paseo stage` | Stage the hunk the quickfix list is on, then advance |
| `:Paseo review [unified]` | Diff panel, one tab per repo |
| `:Paseo repos` | The repos in the current unit of work |
| `:Paseo health` | `:checkhealth paseo` |

Default keys, all under `<leader>a`: `aa` changes · `aq` hunks · `as` stage ·
`ar` review · `au` review unified · `aR` repos · `aH` health.

## Tests

```sh
tests/run.sh
```

Builds real git fixtures and runs the suite in a real Neovim — no plenary, no
busted. Every assertion corresponds to something that was actually wrong at
some point, not to a line that wanted covering: the porcelain-v2 rename record,
beginning- and end-of-file deletions, a whole-file deletion, a pure rename, a
non-ASCII path, partial staging of one hunk among three, and the async-cwd race
in the diff panel.

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

**Finding it.** 6767 is the daemon's default port, not a constant. Candidates
are tried in order — `paseo.url`, `$PASEO_ENDPOINT`, `daemon.listen` from
`$PASEO_HOME/config.json`, then `127.0.0.1:6767` — each probed with `GET
/api/status`. A `401` counts as *reachable*: the daemon is there and wants a
password, and treating it as a miss is how you report "no daemon" about a
running one. `:checkhealth paseo` prints every candidate and its answer.

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

**A whole-file deletion cannot be staged through gitsigns at all.** The file
is gone from disk, so no buffer opens on it and nothing attaches — staging
silently does nothing. Found by staging every hunk we compute and checking the
index afterwards: it was the one case out of five that never landed. Those, and
untracked files, route to `git add`, which records a removal correctly.

**A hunk header omits a count of 1.** `@@ -2 +2 @@` means `-2,1 +2,1`. Reading
the missing count as 0 turns every single-line change into a phantom deletion.

**A rename's source must be in the pathspec too**, or rename detection has
nothing to pair the destination with and a pure rename reports as a whole-file
add.

**`gitsigns.stage_hunk()` races its own attach.** Staging from a list means
opening the file first, and gitsigns attaches asynchronously — called straight
after `:edit` it finds no cache for the buffer and returns *silently*. Four of
six hunks vanished that way. Staging therefore goes through a reconstructed
patch and `git apply --cached --unidiff-zero`, which needs no buffer at all.

**`:Gitsigns diff` reads `fn.getcwd()` inside its async body.** Opening one
panel per repo in a loop means every panel resolves against whichever tab was
current when its body finally ran — the last one. Two tabs, two `tcd`s, zero
panels. They have to be serialised on the callback.

**The public hunk type omits `.vend`.** Recompute it as
`added.start + max(added.count - 1, 0)` or pure-delete hunks are never found.

**`git status --porcelain=v2 -z` rename records carry an extra field.** A `2 `
record is followed by a NUL-separated `origPath`; a naive NUL split desyncs
everything after it.

## Roadmap

- **Phase 0 — Neovim config.** *(done; lives in the nvim config repo)*
  `word_diff`, `diff_opts.linematch`, `nav_hunk`-based motions, the `ih` text
  object, `preview_hunk_inline` and the diff panel on the preview/diff keys,
  and a deduplicated `<leader>g` group.
- **Phase 1 — the review loop, end to end.** *(in progress)* Review and explain
  are one phase, not two, because they are halves of a single loop: *find the
  hunk → read it → stage it, or ask about it → next hunk*. Splitting them ships
  half a loop twice — a quickfix list of hunks you cannot interrogate is the
  same dead end as an agent chat with no diff in front of it. So: changed-files
  picker, per-hunk quickfix, diff panel in a fresh tab with `tcd`, references
  from cursor / selection / hunk / file, the Bun sidecar, and a shared
  `explain-change` skill whose rubric ends in *what the reviewer should push
  back on*. The acceptance test is that the whole loop runs without leaving the
  quickfix list.
- **Phase 2 — `ws`, a Go CLI.** *Conditional.* Buys exactly one thing:
  concurrent isolated agents on a multi-repo project. Single-repo projects
  already get real worktree isolation from Paseo, and multi-repo projects
  already work for one agent at a time. Build it only if serialising agents
  becomes the bottleneck.
- **Phase 3 — workspace layer.** Workspace picker with a live, push-driven
  agent status column; a new Neovide window per workspace.
- **Phase 4 — commit, PR, merge.** Agent-agnostic skills over `ws … --json`.

## Licence

MIT.
