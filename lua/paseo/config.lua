--- Configuration: defaults, user merge, and the accessor everything else uses.
---
--- The table is deliberately small. Options land here only once something
--- actually reads them -- a key that exists but is ignored is worse than no key,
--- because it reads like a promise.

local M = {}

---@class paseo.Config
---@field paseo paseo.Config.Paseo
---@field ui paseo.Config.UI
---@field voice paseo.Config.Voice
---@field workspaces paseo.Config.Workspaces
---@field skills paseo.Config.Skills
---@field review paseo.Config.Review
---@field quit paseo.Config.Quit
---@field keys table<string, table<string, string|string[]|false>>

---@class paseo.Config.Paseo
---@field url string?     Daemon WebSocket endpoint. Leave unset to DISCOVER
---                       it -- `daemon.listen` in the daemon's own config.json
---                       is the authoritative answer and 6767 is only a
---                       default. Setting this wins outright. See
---                       `paseo.daemon`.
---@field home string?    `$PASEO_HOME`; defaults to the env var, then ~/.paseo.
---@field password string? Daemon password, if it has one. Left unset for a
---                        local daemon, which does not.
---@field autostart boolean? Start the daemon when nothing answers. Default
---                          true: the alternative is every agent action
---                          failing until you go and start it by hand, which
---                          is precisely the trip out of Neovim this plugin
---                          exists to remove.
---@field provider string? `provider/model` for agents this plugin creates.
---                        Unset means "ask the daemon what is ready" -- which
---                        is the only answer that survives a different host.
--- (There is no `cli` key. `/usr/bin/paseo` is a perfectly good headless CLI,
--- but it still pays Node startup -- about 1s against 8ms for the socket -- so
--- nothing here shells out to it. The daemon is reached over its WebSocket.)
---@field default_host string? Configured host alias used by directory-based actions.
---@field hosts table<string, paseo.Config.Host>? Declarative daemon hosts. When
---                        absent the legacy keys above form one implicit local host.

---@class paseo.Config.Host
---@field label string?
---@field connections paseo.Config.Connection[]
---@field paths paseo.Config.PathMap[]?
---@field provider string?

---@class paseo.Config.Connection
---@field id string?
---@field type "local"|"direct"|"relay"
---@field address string? Direct host:port or ws(s) URL.
---@field tls boolean?
---@field password string|fun(): string?
---@field offer string|fun(): string?

---@class paseo.Config.PathMap
---@field local_root string
---@field remote_root string

---@class paseo.Config.UI
---@field surface "native"|"sidebar"  Which surface `:Paseo chat` opens on.
---                       "native" is the default: full screen, a tab page per
---                       agent, every pane a real split. The sidebar is the
---                       narrower thing beside your code; <C-f> goes from it to
---                       native. "float" and "buffer" -- the old volt
---                       dashboard's mounts -- are accepted and mean "native".
---@field send_behavior "steer"|"interrupt"|"queue"  What sending does while
---                       the agent is mid-turn. "steer" (the default, as in the
---                       Paseo app) folds the message into the running turn;
---                       "interrupt" stops the turn and starts a new one with
---                       it; "queue" holds it here and sends it when the turn
---                       ends -- or interrupts, if the agent is waiting on a
---                       permission, since a queued message would then never
---                       go. The other key (`g<CR>`, `<S-CR>`) does the
---                       opposite: queue when this steers, send now when it
---                       queues. Sending to an idle agent is just sending.
---@field style string|paseo.Style  Frame language. A preset name --
---                       "plate", "rule", "rounded", "square" -- or a table of
---                       the same fields, which only has to name what it
---                       changes. "plate" is the default and draws NO frame
---                       around a card: sections are separated by background
---                       elevation and padding instead. See `paseo.ui.style`.
---@field colors "auto"|"fixed"  Where the eight base colours come from.
---                       "auto" derives them from the colourscheme, which is
---                       what makes the surfaces look like they belong to
---                       whatever you have loaded. "fixed" uses the plugin's
---                       own instead -- for a theme whose colours the agent
---                       surfaces read badly in, or which simply is not what
---                       you want them to look like.
---@field palette paseo.Config.UI.Palette  Those eight colours, by name, laid
---                       over whichever source `colors` names. Everything
---                       downstream still runs: naming `bg` and `blue` alone
---                       gets a full elevation ladder and four accent ramps
---                       built from them.
---@field theme table<string, vim.api.keyset.highlight>  Highlight overrides,
---                       laid over the derived groups. The LAST word, and a
---                       different question from `palette`: a colour set there
---                       is a token every derived group is built from, while
---                       one set here is the one group you named. This is a
---                       config key rather than "set the group again after
---                       setup()" because the derivation re-runs on
---                       `ColorScheme` and used to overwrite anything set that
---                       way.
---@field animate boolean|paseo.Config.UI.Animate  Motion. `false` is instant.
---@field float paseo.Config.UI.Float
---@field sidebar paseo.Config.UI.Sidebar
---@field ask paseo.Config.UI.Answer
---@field terminal paseo.Config.UI.Terminal
---@field pr paseo.Config.UI.PR

