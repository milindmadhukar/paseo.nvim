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
    "nvzone/volt",
    "nvim-telescope/telescope.nvim",
    "lewis6991/gitsigns.nvim",
  },
  event = "VeryLazy",
  opts = {},
}
```

**No build step and no binary.** Everything is Lua, except the modular TypeScript
sidecar run by `bun` (or node ≥ 22) — no bundling, no
compilation, nothing to fetch from a releases page.

`VeryLazy` rather than `cmd = "Paseo"` matters for one small reason: lazy.nvim
has no checkhealth integration, so an unloaded plugin is not on the
runtimepath and a cold `:checkhealth paseo` answers *"No healthcheck found"*,
which reads like a broken install.

| Needed for | |
|---|---|
| Everything | Neovim 0.11+, `git`, a Nerd Font |
| The chat UI | nvzone/volt |
| The workspace and agent-session pickers | telescope.nvim |
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
    cli = "paseo",
  },

  ui = {
    surface = "float",            -- where `:Paseo chat` opens. Or "sidebar".

    style = "plate",              -- frame language. See "Style".

    colors = "auto",              -- derive from the colourscheme. Or "fixed".
    palette = {},                 -- the eight base colours, by name
    theme = {},                   -- highlight overrides, laid over the derived ones
    animate = {                   -- or `false` for instant
      bars = true,                -- ease a bar towards its new value
      flash = true,               -- tint a tool card as it settles
      fps = 30,
    },

    float = {
      width = 94,                 -- percent of the editor, 1-100
      height = 86,
      -- row and col are absent: absent means centred
      composer = 7,               -- rows the composer may grow TO
      zindex = 30,                -- BELOW the 50 a float gets by default
      backdrop = true,
      tab_keys = true,            -- bare 1-6 switch tabs; see below
    },

    sidebar = {
      width = 40,                 -- percent of the editor's columns
      min_width = 60,             -- ...but never narrower than this, in cells
      composer = 8,               -- the MOST rows the composer grows to
      position = "right",         -- or "left"
    },

    terminal = {                  -- terminals are sessions; see below
      keys = { next = "<C-j>", prev = "<C-k>",
               sessions = "<C-s>", terminal = "<C-l>" },
      presets = {},               -- extra entries for `c`
    },

    answer = {                    -- where you answer a question, or decide a plan
      width = 96,                 -- a CAP in cells, not a share of anything
      min_width = 54,             -- narrower than this and it centres on the editor
      backdrop = true,            -- dim the conversation behind it
      zindex = 190,               -- above everything; see below
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
    open = "tab",                 -- what <CR> in the picker does: a new tab
                                  -- page `tcd`'d in. Or "tcd", "cd", or a
                                  -- function -- see below
  },

  review = {
    agents = true,                -- list the other Paseo agents working here,
                                  -- so the review agent can ask what they did
  },

  quit = {
    warn_active_agents = true,    -- warn before leaving while agents are active
  },
}
```

## Commands

| | |
|---|---|
| `:Paseo chat` | Open/close the chat, on whichever surface `ui.surface` names |
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
| `:Paseo dash` | The chat full screen, with the agent panels |
| `:Paseo sidebar` | The chat in the pane beside your code |
| `:Paseo model [provider/model]` | Set the preference for new agents; no agent is created |
| `:Paseo workspaces` | Workspace picker — open, inspect agent sessions, create, archive |
| `:Paseo wcreate` | Create a workspace here — the shape is worked out for you |
| `:Paseo agents` | Agent sessions in this workspace |
| `:Paseo sessions` | Compatibility alias for `agents` |
| `:Paseo term` | Terminals in this workspace, as many as you want |
| `:Paseo ws …` | Manifest-level: `init` · `create <name> [repos]` · `rm` · `ls` · `status` |
| `:Paseo agent [stop]` | Sidecar and agent status |
| `:Paseo repos` | The repos in the current unit of work |
| `:Paseo health` | `:checkhealth paseo` |

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
workspace** leaves the source untouched and starts a branch on the selected
model; **Use for this agent's future turns** changes the existing agent; Cancel
does neither. Values that the target model does not support are replaced with
that model's defaults.

