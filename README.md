# paseo.nvim

Drive agents from Neovim. Ask one about the hunk under your cursor. Never
leave the editor.

Two problems, one plugin:

- **Reviewing.** Put the cursor on a hunk you cannot account for and ask an
  agent to explain it — including *which* agent wrote it and what it was told
  to do — without a context switch, and without being tied to one vendor. The
  review workflow itself (the picker, the quickfix list, staging) is yours to
  build; this plugin gives you [the data layer](#driving-review-from-your-own-config)
  and the agent.
- **Writing.** Agents step on each other. Git worktrees are the standard fix,
  but a worktree is *per repo*, and a real unit of work often spans several
  repos under a parent that is not itself a repo (`~/Code/openfin` → `clm`,
  `clm_api`, `fos-pwa`, `hipa-v2`, …). A **workspace** is that unit: one name,
  N worktrees, plus the untracked context they need to run.

Agents run on [Paseo](https://github.com/getpaseo/paseo), which already
abstracts Claude / Codex / OpenCode and owns agent sessions, status, and terminals.

## Install

`lazy.nvim`:

```lua
{
  "milindmadhukar/paseo.nvim",
  dependencies = {
    "lewis6991/gitsigns.nvim",
  },
  event = "VeryLazy",
  opts = {},
}
```

**No build step, no binary, no UI library.** Every surface is plain Neovim
buffers and splits. Everything is Lua, except the modular TypeScript
sidecar run by `bun` (or node ≥ 22) — no bundling, no
compilation, nothing to fetch from a releases page.

`VeryLazy` rather than `cmd = "Paseo"` matters for one small reason: lazy.nvim
has no checkhealth integration, so an unloaded plugin is not on the
runtimepath and a cold `:checkhealth paseo` answers *"No healthcheck found"*,
which reads like a broken install.

| Needed for | |
|---|---|
| Everything | Neovim 0.11+, `git`, a Nerd Font |
| The hunk under the cursor | gitsigns.nvim |
| Agents | the Paseo daemon running, and `bun` or node ≥ 22 |
| Pasting images | `wl-paste` (Wayland), `xclip` (X11) or `pngpaste` (macOS) |

Without a daemon the review half works unchanged — hunks, blame, staging and
`:Paseo explain` are all local git. The agent half is the part that needs one.
`:checkhealth paseo` reports exactly which of these you have.

### The sidecar's one dependency

`@getpaseo/client` is installed on first use, into `sidecar/`. To do it ahead
of time:

```sh
cd ~/.local/share/nvim/lazy/paseo.nvim/sidecar && bun install
# Without Bun: npm install
```

## Configuration

Defaults, all of which are read by something — a key lands here only once it
does:

```lua
require("paseo").setup {
  paseo = {
    -- url and home are absent by default: absent means "discover the daemon".
    -- Set url to pin it, e.g. "ws://127.0.0.1:6767/ws".
    prewarm = true,               -- a moment after startup, if a local daemon
                                  -- is ALREADY running, connect and fetch
                                  -- what the first open needs. Never starts
                                  -- one; never dials a remote host.
  },

  ui = {
    surface = "native",           -- where `:Paseo chat` opens: full screen,
                                  -- one Paseo tab, every agent a buffer.
                                  -- Or "sidebar".
    send_behavior = "steer",      -- sending mid-turn: "steer", "interrupt"
                                  -- or "queue". `g<CR>` does the other.

    style = "plate",              -- frame language. See "Style".

    colors = "auto",              -- derive from the colourscheme. Or "fixed".
    palette = {},                 -- the eight base colours, by name
    theme = {},                   -- highlight overrides, laid over the derived ones
    animate = {                   -- or `false` for instant
      bars = true,                -- ease a bar towards its new value
      flash = true,               -- tint a tool card as it settles
      fps = 30,
    },

    native = {                    -- the full-screen surface; see below
      markdown = true,            -- the agent's prose as raw markdown
      rail = 32,                  -- starting width; a dragged width is remembered
      panel = 56,                 -- the Settings/Changes/Usage split
      composer = 10,              -- rows the box may grow TO
      composer_min = 3,           -- ...and the fewest it rests at
      keys = {                    -- buffer-local; a key, a LIST, or false
        rail = "<C-b>", focus = "<C-h>", sessions = "<C-s>",
        panel = "<C-p>", new = "<C-n>",
      },
    },

    float = {                     -- (the name is historical)
      rail = {                    -- the workspaces down the left; see below
        enabled = true,           -- where it starts — the toggle is remembered
        show_background = false,  -- background workspaces, as the app hides them
      },
    },

    sidebar = {
      width = 40,                 -- percent of the editor's columns
      min_width = 60,             -- ...but never narrower than this, in cells
      composer = 8,               -- the MOST rows the composer grows to
      composer_min = 3,           -- ...and the fewest
      position = "right",         -- or "left"
    },

    terminal = {                  -- terminals are sessions; see below
      keys = { next = "<C-j>", prev = "<C-k>",
               chrome = "<C-g>",  -- out of terminal mode
               sessions = "<C-s>", terminal = "<C-l>" },
      presets = {},               -- extra entries for `c`
    },

    answer = {                    -- where you answer a question, or decide a plan
      width = 96,                 -- a CAP in cells, not a share of anything
      min_width = 54,             -- narrower than this and it centres on the editor
      backdrop = true,            -- dim the conversation behind it
      zindex = 190,               -- above everything; see below
    },

    pr = {                        -- pull request status, from `gh`; see below
      enabled = true,             -- false leaves the column out entirely
      ttl = 60,                   -- seconds an answer is reused, per branch
    },
  },

  voice = {                       -- dictation; see below
    enabled = true,
    key = "<C-t>",                -- in the composer; false binds nothing
    recorder = nil,               -- nil finds one; a table is a full argv
    rate = 16000,
  },

  workspaces = {
    dir = ".workspaces",          -- relative to a project root
    branch_prefix = "ws/",        -- used when there is no manifest to ask
    open = "tcd",                 -- what <CR> in the picker does: `tcd` this
                                  -- tab in. Or "tab", "cd", or a function --
                                  -- see below
  },

  review = {
    agents = true,                -- list the other Paseo agents working here,
                                  -- so the review agent can ask what they did
  },

  quit = {
    guard = false,                -- ZZ/ZQ and :q abbreviations: global, so opt-in
    warn_active_agents = true,    -- ...and with it on, warn while agents are active
  },

  -- Move or unbind any built-in key, by its DEFAULT: `false` unbinds,
  -- a key moves it, a list binds it on all of them.
  keys = {
    conversation = {}, composer = {}, rail = {}, panel = {},
  },
}
```

### Keys

**The plugin maps nothing globally.** Everything it binds is buffer-local, on
its own buffers; how you get *to* it is yours. Map the `:Paseo` commands, or
the `<Plug>` names that exist for it:

```lua
vim.keymap.set({ "n", "t" }, [[<C-\>]], "<Plug>(paseo-native)") -- in and out, full screen
vim.keymap.set("n", "<leader>an", "<Plug>(paseo-new)")           -- start something
vim.keymap.set("n", "<leader>ap", "<Plug>(paseo-panel-changes)") -- straight to Changes
```

**Every action of the Paseo tab is a function, a command and a `<Plug>`
name**, and each works from anywhere: away from the tab it goes there first,
and a toggle there *shows*.

```lua
local paseo = require("paseo.native") -- or require("paseo").native
paseo.toggle()             -- in and out                :Paseo native
paseo.open() / paseo.close() / paseo.code()  -- onto it, down, back to your code
paseo.toggle_rail()        -- the rail (<C-b>)          :Paseo native rail
paseo.focus_rail()         -- into it and out (<C-h>)   :Paseo native focus
paseo.panel("changes")     -- straight to a panel       :Paseo native panel changes
paseo.toggle_panel()       -- the panel (<C-p>)         :Paseo native panel
paseo.new() / paseo.worktree()  -- start something      :Paseo native new
paseo.next() / paseo.prev()     -- along the row        :Paseo native next
paseo.stop()               -- stop the turn             :Paseo native stop
```

`<Plug>(paseo-<action>)` exists for each (`paseo-rail`, `paseo-focus`,
`paseo-panel-usage`…). See `:help paseo-native-api`.

With `ui.native.hints.winbar` on, a key you map to one of them is shown where
it matters: the full-screen winbar names your `:Paseo native` key as the way
back to your code. And the surface's
own keys (`ui.native.keys`) take lists, so the rail can sit on your explorer
key — only in here:

```lua
ui = { native = { keys = { rail = { "<C-b>", "<leader>e" } } } }
```

## Commands

Two surfaces, and `ui.surface` names which one `:Paseo chat` opens: the
**full-screen** one (`"native"`, the default: one Paseo tab, every agent a
buffer in it) and the
**sidebar**, beside your code. `"float"` and `"buffer"` named the old volt
dashboard's two mounts and now mean the full-screen surface, so a config that
still says them keeps working.

`ui.surface` only decides where the first chat of a session opens. After that
the surface is yours, not the conversation's: switching workspace, picking a
session, `<C-s>` and reopening after a close all land on the surface that is on
screen, or else the one you last used. From the sidebar, `<C-f>` goes full
screen.

| | |
|---|---|
| `:Paseo chat` | Open/close the chat, on whichever surface `ui.surface` names |
| `:Paseo native` | Toggle the chat full screen: one Paseo tab, every agent a buffer — see [below](#the-chat-full-screen) |
| `:Paseo explain [kind]` | Explain the hunk/selection/file, using the rubric |
| `:Paseo ask [kind]` | Ask about the hunk/selection/file — a box takes the question |
| `:Paseo qfask` | Ask about every entry in the quickfix list — whoever built it |
| `:Paseo image [path]` | Attach an image — the clipboard, or a file |
| `:Paseo mode` | This provider's permission or operating modes |
| `:Paseo plan` | Toggle Plan: a Codex feature or Claude mode |
| `:Paseo thinking` | Reasoning level for this agent session |
| `:Paseo fast [feature_id]` | Toggle Fast, name another feature, or pick an available toggle |
| `:Paseo switchmodel` | Change the running agent session's model, or fork it |
| `:Paseo agent-settings` | What this agent session is set to |
| `:Paseo session` | Compatibility alias for `agent-settings` |
| `:Paseo dash` | Open the chat full screen (not a toggle) |
| `:Paseo buf` | Same as `:Paseo native` (`:Paseo tab` too): the old dashboard's names, kept |
| `:Paseo sidebar` | The chat in the pane beside your code |
| `:Paseo model [provider/model]` | Set the preference for new agents; no agent is created |
| `:Paseo workspaces [all]` | Workspace picker for this project (`<C-a>` or `all`: every project's) — open, inspect agent sessions, create, archive |
| `:Paseo new` | Start something: a chat (Local, a new agent in this workspace, or in a new worktree off a base branch) or a terminal — one screen |
| `:Paseo wcreate` | The same screen, opened on a new worktree (no name to type) |
| `:Paseo agents` | Agent sessions in this workspace |
| `:Paseo subagents` | Subagents of the chat's agent (`gs` in the chat), in a live list: a spinner and a clock on each running one, updated as they start and finish. A Paseo one opens as a chat you can message, a provider one (Claude's Task tool) opens read-only, live |
| `:Paseo sessions` | Compatibility alias for `agents` |
| `:Paseo term` | Into the rail, where this workspace's terminals are, under it |
| `:Paseo ws …` | Manifest-level: `init` · `edit` · `create <name> [repos]` · `rm` · `ls` · `status` |
| `:Paseo agent [stop]` | Sidecar and agent status |
| `:Paseo repos` | The repos in the current unit of work |
| `:Paseo health` | `:checkhealth paseo` |
| `:Paseo perf [reset]` | Where the time went: per-function and per-request timings since recording began (the first call turns recording on) |

Default keys, all under `<leader>a`. `aa` chat · `ae` explain · `ak` ask · `af`
ask about the file · `aQ` ask about the whole quickfix list — `ae` and `ak`
also bind in visual mode and send the live selection. The review keys (`ac`
changes · `aq` hunks · `as` stage · `ar`/`au` diff panel) are config-side now
and build on [the data layer](#driving-review-from-your-own-config). Agent controls, the row under the composer in the app: `ap` mode · `ah`
thinking · `az` fast · `am` model · `a?` settings. Then `aw` workspaces · `aW`
new workspace · `aS` agent sessions · `at` terminals · `aR` repos · `aH` health.

The model picker chooses a provider, then one of its labeled models. When a new
agent is needed, [one screen](#starting-a-session) sets provider, model,
permissions, reasoning and features before creation — `c` creates, `q` cancels.
Opening an existing chat reuses it only when it matches the
selected provider and model. Modes are per provider: Codex reports Default,
Auto-review, and Full Access; its Plan and Fast controls are separate features.
Claude reports Plan as a mode. Reasoning and creation-time feature choices come
from the selected model.

Changing a live agent's model asks what the change means. **Fork into a new
session** and **Fork into a new workspace** both leave the source untouched and
start a branch on the selected model — they differ only in where it runs; **Use
for this agent's future turns** changes the existing agent; Cancel does neither.
Values that the target model does not support are replaced with that model's
defaults.

### Forking

In either chat buffer, press `f` in normal mode — both surfaces advertise it on
their hint bar — to fork the complete conversation available at that moment.
On the rail, `f` forks the agent under the cursor, whichever one is on screen.
The first question is where it goes, because it is the only one whose answer
changes anything on disk:

```
Fork "otp rate limit" into…
  new session     here, beside this one
  new workspace   a directory of its own
  cancel
```

Both carry the same conversation. A **new session** is a second agent in the
workspace the source is already in: it starts immediately, and the two share
the checkout, so they can edit the same files. A **new workspace** asks for a
name and creates the appropriate local/worktree/assembled workspace first, so
the fork gets files of its own.

Either way Paseo supplies the chat-history attachment, the plugin asks for the
fork's first prompt, and the agent is created with that prompt and attachment
atomically. A host without the `agentForkContext` capability is rejected before
anything is created. If agent creation fails after a workspace was created for
it, that empty workspace is retained and named in the error.

### Messages from other agents

When another agent sends this one a message (one agent steering another
through Paseo's tools), or the daemon tells it that a child agent finished,
failed or needs a permission, the chat draws it as a message with its sender,
as `you` is drawn for yours:

```
▌ 󱙺 from Planner
▌ the schema is ready for review
```

These used to arrive as an empty tool card called *Agent message*. The sender
and the words were on the item, and nothing read them.

### The header

The header says what the session *is*:

```
─ codex/gpt-5.6-sol · Auto-review · 󰅙 #412 checks failing · 󰧑 high · 58% left · ~/Code/paseo.nvim ──── ⠹ 28m 49s ─ ⏎ send ─
```

While a turn runs, a spinner and an elapsed count say what it is *doing*, on
the same row — **on top of the box**, because what you are waiting for is the
answer to whatever is in it:

```
─ claude/sonnet-5 · acceptEdits · 58% left · ~/Code/kora ────── ⠹ 28m 49s ─ ⏎ send ─
```

The count is the point: a static dot looked identical at two seconds and at two
minutes, so a wedged turn and a working one were the same picture. It is
humanised for the same reason — `1729s` is arithmetic homework, `28m 49s` is a
duration. Past an hour the seconds are dropped (`1h 24m`); at that scale they
are noise, and dropping them stops the field growing a third segment that
shifts everything beside it.

It sits in a **fixed-width slot**, which is the answer to the reason it used to
live at the bottom of the screen: it is the one field on the row that changes
ten times a second, and among static ones it pushed everything beside it
sideways every time the count gained a digit. Given ten columns whether it
needs them or not, it cannot.

The conversation says it too: while the agent works, a `⠹ thinking…` line sits
**under the last block**, follows the reply down as it streams, and goes when
the turn ends or the agent stops to ask you something. It is there for the wait
before the first word: with the rail shut, the gap after a first message used
to show nothing at all in the conversation. A chat opened onto an agent that is
already mid-turn (a new worktree's first agent, a running one opened from the
rail) shows it as well, on the agent directory's word.

A pending permission shouts from the header itself — ` needs you` — because
then the agent is not working, it is waiting for you.

A **subagent's** request is answered in its parent's chat. A Paseo subagent (an
agent another agent started through Paseo) has a timeline of its own that
nobody has open, so its requests are relayed into the parent's chat, marked
`asked by subagent <title>`, and the answer goes back to the subagent.

**It is drawn against the box you type in**, one row above it, on both
surfaces. That is a move: it used to live at the far top of the screen — a
winbar over the transcript — which is as far from the cursor as that screen
goes. You decide
what to type with those five facts and you decide it while looking at the
composer, so they belong there. It doubles as the composer's title row, which
is what lets the box drop its drawn border and be a plate like everything else
([below](#the-composer)).

**It is only ever this row.** The panel that can change any of these facts is
[Settings](#the-settings-panel), `<C-p>` then `1`.

**The row is also the box's top edge.** Without a frame the composer was a slab
of card colour with a row of text on it, and on a theme whose elevation tiers
sit close together that is not a box — it is the same screen, slightly
different. A rule of its own would cost a row of the transcript to say
something that is true the whole time, so the bar *is* the rule: it starts and
ends on a hairline and the words sit on it, the way a title sits on a frame.

**It degrades by dropping whole facts, not by cutting the row.** A sixty-column
sidebar cannot say all of it, and `truncate` cuts from the right, which is
where the working directory is. So it gives up what it can spare, cheapest
first — the feature toggles, then the thinking level, then the context figure,
then the model and the [pull request](#pull-request-status). Shortening is
tried only once there is nothing cheaper left to drop: `~/Code/paseo.nvim`
beats `paseo.nvim`, `#412` beats `#412 checks failing`, and `paseo.nvim` beats
no directory at all.

```
─ Plan Mode · paseo.nvim   ⠹ 1m 12s ─ 󰌑 / Alt + 󰌑 send ─
```

Nothing outranks a pending permission, which is never dropped at any width.

The row at the top of the sidebar is left saying which session you are looking
at, with the surface's own keys on the end of it.

### Pull request status

`git status` says what you changed. This says whether what you already pushed
passed, whether anyone reviewed it, and whether it landed — the question you
have when an agent tells you it opened a PR and you are sitting in Neovim with
no browser open.

It comes from `gh pr view`, which already knows which pull request belongs to
the branch you are on, which remote is GitHub, and how you are authenticated.
Nothing here owns a token.

It shows up on the composer's bar, beside the model and the working directory,
so it is on screen the whole time you are working.

**One word for N repos.** A unit of work spanning six repos has six pull
requests and the question is still singular — *is this landable* — so the worst
state wins:

```
󰅙  #412 checks failing      a check has failed, errored or timed out
󰀦  #412 changes requested   a reviewer has asked for something
󰦖  #412 checks running      still going
󰓂  #412 draft               a draft, and nothing is wrong with it
󰓂  #412 in review           waiting on a reviewer
󰗠  #412 approved
󰘭  #412 merged              it landed
```

Above one pull request there is no single number to give, so the row says
`3 PRs` — or `1/2 merged` while a unit of work is landing repo by repo, which
*is* the status when it is true. Merged gets a glyph of its own rather than
only a colour, because colour alone does not reach a reader who cannot tell
green from amber.

A repo with no pull request, no GitHub remote, or no `gh` says **nothing** —
the column is absent rather than drawing `none` on every row. Most branches
most of the time have no pull request, and a column that is always there to say
so has made every row wider in order to say nothing.

Everything else in this plugin is pushed from the daemon at about a
millisecond. This is a subprocess and a round trip, so it is cached per repo
*and per branch* and refreshed at most once a minute (`ui.pr.ttl`); the branch
underneath it is re-read every two seconds, which is local, so switching branch
is noticed straight away. `ui.pr.enabled = false` turns the whole thing off.

### The chat, full screen

The default surface. `:Paseo chat` and `:Paseo native` toggle you **in and
out** of it: from your code to **the Paseo tab**, and from there back to the
tab you came from. Coming back lands on it as you left it, with whatever was
in the middle still there (`q` is what closes it). `:Paseo buf` and
`:Paseo dash` open it too, so keys bound to the old names keep working. There
is **one** Paseo tab, never one per agent: your code and Paseo, two tabs, and
the toggle moves between them so you never `gt`. Every pane is a **real
split**. `<C-f>` goes here from the sidebar; `<C-c>` stops the turn, from the
composer or the conversation, normal mode or insert.

```
┌ rail ┬ conversation  (winbar: agent · ⠹ 14s)        ┬ panel ┐
│      ├ composer      (its bar: model, mode, spinner)  │       │
```

- **The conversation is markdown.** With `ui.native.markdown` (the default)
  the agent's prose is written as raw markdown and soft-wrapped, so
  treesitter, and render-markdown.nvim if you have it, draw headings, code
  fences, lists and tables. Tool cards, thinking and permissions keep their
  usual look. Code keeps its indentation.
- **[The rail](#the-workspace-rail)** is down the left: the project's
  workspaces, each opening into its agents, subagents and terminals.
- **`<C-p>`** opens a split on the right and puts you in it, on the panel you
  last looked at. **`1` `2` `3`** in it jump straight to Settings, Changes or
  Usage, and its bar shows which is which. `<C-p>` again closes it.
- **`<C-n>`** starts something, from any of these buffers in normal mode:
  the [new-task screen](#starting-an-agent-session) — a chat (Local, beside
  this one, or in a new worktree named for you), or a terminal — with every choice prefilled from
  last time and the box ready to type in.
- **What is current is what is in the middle.** The agent in the middle
  window is the one `:Paseo mode`, `:Paseo stop` and the rest act on.
- `q`, or `:q` in the conversation or the box, closes the Paseo tab. The
  agents and your drafts live on.
- **One background for every pane.** It is your editor's own with
  `ui.colors = "auto"` and the plugin's with `"fixed"`, the same across the
  Paseo tab either way. Only the box you type in is a step raised.

#### Every agent is a buffer

The Paseo app shows the agents you have open as a row of tabs over the chat.
Here that row is **your bufferline**: every agent and terminal **you open** —
from the rail, the picker, anywhere — is a **listed buffer**
(`paseo://agent/<title>`, `paseo://terminal/<name>`), so a bufferline shows
them by name, in the order you opened them, and you move between them the way
you move between any buffers. Agents of different workspaces sit side by
side: **nothing is opened for you, and nothing is closed for you.**

- **The middle window swaps buffers.** `:bnext`, `:b N` or a click on the
  bufferline puts another agent there, and its composer, its keys and the
  rail's highlight come with it. A buffer key pressed in the box sends the
  agent to the middle and leaves the box its composer.
- **Nothing loads until you look.** An agent's history is fetched the first
  time its buffer is shown; a terminal's buffer becomes the live terminal the
  first time you enter it, keeping its place on the row. A terminal in the
  middle puts the composer away; going back to an agent brings it back.
- **Another workspace is one more buffer.** Opening an agent of another
  workspace — on the rail, or in the picker while you are on the Paseo tab —
  adds it to the row beside the rest. The Paseo tab's directory (`tcd`)
  follows whichever agent is in the middle. An agent started elsewhere — the
  app, the CLI — shows up on the rail, and is on the row once you open it.
- **Each agent keeps its place.** Scroll up in a transcript and it stays
  there — new output does not drag you down, and switching to another agent,
  workspace or window and back finds it where you left it. `G` to the bottom
  and it sticks again, following what the agent writes next. An agent you
  were following while it was off screen comes back at its new end.
- **Leaving the Paseo tab unlists the row**, so agents never show up among
  your code's buffers; coming back lists them again.
- **A subagent is a peek.** Opening one (from the rail or `gs`) shows it in
  the middle window in place of its parent, unlisted — it is not one of the
  workspace's agents — and `q` goes back to the parent.
- **`:bdelete` on an agent** takes just that one off the row, and the
  neighbour takes the middle; backing out of a new task does the same. The
  agent itself lives on, on the rail.
- **An archived agent's buffer closes by itself**, the same way — whoever
  archived it: the rail's `d`, the app, the CLI, another agent, or while
  Neovim was disconnected (a fresh snapshot without it says so). A message
  names it; the last one going takes the Paseo tab with it.

A bufferline that keeps a buffer list per tab page — NvChad's tabufline, with
its `t:bufs` — shows the agents on the Paseo tab and your files on yours with
nothing to configure. Map your next/previous-buffer keys to the bufferline's
own per-tab functions rather than plain `:bnext`, which cycles every listed
buffer in Neovim:

```lua
vim.keymap.set("n", "<S-l>", function() require("nvchad.tabufline").next() end)
vim.keymap.set("n", "<S-h>", function() require("nvchad.tabufline").prev() end)
```

**The row starts past the rail**, the way it starts past nvim-tree, if you tell
your bufferline about it — the rail's filetype is `paseo-rail`, and the plugin
redraws the tabline whenever the rail opens or closes. bufferline.nvim:

```lua
options = { offsets = { { filetype = "NvimTree" }, { filetype = "paseo-rail" } } }
```

NvChad's tabufline knows one filetype (`treeOffsetFt`), so replace its
`treeOffset` module in `chadrc.lua`:

```lua
tabufline = {
  modules = {
    treeOffset = function()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local ft = vim.bo[vim.api.nvim_win_get_buf(win)].ft
        local hl = (ft == "NvimTree" and "NvimTree") or (ft == "paseo-rail" and "PaseoTree")
        if hl then
          return "%#" .. hl .. "Normal#" .. string.rep(" ", vim.api.nvim_win_get_width(win))
            .. "%#" .. hl .. "WinSeparator#│"
        end
      end
      return ""
    end,
  },
},
```

The panels:

| | |
|---|---|
| `Settings` | mode, thinking level, model, feature toggles |
| `Changes` | what is changed on disk, per repo; `<CR>` opens one with your code: on the tab you came from, with `:edit` |
| `Usage` | context window, tokens, cost, and this provider's 5-hour and weekly limits |

`Changes` takes the list keys: `j`/`k` to move, `h`/`l` by section, `g`/`G`
to the ends, `<CR>` to open, `r` to re-fetch. **The focused row is painted**,
and focus is held by **id**, so a list that moves under you (these are
push-fed) does not take it with it. Every workspace Paseo knows is
`:Paseo workspaces`, a picker.

**No UI library.** This replaced a dashboard drawn by nvzone/volt: a float
(or a borrowed window) of tabs over floated panes. Everything it showed is
here as splits, popups and dialogs are plain windows, and the plugin needs
nothing to draw any of it.

**A popup keeps its own buffer.** Every Paseo float is opened with
`'winfixbuf'`, so a buffer command run inside one — `:bnext`, `:b N`, `<C-^>`, a
tabufline/bufferline key — is refused (`E1513`) instead of loading an agent into
the popup's window. A permission request that pops up while you are cycling
buffers takes the cursor, and the next "next buffer" key no longer replaces it.
To make that key silent rather than an error, have your mapping do nothing
when `vim.api.nvim_win_get_config(0).relative ~= ""`.

#### The workspace rail

Down the left of the Paseo tab: each workspace in the project you are
standing in, and what its agents are doing — the desktop app's sidebar, and
laid out as it is: the project's tile and name at the top, then one row per
workspace with its lines changed at the right, and a workspace's agents,
subagents and terminals under it, **nested by indentation alone** — no
arrows, no folder icons.

**Every row leads with one status slot**, as the app's does: one cell, one
plain character, never a nerd-font icon (a terminal like Ghostty lets those
spill into the next cell and swallow the gap after them).

| | |
|---|---|
| `⠋` spinner | working — or a subagent is, after its parent's turn has ended |
| `!` (warning colour) | waiting on you: a permission, or a question |
| `✗` (error colour) | a turn failed |
| `•` (accent) | finished while you were elsewhere |
| `•` (faint) | done — kept so the column of statuses still has an edge |
| `$` | a terminal |

A workspace shows its **most urgent** agent, so one waiting on you among three
running shows the `!`. Only its **own** agents count, matched by workspace
id: every agent the app starts in a checkout gets a workspace of its own on
that same directory, and one running agent spins only its own row. **The
session on screen** has its title in `Special`, and so does its workspace
while that is folded.

What the app's row says goes on the row: the **lines the workspace has
changed** against its base branch (`+120 -7`, right-aligned), and on a line
under it, when there is one, its **pull request and CI** — `#128 · ● 3/5`
while checks run, `✓ passed`, `✗ failed`, `approved` or `changes requested`,
`merged` or `closed` once it is done. All of it is the daemon's, pushed as it
changes: the diff stat on every save, the pull request every twenty seconds
while a check is pending.

```
   P   paseo.nvim                  5

  !  rail-spinner-fix      +75 -51
     #131 · ✗ failed · changes…
  ⠋  main               +1240 -386
     #128 · ● 3/5
    ⠋  nvim-tree style rail
      •  Study nvim-tree rendering
      ⠋  Research Paseo app sidebar
    •  review the sidecar diff  +1
    •  docs sweep
    $  zsh

  ✗  upstream-0.16          +12 -0
     #120 merged
  •  voice-mode-experiment
```

**The rail's colours are its own**, and it needs no other plugin. It sits a
shade darker than the panes beside it, derived from your colourscheme the
way an explorer sidebar is (catppuccin's mantle under its base), one
background top to bottom, with `CursorLine` for the cursor band, the line the conversation draws against
the panel on its edge, and the diagnostic colours for status. It looks the
same whether or not you have nvim-tree. The groups are `PaseoTree*`, and
`ui.theme` overrides any of them.

The workspace on screen is open and the rest are closed until you open them;
an agent's subagents are open while one of them runs, and folded once they
are done, with how many after its title (`1/3` while some run, `+3` after). Both
kinds hang off their parent, and both open as a **peek** in the middle
window, in place of the parent and off the row of buffers (`q` goes back): a
**provider** subagent (Claude's Task tool) read-only, a **Paseo** subagent (an
agent another agent started) with its composer, so you can talk to it. The cursor
band only ever says where the cursor is. A workspace's agents are its own, by
workspace id, so two workspaces on one checkout do not mix them.

**Every real line is a row.** The pull request line, "no sessions yet" and
the key hints (if you turn them on) are virtual lines, so `j`/`k`, counts, `gg`/`G` and `/` are Vim's
own and never stop on decoration. The cursor sits on the title, as nvim-tree's
`hijack_cursor` keeps it, and stays on the row it was on when rows above it
come and go.

`<C-b>` shows and hides the rail, and the choice is remembered across restarts.
The cursor goes with it, as with nvim-tree: showing the rail puts the cursor in
it, on the session in the middle, and `<C-b>` there hides it and returns you to
the window you came from; hidden from anywhere else, the cursor stays put.
`<C-h>` moves into it, showing it first if it was hidden; **`<C-s>`** moves
into it **on the session on screen**, unfolding what it is under — from the
composer in either mode, from a terminal, and from every other buffer of the
surface. Inside it, nvim-tree's keys where it has one for the job — a
workspace and an agent with subagents fold as nvim-tree's folders do (`g?`
lists them):

| | |
|---|---|
| `<CR>` / `o` | on a session, put it in the middle (a subagent as a peek; another workspace's swaps the row); on a workspace, fold or unfold it |
| `l` | unfold; on something open, step onto its first row; on a session, open it |
| `h` / `<BS>` | fold; on a row that does not fold, fold the one it is in and land on it |
| `<Tab>` / `za` | fold or unfold |
| `O` | open the workspace as a place: its newest agent, one more buffer on the row |
| `P` / `<` `>` / `K` `J` | the parent; the previous and next sibling; the first and last |
| `W` / `E` | fold everything (the cursor stays in its workspace); unfold everything |
| `a` / `w` / `t` | a new agent in the workspace under the cursor (on any of its rows), an agent in a new worktree, a terminal (`c` too) |
| `f` | fork the agent under the cursor: same conversation, beside it or in a worktree of its own (asks which) |
| `y` / `R` / `d` | copy an agent's ID, rename a terminal, archive an agent or kill a terminal (asked first) |
| `.` / right-click | what you can do to the row under the cursor, as a menu, each with its key |
| `m` / `r` | pin a workspace, refetch the list |
| `g?` | the keys |
| `q` / `<Esc>` / `<C-h>` / `<C-s>` | back to where you were typing |

It is 32 cells wide by default (`ui.native.rail`; `0` starts it hidden).
`ui.float.rail.indent_markers = true` draws nvim-tree's `│ └` down the left
of a workspace's sessions.

**Key hints are off by default.** `ui.native.hints = { winbar = true, rail =
true }` (or just `hints = true`) puts `code  panel  rail  close` on the
conversation's winbar and `a new  w worktree  . actions  g? keys` under the rail. `g?`
in the rail lists its keys either way.

**Pinned workspaces lead it**, with a pin. `m` pins or unpins the one under the
cursor. The pin is the daemon's, so it is the same pin the app's sidebar
shows, whichever side set it. **Background workspaces**, which agents and
plugins make for themselves, are hidden the way the app hides them unless
"Show background" is on. `ui.float.rail.show_background = true` shows them.
A pushed change to a workspace is written over its row in place; one that
moves it (created, archived, pinned, or **titled**) refetches the list, so a
generated title appears when it is written rather than on the next poll.

#### The composer

The box you type in **grows with the prompt**, between `composer_min` and
`composer`, and shrinks back when you send:

```
─ claude/claude-opus-5 · Plan Mode · 71% left · ~/Code/paseo.nvim ───── ⠹ 1m 9s ─ 󰌑 / Alt + 󰌑 send ─
 why is the ref suite opening a file it then deletes?
```

Standing at its configured height over an empty buffer made it the largest and
emptiest shape on the screen: seven rows of flat card colour, nothing saying
you could type in it. Resting at *one* row is the same mistake the other way
round — that is the shape of `:e `, not of the place you write a paragraph,
and it is where every session starts. So the floor is **three**
(`composer_min`, 1 for the old behaviour).

The ceiling is `composer`: `ui.native.composer` on the full-screen surface,
`ui.sidebar.composer` beside your code.

Wrapped lines count towards the height — `wrap` is on, so a 300-column
paragraph is four rows on screen, and asking the buffer for its line count
would say one and leave the cursor off the bottom of the box.

**The text above the cursor stays on screen.** The box is resized from
`TextChanged`, which fires *after* Neovim has already scrolled: press `<CR>` in
a one-row box and line 1 goes above the top of the window to keep the cursor
visible, and only then does the box grow. Neovim never scrolls back —
`update_topline` scrolls as far as it must to keep the cursor visible, and the
cursor already is — so the box grew and the line you had just typed stayed the
only one you could see, with everything above it still in the buffer, still in
the send, and invisible. Whenever the whole draft fits, the box is scrolled to
the top of it; past the ceiling it is a viewport onto something longer than
itself and Neovim's own behaviour is the right one.

**No box drawn around it, under `plate`** — which is the default, and where
nothing else on the surface has an edge either. A hard rounded rule around the
composer, inside a window whose own edge is invisible, above cards with no
frames, was the one thing on the surface that ignored `ui.style`. What
separates the box from the transcript now is what separates every other card
from it: one tier of elevation, and a title row. Under `rounded` and `square` it
keeps a real frame, because that is what those styles are for.

The title row is [the header](#the-header), and it ends with **how to send**.
Both keys, because they are not interchangeable: `<CR>` sends from normal mode
and opens a line from insert mode, so the one that works while you are still
typing is `<M-CR>` — Alt and Enter. (`<C-CR>` is bound beside it for terminals
that speak the kitty keyboard protocol; the ones that do not simply never send
it.) **`<C-s>` is not either of them.** It means *the session list* in the
rail and in every terminal — so a composer that quietly sent on it was one
key with two meanings, both advertised on screen at once. From the composer it now does what it does
everywhere else: takes you to the session on screen, in [the rail](#the-workspace-rail).

**While the agent is working**, the hint changes to say what sending will
*do*: `󰌑 steer · g󰌑 queue`. Mid-turn, the daemon's own default is to
**interrupt**, so a follow-up typed here while the agent worked used to stop
it. Now `<CR>` **steers** by default, as in the Paseo app: the message is
folded into the running turn. Set `ui.send_behavior` to `"interrupt"` for the
old behaviour, or to `"queue"` to hold the message until the turn ends.
`g<CR>` (and `<S-CR>`, where the terminal can tell it apart) does the
opposite: it queues when you steer and sends now when you queue, like
long-pressing Send in the app. A queue is counted on the bar (`2 queued`) and
sent as one message when the turn **completes**. It is kept, with a warning,
when the turn fails or is stopped. While the agent is waiting on a permission,
a queued message would never go, so queue interrupts instead.

**`<Up>` in an empty composer** brings back the last prompt you sent this
agent, and again for the one before. `<Down>` walks back to an empty box.
Prompts sent from the Paseo app are recalled too, because the list is read
from the transcript. In a box where you are writing, they are just the arrow
keys.

**The composer is the size of what is in it**, on the sidebar as well as the
full-screen surface. `composer_min` rows over an empty buffer, growing as you type up to
`composer`, shrinking back when you send — measured in *screen* rows rather
than buffer lines, because it soft-wraps and one pasted sentence is three rows
in a narrow pane. A fixed eight rows in the sidebar was a third of that pane
spent on whitespace for the whole of a session.

**The sidebar takes the same units**, under `ui.sidebar`: `width` as a
percentage, `min_width` as a floor in cells (40% of a 100-column terminal is a
pane too narrow to read a tool card in, and a percentage has no way to know
that), `composer` and `composer_min` in rows, and `position` for which side it
opens on. Its
width is also capped at what `'winwidth'` leaves for the window you came back
from — Neovim claws the difference back the instant focus returns there, so a
bigger number is not a wider sidebar, it is a number that quietly does not
happen.

### The Settings panel

Everything this agent session is set to, at once, with the current value **filled in**
rather than marked with a dot:

```
  󰌾  Permission mode   m
   Plan   Always ask   Accept edits   Bypass
  Edits are applied without asking.

  󰧑  Thinking   t              󰥕  Features   f
   Off   Think                  Fast mode

  󰧑  Model   s
  ● Opus 5                                     default
  ○ Sonnet 5

   h j k l  move    󰌑  apply    m t f s  group    r  reload
```

Each block above is a **card**, and on the default `ui.style` a card has no
frame at all: it is a plate one elevation step above the surface, with a row
of padding top and bottom. `ui.style = "rounded"` puts the boxes back.

`h`/`j`/`k`/`l` move — all four directions, and running off the end of a card
lands on the next one, so there is one traversal rather than one per card.
`m` `t` `f` `s` jump to a group, and the letter is printed **on the card** so
the key is where you are already looking. `<CR>` applies.

In **the rail**, `y` on an agent copies the selected agent's complete ID to the
unnamed register and, when available, the system clipboard. The agent picker
uses `<C-y>`. Terminal rows deliberately have no copy-agent-ID action. To ask
one agent to contact another, copy the receiving agent's ID, paste it into the
sending agent's chat, and ask it to use Paseo's
[cross-agent prompt tool](https://paseo.sh/docs/orchestration-workflows#send-a-prompt-to-another-agent).

Focus is *ours*, held on the entry rather than the cursor, so redrawing the
panel never moves it.

`bypassPermissions` is red and `acceptEdits` amber. Until now every mode was
the same colour, so *"nothing asks, everything runs"* looked identical to
*"research and write a plan"*.

The description belongs to whatever is **focused**, not to every row — one line
that changes as you move, rather than five stacked lines you read once. And the
layout is measured before it is drawn: on a short editor the cards drop their
internal padding so the whole thing still fits, which on 80×24 is exactly the
difference between seeing the model list and not.

The same cards open on their own — `:Paseo mode`, `:Paseo thinking`,
`:Paseo switchmodel`, `:Paseo agent-settings` (`session` remains an alias) —
centred, with `q` to close. Those used
to be `vim.ui.select` lists of strings with a `●` glued to the front of one of
them, formatted independently of the panel that drew the same four settings.
There is one renderer now, and one place a change is written.

### Starting an agent session

**Only where there is none.** `:Paseo chat` first asks the daemon what is
already running in this directory and opens that — the session you started in
the Paseo app counts, tabs and all. It used to look only for sessions this
plugin had created *and* on the model `:Paseo model` was set to, so opening
the chat in a workspace with two live tabs in it offered to start a third. A
session of this plugin's own is still preferred over the app's, and the model
you are set to over one you are not; beyond that, whichever was touched last.

**One screen.** When the answer is genuinely nothing — and whenever you ask
for something new (`<C-n>`, the rail's `a` `w` `t`, `:Paseo new`,
`<Plug>(paseo-new)`) — you get the **new-task screen**: the composer you will
keep typing in, focused and in insert mode, with the choices drawn above it
where the conversation will be:

```
  Start        a   [Chat]  Terminal        Where  w   [Local]  New worktree
  Base branch  b   [main]  dev  feat/login  …            (a worktree, in git)
  Provider p · Model s · Permission mode m · Thinking t · Features f
  ─────────────────────────────────────────────────────────────────────────
  ▌ Fix the flaky login test on CI
```

Type and send. The first message creates the agent — and for **New
worktree**, the worktree with it — with your message as its first prompt.
**Nothing is asked that Neovim already knows:** the project and host are
where you are standing, and a new worktree is **not named by you**: the daemon
names it and its branch (`frail-squid`) and titles the workspace from your
message, as the app's New workspace does. *Where* only appears where
something can be isolated (a git checkout, or a [multi-repo
project](#workspaces)); *Base branch* defaults to what is checked out, and
`…` on it picks any branch, local or remote. A
**Terminal** needs no prompt: `<Tab>` up to the choices and `<CR>` on what to
run — a shell, `claude`, `codex`, `pi`, any provider the daemon has, your
`ui.terminal.presets`, or a command you type.

**Everything is remembered** — chat or terminal, Local or a worktree, the base,
the provider and model, mode, thinking, features, the terminal you ran — per
project and host, and prefilled next time. Nothing is written until something
is created.

In the choices `h` `j` `k` `l` move, `<CR>` applies, the letter on a card
jumps to it, `i` or `<Tab>` returns to the box and `q` cancels. *Local* is the
app's word for it: a **new agent in the workspace on screen**, joined by id, so
it lands beside the first and shares its files; the draft becomes that agent
in place. A new worktree's agent, and a terminal,
open on tabs of their own.

An *automatic* open never reaches any of this: following a workspace switch
passes `create = false`, so a workspace with no agent says so rather than
putting a modal in front of someone who only changed directory.

The new-agent screen **takes the cursor when it opens** — it is a question, and
a question you have to click before you can answer is a worse question.

Starting an agent where there is none opens **that same renderer** over an
agent session that does not exist yet. Two more cards, because provider and model are
settings here and are not settings on a running agent:

```
  ╭─ 󱚠  Provider   p  ────────────╮  ╭─ Permission mode   m  ─────────╮
  │   Claude   Codex              │  │   Plan   Always ask   Bypass   │
  ╰───────────────────────────────╯  ╰────────────────────────────────╯

  ╭─ Model   s  ──────────────────────────────────────────────────────╮
  │  ● Opus 5                                                default  │
  │  ○ Sonnet 5                                                       │
  ╰───────────────────────────────────────────────────────────────────╯

  ╭─ 󰧑  Thinking   t  ────────────╮  ╭─ ⚡  Features   f  ────────────╮
  │   Off   Think                 │  │    Fast mode                   │
  ╰───────────────────────────────╯  ╰────────────────────────────────╯

   c   create agent                                  claude/opus-5

   h j k l  move   ⏎  apply   p s m t f  group   r  reload   c  create
```

`c` opens the chat on these settings, `q` cancels. Even `c` creates nothing;
the first message does. There is no
Create *card*, because a card that is not a setting reads as one.

**The screen is the picker.** Choosing a provider used to be two
`vim.ui.select` prompts *before* you saw anything, and what you saw afterwards
was a plain buffer — `Provider        Claude`, formatted with `%-15s`, no
highlights — with another `vim.ui.select` behind every row. It was the only
screen in the plugin that was not drawn by the renderer every other screen
uses, and it looked it.

Changing provider, model or mode re-asks the daemon what **features** that
combination supports, because they are per model and per mode both. The card
holds the height it had while that is in flight, so the cards below it do not
jump — and a reply for a choice you have since changed is dropped rather than
applied, which is what two quick mode changes used to produce.

### Terminals

Paseo runs terminals as well as agents — the `claude` and `codex` sessions you
started in the app are PTYs on the daemon — and **a terminal is a session.** It
lists on [the rail](#the-workspace-rail), under its workspace, and it is **a
buffer on the row** like an agent: opening one puts the terminal in the middle
of the Paseo tab, the composer put away while it is there.

It used to be a surface of its own — a rail of names, a title bar, the terminal
and a backdrop, floated over whatever you were looking at, with its own
geometry and keymaps. That shape was
[floaterm](https://github.com/nvzone/floaterm)'s, and it was the wrong one to
borrow: a terminal you open a second application to reach is not a session, it
is a place you get stuck.

**A terminal takes every key, and that is what it is for** — so the handful it
does not take are your whole way out. They are bound in **terminal mode as
well as normal**, or each would start with `<C-\><C-n>`, and they are
Neovim's own moves:

| | |
|---|---|
| `<C-g>` | out of terminal mode, into normal mode, without closing anything |
| `<C-l>` | back into the terminal |
| `<C-j>` / `<C-k>` | the workspace's next and previous buffer: the next agent or terminal |
| `<C-s>` | into the rail |
| `q` | (normal mode) back to the agent; the terminal lives on, on the daemon |

Binding them in terminal mode takes them from whatever is running inside,
which is right for `claude` and wrong for `tmux`, so `ui.terminal.keys` renames
or disables any of them. `<C-c>` is not bound: it is SIGINT and belongs to the
program. `<Esc>` is never bound at all, so vim running inside one can still
leave insert mode.

On the rail, `t` (or `c`) starts a terminal, `R` renames one and `d` kills it
(asked first — something is usually running in there). `c` opens a **screen, not
a prompt**: a shell, then one entry per provider the daemon has — read live, so
enabling one in Paseo makes it appear without a config change — then anything in
`ui.terminal.presets`, then a free-text command. It was a `vim.ui.select` of
bare labels opened over a surface that was itself an overlay; it is the same
card renderer every other choice in this plugin uses. Nothing checks that a
command exists, on purpose: the terminal runs on the **daemon's** host, which is
not necessarily this machine, so the honest failure is the PTY printing
`command not found`.

**A name you give is kept here**, by the plugin, and the daemon is told as
well. That is not belt and braces. `renameTerminal` sets a terminal's `title`,
and `title` is also what the PTY reports for itself — so the shell overwrites
your name with `milind@host:~/dir` within a second, and every terminal in one
directory ends up labelled identically. The list shows, in order: the name you
gave, the stable one the daemon assigned (`Terminal 3`), then the live title.

A terminal is a **real** terminal — `nvim_open_term`, the same libvterm behind
`:terminal`, fed the PTY's own bytes, so colour, the cursor and a TUI redrawing
itself all work. One `terminal_output` listener routes to a registry keyed by
id, which is the whole of how several are fed at once; `bridge.on` has no
`off`, so a listener per attach would stack up one dead closure per terminal
you opened. That registry owns no window, which is why the surfaces above it
could be deleted and replaced without touching it.

A terminal **dying** is a directory update that no longer lists it, never a
process exiting under us — Paseo owns the process, not Neovim, so none of
floaterm's reaping machinery applies.

### Style

Four frame languages, under `ui.style`. A preset name, or a table of the same
fields when you only want to change one:

```lua
ui = { style = "plate" }                            -- the default
ui = { style = { preset = "rounded", border = "none" } }
```

| `card` | |
|---|---|
| `plate` | **no frame at all.** A title row and a body painted one elevation step above the surface, with a row of padding. The default. |
| `rule` | a title, then one hairline **inset** from both edges — full-bleed reads as a table border, not a divider |
| `rounded` | real boxes, `╭╮╰╯`, title inset in the top rule |
| `square` | the same with `┌┐└┘` |

**The composer follows this too**, which it did not before: it was framed in
every style, always — a hard rounded rule around the box you type in, inside a
window whose own edge is invisible, above cards with no frames. Under `plate`
and `rule` it is a card like any other, its bar the title row; under `rounded`
and `square` it keeps a box. The geometry is measured from the same answer, so
the bottom of the box lands on the last body row either way.

| `border` | the outer edge |
|---|---|
| `invisible` | a real border painted `fg == bg`, so it becomes a one-cell ring of padding in the surface's own colour. The default — and **not** the same as `none`, which drops the padding with it and puts content hard against the window edge. |
| `rounded` · `single` · `none` | literal |

A drawn edge is painted with `PaseoSurfaceBorder`, which has the surface's own
background. It used to be `PaseoBorder`, which has none — so the glyphs
rendered on the *editor's* background and the framed styles lost the one cell
of padding the unframed ones get, which is what made the frame read as a
hairline pasted onto the editor rather than as the edge of a raised sheet.

Every style produces the **same number of rows** for the same content, so
changing it never moves a panel's rows under the cursor.

The default is `plate` because the old look was three frame weights competing
inside one window — a box around every card, inside a window border, with a
rule under it as well.

### Colour

Everything is derived from your colourscheme by default, and there is no
dependency on NvChad. **Three keys, and they are different questions:**

```lua
ui = {
  colors = "auto",   -- where the eight base colours come from
  palette = {},      -- those eight colours, by name
  theme = {},        -- finished highlight groups
}
```

| | |
|---|---|
| `ui.colors` | `"auto"` derives the base colours from the colourscheme — what makes the chat look like it belongs to whatever you have loaded. `"fixed"` uses the plugin's own instead, and then a `:colorscheme` does not move them. |
| `ui.palette` | the eight base colours by name — `red` `green` `blue` `yellow` `grey` `border` `text` `bg` — laid over **whichever** source. So it is a correction to a theme that got one colour wrong as readily as it is a whole palette on top of `"fixed"`. |
| `ui.theme` | the last word: finished groups, laid over the derived table. |

`palette` and `theme` are not the same tool. A colour set in `palette` is a
**token**, and everything below still runs on it — the elevation ladder, the
four accent ramps, the contrast corrections — so naming two colours still gets
a coherent set, and the colour reaches every group derived from it. A colour
set in `theme` is the one group you named.

```lua
-- Ignore the colourscheme entirely.
ui = { colors = "fixed" }

-- Keep deriving, but this theme's Function colour is not what I want
-- the chat's blue to be.
ui = { palette = { blue = "#7aa2f7" } }

-- My own palette, derived into a full set.
ui = { colors = "fixed", palette = { bg = "#1a1b26", blue = "#7aa2f7" } }
```

Leave `palette.bg` unset on a **transparent** theme: absent is what tells the
derivation there is nothing to build tiers on.

The rest of this section is what `"auto"` does.

**Backgrounds** are an elevation ladder stepped off `Normal`: the editor, the
surface two points away, a card five, a chip eight, the selected row eleven.
Light themes step the other way (`vim.o.bg == "dark" and 1 or -1`, applied to
every step). Depth comes from that ladder rather than from drawn boxes, which
is the whole idea behind `ui.style = "plate"`.

**Accents** get four stops each — `mix(accent, bg, 10/40/60/80)`, as
`PaseoGreen0`…`PaseoGreen3` — so there is something to fade a flash *through*,
shade a heat scale with, and draw a divider in that is not content weight.

Where the accents come from is a chain, and the order is load-bearing:

- **With NvChad**, base46's palette, read from its own cache.
- **Without it**, `DiagnosticError`/`Removed`, `DiagnosticOk`/`Added`,
  `Function`, `DiagnosticWarn`/`Changed` — the groups that *mean* what we mean.
  `Added` before `String`, because on `morning` `String` is **magenta**, so a
  tool that succeeded was drawn the colour of a string literal.


Three corrections are then applied, each of which a real colourscheme forced:

- An accent used as **text** is pushed until it is legible on whatever it sits
  on — measured, both directions tried, and a colour that already clears the
  bar is left alone. `morning`'s `added` is `#90ee90`, unreadable on a plate
  tinted with that same green; `default`'s is `#166336`, already dark enough
  that pushing it further lands on black and throws the hue away.
- **Dim** has to be dimmer than body text, and neutral. `morning` sets
  `Comment` to pure blue: quiet by luminance, loud by saturation, so every
  label came out louder than the words it qualified.
- A bar's **track** is derived from the background, because a track is the
  absence of fill. A comment-derived one came out pale blue on `morning` and a
  42% bar looked full.

**Identity** colours — the dot beside a repo, a project, a workspace — are a
separate set of eight, and not the semantic accents. Two reasons, both found by
looking at it: four is too few, so two repos in a list of four collided; and red
already means *this failed*, so a repo drawn red read as a repo with a problem.
The eight are hue rotations off the theme's own blue, stepped by the **golden
angle** rather than by an even division — an even division puts consecutive
indices next to each other on the wheel, and since a hash scatters names
uniformly, neighbouring buckets come up constantly and three repos drew three
shades of the same green.

On a **transparent** theme — `Normal` with no background — nothing is painted
at all, and selection is signalled by removing dimming rather than by adding a
fill. An opaque rectangle over someone's wallpaper is worse than no card.

Override any group with `ui.theme`, which is laid over the derived table:

```lua
ui = { theme = { PaseoChipOn = { bg = "#204a26" } } }
```

That is a config key rather than "set the group again after `setup()`", which
is what the docs used to say and which quietly stopped working the moment you
changed colourscheme — the derivation re-runs on `ColorScheme` and overwrote it.
The same is true of `ui.colors` and `ui.palette`: all three survive a theme
change because all three are read on every re-derivation.

### Glyphs

A Nerd Font is required, and every glyph lives in one registry
(`lua/paseo/ui/icons.lua`) defined by **codepoint** rather than by literal
bytes.

The codepoints are the point. Twice the bytes of a Private Use Area glyph have
been lost out of a source file: `check_on`/`check_off` went first, and a test
was added covering exactly those four names — while six slots in
`render.icons`, the `permission` marker in the Sessions panel, two group icons
and five inline glyphs elsewhere were empty the whole time and the suite stayed
green. An empty icon is not a visible failure; the line still draws, and "off"
and "broken" look identical.

The test now walks the whole registry and asserts every entry is at least one
cell wide.

### Motion

`ui.animate`, or `false` for instant. Two effects: a bar eased towards its new
value, and a tool card tinted as it settles then fading out through the accent
ramp. The spinner is not one of them and is never disabled — a turn that is
running has to look different from a turn that is wedged, and that is
information rather than decoration.

Neither changes a panel's **height**: a panel whose rows moved mid-flight
would move them under the cursor.

There was a **third** effect, staggering a panel's rows in on a tab switch, and
it is gone for a reason worth recording. It respected that constraint — it drew
fewer rows into a block already padded to its final height. But the Sessions
panel maps cursor rows to entities, and that map still named every row while
only some were painted, so for the length of the reveal the screen disagreed
with what a keypress would do. A decorative effect is not worth a window in
which the surface lies about itself.

### Questions

A question — Claude's `AskUserQuestion`, and the `ask_user` the other providers
wrap the same way — arrives as a permission request like any other. Treating it
like one is why an agent that asked you something got back *"The user did not
answer the questions"*: allowing a question only consents to the **asking**. The
answer rides back inside the tool input, so a bare allow is approval and
silence, whichever button you pressed.

So the dialog answers it instead — and it is not a dialog any more. It takes
over the **chat window**: the conversation dims behind it and the questions are
a card laid on top of the thing they are about, on either surface, rather than a
float centred on the editor over whatever file you were reading.

**One question at a time**, with `2 of 3` in the corner and a dot per question
above it — `●` answered, `◉` where you are, `○` not yet:

```
╭─ 󰘦  The agent is asking 3 things ───────────────────────────╮
│ ● ◉ ○                            2 of 3  ││││││││           │
│                                                             │
│ Which checks should run?                                    │
│                                                             │
│  1  ■ tests                                                 │
│       The unit suite, about 40s                             │
│  2  □ lint                                                  │
│  3  □ typecheck                                             │
│    󰎞 skip the slow ones on this branch                      │
│    choose as many as apply                                  │
╰─────────────────────────────────────────────────────────────╯

  1-9  pick    ⏎  send the answers    ← →  question    c  note    ␛  later
```

`1`-`9` picks, `j`/`k` (or `↑`/`↓`) reaches an option past the ninth, `<Space>`
takes the one you are on, `x` clears the answer, `s` skips an optional question,
and `←`/`→` move between questions — so do `h`/`l` and `<Tab>`/`<S-Tab>`. Back
is as easy as forward: an answered question is never locked, and returning to
one puts the focus **on its answer**, so `<Space>`, `c` and `x` act on what you
chose and a number replaces it. The marker is a checkbox where a second pick **adds** and a
radio where it **replaces**, so the shape tells you which before you press
anything. The bar beside `2 of 3` is how much of the set is answered.

**An option's description is shown in full**, wrapped under the option it
belongs to rather than truncated onto one row — the half that used to fall off
the end was usually the half that told it apart from the option below it. It is
drawn for the option you are **on** and for every option you have **picked**, so
an answer does not lose its meaning the moment you choose it.

`c` writes a **note** about the answer — the caveat the options did not cover,
like *"the second one, but only for new workspaces"*. It never replaces the
pick: the label still travels in `answers`, and the remark rides beside it in
`annotations`, so a reader that knows nothing about notes still gets a clean
option. Clearing the answer with `x` clears its note too, and the note appears
in the transcript badge beside what was answered.

`<CR>` sends the moment nothing is missing, and until then it **takes you to the
first thing that is** — which is what the old "that question still needs an
answer" should have done, since with three questions on a stepper *which one* was
the only part you needed.

**The set is still sent as one response.** The stepper is presentation, not
protocol. Showing all four at once was the previous answer to the same problem
and it was the wrong one: four questions stacked in a float is a wall you skim,
and the one fact you needed — that there are four — was still yours to count.
`2 of 3` is that fact, stated, on every frame, and the hint bar says `⏎ next`
until the last question and `⏎ send the answers` on it.

`i` answers in your own words, in a box that is **a real buffer** inside the
card — so your completion, abbreviations, insert-mode maps and undo all work,
which a `vim.ui.input` prompt could never give you. A question with no options at
all opens it for you and starts insert; there is nothing else to do on one.
`<M-CR>`, or `<CR>` in normal mode, saves; `<Esc>` twice discards. The same
contract as the composer, because it is the same act — including *not* being
`<C-s>`, which means the session list everywhere in this plugin.

`<Esc>` is later, not no: the request stays pending and `gp` reopens it **with
your answers still in it**. `n` declines to answer and `N` declines and stops the
turn. There is no timeout — a question waits until it is answered here, or
answered in the Paseo app, which closes this too.

Multi-select is serialised the one way the provider parses back: `", "`-joined,
quoting any label that contains the separator — otherwise `Rebase, then push`
returns as two answers matching no option.

**The record it leaves folds up.** The picker is transient and the conversation
is the record, so the question, its options and their descriptions are written
into the transcript as a card of their own. Answered, that card is **one line**
— the question's header and what you chose — and `<Tab>` opens it again:

```
  Input box  Floor of 3, cap scales with the surface
```
```
  Input box  Floor of 3, cap scales with the surface
 The composer grows from 1 row up to a flat 7-row cap. What shape should the box take?
 󰗠 Floor of 3, cap scales with the surface
     Empty box is 3 rows so it reads as a field, not a one-liner. The cap becomes
     a share of the surface (≈a third of the window) instead of a flat 7.
 · Keep the 1-row floor, just fix the scroll
     Minimal change: the empty box stays a single row, but it grows correctly.
```

It used to be neither. It stood open forever — a dozen lines of identical grey
in the middle of the transcript, every option run onto one line behind an em
dash, for a decision whose whole outcome fits in the badge — and no key folded
it, because the card was built as not collapsible. So: **the option you took is
ticked** and the rest are not, descriptions sit under their own option, and an
*unanswered* question still draws open whatever `ui.expand` says, because the
options are the thing being asked about.

**And a card is text, not markdown.** The transcript is `filetype=markdown` so
that what the agent *writes* reads the way it wrote it, and an option
description is not that — it is a string that lands in the same buffer, where
treesitter will find emphasis in it and style straight over our own
highlights. No extmark priority undoes that, because strikethrough and italic
are attributes rather than colours. One real description read *"a share of the
surface (~a third of the window) … a long prompt gets ~15 rows"*: two tildes in
a paragraph is a GFM strikethrough, and everything between them was drawn
struck through, across four wrapped lines, starting mid-sentence. So `**`, `~~`
and backtick pairs are taken out of card text and a lone `~` becomes `≈`, which
is what it meant. `_` is left alone on purpose — stripping it would turn
`composer_min` into `composermin`, and a card lying about an option's text is
worse than one drawing it in italics.

Too narrow or too short a chat window — under 48 columns or 14 rows — or no chat
window at all, and the same card opens centred on the editor instead. Same keys,
same layout; only where it sits differs.

### Plans

Approving a finished plan is two decisions, and the dialog only ever asked one.
`ExitPlanMode` arrives as a permission request with an Implement and a Reject;
press Implement and the daemon picks the mode for you, always `acceptEdits`:

```js
if (pending.request.kind === "plan") {
    const targetMode = shouldResumePriorMode ? "bypassPermissions" : "acceptEdits";
    await this.setMode(targetMode);
```

The second decision cannot ride along with the first — `AgentPermissionResponse`
has no field for a mode — so it is a follow-up `setAgentMode`, and it has to come
*after* the approval or the daemon's own call overwrites it. The dialog offers
one Implement per mode, least rope first, so `y` is the cautious key:

```
   1 Implement, accept edits    2 Implement, auto
   3 Implement, always ask      4 Reject, keep planning
```

Every one of them sends the **daemon's** action id and differs only in the mode
applied afterwards — an invented id is rejected outright. The modes are filtered
against what the provider reports, so codex, which has no `acceptEdits`, is
offered the ones it has.

The plan itself is on screen while you decide, in the same overlay, as a **real
buffer you can scroll and `/`-search** with the buttons as chrome around it.
It has to be a real buffer: the card is drawn as virtual text, virtual text
cannot be scrolled, and the version before this therefore budgeted the plan
against `vim.o.lines - 16` and truncated it — so on any plan longer than the
terminal you were approving the part that happened to fit, plus the words `… 84
more lines`. `j`/`k`/`<C-d>`/`<C-u>`/`gg`/`G` scroll it without ever leaving the
buttons, **and so does the mouse wheel**: the body used to be an unfocusable
float, which is one the mouse lands straight *through*, so the wheel scrolled
the conversation behind the plan while the plan itself sat still. It is
focusable now, and it carries the same keys the card does so landing in it with
the mouse is not a dead end.

A plan takes the **whole width** the conversation has, rather than the 96-column
cap a question's options are held to: a plan is a document with code in it, and
that cap wrapped every fenced block. The percentage and bar in the title say how
far down it you are — without one, a document that scrolls cannot be told from
one that does not, which is most of what "scrolling does not work" looks like.

A plan request also carries no tool `detail` at all — the markdown travels in the
tool input — so the dialog, which renders `detail` for everything else, was
drawing an empty box and asking you to approve it.

### Images

`p` in the composer pastes the image on the clipboard. Neovim's own clipboard
is text — a screenshot copied from a browser never reaches a register — so
this shells out to `wl-paste`, `xclip` or `pngpaste` and reads the bytes
directly.

It used to be `<C-v>`, with `^V image` in the composer's winbar to tell you
so. A paste key you have to be taught is a worse answer than paste working,
and the hint cost four columns of a narrow pane. `p`, `P` and `<C-v>` all look
at the clipboard for a picture first now, and the winbar says nothing about
it.

What lands in the buffer is a **placeholder**:

```
[Image #1] why is the right-hand panel empty here?
```

The bytes travel beside the prompt, not inside it, so the buffer stays
something you can read and edit, and the number is how a sentence refers to
one of several. With no image on the clipboard the key does its ordinary job —
and does it properly: the count and the register are carried through, so `3p`
is still `3p` and `"ap` is still `"ap`. `:Paseo image ~/shot.png` attaches a
file, from anywhere.

### The ask box

`:Paseo ask` and `:Paseo qfask` open a small float, take your question, send
it, and let the chat come up behind the answer. They used to open the whole
chat surface with the reference queued in its composer — a lot of window for
one sentence, and it put you in the conversation before you had said anything.

| | |
|---|---|
| `<CR>` | send (normal mode) |
| `<M-CR>` | send (normal or insert) |
| `<Esc>` / `q` | cancel, throwing the draft away |

An empty box cancels. The box grows with the question, to a cap.

It is a **real buffer**, not `vim.ui.input`, for the same reason the composer
is one: a one-line field throws away your insert-mode keymaps, completion,
abbreviations and undo, and cannot hold a question with a blank line in it.
`<CR>` is therefore not bound in insert mode — that is how you write a second
paragraph.

`:Paseo explain` does not open the box; it already has a question, the rubric.

### Dictation

`<C-t>` in the composer opens the microphone; `<C-t>` again closes it and puts
what you said in at the cursor; `<Esc>` throws the recording away. One key for
both halves, and not hold-to-talk, because Neovim delivers a keypress and never
a key *release* — "while held" cannot be expressed.

**Opening it is a state of its own.** Two round trips stand between the key and
the first sample: the sidecar has to be up, and then the daemon has to accept
the stream — which on a cold daemon is where the speech models load, and is
seconds rather than milliseconds. So there is a spinner, a count, and a way
out, and *the box will not take keys until the microphone is open*:

```
 ⠙ opening the microphone ───────────────────────────────  0:03   󱊷  cancel
 what does this function do   ⠙ typing is off until the microphone opens
```

Typing is off for the length of it because anything typed in there is racing
the transcript that is about to land on top of it. The composer leaves insert
mode rather than merely going read-only — a buffer you are still inserting into
with `'modifiable'` off rejects every keystroke with its own `E21` — and it
comes *back* to insert mode, at the column you left, the moment the microphone
opens. A second `<C-t>` during the wait is a change of mind: it gives up on the
start rather than trying to open a second microphone.

**Then the bar becomes a meter.** While the microphone is open the bar over the
composer is the recorder — a red dot, a scrolling waveform, how long you have
been talking, and the key that stops it:

```
 󰍬 listening  ▁▁▂▃▅▆▇█▇▅▃▂▁▁▂▄▆▇▇▅▃▁▁▁▂▃▅▆▇▇▆▄▂▁▁  0:04   Ctrl + t  stop    󱊷  discard
```

**One meter, not two.** There was a second copy of the same wave inside the box
as well, and two rows of blocks answering the same voice is the same
information twice in the same glance — so the one you are not looking at went.
The box still speaks up while the microphone is *opening*, because a box that
is refusing your keystrokes has to say so; it just has nothing to add once the
wave is running.

That is there because *"it is not clear when I am speaking"* is the whole
problem with dictation you cannot see: a word missed by a muted microphone and
a word missed by a thinking daemon look identical if the only feedback is text
that has not arrived yet.

**The level is measured about the signal's own mean**, and that one word is the
difference between a meter and a flat line. A microphone is not obliged to hand
you a waveform centred on zero: the default source on the machine this was
fixed on sits at a constant +5642, a sixth of full scale, with the sound riding
on top of it. RMS taken about *zero* therefore reports that bias and not the
sound — an empty room read 0.1693 to 0.1776 across eleven seconds, four tenths
of a decibel of swing — and speech cannot rescue it either, because energy adds
in quadrature and an ordinary voice over that bias moves the total by a third
of a decibel. Nothing downstream can recover from that. The same eleven seconds
measured about the mean swing 10.5 dB.

**And nothing in the meter is calibrated to a microphone.** A headset an inch
from your mouth and a laptop across the desk are fifty times apart on the same
sentence, so every number the scale needs is measured from the signal instead,
and the only constants are ratios and bounds:

| | what it is | why not a constant |
|---|---|---|
| floor | the 5th percentile of the last twenty seconds | the room, whatever the room is |
| gate | the room's own spread over that floor, clamped | a study swings 10 dB on its own; a clean line, 2 |
| top | the loudest thing heard in the last five seconds | how far speech sits over a room is a fact about the room, the gain and how far away you are sitting |
| bottom of the bar | the gate, opened downward once the top has cleared it | the gate answers *"room or voice"*; it was never the right place to start drawing |

The adaptive **top** is what keeps a loud input off the ceiling and a quiet one
off the floor: the bar is full when you are as loud as you have been, which is
the question it is actually being asked. Checked against 82 combinations of
gain (over a 120:1 span), DC bias and noise character, plus real recordings
rescaled from ×0.05 to ×4 — silence flat on every one, speech proportional on
every one.

**The gate is not the bottom of the bar**, and using it as both is the fourth
way this drew a flat line at a working microphone. The window is cleared every
time you press the key, so it holds only the seconds since — start talking
straight away and there is no silence in it anywhere. The floor is then
measured from your own quietest syllable and the median from your own voice,
which puts a gate a dozen decibels above the floor most of the way up your
actual signal: ordinary speech drew one glyph and the odd stressed vowel
spiked. On a soft voice it was worse than that — the loudest thing in a
ten-second window reached 11.8 dB against a gate of 12.0, so the row never
moved at all. So once the top has *cleared* the gate — which a room never does,
which is what keeps silence silent — the range opens downward and puts
mid-speech in the middle of the bar. In proportion, never as a step: measured
on a quiet room the gate sits at 9.65 against a top of 9.69, and a step there
strobes the bar between empty and full twenty times a second.

Three versions of this were wrong before that, and the first two failed the
same way: one crept its floor upwards at a fixed rate, so a few seconds into a
sentence the floor had climbed over the voice and the wave died mid-word; the
next gated on a fraction of that floor, which in a loud room is a bar an
ordinary voice cannot clear. Both were built on a number that was measuring a
DC offset, which is why neither could be fixed by tuning it.

Neovim cannot record audio, so this shells out to the first of `arecord`,
`rec` (sox) or `ffmpeg` that is installed. `:checkhealth paseo` says which one
it found, or that it found none — the failure mode otherwise is a key that
appears to do nothing. If the recorder **dies** — a microphone that is busy, or
refused — you are told, with whatever it said on its way out. It used to be
silent: the indicator stayed lit, no audio was ever sent, and the key appeared
to have stopped working.

Audio is streamed **while you speak** rather than recorded and then uploaded:
the daemon transcribes as it goes, so the text arrives in about as long as it
takes to lift your finger. What goes over the wire is raw PCM16 mono, base64,
with the sample rate in the format string — no container.

**Chunks are numbered from zero**, and that is not a detail. The daemon
acknowledges the stream itself with `ackSeq: -1` and then reassembles the audio
by sequence, so a first chunk numbered `1` leaves a hole at `0` that never
fills: every chunk waits in the reorder buffer, nothing is transcribed, and
`dictation.finish` eventually gives up with *"Timed out waiting for final
transcription"*. Which is exactly what dictation from this editor did, on a
daemon whose own app dictates fine.

The **daemon** does the transcribing, and a microphone is not enough: if it has
no speech model it says so, in its own words, the first time you press the key.

Speech-to-*text* only. Paseo also has a duplex voice mode with synthesised
replies; an editor that talks back needs a player, an interrupt and somewhere
to put the transcript, which is a surface rather than a key.

### References are locations, not quotations

`explain` / `ask` / `qfask` send the agent a path and a line range and let it
open the file. Pasting the lines in made the prompt scale with whatever you
asked about, and the worst case is not a long hunk — it is a **newly created
file**, which gitsigns reports as one all-added hunk, so the whole file went
into the prompt. Reading also gets the current file and its surroundings, where
a paste is a snapshot from when you pressed the key.

The path is **absolute**, which is not cosmetic. A ref's `path` is relative to
the *workspace* so it disambiguates across member repos (`clm_api/app/main.py`),
while `root` — the agent's cwd — is the member worktree. Resolve one against
the other and you get `…/clm_api/clm_api/app/main.py`. While the code was
inlined the path was only a label and nobody noticed.

**One carve-out: a pure deletion.** Its lines are not in the file to read, and
a deletion's line number is the line *above* the removed block — so "go read
it" would show the agent the code that survived and get a confident answer
about the wrong lines. Those are still quoted, fenced as `diff`, and labelled
so the agent does not go hunting for them (`lua/paseo/ref.lua`, `detached`).

If the buffer has unsaved changes the reference says so, since the agent reads
disk and you are looking at the buffer.

## Driving review from your own config

The plugin does not own your review workflow. It owns the git knowledge the
workflow needs, and the agent you ask when a hunk is opaque. `paseo.repos` and
`paseo.git` are public and stable, contain no UI, and are the seam the
changed-files picker and the hunk quickfix list are built on in your config:

```lua
local repos, git = require "paseo.repos", require "paseo.git"

-- Every changed file, across every repo in the unit of work. In a `ws`
-- workspace that is all six worktrees; in a plain repo it is just that repo.
local function changed()
  local out = {}
  for _, repo in ipairs(repos.list()) do
    vim.list_extend(out, git.status(repo))       -- paseo.Change[]
  end
  return out
end

-- Telescope: finder over changed(), previewer over
--   git.diff_text(change, { context = 3 })      -- string[]

-- Quickfix: expand the files you picked into hunks. `hunk.lnum` is already the
-- line to jump to, including the delete-hunk case that is NOT `c + 1`.
local function to_quickfix(repo, picked)
  local items = {}
  for _, hunk in ipairs(git.hunks(repo, picked)) do  -- paseo.Hunk[]
    items[#items + 1] = {
      -- Absolute: the list outlives the cwd that built it, and in a workspace
      -- the entries come from several different worktrees.
      filename = vim.fs.joinpath(hunk.repo.worktree, hunk.path),
      lnum = hunk.lnum,
      text = ("%s  +%d -%d"):format(hunk.path, hunk.added, hunk.removed),
    }
  end
  vim.fn.setqflist({}, " ", { title = "hunks", items = items })
end

-- Staging: needs no buffer, and handles whole-file deletions and untracked
-- files, both of which gitsigns structurally cannot.
git.stage(hunk, function(err) ... end)
```

A worked implementation of exactly this — the picker with its diff previewer,
a `quickfixtextfunc` rendering `clm_api  app/main.py  L34-L69  +7 -2` while
keeping real `filename`/`lnum`/`end_lnum` values, staging from the list, and
the per-member-repo diff panel — lives in the author's config as
[`lua/utils/review.lua`](https://github.com/milindmadhukar/nvim/blob/main/lua/utils/review.lua).
Its keys are bound on paseo.nvim's own lazy spec, so pressing one loads the
plugin before the module's top-level `require "paseo.git"` runs.

Two things to know before you write this:

- **`git.hunks()` is `-U0` by contract.** The `lnum` it returns only means "the
  hunk" at zero context; asking git for context elsewhere and reusing these
  numbers puts you off by the context width.
- **`git.diff_text()` uses `--no-index` for untracked files**, which exits 1 by
  design ("the files differ"). It handles that; a previewer of your own that
  shells out directly must too.

`:Paseo qfask` reads whatever is in the quickfix list, so it works over yours.
The workspace picker's `<C-r>` fires a `User PaseoReview` autocmd with the
workspace root in `data.root` instead of building a list itself:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "PaseoReview",
  callback = function(ev) my_hunk_list(ev.data.root) end,
})
```

## Paseo glossary

These names follow [Paseo's workspace model](https://paseo.sh/docs/workspaces).
In particular, a Neovim tab page
is not a Paseo tab, and a terminal is not an agent session.

| Term | Meaning here |
|---|---|
| **Project** | The long-lived codebase Paseo knows about. A project contains workspaces. |
| **Workspace** | One unit of work inside a project, with its own working directory. It contains agent sessions and terminals. |
| **Agent** | The AI worker identified by an agent ID. In UI text, its ongoing conversation is an **agent session**. |
| **Agent session** | One agent's state and timeline inside a workspace. Several can share the same workspace and files. Bare “session” is retained only in compatibility command aliases and stable internal module/protocol names. |
| **Tab** | A Paseo application surface that presents an agent session. paseo.nvim shows each one as a **buffer** on the Paseo tab, so your bufferline is the app's row of tabs; neither is an isolation boundary. |
| **Dashboard** | paseo.nvim's full-screen surface: the five tabs, the panels, the panes, and the workspace rail with each workspace's sessions. One thing, on one of two **mounts**. |
| **Sidebar** | The narrow surface beside your code, the other to the full-screen one. |
| **Terminal** | A daemon-owned PTY inside a workspace. It appears beside agent sessions but is not an agent. |
| **Worktree** | A Git checkout used to isolate a workspace. It is an implementation mechanism, not a synonym for workspace. |
| **Daemon** | The background Paseo process that owns projects, workspaces, agent sessions, timelines, and terminals. |
| **Provider** | The agent backend, such as Claude, Codex, or OpenCode. |
| **Model** | A provider-specific model used by an agent. |
| **Subagent** | An agent created or coordinated by another agent as part of its work. |
| **Fork** | A new agent session initialized from a source agent's conversation snapshot. It goes beside the source agent or into a worktree of its own; you are asked which. |

Isolation belongs to the **workspace**, not the agent session. Two agent sessions in one
workspace edit the same files on purpose — that is what makes "one agent
writing, another reviewing its diff" work. Two *workspaces* are isolated from
each other only when each has its own worktree.

### Quitting Neovim

Paseo agent sessions belong to the
[background daemon](https://paseo.sh/docs/cli#daemon-lifecycle), not to Neovim. Closing
Neovim stops only this plugin's sidecar; active agents continue running.

**Which is why the warning only asks about a daemon this Neovim started.** If
the daemon was already up when you opened the editor — the desktop app's, or
one left from an earlier session — quitting risks nothing and nothing is
asked. When the plugin started the daemon itself, normal whole-editor exits
(`:q`, `:qa`, `:wq`, `:x`, their long forms, `ZZ`, and `ZQ`) warn if a
non-archived agent is running, starting, queued, or waiting for attention.
Closing a split, tab page, or float does not warn, and a forced `!` exit is the
explicit bypass. The guard is off unless `quit.guard = true` (it maps `ZZ`/`ZQ`
and abbreviates `:q`, which a plugin should not do unasked); with it on, set
`quit.warn_active_agents = false` to keep it quiet. Custom quit
routers can call:

```lua
require("paseo.quit").guard(function()
  -- existing quit confirmation or exit route
end)
```

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

### One command, three mechanisms

That leaves three ways to get a working directory — and which one applies is a
property of the **directory**, not a question worth asking you. So `:Paseo
wcreate` answers it:

| Project | What happens | Picker says |
|---|---|---|
| A plain directory holding repos | Its worktrees are **assembled** into one composite directory, handed to Paseo as a local workspace | `N repos` |
| A git repository | Paseo **cuts the worktree** itself, off whatever is checked out (or the *Base* you pick), and names it | `worktree` |
| Neither | A plain workspace on the directory as it stands | `local` |

No manifest in the first case? One is discovered and **offered**, on a screen:

```
 󰙅  Workspace                              ~/Code/openfin

  󰳏  Repos   m                  󰉋  Shared   s
   ■  clm                dev     ■  Docs
   □  clm_api            dev     □  test quotes
   ■  fos-pwa            dev     □  test-s3

  c  write the manifest             2 repo(s), 1 shared
```

Discovery works out nearly everything by looking at the project. The two
things it cannot are **which branch each repo is based on** and **which of the
directories beside your repos are shared context rather than junk that happens
to be there** — so those are what it asks. `<CR>` toggles, `b` sets the
focused repo's base, `t` drops to the raw TOML, `c` writes it. `q` writes
nothing and creates nothing.

Those questions used to be asked in *comments inside the generated file* —
`# init lists every non-repo directory it found; PRUNE THIS` — which is a
question posed in a medium you cannot answer in. The openfin manifest still
listed `test quotes` and `test-s3` months later because of it. Opening the
screen on a project that already has a manifest **loads** it, and a sibling
you pruned stays pruned even though it is still on disk.

`:Paseo ws init` opens the same screen, from anywhere inside the project;
`:Paseo ws init raw` is the old TOML buffer, and `:Paseo ws edit` opens the
file itself as it is on disk. `:Paseo ws create <name> repo,repo` is still the only way to pick
which repos one workspace gets — but none of it is a prerequisite.

The point is that "is this the `ws init` kind of project?" is a question about
plumbing, and you should be able to type one command without answering it.

### Taking one down

`<C-d>` in the picker, or `:Paseo ws rm <name>`. It refuses first and says what
it would lose — a member with uncommitted changes, or with commits that exist
on no remote and not on the base the branch was cut from — and `force`
discards that.

Once it goes ahead, the members leave through `git worktree remove`, never
`rm -rf`: deleting the directory is how stale `.git/worktrees` entries get left
behind. The `ws/<name>` **branch goes too**, with a plain `git branch -d`, which
refuses an unmerged branch rather than taking it with the worktree. Without
that, `git worktree remove` left the branch standing in every member — one dead
`ws/…` per repo per workspace anyone had ever made.

### Opening one

`<CR>` in the picker switches **inside this Neovim**: this tab is `tcd`'d into
the workspace. The plugin opens no tab pages you did not ask for; a `tcd`
rather than a bare `cd` so it is the tab that moves and not the editor. If you
would rather keep each workspace's buffers, LSP clients and jumplist apart,
`"tab"` gives every workspace a tab page of its own. `workspaces.open` picks:

| | |
|---|---|
| `"tcd"` | this tab's cwd, no new tab — the default |
| `"tab"` | a new tab page, `tcd`'d in |
| `"cd"` | the editor's cwd; everything follows |
| a function | you do it |

The function is how you get a GUI window per workspace instead — which is what
this used to do unconditionally, and shouldn't have: over ssh, or in any
terminal Neovim, there is nothing to spawn and `<CR>` appeared to do nothing.

```lua
workspaces = {
  open = function(ws)
    if vim.g.neovide then
      vim.fn.jobstart({ "neovide" }, { cwd = ws.directory, detach = true })
      return
    end
    return false  -- decline: fall back to the built-in switch
  end,
}
```

Returning `false` **declines**, so one config can spawn a window under a GUI and
switch in place in a terminal. Anything else — `nil` included — means you
handled it.

**On the Paseo tab** the picker does not move your editor at all: picking a
workspace there swaps the [row of agent buffers](#every-agent-is-a-buffer),
as the rail does. A `workspaces.open` function still gets the first word.

**An open chat comes with you.** It used to keep showing the agent in the
workspace you had just left. Now it follows: the sidebar is rebuilt on the tab
you are standing on, and the full-screen surface swaps its row to that
workspace's agents.

It re-points an open chat and nothing more: with no chat up, switching
directory opens nothing, and a workspace you have not started an agent in yet
says so rather than opening a provider picker at you. The full-screen surface
takes focus — it covers the screen, so you need to be able to type into it —
and the sidebar does not, because your cursor is in your code. `<C-r>` follows
too but never takes focus; that belongs to whatever your review autocmd opens.
A `workspaces.open` function that spawns its own window doesn't move this
Neovim, so the chat in it stays put.

**And if you open the chat afterwards instead**, `:Paseo chat` resolves the
directory you are *standing in* — the workspace containing the cwd, else the
repo containing it, else the cwd. It used to read the git toplevel of the
**buffer**, falling back to the cwd only for an unnamed one, which is what
made "switch workspace, open the chat" land you back in the workspace you
left: with `workspaces.open = "tcd"` the switch reuses the tab, so the file
you had open in the old worktree is still the current buffer. Anything that
means a particular *file* — `:Paseo ask`, `:Paseo explain` — still resolves
from that file; only "open the chat", which means *here*, reads the cwd.

To keep the built-in switch and only decide what the new tab *shows*, listen for
`User PaseoWorkspaceOpen` instead; it fires after the `tcd`, with the root in
`data.root`:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "PaseoWorkspaceOpen",
  callback = function(ev) require("oil").open(ev.data.root) end,
})
```

## Using it without the Paseo app

That is the point. The composer is a real Neovim buffer, the conversation is
the agent's actual timeline fetched on open, and the agent lives on the daemon
— so it survives closing Neovim and reopening the chat picks the conversation
back up. Paseo is the engine; you should not need to look at it.

## Tests

```sh
tests/run.sh          # everything
tests/run.sh git      # only the suites whose name matches `git`
```

The suite runs Neovim, the sidecar typecheck, and TypeScript tests. Install
the sidecar dependencies first with `bun install` or `npm install`; the test
harness uses Bun when present and Node plus the local TypeScript otherwise.

Neovim is started with `-u tests/minimal_init.lua` and nothing else, so none of
your own configuration is loaded: gitsigns and telescope are cloned into
`~/.cache/paseo-nvim/test-deps` by `tests/deps.sh` and the suite runs against
those. A green run means the plugin works, not that one laptop is set up right
— which is also what makes it runnable on a machine with no configuration at
all, and is why the same command is all CI does:

```
tests/
  run.sh              fixtures, then Neovim, then the sidecar's own tests
  fixtures.sh         the git repositories every assertion is made against
  deps.sh             shallow clones of the plugins under test
  minimal_init.lua    the Neovim the suite runs in
  spec.lua            the runner: the suite files, in the order they run
  spec/               one file per area
    helpers.lua       eq, truthy, and the shared fixtures
    git.lua  ui/      ...
  orphan.sh           does the sidecar die when Neovim does?
  e2e/                a real daemon, a real Neovim, in tmux (below)
```

The suites share one Neovim and one fixture tree, so `tests/spec.lua` lists
them in a deliberate order rather than discovering them — a file nobody listed
fails the run instead of silently never being run.

### End to end, against a real daemon

The headless suite stubs the daemon, so it cannot catch the bugs that only
exist with one: a thought that streams in as fourteen blocks, a surface that
swaps when you paste, a workspace that never gets its title. `tests/e2e/`
drives the whole stack instead:

```sh
tests/e2e/run.sh              # every scenario
tests/e2e/run.sh thinking     # only scenarios whose name matches
tests/e2e/daemon.sh stop      # take the throwaway daemon down
```

- **A throwaway daemon.** `daemon.sh` runs your installed `paseo` with its
  own `PASEO_HOME` under `$TMPDIR/paseo-e2e`, on port 6797, with the relay
  off. It never touches the daemon on 6767. It stops only the pid it started.
- **A provider with no model behind it.** `fake-acp.mjs` is a scripted ACP
  agent registered as the `fake` provider. It streams reasoning in small
  chunks, makes a tool call, and answers. It is free, offline and the same
  every run. Words in the prompt pick the script: `think`, `tool`, `slow`,
  `long`, `echo`.
- **A real Neovim in tmux.** `nvim.sh` opens Neovim against that daemon and
  sends it keys. Scenarios assert on `nvim.sh state`, a JSON dump of the
  mount, windows and transcript blocks read from the running instance, and on
  the daemon's own CLI (`daemon.sh paseo ls --json`).
- **Screenshots.** `nvim.sh shot <name>` captures the pane in colour and
  renders it to a PNG under `$TMPDIR/paseo-e2e/shots`, because a test never
  says how something looks.

It needs `tmux`, `python3`, `node` and a Chromium-family browser for the
PNGs. It is opt-in and not part of CI: it runs the daemon you have
installed, which is the point.

### Benchmarks

Numbers rather than pass/fail, so they are not part of `run.sh`:

```sh
tests/bench/run.sh micro [out.json]   # main-loop work, stubbed daemon, headless
tests/e2e/bench.sh [label]            # real windows against a throwaway daemon
python3 -I tests/bench/compare.py before.json after.json
```

- **Micro** times what a key press waits on at the sizes a real day reaches
  — fifty workspaces, a hundred and fifty agents, a long reply — with every
  daemon reply canned: building and painting the rail, a spinner tick, one
  agent event fanning out to every listener, a reply streaming in, a
  conversation loading, and the new-task screen working out where it is.
- **UI** seeds its own daemon (port 6798, `$TMPDIR/paseo-bench-e2e`) with
  twenty worktree workspaces of two agents each, then times each flow from
  the function a key calls to **paint** (the window is up and the loop has
  gone idle) and **ready** (the real content is in it): opening a chat cold,
  the rail, the Settings panel, the new-task screen, switching chats. Then a
  load test: four agents streaming with the rail open, and how much of each
  second the main loop spent drawing.
- **In your own editor**, `PASEO_PERF=1 nvim` (or `:Paseo perf` once) records
  the same spans — and, for every request, how long it waited in the sidecar's
  queue against how long the daemon took — and `:Paseo perf` prints them.

[![tests](https://github.com/milindmadhukar/paseo.nvim/actions/workflows/tests.yml/badge.svg)](https://github.com/milindmadhukar/paseo.nvim/actions/workflows/tests.yml)

Every push and pull request runs the suite against Neovim 0.11, stable and
nightly, plus `tests/orphan.sh` under both Bun and Node. Nightly is allowed to
fail: it breaks for reasons that are not this plugin's.

## Agent skills

The plugin ships five skills in `.agents/skills/` — `workspace`,
`workspace-commit`, `workspace-pr` (multi-repo workspaces), `explain-change`
(the rubric `:Paseo explain` uses) and `paseo-sdk`. They are plain markdown
over plain git and `.workspaces/workspace.toml`; nothing in them needs a binary this
plugin does not ship.

An agent only discovers skills near its working directory, so bundled ones are
invisible everywhere **except inside this repository** — which is backwards,
since three of them are about projects that live somewhere else entirely:

```vim
:Paseo skills              " what is bundled, and where it has got to
:Paseo skills install      " symlink them into ~/.claude/skills
```

**Global is the default, and that is not taste.** An agent working in a
workspace has a cwd of `<project>/.workspaces/<name>/<repo>` — a *member
worktree*. It reads project skills from there and the repo around it, so
`<project>/.claude/skills` is two levels up in a different tree: invisible to
the one agent these are for. `install project` exists anyway, and refuses when
that root is itself a git repository.

Installing is idempotent, and refuses to clobber: a directory it did not
create is left alone unless you add `force`, which *moves* it to
`<name>.paseo-backup` rather than deleting it. A link left dangling by a
plugin reinstall repairs without `force` — a link to nothing is nobody's data.
`dry` prints the plan without touching the disk.

It never runs on its own. Writing into `~/.claude/skills` changes the
behaviour of a different program, and a plugin does not get to do that as a
side effect of a command about worktrees. `:checkhealth paseo` names the
bundled skills and the command; that is the whole discovery mechanism.

## Layout

```
lua/paseo/          the plugin
  ui/               the design system, then the surfaces built on it
    theme.lua       tokens: the palette, the elevation ladder, the accent ramps
    hl.lua          applies them, plus the user's `ui.theme` overrides
    style.lua       frame presets, and the box characters nothing else names
    icons.lua       every glyph, by codepoint
    layout.lua      the sidebar's row budget, stated once
    native.lua      the full-screen surface: one Paseo tab, agents as buffers
    color.lua       colour arithmetic: mix, lighten, hue, HSL
    rail.lua        the workspace rail down the Paseo tab's left
    subagents.lua   the live subagent list `gs` opens
    surface.lua     which surface a chat goes on when nobody named one
    tree.lua        a workspace's sessions as the rail nests them: agents, subagents, terminals
    sidebar.lua     the narrow pane beside your code, in two real splits
    animate.lua     motion, none of which may change a height
    render.lua      the cell/line alphabet and its sinks
    widgets.lua     the vocabulary: cards, chips, keycaps, tiles, bars, tables
    manifest.lua    the workspace manifest, as a screen you answer
    panels/         Settings, Changes, Usage -- the native panel split
  workspace/        assembling N worktrees into one unit of work
  pickers/          workspaces, sessions
  fork.lua          a second agent that starts where this one has got to
  start.lua         what to do in a directory with nothing running in it
  pr.lua            what GitHub thinks of the branch each repo is on
  plugin.lua        where this plugin's own files are, asked once
  skills.lua        installing the bundled skills where an agent can see them
sidecar/            paseo-bridge.ts entry point, bridge-*.ts modules, SDK deps
.agents/skills/     the bundled agent skills -- the source of truth
.claude/skills/     symlinks into .agents/skills, for Claude Code -- plus
                    paseo-e2e, the dev-only skill for driving this checkout
                    against real test agents (not shipped)
tests/              fixtures + suites, run by tests/run.sh
doc/                :help paseo
```

Builds real git fixtures and runs the suite in a real Neovim — no plenary, no
busted. Every assertion corresponds to something that was actually wrong at
some point, not to a line that wanted covering: the porcelain-v2 rename record,
beginning- and end-of-file deletions, a whole-file deletion, a pure rename, a
non-ASCII path, and partial staging of one hunk among three.

## Architecture

Three layers with clean seams, so each can be replaced without touching the
others.

```
┌ paseo.nvim ──────────────────────────────────────────────────┐
│  paseo.repos · paseo.git · paseo.ref · explain bridge · UI   │
└───────────┬──────────────────────────────┬───────────────────┘
            │ in-process                   │ stdio JSON-lines
            │                              │ (push, ~1–10 ms)
┌───────────▼──────────────┐   ┌───────────▼───────────────────┐
│ workspace/ (Lua)         │   │ TypeScript sidecar (Bun/Node) │
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

Assembly builds the composite directory, then registers it with Paseo as an
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
to Lua over stdio, spawned once per Neovim session — a moment after startup
when a local daemon is already running (`paseo.prewarm`), otherwise on the
first thing that needs it. Booting it to its `ready` line is about 200 ms.

**Requests run at once**, ordered only where order matters
(`sidecar/bridge-dispatch.ts`): `connect` and `close` are barriers; requests
about the same terminal, agent or dictation stream keep their order, as do
the ones that may create a workspace for the same directory; everything else
is concurrent. It used to be one queue, which put a `providers` call — it
waits up to 15 s for a directory's discovery — in front of the conversation
you had just opened. `:Paseo perf` shows, per request, the time it spent
queued against the time the daemon took.

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
port. Each is probed with `GET /api/status` — without blocking the editor, one
after another. A `401` counts as *reachable*: the
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

## Notes from the source

Things that are true of gitsigns and git, checked rather than assumed, and
several of which contradict the obvious approach. The ones about hunks, staging
and the diff panel are kept even though those surfaces moved into the config —
they are exactly what you need when you rebuild them, and `paseo.git` already
encodes the first four.

**Delete hunks are the whole problem.** `stage_hunk()` *does* work on a pure
deletion: `hunks.lua:51` sets `vend = added.start + max(added.count - 1, 0)`, so
a delete occupies exactly one line — the line *above* the removed block — and
`find_hunk` special-cases deletions at beginning- and end-of-file. The pain is
visibility, not capability. The consequence for us is sharp: a delete hunk's
quickfix `lnum` must be `c` from `@@ -a,b +c,0 @@`, **not `c + 1`**, or
`stage_hunk()` misses every deletion.

**`gitsigns.setqflist('all')` cannot be merged across repos.** It ends in
`vim.fn.setqflist({}, ' ', …)` — a replace — and collects repos from attached
buffers plus `uv.cwd()` only (`actions/qflist.lua`). At review start, with no
buffers open, it sees one repo, and a workspace has six. That is why
`paseo.git.hunks()` exists and is public: it reads `git diff -U0` per repo, so
your list can span the whole unit of work.

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
- **Phase 1 — the review loop, end to end.** *(done, then split)* Review and
  explain shipped as one phase because they are halves of a single loop: *find
  the hunk → read it → stage it, or ask about it → next hunk*. The loop works;
  what changed is where each half lives. The **navigation** half — changed-files
  picker, per-hunk quickfix, staging keys, diff panel — turned out to be
  ordinary Neovim plumbing with no Paseo in it, and moved to the nvim config on
  top of `paseo.repos` / `paseo.git`. The **interrogation** half is what this
  plugin keeps: references from cursor / selection / hunk / file, the Bun
  sidecar, and a shared `explain-change` skill whose rubric ends in *what the
  reviewer should push back on* — and now asks *which agent wrote this*.
- **Phase 2 — workspace assembly.** Started as a Go CLI and is now
  `lua/paseo/workspace/`. The only argument for Go was concurrency across ~66
  git invocations, and `vim.system` gives that natively — so the binary bought
  a build step, a release pipeline and a second language for nothing.
- **Phase 3 — workspace layer.** Workspace picker with a live, push-driven
  agent status column; `<CR>` switches this Neovim, or runs whatever
  `workspaces.open` is.
- **Phase 4 — commit, PR, merge.** Agent-agnostic skills over plain git and
  the manifest -- no CLI of our own to install, which is what makes them
  usable by whatever agent the reader happens to be running.

## Licence

MIT.
