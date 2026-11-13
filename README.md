# paseo.nvim

Drive [Paseo](https://github.com/getpaseo/paseo) coding agents from Neovim.
Chat with them, start them in a new worktree, answer their permission
requests, and ask one about the hunk under your cursor, without leaving the
editor.

Paseo runs the agents (Claude Code, Codex, OpenCode, …) in a local daemon.
This plugin gives it a Neovim-native front end: every agent is a buffer,
every pane a real split, and the keys are Vim's.

[![tests](https://github.com/milindmadhukar/paseo.nvim/actions/workflows/tests.yml/badge.svg)](https://github.com/milindmadhukar/paseo.nvim/actions/workflows/tests.yml)

## Requirements

| | |
|---|---|
| Always | Neovim 0.11+, `git`, a Nerd Font |
| Agents | the Paseo daemon (the desktop app runs one), and `bun` or `node` ≥ 22 |
| Pasting a screenshot | `wl-paste` (Wayland), `xclip` (X11) or `pngpaste` (macOS) |
| Dictation | `arecord`, `rec` (sox) or `ffmpeg` |
| Pull-request status | `gh` |

There's no build step and no UI library. The one dependency, the sidecar's
`@getpaseo/client`, is installed into `sidecar/` on first use.
`:checkhealth paseo` tells you what you have.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "milindmadhukar/paseo.nvim",
  event = "VeryLazy",
  opts = {},
}
```

The plugin maps **no** global keys. Pick your own:

```lua
vim.keymap.set({ "n", "t" }, "<C-\\>", "<Plug>(paseo-native)")      -- the chat, in and out
vim.keymap.set("n", "<leader>an", "<cmd>Paseo new<cr>")             -- start an agent
vim.keymap.set("n", "<leader>ak", "<cmd>Paseo ask<cr>")             -- ask about this hunk
vim.keymap.set("v", "<leader>ak", "<cmd>Paseo ask visual<cr>")      -- …or this selection
vim.keymap.set("n", "<leader>ae", "<cmd>Paseo explain<cr>")         -- explain this hunk
vim.keymap.set("n", "<leader>aw", "<cmd>Paseo workspaces<cr>")      -- switch workspace
vim.keymap.set("n", "<leader>as", "<cmd>Paseo settings<cr>")        -- mode, model, thinking
```

## Quick start

1. `:Paseo` opens the chat for the directory you're in. With no agent there
   yet, you get the new-task screen: pick Local or New worktree, write your
   first message, and send it with `<M-CR>` (or `<CR>` in normal mode).
2. The agent works in the middle of the Paseo tab. The **rail** on the left
   (`<C-b>`) lists your workspaces and their agents, and `<C-p>` opens a panel
   with Settings, Changes and Usage. In Settings, `m`, `t` and `s` open the
   permission mode, thinking level and model in your own picker: whatever
   replaces `vim.ui.select` (snacks, telescope, fzf-lua), so you can type to
   filter.
3. When the agent asks for permission, a dialog opens. `y` allows, `n` denies,
   and `1`–`9` pick a specific action.
4. Back in your code, put the cursor on a hunk and run `:Paseo ask`. The
   chat opens beside your code with the hunk as a chip, `@path:42-58`, in
   its composer. Type your question and send it; the agent gets the file and
   line range.
5. `:Paseo` again takes you back to your code.

## Commands

| Command | What it does |
|---|---|
| `:Paseo` | Open or close the chat |
| `:Paseo new [worktree]` | Start an agent here, in a new worktree, or a terminal |
| `:Paseo ask [hunk\|visual\|file\|cursor\|qf]` | Ask about code; `qf` covers the whole quickfix list |
| `:Paseo explain [kind]` | Explain code with the bundled review rubric, sent at once |
| `:Paseo workspaces [all]` | This project's workspaces (`all`: every project's) |
| `:Paseo agents` | The agents in this workspace |
| `:Paseo settings [mode\|thinking\|model\|features]` | The chat agent's settings; `mode`, `thinking` and `model` open straight in your picker |
| `:Paseo stop` | Interrupt the agent's turn |
| `:Paseo ws init\|edit\|create\|rm\|ls\|status` | Multi-repo workspaces |

Everything else is a key inside the chat or a Lua function.

## In the chat

| Key | Where | |
|---|---|---|
| `<CR>` / `<M-CR>` | composer | send (normal / either mode) |
| `g<CR>` | composer | send the other way mid-turn: queue instead of steer |
| `p` `P` `<C-v>` | composer | paste, **including an image** from the clipboard |
| `<C-t>` | composer | dictate |
| `<Up>` | empty composer | your previous prompts |
| `<C-c>` | chat | stop the turn |
| `f` | chat | fork the conversation |
| `<Tab>` | conversation | expand or collapse a tool call |
| `gp` | conversation | reopen a pending permission |
| `gs` | conversation | this agent's subagents |
| `<C-b>` `<C-h>` | full screen | the rail: show or hide it / go in and out |
| `<C-p>` | full screen | the Settings / Changes / Usage panel |
| `<C-n>` | full screen | a new session (Local or a new worktree) |
| `q` | chat | close it |

The rail uses nvim-tree's keys: `l`/`h` unfold and fold, `a` starts a new
session, `A` a new agent in the session under the cursor, `w` a session in a
new worktree, `t` a terminal, `d` archives, and `.` lists everything you can
do to the row. `g?` shows them all.

These are defaults, and they are bound only in Paseo's own buffers. Every
built-in key can be moved or unbound with the `keys` option
(`:help paseo-config.keys`). The full-screen keys are set in `ui.native.keys`,
so `rail = "<leader>e"` puts the rail on your explorer key in place of
`<C-b>`, and `rail = { "<C-b>", "<leader>e" }` binds both.

### Images

Copy a screenshot and press `p` in the composer, or `<C-v>` in insert mode.
The image is attached as `[Image #1]`, which you can refer to in the prompt.
Delete the placeholder and the image goes with it.
Without an image on the clipboard, `p` pastes text as usual.

Dragging an image file onto the terminal, or pasting one copied in a file
manager, also attaches it: the terminal sends the path, and the plugin
recognises it. Your terminal's own paste key on a raw screenshot sends
Neovim nothing at all, so use `p` for those.

### Asking about code

`:Paseo ask` works like Copilot's "Add to chat". The hunk, selection or file
becomes a chip in the composer of the chat in the sidebar, beside your code,
and you write the question after it. Go back to the code and ask about
something else, and the next chip joins the same message. A chip is plain
text: delete it and that reference no longer goes. `<C-f>` takes the chat
full screen and, from there, back beside the code. `review.surface =
"native"` sends asks to the full-screen tab instead.

### Lists look the same everywhere

Workspaces, agents, subagents, a fork's destination, the rail's `.` menu, a
base branch, a yes-or-no: every list uses one chooser. It's a real buffer
where the cursor is the selection. `j`/`k`, `/` and counts work as usual,
`<CR>` or `1`–`9` picks, `q` cancels, and any extra actions are listed in its
footer. Settings are cards, drawn in the same frame.

## Configuration

Every option is optional. These are the ones you're most likely to want:

```lua
require("paseo").setup {
  paseo = {
    provider = "claude/opus",     -- default model for new agents (unset: ask the daemon)
    -- url = "ws://127.0.0.1:6767/ws",   -- unset: discovered from the daemon's config
  },
  ui = {
    surface = "native",           -- :Paseo opens full screen; or "sidebar"
    send_behavior = "steer",      -- mid-turn: "steer" | "interrupt" | "queue"
    colors = "auto",              -- derived from your colourscheme; "fixed" for ours
    theme = {},                   -- highlight overrides: { PaseoChipOn = { bg = "#204a26" } }
    native = { rail = 32, panel = 56 },
  },
  voice = { key = "<C-t>" },
  quit = { guard = false },       -- true: ask before :q while an agent works
  keys = {                        -- remap built-in keys, by their default
    rail = { ["d"] = false },
  },
}
```

`:help paseo-configuration` has every option with its default.

## Lua API

```lua
local paseo = require("paseo")
paseo.toggle()                       -- :Paseo
paseo.new_task({ where = "worktree" })
paseo.ask("visual")                  -- :Paseo ask visual
paseo.settings("model")
paseo.toggle_feature()               -- Fast
paseo.toggle_plan()
paseo.paste_image("~/shot.png")      -- from a code buffer
paseo.stop()

local native = require("paseo.native")   -- the full-screen surface
native.toggle_rail()
native.panel("changes")
native.next()

require("paseo.ui.choose").select(items, opts, on_choice)   -- vim.ui.select, Paseo-style
```

There's also a data layer for building your own review workflow:
`require("paseo.repos").list()` gives the repos in the current unit of work,
and `require("paseo.git")` provides `status`, `hunks`, `buffer_hunks`,
`diff_text` and `stage`. Two events, `User PaseoWorkspaceOpen` and `User PaseoReview`, let you
decide what happens around a workspace switch.

`:help paseo-api` documents every function, `:help paseo-plug` the `<Plug>`
names, and `:help paseo-events` the autocmds.

## Multi-repo workspaces

A project that's a directory of several repositories can describe itself in
`.workspaces/workspace.toml` (`:Paseo ws init` writes it on a screen). A new
worktree then gets one worktree per repo, side by side, on one branch name,
and the agent works across all of them. A single repository needs none of
this, because Paseo's own worktrees are used. See `:help paseo-ws`.

## Agent skills

The plugin bundles skills for agents in `.agents/skills/`: explain-change,
paseo-sdk, and three about multi-repo workspaces. Install them where Claude
Code looks with `:lua require("paseo.skills").install()`. It only touches
what it put there. See `:help paseo-skills`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the test suite, the end-to-end
harness, the code layout and the architecture.

## Licence

MIT.