In either chat buffer, press `f` in normal mode to fork the complete
conversation available at that moment into a new workspace. Paseo supplies a
chat-history attachment; the plugin asks for the workspace name and the fork's
first prompt, creates the appropriate local/worktree/assembled workspace, and
creates the agent with that prompt and attachment atomically. A host without
the `agentForkContext` capability is rejected before anything is created. If
agent creation fails after workspace creation, the empty workspace is retained
and named in the error.

### The header

The header says what the session *is*:

```
─ codex/gpt-5.6-sol · Auto-review · 󰧑 high · Fast · 58% left · ~/Code/paseo.nvim ──── ⠹ 28m 49s ─ ⏎ send ─
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
needs them or not, it cannot. The dashboard's footer keeps a copy for the tabs
that have **no** composer on them — a turn runs on while you read the Changes
panel, and that is exactly when nothing else on screen is moving.

A pending permission shouts from the header itself — ` needs you` — because
then the agent is not working, it is waiting for you.

**It is drawn against the box you type in**, one row above it, on both
surfaces. That is a move: it used to live at the far top of the screen — a
winbar over the transcript in the sidebar, the first row of the chrome on the
dashboard — which is as far from the cursor as that screen goes. You decide
what to type with those five facts and you decide it while looking at the
composer, so they belong there. It doubles as the composer's title row, which
is what lets the box drop its drawn border and be a plate like everything else
([below](#the-composer)).

Where there is no box there is still a header: on every dashboard tab but
`Chat` it is a volt section in the chrome above the tab bar, so "which model is
this" does not stop being answerable when you look at Usage — and clicking it
takes you to the panel that can change what it says. On the `Chat` tab that
row is given back to the transcript.

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
then the model. Shortening is tried only once there is nothing cheaper left to
drop: `~/Code/paseo.nvim` beats `paseo.nvim`, and `paseo.nvim` beats no
directory at all.

```
─ Plan Mode · paseo.nvim   ⠹ 1m 12s ─ 󰌑 / Alt + 󰌑 send ─
```

Nothing outranks a pending permission, which is never dropped at any width.

The row at the top of the sidebar is left saying which session you are looking
at, with the surface's own keys on the end of it.

### The full-screen surface

The default. `:Paseo chat` opens it, `:Paseo chat` again closes it, `<C-f>`
swaps to the sidebar and back. `<C-c>` stops the turn — from the composer or
the conversation, normal mode or insert.

```
   1 󰀄 Chat   2 󱙺 Agents & terminals   3 󱕂 Settings   4 󰘬 Changes   5 󰄨 Usage   6 󰙅 Workspaces
   󱙺 main   󱙺 reviewer   󰆍 lazygit                                    Ctrl + s  sessions
```

The tab bar **degrades rather than truncates**, because the tab that would
fall off the end is always the last one — which is the one you had not
discovered yet. The hint bars do the same: a winbar wider than its window is
cut from the *left*, so a narrow sidebar was eating `send` — the first thing
you need — to keep `close`. Four levels, widest that fits:

| | |
|---|---|
| `1 󰀄 Chat` | number, icon and name |
| `1 Chat` | the icon goes first: the name is what you read, the icon is what you recognise |
| `1 󰀄` | six of these fit in 36 columns |
| `1` | and at the last level the active tab alone keeps its name |

The row count never changes at any level, because the body height and the
composer geometry are both measured against it.

| | |
|---|---|
| `Chat` | the conversation and the composer, real buffers floated on top |
| `Agents & terminals` | the agent sessions **and terminals** here, live; open one, or `y` to copy an agent ID |
| `Settings` | mode, thinking level, model, feature toggles — keyboard or click |
| `Changes` | what is changed on disk, per repo; open one |
| `Usage` | context window, tokens, cost — and this provider's 5-hour and weekly limits |
| `Workspaces` | every workspace Paseo knows, grouped by project; archive one, or forget a project |

`Agents & terminals`, `Workspaces` and `Changes` are one kind of screen and
take one set of keys — `j`/`k` to move, `h`/`l` by section, `g`/`G` to the
ends, `<CR>` to open, `r` to re-fetch — plus their own verbs:
`c`/`a`/`y`/`R`/`d` on `Agents & terminals`, `n`/`o`/`d` on Workspaces. **The focused row is painted**, in the colour hover
uses, and arriving at a tab puts focus on a row so the first `<CR>` does
something.

**Where the cursor is and which one is open are two different marks.** The
focus band is one flat sweep across the row, so "this is the session you are
in" — which used to be a coloured bar and a coloured title *inside* that sweep
— said nothing the moment you pointed at the row, and the two states were
indistinguishable whenever they were the same row. Both marks live in a
two-column gutter the band never paints over now: a caret for the keyboard, a
bar for the live one.

```
   ▌ 󱙺 󰦖 fix the archive redraw                            claude/opus     ← open, not focused
     󱙺 󰧞 sidebar perf                                    claude/sonnet
  ▸  󱙺 󰀦 voice dictation                     needs you      codex/gpt     ← focused, not open