---@class paseo.Config.UI.Palette
---@field red string?     Failure, and a destructive permission.
---@field green string?   Success, and the agent's own voice.
---@field blue string?    Your voice, headings, paths, and the seed the eight
---                       identity swatches are rotated off.
---@field yellow string?  Running, and a warning.
---@field grey string?    Everything that has to recede: dividers, labels,
---                       disabled rows.
---@field border string?  Frames, where a style draws them.
---@field text string?    Body text.
---@field bg string?      The editor background the five elevation tiers are
---                       stepped off, and the colour every accent ramp blends
---                       towards. Leave it unset on a TRANSPARENT theme:
---                       absent is what tells the derivation there is nothing
---                       to build tiers on, and painting an opaque rectangle
---                       over someone's wallpaper is worse than having no card.

---@class paseo.Config.UI.Animate
---@field bars boolean    Ease a progress bar towards its new value rather than
---                       snapping. The context-window bar is the one that
---                       benefits: a jump from 40% to 70% reads as a glitch.
---@field flash boolean   Briefly tint a tool card as it settles to ok or
---                       failed, then fade out through the accent ramp.
---@field fps integer     Frames a second for all of the above. Every frame
---                       repaints the panels, or the one transcript block that
---                       is flashing, in place -- cheap, but not free on a
---                       slow link.

---@class paseo.Config.UI.Float
---
---The old dashboard's table. What is still read from it is the workspace
---`rail` and `keys.new`, which the native surface binds, and `zindex`, which
---the subagent picker stacks itself over. The size, composer, `backdrop` and
---`tab_keys` fields described that float; they are still validated, so an old
---config loads, but no surface reads them now.
---@field width number|fun(columns: integer): integer   PERCENT of the editor,
---@field height number|fun(lines: integer): integer    1-100 -- the same unit
---                       floaterm's `size` takes, so a number means the same
---                       thing in either config. A function is the escape
---                       hatch for a size a percentage cannot express, and it
---                       returns CELLS.
---@field row integer?    Absolute editor cells; these are window coordinates,
---@field col integer?    not sizes. Absent means CENTRED, with the same
---                       `(total - size) / 2` floaterm centres with -- so the
---                       two at one size land in one place.
---@field composer integer|fun(lines: integer): integer  The MOST rows the
---                       composer grows to -- a ceiling, not a size: the box
---                       grows with what you type and shrinks back. The rest
---                       of the box, less the header, tab bar and footer, is
---                       the conversation. A function is handed the SURFACE's
---                       rows and returns cells, which is what lets a ceiling
---                       be a share of the space there actually is rather
---                       than a number that fits one terminal.
---@field composer_min integer  And the FEWEST. A one-row box reads as a
---                       filename prompt rather than as the place you write
---                       a paragraph, and the row you type on is the one row
---                       on the surface that is never wasted -- so the floor
---                       is three. Set 1 for the old behaviour.
---@field zindex integer  Base z-index. It was the dashboard's, kept below the
---                       50 that floating windows and plenary popups get so a
---                       telescope picker opened over it stayed visible. The
---                       subagent picker is all that reads it now, and opens
---                       20 above it.
---@field backdrop boolean  Dimmed the editor behind the old float.
---@field tab_keys boolean  Bound bare `1`-`6` to the old dashboard's tabs.
---@field rail paseo.Config.UI.Rail  The workspace rail down the left.

---@class paseo.Config.UI.Rail
---@field enabled boolean  Shown the first time. After that your last toggle
---                       is remembered, in `stdpath("state")/paseo/ui.json`.
---@field width integer   Cells. Capped at a quarter of the surface, and the
---                       rail is left out altogether below 90 columns.
---@field keys { toggle: string|false, focus: string|false }  Normal mode, on
---                       the native surface's conversation, composer and rail.
---                       `false` unbinds.
---@field show_background boolean  Show the workspaces agents and plugins make
---                       for themselves, which the app's sidebar hides unless
---                       "Show background" is on. Default false.

---@class paseo.Config.UI.Buffer
---
---The old dashboard as a WINDOW rather than as a float. That mount is gone and
---`surface = "buffer"` means the native surface now; the table is still
---validated, so an old config loads, but no surface reads it.
---@field open "here"|"tab"  Where it went: `"here"` was the window you were
---                       standing in, `"tab"` a tab page of its own.
---@field chrome boolean  Whether the editor's own tabline and statusline
---                       stayed up around it.
---@field composer integer|fun(lines: integer): integer
---@field composer_min integer

