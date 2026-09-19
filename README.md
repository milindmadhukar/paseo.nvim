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

Everything in the plan is built and tested: the review loop, the explain
bridge, the `ws` CLI, the workspace layer, and the agent-facing skills.
57 Lua assertions and 4 Go tests, all green.

| | |
|---|---|
| ✅ | `repos.lua` — the repo list, workspace-aware |
| ✅ | `:checkhealth paseo` |
| ✅ | `:Paseo` command surface |
| ✅ | `git.lua` — status/diff parsing and hunk staging |
| ✅ | changed-files picker, hunk quickfix, diff panel |
| ✅ | 48-assertion test suite (`tests/run.sh`) |
| ✅ | explain bridge + Paseo sidecar (`bin/paseo-bridge.ts`) |
| ✅ | tool calls, reasoning and todos rendered in the transcript |
| ✅ | permission dialog — answer a prompt without the desktop app |
| ✅ | two surfaces: the sidebar pane and the full-screen dashboard |
| ✅ | workspace assembly — `ws`, a Go CLI |
| ✅ | workspace picker with a live, push-driven agent status column |
| ✅ | `workspace` / `workspace-commit` / `workspace-pr` skills |

## Install

`lazy.nvim`:

```lua
{
  "milindmadhukar/paseo.nvim",
  dependencies = {
    "nvzone/volt",
    "nvim-telescope/telescope.nvim",
    "lewis6991/gitsigns.nvim",
  },
  event = "VeryLazy",
  opts = {},
}
```

**No build step and no binary.** Everything is Lua, except the sidecar, which
is a single TypeScript file run by `bun` (or node ≥ 22) — no bundling, no
compilation, nothing to fetch from a releases page.

`VeryLazy` rather than `cmd = "Paseo"` matters for one small reason: lazy.nvim
has no checkhealth integration, so an unloaded plugin is not on the
runtimepath and a cold `:checkhealth paseo` answers *"No healthcheck found"*,
which reads like a broken install.

| Needed for | |
|---|---|
| Everything | Neovim 0.10+, `git` |
| The chat UI | nvzone/volt |
| The pickers | telescope.nvim |
| Staging and previews | gitsigns.nvim |
| Agents | the Paseo daemon running, and `bun` or node ≥ 22 |
| Pasting images | `wl-paste` (Wayland), `xclip` (X11) or `pngpaste` (macOS) |

Without a daemon the review half works unchanged and the agent half degrades
to the `local` backend rather than breaking. `:checkhealth paseo` reports
exactly which of these you have.

### The sidecar's one dependency

`@getpaseo/client` is installed on first use, into `sidecar/`. To do it ahead
of time:

```sh
cd ~/.local/share/nvim/lazy/paseo.nvim/sidecar && bun install
```

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
| `:Paseo chat` | Open/close the chat — conversation above, composer below |
| `:Paseo explain [kind]` | Explain the hunk/selection/file, using the rubric |
| `:Paseo ask [kind]` | Attach the hunk/selection/file, then type your question |
| `:Paseo qfask` | Attach every hunk in the quickfix list |
| `:Paseo image [path]` | Attach an image — the clipboard, or a file |
| `:Paseo mode` | Permission mode — plan, always ask, accept edits, auto, bypass |
| `:Paseo thinking` | Reasoning level for this session |
| `:Paseo fast` | Toggle fast mode (⚡), or pick another feature toggle |
| `:Paseo switchmodel` | Change the running session's model |
| `:Paseo session` | What this session is set to |
| `:Paseo dash` | The chat full screen, with the session panels |
| `:Paseo model` | Choose the provider/model new agents get |
| `:Paseo workspaces` | Workspace picker — open, sessions, create, archive |
| `:Paseo wcreate` | Create a workspace here |
| `:Paseo sessions` | Sessions in this workspace |
| `:Paseo ws …` | `init` · `create <name>` · `rm <name>` · `ls` · `status` |
| `:Paseo agent [stop]` | Sidecar and agent status |
| `:Paseo repos` | The repos in the current unit of work |
| `:Paseo health` | `:checkhealth paseo` |

Default keys, all under `<leader>a`. `aa` chat · `ae` explain · `ak` ask · `af`
ask about the file · `aQ` ask about the whole quickfix list — `ae` and `ak`
also bind in visual mode and send the live selection. Review: `ac` changes ·
`aq` hunks · `as` stage · `ar`/`au` diff panel. Session controls, the row under the composer in the app: `ap` mode · `ah`
thinking · `az` fast · `am` model · `a?` settings. Then `aw` workspaces · `aW`
new workspace · `aS` sessions · `at` agents · `aR` repos · `aH` health.

Everything in those pickers is **discovered from the daemon**. Modes are per
provider — claude has plan / always-ask / accept-edits / auto / bypass, codex
has auto / auto-review / full-access. Thinking levels are per *model*. Feature
toggles are per agent. Hardcoding any of it would be wrong on the next
provider.

### Images