```

**A push repaints the surface.** Both directories are fed by the daemon rather
than polled, and nothing used to ask the screen to draw them again — so
archiving a session left its row up until the next `j`, and an agent that
started working did not change colour until you moved. One archive produces
three `remove` events from a live daemon, so the repaint is coalesced, and it
redraws the session strip plus the list itself and nothing else: the Changes
panel shells out to `git status` per repo, and it is not what changed.

None of that was true before. Selection lived on the **cursor**, which volt
resets to line 1 after every click, nothing was drawn to say where it was, and
the cursor was never put on a row — so Sessions had working keymaps and read as
a tab you could only click, and Workspaces had no keymaps at all. Focus is held
by **id** now, so a list that moves under you — and these are push-fed, so they
do — does not take it with it.

`1`–`6` jump, `<M-1>`–`<M-6>` and `<Tab>`/`<S-Tab>` do the same, and
everything that does something responds to a click as well.

#### The composer

The box you type in **grows with the prompt** — one row when it is empty, up to
`ui.float.composer` rows as you fill it, and back again when you send:

```
─ claude/claude-opus-5 · Plan Mode · 71% left · ~/Code/paseo.nvim ───── ⠹ 1m 9s ─ 󰌑 / Alt + 󰌑 send ─
 why is the ref suite opening a file it then deletes?