---@class paseo.Config.UI.Sidebar
---@field width number|fun(columns: integer): integer  PERCENT of the editor's
---                       columns. A function returns CELLS.
---@field min_width integer  ...but never narrower than this, in CELLS. A
---                       percentage of a small terminal is a pane too narrow to
---                       read a tool card in, and how narrow is too narrow is
---                       a matter of taste.
---@field composer integer  The MOST rows the composer grows to, under the
---                       conversation -- a ceiling, not a size.
---@field position "right"|"left"  Which side the pane opens on.

---@class paseo.Config.Voice
---@field enabled boolean  Bind the dictation key at all.
---@field key string|false  What starts and stops it, in the composer.
---@field recorder string[]|nil  A full argv, or nil to find one.
---@field rate integer    Sample rate. The daemon resamples, so this is about
---                       what your microphone does well, not what it wants.

---@class paseo.Config.UI.Answer
---@field width integer   A CAP, in cells, not a share of anything. The overlay
---                       takes over the chat window, so its width is whatever
---                       the conversation has, less a margin, up to this.
---@field min_width integer  Below this the overlay stops trying to fit inside
---                       the chat window and centres on the editor instead. A
---                       30-column sidebar cannot show an option label, and an
---                       unreadable question is worse than one that is not
---                       where you expected it.
---@field backdrop boolean  Dim the conversation behind the overlay.
---@field zindex integer  Base z-index. Above the surface's windows and above
---                       anything opened over them, because a question you
---                       cannot see is a turn that never finishes. The card
---                       sits 10 above this and its children 15.
---@class paseo.Config.UI.Terminal
---
---A terminal is a SESSION now, opened from the rail on a native tab page of its
---own, so this no longer describes a surface of its own: `width`, `height`,
---`row`, `col`, `list`, `zindex` and `backdrop` all belonged to the
---rail-and-pane window that used to open over the top, and are gone with it.
---@field keys paseo.Config.UI.Terminal.Keys
---@field presets (string|table)[]  Extra entries for the new-terminal screen,
---                      beside a shell and one per provider the daemon has.
---                      `"lazygit"`, or `{ label = "Lazygit", command = … }`.

---@class paseo.Config.UI.Terminal.Keys
---
---All of these are bound in TERMINAL mode as well as normal, which is the only
---way any of them is worth having: a key you must press `<C-\><C-n>` to reach
---first is a key you do not reach. That does take them from whatever is
---running inside -- right for `claude`, wrong for `tmux` -- so any of them can
---be `false`.
---@field next string|false   The next tab page, and the previous one -- an
---@field prev string|false   agent's or another terminal's.
---@field sessions string|false  Into the rail beside the terminal, and in the
---                      composer the session list. Was `keys.list`, which
---                      meant the rail.
---@field chrome string|false  OUT OF THE PTY, into normal mode, without
---                      closing anything: the terminal stays on screen and the
---                      keystrokes stop going to it. The name is from when it
---                      landed you on the old dashboard's tab bar.
---@field terminal string|false  From normal mode back into the PTY -- the
---                      other direction.

---@class paseo.Config.Workspaces
---@field dir string      Directory, relative to a project root, holding the
---                       assembled worktrees. Flipping this is the one knob
---                       that moves them out of the project tree.
---@field branch_prefix string  Prefix for the branch a new workspace works on.
---                       A manifest carries its own `branch_prefix` and that
---                       wins; this is for the case that has no manifest --
---                       a plain git repo, where Paseo cuts the worktree.
---@field open "tab"|"tcd"|"cd"|fun(ws: paseo.PaseoWorkspace): boolean?
---                       What `<CR>` in the workspace picker does. The three
---                       strings all switch INSIDE this Neovim:
---                         "tcd" -- this tab's cwd, no new tab. The default:
---                                  the plugin opens no tab pages you did not
---                                  ask for.
---                         "tab" -- a new tab page, `tcd`'d into the workspace,
---                                  for keeping each workspace's buffers apart.
---                         "cd"  -- the editor's cwd. Everything follows.
---                       A function is the escape hatch, and it is how you
---                       spawn a GUI window per workspace instead:
---                         open = function(ws)
---                           vim.fn.jobstart({ "neovide" },
---                             { cwd = ws.directory, detach = true })
---                         end
---                       Return `false` from it to DECLINE -- the built-in
---                       "tcd" switch then happens instead, which is what lets
---                       one config do both (spawn when `vim.g.neovide`, switch
---                       in place in a terminal). Any other return value, `nil`
---                       included, means you handled it.