`<C-v>` in the composer pastes the image on the clipboard. Neovim's own
clipboard is text — a screenshot copied from a browser never reaches a
register — so this shells out to `wl-paste`, `xclip` or `pngpaste` and reads
the bytes directly.

What lands in the buffer is a **placeholder**:

```
[Image #1] why is the right-hand panel empty here?
```

The bytes travel beside the prompt, not inside it, so the buffer stays
something you can read and edit, and the number is how a sentence refers to
one of several. `<C-v>` with no image on the clipboard does its ordinary job
instead of swallowing the key. `:Paseo image ~/shot.png` attaches a file, from
anywhere.

## Workspaces and sessions

Paseo's model, used directly:

| | |
|---|---|
| **Project** | a directory or repo Paseo knows about — `kora`, `openfin` |
| **Workspace** | one unit of work inside it, with a working directory |
| **Session** | an agent inside a workspace; several run at once, sharing its directory |

Isolation belongs to the **workspace**, not the session. Two sessions in one
workspace edit the same files on purpose — that is what makes "one agent
writing, another reviewing its diff" work. Two *workspaces* are isolated from
each other only when each has its own worktree.

**The conversation is two-way.** A prompt typed in the Paseo desktop appears in
the Neovim chat, and vice versa — they are the same timeline. Live events carry
a `seq`, which is what lets an overlapping history fetch and subscription render
each message exactly once instead of twice.

Paseo is the source of truth: a workspace created in the app appears in the
picker exactly like one this plugin assembled. What the plugin adds is what
Paseo cannot know — that a directory is several worktrees rather than one
checkout. That matters because `--isolation worktree` needs a git repository,
and a project like `~/Code/grasslabs/kora` is a plain directory holding five
repos. Paseo cannot isolate it; assembly can.

## Using it without the Paseo app

That is the point. The composer is a real Neovim buffer, the conversation is
the agent's actual timeline fetched on open, and the agent lives on the daemon
— so it survives closing Neovim and reopening the chat picks the conversation
back up. Paseo is the engine; you should not need to look at it.

## Tests

```sh
tests/run.sh
```

## Layout

```
lua/paseo/          the plugin
  workspace/        assembling N worktrees into one unit of work
  pickers/          changed files, workspaces
  backends/         the no-daemon fallback
sidecar/            paseo-bridge.ts and its bun deps
.agents/skills/     skills, symlinked from .claude/skills
tests/              fixtures + spec, run by tests/run.sh
doc/                :help paseo
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
            │ in-process                   │ stdio JSON-lines
            │                              │ (push, ~1–10 ms)
┌───────────▼──────────────┐   ┌───────────▼───────────────────┐
│ workspace/ (Lua)         │   │ paseo-bridge.ts (Bun sidecar) │
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
`$PASEO_HOME/config.json`, and `127.0.0.1:6767` *only* when no config named a
port. Each is probed with `GET /api/status`. A `401` counts as *reachable*: the
daemon is there and wants a password, and treating it as a miss is how you
report "no daemon" about a running one.

**Starting it.** If nothing answers, the plugin runs `paseo daemon start` and
waits for it to come up — so opening a chat works from cold. It only does this
when nothing answered: against a running daemon that command exits 1 and prints
a wall of logs. Set `autostart = false` to opt out. `:checkhealth paseo` prints
every candidate and its answer.

**The `paseo` CLI is never invoked** — but not because it is broken.
`/usr/bin/paseo` is a wrapper that runs the Electron binary with
`ELECTRON_RUN_AS_NODE=1`: headless, clean stdout, parseable `--json`. It just
still pays Node startup, about **1 s** against 8 ms for the socket, so
everything goes over the WebSocket.

Worth knowing because the symptom is confusing: `/opt/Paseo/Paseo` is the
*desktop* binary, and a stale symlink from a CLI-only install can leave it
shadowing `/usr/bin/paseo` on `$PATH`. Then a window opens and `--json` returns
Electron startup logs — which looks like a CLI defect and is not.
`:checkhealth paseo` reports which one you have.

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

**lazy.nvim resolves a plugin's Lua modules through its own loader**, so
`require` works long before the plugin directory reaches the runtimepath.
Anything that needs a *file* out of the plugin — the sidecar script here — has
to derive its path from the module's own `debug.getinfo` source, not from
`nvim_get_runtime_file`.

**`a and nil or b` does not work in Lua.** `true and nil` is `nil`, which falls
through to `or b`. Written as `message.ok and nil or message.error`, every
*successful* bridge reply came back as an error.

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
- **Phase 2 — workspace assembly.** Started as a Go CLI and is now
  `lua/paseo/workspace/`. The only argument for Go was concurrency across ~66
  git invocations, and `vim.system` gives that natively — so the binary bought
  a build step, a release pipeline and a second language for nothing.
- **Phase 3 — workspace layer.** Workspace picker with a live, push-driven
  agent status column; a new Neovide window per workspace.
- **Phase 4 — commit, PR, merge.** Agent-agnostic skills over `ws … --json`.

## Licence

MIT.