```

Standing at its configured height over an empty buffer made it the largest and
emptiest shape on the screen: seven rows of flat card colour, nothing saying
you could type in it. Wrapped lines count towards the height — `wrap` is on, so
a 300-column paragraph is four rows on screen, and asking the buffer for its
line count would say one and leave the cursor off the bottom of the box.

**No box drawn around it, under `plate`** — which is the default, and where
nothing else on the surface has an edge either. A hard rounded rule around the
composer, inside a window whose own edge is invisible, above cards with no
frames, was the one thing on the dashboard that ignored `ui.style`. What
separates the box from the transcript now is what separates every other card
from it: one tier of elevation, and a title row. Under `rounded` and `square` it
keeps a real frame, because that is what those styles are for.

The title row is [the header](#the-header), and it ends with **how to send**.
Both keys, because they are not interchangeable: `<CR>` sends from normal mode
and opens a line from insert mode, so the one that works while you are still
typing is `<M-CR>` — Alt and Enter. (`<C-CR>` is bound beside it for terminals
that speak the kitty keyboard protocol; the ones that do not simply never send
it.) **`<C-s>` is not either of them.** It means *the session list* on the
chrome, in every terminal, and in the session strip drawn four rows above the
box — so a composer that quietly sent on it was one key with two meanings, both
advertised on screen at once. From the composer it now does what it does
everywhere else: takes you to the session list.

A bare digit is also a **count**, and the two panes these are bound on are
ordinary buffers — so while the dashboard is open, `3p` and `5j` in the
conversation and the composer go to the tab bar. That is the right default for
a seven-line prompt box, but it is a trade: `tab_keys = false` buys the counts
back and leaves the `<M-…>` forms and `<Tab>`, which collide with nothing.

Two things had to be true for that, and neither was. The number keys were
bound on the **chrome** buffer, and the Chat tab puts your cursor in the
composer — so the footer advertised keys that went to a buffer with no such
mapping. And the click targets were all there, on the cell's third element the
way volt wants them, but `volt.events.enable()` — which routes `LeftMouse` to
them, and which `volt.run` calls — was never reached, because this surface
drives `gen_data`/`redraw` itself to keep the conversation buffer out of
volt's hands.

**The box is yours**, under `ui.float`. `width` and `height` are **percentages
of the editor, 1–100** — the same unit
[floaterm](https://github.com/nvzone/floaterm)'s `size` takes, computed with
the same arithmetic in the same order, so a number means the same thing in
either config and the two agree to the cell rather than to within a rounding
error. `row` and `col` are absolute cells, because they are window coordinates
rather than sizes; absent means centred, with the same `(total - size) / 2`
floaterm centres with. So floaterm's `size = { h = 90, w = 92 }` is:

```lua
ui = { float = { width = 92, height = 90 } }
```

and the two windows land in the same place — switching between them does not
move the frame under you.

Percentages rather than a margin in cells because a margin that looks right on
a 200-column monitor is most of a laptop screen; and 1–100 rather than
fractions because `0.92` and `92` are each obvious once you know which
convention you are in, and nothing on the page tells you which. A function is
the escape hatch for a size no percentage can express, and returns cells.

Whatever you ask for is clamped to 60×20 — below that the tab bar and the
composer stop fitting — and to the editor, so no setting can put the border
off screen.

**The composer is the size of what is in it**, on the sidebar as well as the
dashboard. One row over an empty buffer, growing as you type up to `composer`,
shrinking back when you send — measured in *screen* rows rather than buffer
lines, because it soft-wraps and one pasted sentence is three rows in a narrow
pane. A fixed eight rows in the sidebar was a third of that pane spent on
whitespace for the whole of a session.

**The sidebar takes the same units**, under `ui.sidebar`: `width` as a
percentage, `min_width` as a floor in cells (40% of a 100-column terminal is a
pane too narrow to read a tool card in, and a percentage has no way to know
that), `composer` in rows, and `position` for which side it opens on. Its
width is also capped at what `'winwidth'` leaves for the window you came back
from — Neovim claws the difference back the instant focus returns there, so a
bigger number is not a wider sidebar, it is a number that quietly does not
happen.

**Z-index is 30, not 100.** The default for a floating window is 50, and
plenary's popup — so every telescope picker — takes it. A dashboard above that
number renders every telescope picker, its previewer and every `vim.ui.select`
*underneath itself*, which looks exactly like the command doing nothing. The
permission dialog is the one exception and sits above everything, because it
is the one window that must not be covered.

The chrome is four volt sections rather than one, which is not tidiness: the
header repaints ten times a second while a turn runs, and a single section
would drag the `Changes` panel — one `git status` per repo — through every
frame.

### The Settings tab

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

On **Agents & terminals**, `y` copies the selected agent's complete ID to the
unnamed register and, when available, the system clipboard. The agent picker
uses `<C-y>`. Terminal rows deliberately have no copy-agent-ID action. To ask
one agent to contact another, copy the receiving agent's ID, paste it into the
sending agent's chat, and ask it to use Paseo's
[cross-agent prompt tool](https://paseo.sh/docs/orchestration-workflows#send-a-prompt-to-another-agent).

This panel previously had **no key bindings at all**: interaction was 100%
volt click dispatch, so the only way to change a setting was to reach for the
mouse or land the cursor on exactly the right row. The mouse still works, and
pointing at a setting lights it exactly as moving to it does — hover and focus
are the same paint, because they are the same state.

Focus is *ours*, not the cursor's. Volt dispatches `<CR>` through a
`CursorMoved` autocmd and resets the cursor to `{1,1}` after every click, so a
selection living on the cursor is thrown away by the framework on each
interaction.

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

The new-agent screen is what you get when the answer is genuinely nothing, and
it **takes the cursor when it opens** — it is a question, and a question you
have to click before you can answer is a worse question.

Starting an agent where there is none opens **that same renderer** over a
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

`c` creates, `q` cancels, and nothing exists until you press one. There is no
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
lists on the `Agents & terminals` tab beside the agent sessions, and opening
one shows it **on the Chat tab**, where the conversation would be:

```
 ╭──────────────────────────────────────────────────────────────────────╮
 │  claude/opus-5 · acceptEdits · 58% left               ~/Code/kora     │
 │  1 󰀄 Chat   2 󱙺 Agents & terminals   3 󱕂   4 󰘬   5 󰄨   6 󰙅           │
 │ ──────────────────────────────────────────────────────────────────── │
 │  󱙺 main   󱙺 reviewer   󰆍 lazygit   󰆍 shell      Ctrl + s  sessions   │
 │                                                                      │
 │  ▐▛███▜▌ Claude Code v2.1.263                                        │
 │  ▝▜█████▛▘ Opus 5 (1M context)                                       │
 │                                                                      │
 │  > _                                                                 │
 ╰──────────────────────────────────────────────────────────────────────╯