---@class paseo.Config.Skills
---@field dirs string[]  Where `:Paseo skills install` puts the bundled skills.
---                      Absolute; `~` is expanded at setup. The default is the
---                      one directory an agent can see from INSIDE a workspace
---                      member worktree, which a project-local one cannot.
---@field project_dirs string[]  Relative to the ws project root, for
---                      `:Paseo skills install project`.
---@field method "link"|"copy"  A symlink keeps the plugin the source of
---                      truth, so `:Lazy update` updates the skills. Defaults
---                      to "copy" on Windows, where symlinks need privileges.

---@class paseo.Config.UI.PR
---
---What GitHub thinks of the branch you are on, on the composer's bar and in
---the workspace list. See |paseo.pr|.
---@field enabled boolean  Ask `gh` at all. The only thing in this plugin that
---                       touches the network on its own, and the only status
---                       column that is not push-fed -- so it is the one with
---                       an off switch. Off means the pull request column is
---                       not drawn rather than drawn empty. Absent `gh` is
---                       the same as off, and says nothing about it: a plugin
---                       that nags about an optional tool you have chosen not
---                       to install is worse than one that quietly does less.
---@field ttl integer      Seconds an answer is reused before `gh` is asked
---                       again, per repo. The branch itself is re-read far
---                       more often than this -- it is a local file read --
---                       so switching branch updates the column promptly
---                       whatever this is set to.

---@class paseo.Config.Review
---@field agents boolean  Whether `:Paseo explain` and `:Paseo ask` list the
---                       other Paseo agents working in this tree, so the review
---                       agent can interrogate them about who made a change.
---                       Off means the prompt is the reference and nothing else.

---@class paseo.Config.Quit
---@field guard boolean  Install the quit guard (ZZ/ZQ, `:q`/`:wq`/`:x`
---                       abbreviations). Off by default: global mappings.
---@field warn_active_agents boolean  Ask before leaving Neovim while a Paseo
---                       agent session is running or waiting for attention.
---                       The agents keep running; this protects the view, not
---                       the daemon process. Default true.

