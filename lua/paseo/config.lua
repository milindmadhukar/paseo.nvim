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

---@class paseo.Config.UI
---@field surface "float"|"sidebar"|"buffer"  Which surface `:Paseo chat` opens
---                       on. "float" is the default: the full-screen dashboard
---                       is the one with everything on it, and the sidebar is
---                       the narrower thing you switch TO with <C-f>.
---                       "buffer" is the same dashboard as "float" -- same
---                       chrome, same six tabs -- in a real window with a
---                       buffer of its own, on a tab page of its own, using the
---                       whole screen rather than 94% of it.
---@field style string|paseo.Style  Frame language. A preset name --
---                       "plate", "rule", "rounded", "square" -- or a table of
---                       the same fields, which only has to name what it
---                       changes. "plate" is the default and draws NO frame
---                       around a card: sections are separated by background
---                       elevation and padding instead. See `paseo.ui.style`.
---@field colors "auto"|"fixed"  Where the eight base colours come from.
---                       "auto" derives them from the colourscheme, which is
---                       what makes the dashboard look like it belongs to
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
---@field fps integer     Frames a second for all of the above. Every frame is
---                       one `volt.redraw` of one named section, which is an
---                       in-place extmark overwrite -- cheap, but not free on
---                       a slow link.

---@class paseo.Config.UI.Float
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
---@field zindex integer  Base z-index of the surface. DELIBERATELY BELOW 50,
---                       which is what floating windows and plenary popups get
---                       by default: a dashboard that outranks them hides the
---                       telescope picker, its previewer and every
---                       `vim.ui.select` opened on top of it. Our own modal --
---                       the permission dialog -- is exempt and stays above
---                       everything, because it is the one window that must not
---                       be covered.
---@field backdrop boolean  Dim the editor behind the surface.
---@field tab_keys boolean  Bind bare `1`-`6` to the tabs in the conversation,
---                       the composer and a terminal's NORMAL mode, as well as
---                       in the chrome. They have to be bound there or they do
---                       nothing: the Chat tab puts your cursor in the
---                       composer, or in the PTY. The cost is that a bare
---                       digit is also a COUNT, so `3p` and `5j` in those
---                       buffers go to the tab bar instead while the dashboard
---                       is open. Set false to keep the counts; `<M-1>`-`<M-6>`
---                       and `<Tab>` still switch tabs. In TERMINAL mode a
---                       digit is never taken: it belongs to what is running.

---@class paseo.Config.UI.Buffer
---
---The dashboard as a WINDOW rather than as a float. Deliberately one key: how
---tall the composer grows (`composer`), how the panes stack (`zindex`) and
---whether a bare digit switches tab (`tab_keys`) describe the DASHBOARD and
---not the mount, so they are read from |paseo-config.ui.float| unless you set
---them here. The size is not a setting at all -- the host window's size IS the
---geometry, which is the whole point of the surface.
---@field open "here"|"tab"  Where it goes.
---
---                       `"here"` -- THE WINDOW YOU ARE STANDING IN, nvdash's
---                       arrangement. The buffer that was there is remembered
---                       along with its view and put back when the dashboard
---                       closes, so the surface is a toggle you can take and
---                       leave without losing your place. Opening a file from
---                       it simply opens the file: the dashboard's buffer is
---                       displaced, notices, and tears itself down.
---
---                       `"tab"` -- a tab page of its own, which costs a tab
---                       and keeps the window layout underneath it intact.
---@field chrome boolean  Whether the EDITOR's own tabline and statusline stay
---                       up around the surface. False -- the default -- hides
---                       both while it is open and puts them back, whatever
---                       they were, when it closes.
---
---                       They are two rows of chrome around a surface that
---                       has a header and a footer of its own, and what they
---                       say -- the file you are not looking at, the line you
---                       are not on -- is about the buffer this one replaced.
---                       Set true to keep them.
---
---                       Only ever touched for `open = "here"`: on a tab page
---                       of its own the tabline is how you get back, and
---                       hiding it strands you.
---@field composer integer|fun(lines: integer): integer
---@field composer_min integer