```

It used to be a surface of its own — a rail of names, a title bar, the terminal
and a backdrop, four windows over the top of whatever you were looking at, with
its own geometry, its own z-index and its own keymaps. That shape was
[floaterm](https://github.com/nvzone/floaterm)'s, and it was the wrong one to
borrow: a terminal you open a second application to reach is not a session,
it is a place you get stuck, and the way back out was `q`.

Now there is **one surface**, and what changes is what fills the panel area — a
conversation and its composer for an agent, the PTY outright for a terminal.

**The session strip** under the tab bar is what makes that legible: one chip per
session in this workspace, agents then terminals, the one you are in lit. It is
on **every** tab, like the header, because "which session am I in" does not stop
being worth answering when you look at Usage — and a terminal has no transcript
and no composer, so without it the dashboard could be showing a PTY with nothing
on screen naming it. A chip is a click; `<C-s>` is the keyboard.

In a terminal: `<C-s>` to the session list, `<C-j>`/`<C-k>` to the next and
previous session here, `<M-1>`–`<M-6>` for the tabs, `q` (normal mode) to close.
**And a chat picked out of that list opens the chat** — which session the Chat
tab is on survives a trip through the panels, so `<C-s>` out of a terminal and
an agent chosen from the list used to land back on the same PTY, a keystroke
that visibly did nothing.
**All of them are bound in terminal mode too**, which is the only way any of
them is worth having — otherwise each starts with `<C-\><C-n>`. That does take
them from whatever is running inside, which is right for `claude` and wrong for
`tmux`, so `ui.terminal.keys` renames or disables any of them.

The **digits are deliberately not bound**: a bare `5` in a terminal costs you
`50k` to scroll back, and `<M-5>` reaches the same tab. `<C-c>` is not bound
either — it is SIGINT and belongs to the program. `<Esc>` is never bound at all:
it belongs to the PTY, so vim running inside one can still leave insert mode.

On the `Agents & terminals` tab, `c` starts a terminal, `R` renames one and `d` kills it
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
you opened. That registry owns no window, which is why deleting the surface
above it was a deletion and not a rewrite.

A terminal **dying** is a directory update that no longer lists it, never a
process exiting under us — Paseo owns the process, not Neovim, so none of
floaterm's reaping machinery applies. The Chat tab falls back to the agent and
the dashboard stays open.

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

Every style produces the **same number of rows** for the same content, which is
not tidiness: volt records a section's start row when the layout is measured
and never recomputes it, so a card whose height depended on the frame would
move every section below it the moment you changed this.

The default is `plate` because the old look was three frame weights competing
inside one window — a box around every card, inside the float's own border,
with a rule under the tab bar as well.

**That rule under the tab bar is gone in every style.** It survived for the
framed ones, where it was the same complaint in miniature: the float's own
edge, a full-bleed rule directly under the pills, and a box around every card
below it. The pills are a row of filled shapes and delimit the bar by
themselves. The *row* stays — dropping it would shift every section below, and
volt does not recompute those.

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
| `ui.colors` | `"auto"` derives the base colours from the colourscheme — what makes the dashboard look like it belongs to whatever you have loaded. `"fixed"` uses the plugin's own instead, and then a `:colorscheme` does not move them. |
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
-- the dashboard's blue to be.
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

- **With NvChad**, volt's `Ex*` groups, which are base46's palette.
- **Without it**, `DiagnosticError`/`Removed`, `DiagnosticOk`/`Added`,
  `Function`, `DiagnosticWarn`/`Changed` — the groups that *mean* what we mean.
  `Added` before `String`, because on `morning` `String` is **magenta**, so a
  tool that succeeded was drawn the colour of a string literal.

We do not read volt's `Ex*` groups on the non-base46 path, and that is
deliberate: volt's own fallback writes `ExBlue = { fg = get_hl "Function" }`,
and `volt.utils.get_hl` returns a **table**, not a colour — so on every setup
without NvChad each accent resolves to `#000000`. Black is not obviously wrong
on a dark theme, which is why it went unnoticed. It is simply invisible.

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
`render.icons`, the `permission` marker in the Agents & terminals panel, two group icons
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