---@type paseo.Config
local defaults = {
  paseo = {
    -- url, home, password and provider are all deliberately absent rather than
    -- nil-valued: absent means "work it out", and a discovered endpoint is
    -- right on a host that moved the daemon. Set `url` to pin it.
  },

  ui = {
    surface = "native",
    send_behavior = "steer",

    -- Derived from the colourscheme. The alternative is a plugin that looks
    -- pasted in, which is why this is the default and not the other way round.
    colors = "auto",
    palette = {},

    -- No frame around a card. This is the single biggest visual change and it
    -- is the default because a box per card, drawn inside the old float's own
    -- border, with a rule under its tab bar as well, was three frame weights
    -- competing in one window. Depth comes from the elevation ladder in
    -- `ui/theme.lua` instead. `"rounded"` is the old look, kept and fixed.
    style = "plate",

    -- Empty rather than absent: the merge is `tbl_deep_extend`, and a user
    -- setting one group should not have to restate the others.
    theme = {},

    -- Motion, on by default but cheap: two effects, neither of which changes a
    -- block's HEIGHT, so a frame repaints rows in place and nothing below them
    -- moves. (Under volt that was a hard constraint: it drew every section
    -- below a grown one at the wrong row.)
    animate = {
      bars = true,
      flash = true,
      fps = 30,
    },

    -- How much of a tool card is open by default.
    --
    -- "running" -- the useful middle. A command is expanded WHILE it runs, so
    -- you watch the output arrive, and folds to its one-line summary when it
    -- succeeds; a failure stays open, because a failure is the one you wanted
    -- to read. "always" and "never" are the two ends. `<Tab>` overrides
    -- whichever it is, and a card you have toggled by hand is never folded
    -- back under you.
    expand = "running",

    -- The old dashboard's table. Only `rail`, `keys` and `zindex` are still
    -- read; the rest is the float's geometry, kept so an old config that sets
    -- it still validates.
    float = {
      -- Percentages rather than a margin in cells: a margin that looks right
      -- on a 200-column monitor is most of a laptop screen.
      width = 94,
      height = 86,
      -- row and col are deliberately absent: absent means centred.
      composer = 7,
      -- A floor as well as a ceiling. One row over an empty buffer was the
      -- answer to "do not stand a flat seven-row card there whether or not
      -- anyone is typing into it", and it overshot: a single row is the shape
      -- of `:e ` and not the shape of the thing you write a paragraph in, and
      -- it is where every session starts. Three rows is a field.
      composer_min = 3,
      zindex = 30,
      backdrop = true,
      tab_keys = true,
      -- The project's workspaces down the left of the body, each with what
      -- its agents are doing. `enabled` is only where it STARTS: the toggle
      -- is remembered across restarts, and that wins once you have pressed it.
      rail = {
        enabled = true,
        show_background = false,
        -- nvim-tree's `renderer.indent_markers`: `│ ├ └` down the left of a
        -- workspace's sessions, rather than plain indentation. Off, as
        -- nvim-tree has it.
        indent_markers = false,
        -- The `a agent  w workspace  g? keys` line under the last row.
        hints = true,
        -- Cells, on the old float. The native surface's rail is as wide as
        -- `native.rail` says.
        width = 32,
        -- OLD NAMES for `ui.native.keys.rail`/`focus`/`sessions`, read only
        -- when `ui.native.keys` does not set the same one. Empty by default:
        -- the defaults live there now.
        keys = {},
      },
      -- Old name for `ui.native.keys.new`, the same way.
      keys = {},
    },

    -- The old dashboard in a window of its own rather than floating over your
    -- code. That mount is gone and nothing reads this table; it is kept so a
    -- config that sets it still validates.
    buffer = {
      open = "here",
      chrome = false,

      -- A share of the host, where the float took a flat seven.
      composer = function(lines)
        return math.max(7, math.floor(lines / 3))
      end,
    },

    -- EXPERIMENTAL. The native surface (`:Paseo native`): one tab page per
    -- agent, every pane a real split -- the workspace rail on the left, the
    -- conversation over the composer, a panel on the right when you ask for
    -- one. See |paseo.ui.native|.
    native = {
      -- The agent's prose as raw markdown, drawn by treesitter (and
      -- render-markdown.nvim if you have it) rather than hard-wrapped here.
      markdown = true,
      -- Columns for the workspace rail; 0 starts with it hidden. A width you
      -- drag it to is remembered over this (and the same for `panel`).
      rail = 32,
      -- Columns for the Settings/Changes/Usage split, when it is up.
      panel = 56,
      -- A ceiling and a floor for the box you type in, as `sidebar`'s.
      composer = 10,
      composer_min = 3,
      -- The surface's own keys, on EVERY one of its buffers (conversation,
      -- composer, rail, panel), normal mode. Each is a key, a LIST of keys,
      -- or false to leave it unbound -- `rail = { "<C-b>", "<leader>e" }`
      -- puts the rail on your explorer key while you are in here, and only
      -- here: these are buffer-local, so the global one is untouched.
      keys = {
        -- The workspace rail, on or off.
        rail = "<C-b>",
        -- Into the rail and back out. `<C-h>` because the rail is the
        -- window to the left -- the key a split user already presses.
        focus = "<C-h>",
        -- Into the rail ON THE SESSION ON SCREEN, its workspace opened.
        -- `<C-s>` is "the session list" in the composer and out of a
        -- terminal too.
        sessions = "<C-s>",
        -- The Settings / Changes / Usage panel, on or off.
        panel = "<C-p>",
        -- Start something: the new-task screen.
        new = "<C-n>",
      },
    },

    sidebar = {
      width = 40,
      min_width = 60,
      -- A CEILING, not a size: the box grows with what you type and shrinks
      -- back between `composer_min` and this.
      composer = 8,
      composer_min = 3,
      position = "right",
    },

    -- The overlay that answers a question or a plan. It takes over the chat
    -- window rather than floating in the middle of the editor, so its width is
    -- a cap on what the conversation gives it rather than a share of the
    -- screen -- and `min_width` is the point below which a narrow sidebar
    -- cannot show an option label and the overlay centres on the editor
    -- instead.
    answer = {
      width = 96,
      min_width = 54,
      backdrop = true,
      zindex = 190,
    },

    terminal = {
      keys = {
        next = "<C-j>",
        prev = "<C-k>",
        sessions = "<C-s>",
        -- `<C-g>` rather than anything more obvious, because every obvious
        -- chord is one a shell already uses: `<C-a>`/`<C-e>` are line ends,
        -- `<C-w>` deletes a word, `<C-l>` clears the screen. In readline
        -- `<C-g>` is an abort you have already got `<C-c>` for, so it is the
        -- cheapest key in the terminal to take.
        chrome = "<C-g>",
        terminal = "<C-l>",
      },
      presets = {},
    },

    pr = {
      enabled = true,
      ttl = 60,
    },
  },

  -- Speaking into the composer. Speech-to-TEXT only -- the daemon also has a
  -- duplex voice mode with synthesised replies, and an editor that talks back
  -- needs a player, an interrupt and somewhere to put the transcript, which is
  -- a surface rather than a key.
  voice = {
    enabled = true,
    key = "<C-t>",
    -- Absent means "find one": arecord, then rec (sox), then ffmpeg. A table
    -- is a full argv, for a machine with two sound cards or a device that has
    -- to be named. It must produce RAW PCM16 mono at `rate` on stdout --
    -- headerless, no container -- because that is what the daemon parses.
    recorder = nil,
    rate = 16000,
  },

  workspaces = {
    dir = ".workspaces",
    branch_prefix = "ws/",
    -- In this Neovim, not a new GUI window. Spawning one was the author's
    -- habit and it is a terrible default: in a terminal Neovim over ssh there
    -- is nothing to spawn, and `<CR>` did nothing you could see.
    open = "tcd",
  },

  review = {
    agents = true,
  },

  quit = {
    -- OFF unless you ask: guarding ZZ/ZQ and `:q`/`:wq`/`:x` means global
    -- mappings and abbreviations, and a plugin sets none of those on its
    -- own. `true` installs them; `require("paseo.quit").guard` is there for a
    -- config with its own quit router.
    guard = false,
    warn_active_agents = true,
  },

  -- REMAPS for the built-in keys of each surface, keyed by the DEFAULT key:
  -- `["d"] = false` unbinds it, `["d"] = "x"` moves it, `["d"] = { "d", "x" }`
  -- adds one. Scopes: `conversation`, `composer`, `rail`, `panel`. `g?` on
  -- the rail, and every hint, shows what a key is bound as after this.
  keys = {
    conversation = {},
    composer = {},
    rail = {},
    panel = {},
  },

  skills = {
    -- `~/.claude/skills` ONLY. `~/.agents/skills` is one person's stow
    -- convention rather than a standard, and a default that writes into two
    -- places is a default that is wrong in one of them.
    dirs = { "~/.claude/skills" },
    project_dirs = { ".claude/skills" },
    method = "link",
  },
}