---@class paseo.Config.UI.Sidebar
---@field width number|fun(columns: integer): integer  PERCENT of the editor's
---                       columns, read the same way as the float's.
---@field min_width integer  ...but never narrower than this, in CELLS. A
---                       percentage of a small terminal is a pane too narrow to
---                       read a tool card in, and unlike the float -- whose
---                       floor is a hard layout requirement -- how narrow is
---                       too narrow here is a matter of taste.
---@field composer integer  The MOST rows the composer grows to, under the
---                       conversation -- a ceiling, not a size, read the same
---                       way as the float's.
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
---@field zindex integer  Base z-index. Above the dashboard's panes and above
---                       anything opened over them, because a question you
---                       cannot see is a turn that never finishes. The card
---                       sits 10 above this and its children 15.
---@class paseo.Config.UI.Terminal
---
---A terminal is a SESSION now, shown on the dashboard's Chat tab, so this no
---longer describes a surface of its own: `width`, `height`, `row`, `col`,
---`list`, `zindex` and `backdrop` all belonged to the rail-and-pane window
---that used to open over the top, and are gone with it. A terminal is the size
---of the dashboard, because it IS the dashboard.
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
---@field next string|false   The next session in this workspace, agent or
---@field prev string|false   terminal. Stays on the Chat tab.
---@field sessions string|false  To the Sessions tab -- the list of everything
---                      running here and the search over it. Was `keys.list`,
---                      which meant the rail.
---@field chrome string|false  OUT OF THE PTY AND ONTO THE TAB BAR, without
---                      leaving the Chat tab or closing anything: the terminal
---                      stays on screen and the keystrokes stop going to it,
---                      so `1`-`6` and `<Tab>` reach the tabs. This is the key
---                      to rebind if tab navigation from a terminal is only
---                      working with the mouse -- `<M-1>`-`<M-6>` are bound in
---                      terminal mode too, but plenty of terminal emulators,
---                      multiplexers and ssh sessions never deliver an Alt
---                      chord, and then they are six keys that do nothing.
---@field terminal string|false  From the chrome back into the PTY -- the other
---                      direction, bound on the dashboard's own buffer.

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
---                         "tab" -- new tab page, `tcd`'d into the workspace.
---                                  The default: a tab is the cheapest thing
---                                  that keeps the buffers of the workspace you
---                                  just left out of the one you just entered.
---                         "tcd" -- this tab's cwd, no new tab.
---                         "cd"  -- the editor's cwd. Everything follows.
---                       A function is the escape hatch, and it is how you
---                       spawn a GUI window per workspace instead:
---                         open = function(ws)
---                           vim.fn.jobstart({ "neovide" },
---                             { cwd = ws.directory, detach = true })
---                         end
---                       Return `false` from it to DECLINE -- the built-in
---                       "tab" switch then happens instead, which is what lets
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
    surface = "float",

    -- Derived from the colourscheme. The alternative is a plugin that looks
    -- pasted in, which is why this is the default and not the other way round.
    colors = "auto",
    palette = {},

    -- No frame around a card. This is the single biggest visual change and it
    -- is the default because a box per card, drawn inside the float's own
    -- border, with a rule under the tab bar as well, was three frame weights
    -- competing in one window. Depth comes from the elevation ladder in
    -- `ui/theme.lua` instead. `"rounded"` is the old look, kept and fixed.
    style = "plate",

    -- Empty rather than absent: the merge is `tbl_deep_extend`, and a user
    -- setting one group should not have to restate the others.
    theme = {},

    -- Motion, on by default but cheap: two effects, neither of which changes a
    -- section's HEIGHT. That constraint is not a style choice -- volt records
    -- each section's start row when the layout is measured, so a section that
    -- grows mid-animation draws every section below it at the wrong row.
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
    },

    -- The same dashboard, in a window of its own rather than floating over
    -- your code. `composer`, `zindex` and `tab_keys` are read from `float`
    -- above unless you set them here: they describe the dashboard, not where
    -- it is mounted, and two copies of one answer is how the two surfaces
    -- start disagreeing.
    buffer = {
      -- The window you are standing in, not a tab page of its own. A tab is
      -- an arrangement of windows and this surface is one window -- so it
      -- spent a whole tab to say nothing, put a tabline up on a screen that
      -- has a header of its own, and made "go back to my code" a `gt` rather
      -- than the key that opened it.
      open = "here",
      chrome = false,

      -- A SHARE OF THE HOST, where the float takes a flat seven. This surface
      -- is the whole screen: a fifty-row terminal has forty rows of
      -- transcript on it and most of them are blank, and the box you type in
      -- was still the same seven rows it gets in a float over your code. The
      -- floor keeps it honest on a small terminal, where a third is three.
      composer = function(lines)
        return math.max(7, math.floor(lines / 3))
      end,
    },

    sidebar = {
      width = 40,
      min_width = 60,
      -- A CEILING, read exactly as the float's is: the box grows with what
      -- you type and shrinks back between `composer_min` and this.
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
    open = "tab",
  },

  review = {
    agents = true,
  },

  quit = {
    warn_active_agents = true,
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

---Merge user options over the defaults.
---@param opts? table
---@return paseo.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.validate("ui.pr.enabled", config.ui.pr.enabled, "boolean")
  vim.validate("ui.pr.ttl", config.ui.pr.ttl, "number")
  vim.validate("review.agents", config.review.agents, "boolean")
  vim.validate("quit.warn_active_agents", config.quit.warn_active_agents, "boolean")
  vim.validate("ui.surface", config.ui.surface, function(v)
    return v == "float" or v == "sidebar" or v == "buffer"
  end, '"float", "sidebar" or "buffer"')
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
  -- the key that holds it. A bad hex reaching `volt.color` comes back as the
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
  -- below 1 outright, and the backdrop sits five below this.
  vim.validate("ui.float.zindex", config.ui.float.zindex, "number")
  config.ui.float.zindex = math.max(10, math.floor(config.ui.float.zindex))
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
    -- Every one of these may be nil here, which is what lets the buffer mount
    -- inherit it from `ui.float` rather than restate it.
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
  -- the float's z-index is: `nvim_open_win` rejects a z-index below 1, and the
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