Neither changes a section's **height**, and that is a hard constraint rather
than a choice: volt records each section's start row when the layout is
measured, so a section that grows mid-flight draws every section below it at the
wrong row — as `Invalid 'line': out of range`, thrown from inside `vim.on_key`.

There was a **third** effect, staggering a panel's rows in on a tab switch, and
it is gone for a reason worth recording. It respected that constraint — it drew
fewer rows into a block already padded to its final height. But the Agents & terminals
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

  1-9  pick    ⏎  send the answers    c  note    ⇥  question    ␛  later
```

`1`-`9` picks, `j`/`k` reaches an option past the ninth, `<Space>` takes the one
you are on, `x` clears the answer, `s` skips an optional question, and `<Tab>`
moves between them. The marker is a checkbox where a second pick **adds** and a
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

**The box becomes a meter.** While the microphone is open the bar over the
composer is the recorder — a red dot, a level, how long you have been talking,
and the key that stops it — and a scrolling waveform is drawn *inside* the box,
as virtual text, so your draft is untouched:

```
 󰍬 listening  ▁▁▂▃▅▆▇▅▃▂▁▁▁▁▁▁  0:04   Ctrl + t  stop    󱊷  discard
 ▁▁▁▂▃▅▇█▇▅▃▂▁▁▁▂▄▆▇▇▅▃▁▁▁▁▂▃▅▆▇▇▆▄▂▁▁▁