---@type paseo.Config
local config = vim.deepcopy(defaults)

---A key option's value: a key, a list of keys, or false.
---@param v any
---@return boolean
local function is_key(v)
  if v == false or type(v) == "string" then
    return true
  end
  if type(v) ~= "table" then
    return false
  end
  for _, lhs in ipairs(v) do
    if type(lhs) ~= "string" then
      return false
    end
  end
  return true
end

---Merge user options over the defaults.
---@param opts? table
---@return paseo.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  -- The old homes of the native surface's keys still work: a key set there,
  -- and not under `ui.native.keys`, is taken from there.
  local ui_opts = (opts or {}).ui or {}
  local set_native = (ui_opts.native or {}).keys or {}
  local legacy_rail = ((ui_opts.float or {}).rail or {}).keys or {}
  for old_name, new_name in pairs { toggle = "rail", focus = "focus", sessions = "sessions" } do
    if legacy_rail[old_name] ~= nil and set_native[new_name] == nil then
      config.ui.native.keys[new_name] = legacy_rail[old_name]
    end
  end
  local legacy_new = ((ui_opts.float or {}).keys or {}).new
  if legacy_new ~= nil and set_native.new == nil then
    config.ui.native.keys.new = legacy_new
  end

  vim.validate("paseo.hosts", config.paseo.hosts, function(v)
    return v == nil or type(v) == "table"
  end, "a table keyed by host alias")
  vim.validate("paseo.default_host", config.paseo.default_host, function(v)
    return v == nil or type(v) == "string"
  end, "a configured host alias")
  if config.paseo.hosts then
    if next(config.paseo.hosts) == nil then
      error "paseo.hosts must contain at least one host"
    end
    for alias, host in pairs(config.paseo.hosts) do
      vim.validate("paseo.hosts key", alias, "string")
      vim.validate("paseo.hosts." .. alias, host, "table")
      vim.validate("paseo.hosts." .. alias .. ".label", host.label, function(v)
        return v == nil or type(v) == "string"
      end, "a string")
      vim.validate("paseo.hosts." .. alias .. ".connections", host.connections, function(v)
        return type(v) == "table" and #v > 0
      end, "a non-empty list")
      for i, connection in ipairs(host.connections) do
        local at = ("paseo.hosts.%s.connections[%d]"):format(alias, i)
        vim.validate(at, connection, "table")
        vim.validate(at .. ".type", connection.type, function(v)
          return v == "local" or v == "direct" or v == "relay"
        end, '"local", "direct", or "relay"')
        if connection.type == "direct" then
          vim.validate(at .. ".address", connection.address, "string")
        elseif connection.type == "relay" then
          vim.validate(at .. ".offer", connection.offer, function(v)
            return type(v) == "string" or type(v) == "function"
          end, "a pairing-link string or function")
        end
      end
      for i, mapping in ipairs(host.paths or {}) do
        local at = ("paseo.hosts.%s.paths[%d]"):format(alias, i)
        vim.validate(at .. ".local_root", mapping.local_root, "string")
        vim.validate(at .. ".remote_root", mapping.remote_root, "string")
      end
    end
    if config.paseo.default_host and not config.paseo.hosts[config.paseo.default_host] then
      error(("paseo.default_host %q is not present in paseo.hosts"):format(config.paseo.default_host))
    end
  end

  vim.validate("ui.pr.enabled", config.ui.pr.enabled, "boolean")
  vim.validate("ui.pr.ttl", config.ui.pr.ttl, "number")
  vim.validate("review.agents", config.review.agents, "boolean")
  vim.validate("quit.warn_active_agents", config.quit.warn_active_agents, "boolean")
  vim.validate("ui.send_behavior", config.ui.send_behavior, function(v)
    return v == "steer" or v == "interrupt" or v == "queue"
  end, '"steer", "interrupt" or "queue"')
  -- "float" and "buffer" were the old dashboard's mounts; both mean the
  -- native surface now, so a config that still says them keeps working.
  vim.validate("ui.surface", config.ui.surface, function(v)
    return v == "native" or v == "sidebar" or v == "float" or v == "buffer"
  end, '"native" or "sidebar"')
  vim.validate("ui.native.markdown", config.ui.native.markdown, "boolean")
  vim.validate("ui.native.rail", config.ui.native.rail, "number")
  vim.validate("ui.native.panel", config.ui.native.panel, "number")
  vim.validate("ui.buffer.open", config.ui.buffer.open, function(v)
    return v == "here" or v == "tab"
  end, '"here" or "tab"')
  vim.validate("ui.sidebar.position", config.ui.sidebar.position, function(v)
    return v == "right" or v == "left"
  end, '"right" or "left"')
  vim.validate("ui.expand", config.ui.expand, function(v)
    return v == "running" or v == "always" or v == "never"
  end, '"running", "always" or "never"')
  -- Validated against the style module rather than inline, so the list of
  -- presets has one home and a new one does not need remembering here.
  vim.validate(
    "ui.style",
    config.ui.style,
    require("paseo.ui.style").valid,
    'a preset name ("plate", "rule", "rounded", "square") or a table of card/border'
  )
  vim.validate("ui.colors", config.ui.colors, function(v)
    return v == "auto" or v == "fixed"
  end, '"auto" or "fixed"')
  -- Checked HERE rather than where it is read, so `#00ff0` is reported against
  -- the key that holds it. A bad hex reaching `ui/color.lua` comes back as the
  -- input unchanged, which surfaces as one tier of the elevation ladder
  -- silently collapsing into the one below it -- a bug with no error and no
  -- obvious cause.
  vim.validate("ui.palette", config.ui.palette, "table")
  for _, role in ipairs(require("paseo.ui.theme").ROLES) do
    vim.validate("ui.palette." .. role, config.ui.palette[role], function(v)
      return v == nil or (type(v) == "string" and v:match "^#%x%x%x%x%x%x$" ~= nil)
    end, "a #rrggbb colour")
  end
  vim.validate("ui.theme", config.ui.theme, "table")
  vim.validate("ui.animate", config.ui.animate, function(v)
    return type(v) == "boolean" or type(v) == "table"
  end, "false, or a table of bars/flash/fps")
  -- `animate = false` is the shorthand everyone will actually type; normalise
  -- it here so nothing downstream has to handle both shapes.
  if config.ui.animate == false then
    config.ui.animate = { bars = false, flash = false, fps = 30 }
  elseif config.ui.animate == true then
    config.ui.animate = { bars = true, flash = true, fps = 30 }
  end
  config.ui.animate.fps = math.max(1, math.min(60, math.floor(config.ui.animate.fps or 30)))
  vim.validate("voice.enabled", config.voice.enabled, "boolean")
  vim.validate("voice.key", config.voice.key, function(v)
    return v == false or type(v) == "string"
  end, "a key, or false to leave it unbound")
  vim.validate("voice.recorder", config.voice.recorder, function(v)
    return v == nil or (type(v) == "table" and #v > 0 and type(v[1]) == "string")
  end, "a full argv, or nil to find one")
  config.voice.rate = math.max(8000, math.floor(config.voice.rate or 16000))

  vim.validate("workspaces.open", config.workspaces.open, function(v)
    return type(v) == "function" or v == "tab" or v == "tcd" or v == "cd"
  end, '"tab", "tcd", "cd", or a function taking the workspace')

  for _, key in ipairs { "dirs", "project_dirs" } do
    vim.validate("skills." .. key, config.skills[key], function(v)
      if type(v) ~= "table" then
        return false
      end
      for _, item in ipairs(v) do
        if type(item) ~= "string" then
          return false
        end
      end
      return true
    end, "a list of strings")
  end
  vim.validate("skills.method", config.skills.method, function(v)
    return v == "link" or v == "copy"
  end, '"link" or "copy"')
  -- Expanded here so nothing downstream has to: a `~` reaching `fs_symlink`
  -- creates a directory literally called "~" in the cwd.
  for i, dir in ipairs(config.skills.dirs) do
    config.skills.dirs[i] = (vim.fn.expand(dir):gsub("/+$", ""))
  end
  -- Platform-aware, but only when nobody chose. Windows symlinks need
  -- Developer Mode or elevation; an explicit "link" there is someone who has
  -- it and means it.
  if vim.fn.has "win32" == 1 and not (opts and opts.skills and opts.skills.method) then
    config.skills.method = "copy"
  end
  -- Clamped rather than merely validated: `nvim_open_win` rejects anything
  -- below 1 outright. (The old float's backdrop sat five below this; the
  -- subagent picker that reads it now opens 20 above.)
  vim.validate("ui.float.zindex", config.ui.float.zindex, "number")
  config.ui.float.zindex = math.max(10, math.floor(config.ui.float.zindex))
  vim.validate("ui.float.rail", config.ui.float.rail, "table")
  vim.validate("ui.float.rail.width", config.ui.float.rail.width, "number")
  for _, group in ipairs {
    { "ui.float.rail.keys", config.ui.float.rail.keys },
    { "ui.float.keys", config.ui.float.keys },
    { "ui.native.keys", config.ui.native.keys },
    { "keys.conversation", config.keys.conversation },
    { "keys.composer", config.keys.composer },
    { "keys.rail", config.keys.rail },
    { "keys.panel", config.keys.panel },
  } do
    for name, key in pairs(group[2] or {}) do
      vim.validate(("%s.%s"):format(group[1], name), key, is_key, "a key, a list of keys, or false to leave it unbound")
    end
  end
  vim.validate("quit.guard", config.quit.guard, "boolean")
  vim.validate("ui.terminal.presets", config.ui.terminal.presets, "table")
  for name, key in pairs(config.ui.terminal.keys) do
    vim.validate(("ui.terminal.keys.%s"):format(name), key, function(v)
      return v == false or type(v) == "string"
    end, "a key, or false to leave it unbound")
  end
  -- Validated here rather than at the window, where a bad value would surface
  -- as `nvim_open_win` complaining about a width -- true, and no help at all in
  -- finding the key that caused it.
  for where, keys in pairs {
    float = { "width", "height", "row", "col", "composer" },
    -- Every one of these may be nil here: the old buffer mount inherited them
    -- from `ui.float` rather than restating them.
    buffer = { "composer", "zindex" },
    sidebar = { "width", "min_width", "composer" },
    terminal = { "width", "height", "row", "col", "list" },
  } do
    for _, key in ipairs(keys) do
      vim.validate(("ui.%s.%s"):format(where, key), config.ui[where][key], function(v)
        return v == nil or type(v) == "number" or type(v) == "function"
      end, "a percentage of the editor (1-100), or a function returning cells")
    end
  end

  -- The overlay's widths are CELLS, not percentages, so they take neither a
  -- function nor a value read through `M.cells`. Clamped for the same reason
  -- `ui.float.zindex` is: `nvim_open_win` rejects a z-index below 1, and the
  -- backdrop sits at this value with the card ten above it.
  vim.validate("ui.answer.backdrop", config.ui.answer.backdrop, "boolean")
  for _, key in ipairs { "width", "min_width", "zindex" } do
    vim.validate(("ui.answer.%s"):format(key), config.ui.answer[key], "number")
    config.ui.answer[key] = math.floor(config.ui.answer[key])
  end
  config.ui.answer.zindex = math.max(10, config.ui.answer.zindex)
  -- A `min_width` above `width` would make the fallback unreachable in one
  -- direction and permanent in the other.
  config.ui.answer.min_width =
    math.max(20, math.min(config.ui.answer.min_width, config.ui.answer.width))

  return config
end

---A configured extent, in cells.
---
---The unit is a PERCENTAGE of the editor, 1-100 -- the same unit floaterm's
---`size` takes, so a number copied from one config means the same thing in the
---other. Fractions were the first attempt and they are worse: `0.92` and `92`
---are both obvious once you know which convention you are in, and nothing on
---the page tells you which.
---
---A function is the escape hatch for a size no percentage can express, and it
---is handed the editor's total and returns CELLS.
---@param value number|fun(total: integer): integer|nil
---@param total integer   `vim.o.columns` or `vim.o.lines`.
---@param fallback number  A percentage, used when `value` is unusable.
---@return integer
function M.cells(value, total, fallback)
  if type(value) == "function" then
    local ok, computed = pcall(value, total)
    if ok and type(computed) == "number" then
      return math.floor(computed)
    end
    value = nil
  end
  if type(value) ~= "number" or value <= 0 then
    value = fallback
  end
  -- The same arithmetic floaterm does, in the same order, so the two agree to
  -- the cell rather than to within a rounding error.
  return math.floor(total * math.min(100, value) / 100)
end

---The live config. Safe to call before `setup()`; you get the defaults.
---@return paseo.Config
function M.get()
  return config
end

---The pristine defaults, for docs and tests.
---@return paseo.Config
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