```

That is there because *"it is not clear when I am speaking"* is the whole
problem with dictation you cannot see: a word missed by a muted microphone and
a word missed by a thinking daemon look identical if the only feedback is text
that has not arrived yet.

**The meter is a ratio against the room, in decibels.** Raw loudness means
nothing on its own — the laptop this was written on reads 0.16 RMS with nobody
in the room, while a headset a foot away reads a hundredth of that — so the
floor is the quietest reading of the last twenty seconds and the wave is how
far over it you are, with four times the room as full scale. A *difference*
would not do: on a microphone whose room reads 0.16, genuinely doubling the
input moves the number by 0.16 and the same doubling on a quiet headset moves
it by 0.002, so a meter built on subtraction is calibrated for exactly one
microphone. As a ratio both are the same event — which is what your ear says
too.

Two versions of this were wrong before it worked, and both failed the same
way, by drawing a flat line at a working microphone: one crept its floor
upwards at a fixed rate, so a few seconds into a sentence the floor had climbed
over the voice and the wave died mid-word; the next gated on a fraction of that
floor, which in a loud room is a bar an ordinary voice cannot clear. A twenty
second window and a decibel ratio have neither failure mode.

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
| **Tab** | A Paseo application surface that presents an agent session. It is distinct from a Neovim tab page. paseo.nvim's dashboard sections are also UI tabs, not isolation boundaries. |
| **Terminal** | A daemon-owned PTY inside a workspace. It appears beside agent sessions but is not an agent. |
| **Worktree** | A Git checkout used to isolate a workspace. It is an implementation mechanism, not a synonym for workspace. |
| **Daemon** | The background Paseo process that owns projects, workspaces, agent sessions, timelines, and terminals. |
| **Provider** | The agent backend, such as Claude, Codex, or OpenCode. |
| **Model** | A provider-specific model used by an agent. |
| **Subagent** | An agent created or coordinated by another agent as part of its work. |
| **Fork** | A new agent session initialized from a source agent's conversation snapshot. paseo.nvim currently places the fork in a new workspace. |

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
explicit bypass. Set `quit.warn_active_agents = false` to opt out. Custom quit
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
| A git repository | Paseo **cuts the worktree** itself, on `ws/<name>` off whatever is checked out | `worktree` |
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

`:Paseo ws init` opens the same screen; `:Paseo ws init raw` is the old TOML
buffer. `:Paseo ws create <name> repo,repo` is still the only way to pick
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

`<CR>` in the picker switches **inside this Neovim**: a new tab page, `tcd`'d
into the workspace. A tab rather than a bare `cd` because chdir'ing in place
leaves the buffers, LSP clients and jumplist of the workspace you just left
pointing into it — one tab per unit of work keeps them apart for the price of a
tab. `workspaces.open` picks something else:

| | |
|---|---|
| `"tab"` | new tab page, `tcd`'d in — the default |
| `"tcd"` | this tab's cwd, no new tab |
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
    return false  -- decline: fall back to the built-in tab switch
  end,
}
```

Returning `false` **declines**, so one config can spawn a window under a GUI and
switch in place in a terminal. Anything else — `nil` included — means you
handled it.

**An open chat comes with you.** It used to keep showing the agent in the
workspace you had just left — and since a float belongs to the tab page it was
opened on, the `"tab"` switch did not even leave it on screen. Now the surface
is rebuilt on the tab you are standing on, pointed at that workspace's agent.

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
your own configuration is loaded: volt, gitsigns and telescope are cloned into
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
```

The suites share one Neovim and one fixture tree, so `tests/spec.lua` lists
them in a deliberate order rather than discovering them — a file nobody listed
fails the run instead of silently never being run.

[![tests](https://github.com/milindmadhukar/paseo.nvim/actions/workflows/tests.yml/badge.svg)](https://github.com/milindmadhukar/paseo.nvim/actions/workflows/tests.yml)

Every push and pull request runs the suite against Neovim 0.11, stable and
nightly, plus `tests/orphan.sh` under both Bun and Node. Nightly is allowed to
fail: it breaks for reasons that are not this plugin's.

## Agent skills

The plugin ships five skills in `.agents/skills/` — `workspace`,
`workspace-commit`, `workspace-pr` (multi-repo workspaces), `explain-change`
(the rubric `:Paseo explain` uses) and `paseo-sdk`. They are plain markdown
over plain git and `.ws/workspace.toml`; nothing in them needs a binary this
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
    layout.lua      the chrome's row budget, stated once
    animate.lua     motion, none of which may change a height
    render.lua      the cell/line alphabet and the three sinks
    widgets.lua     the vocabulary: cards, chips, keycaps, tiles, bars, tables
    manifest.lua    the workspace manifest, as a screen you answer
    panels/         one per dashboard tab
  workspace/        assembling N worktrees into one unit of work
  pickers/          workspaces, sessions
  plugin.lua        where this plugin's own files are, asked once
  skills.lua        installing the bundled skills where an agent can see them
sidecar/            paseo-bridge.ts entry point, bridge-*.ts modules, SDK deps
.agents/skills/     the bundled agent skills -- the source of truth
.claude/skills/     symlinks into .agents/skills, for Claude Code
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
