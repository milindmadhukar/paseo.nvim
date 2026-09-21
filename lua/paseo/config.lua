--- Configuration: defaults, user merge, and the accessor everything else uses.
---
--- The table is deliberately small. Options land here only once something
--- actually reads them -- a key that exists but is ignored is worse than no key,
--- because it reads like a promise.

local M = {}

---@class paseo.Config
---@field paseo paseo.Config.Paseo
---@field ui paseo.Config.UI
---@field workspaces paseo.Config.Workspaces
---@field skills paseo.Config.Skills
---@field review paseo.Config.Review

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
---@field surface "float"|"sidebar"  Which surface `:Paseo chat` opens on.
---                       "float" is the default: the full-screen dashboard is
---                       the one with everything on it, and the sidebar is the
---                       narrower thing you switch TO with <C-f>.
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
---@field composer integer  Rows the composer gets. The rest of the box, less
---                       the header, tab bar and footer, is the conversation.
---@field zindex integer  Base z-index of the surface. DELIBERATELY BELOW 50,
---                       which is what floating windows and plenary popups get
---                       by default: a dashboard that outranks them hides the
---                       telescope picker, its previewer and every
---                       `vim.ui.select` opened on top of it. Our own modal --
---                       the permission dialog -- is exempt and stays above
---                       everything, because it is the one window that must not
---                       be covered.
---@field backdrop boolean  Dim the editor behind the surface.
---@field tab_keys boolean  Bind bare `1`-`6` to the tabs in the conversation
---                       and composer as well as in the chrome. They have to be
---                       bound there or they do nothing: the Chat tab puts your
---                       cursor in the composer. The cost is that a bare digit
---                       is also a COUNT, so `3p` and `5j` in those two buffers
---                       go to the tab bar instead while the dashboard is open.
---                       Set false to keep the counts; `<M-1>`-`<M-6>` and
---                       `<Tab>` still switch tabs.

---@class paseo.Config.UI.Sidebar
---@field width number|fun(columns: integer): integer  PERCENT of the editor's
---                       columns, read the same way as the float's.
---@field min_width integer  ...but never narrower than this, in CELLS. A
---                       percentage of a small terminal is a pane too narrow to
---                       read a tool card in, and unlike the float -- whose
---                       floor is a hard layout requirement -- how narrow is
---                       too narrow here is a matter of taste.
---@field composer integer  Rows the composer gets, under the conversation.
---@field position "right"|"left"  Which side the pane opens on.

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
---@field width number|fun(columns: integer): integer   PERCENT of the editor,
---@field height number|fun(lines: integer): integer    1-100, the same unit
---                      `ui.float` and floaterm's `size` take, so a number
---                      means the same thing in all three.
---@field row integer?    Absolute editor cells. Absent means centred.
---@field col integer?
---@field list integer    Width of the terminal list, in CELLS. The one
---                      exception to the percentage rule, and deliberately:
---                      the rail holds NAMES, and 10% of a 300-column monitor
---                      is thirty columns of mostly nothing.
---@field zindex integer  Base z-index. Above the dashboard's 30 -- this opens
---                      over it -- and below the 50 telescope and
---                      `vim.ui.select` take, so a picker opened from here is
---                      on top of it.
---@field backdrop boolean  Dim the editor behind the surface.
---@field keys paseo.Config.UI.Terminal.Keys
---@field presets (string|table)[]  Extra entries for the new-terminal picker,
---                      beside a shell and one per provider the daemon has.
---                      `"lazygit"`, or `{ label = "Lazygit", command = … }`.

---@class paseo.Config.UI.Terminal.Keys
---@field next string|false   Next terminal. Bound in TERMINAL mode too, which
---@field prev string|false   is what makes it worth having -- and which takes
---                      the key from whatever is running inside. Fine for
---                      `claude`; set false if you run `tmux` in there.
---@field list string|false   From the terminal to the rail.
---@field terminal string|false  From the rail back to the terminal.

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

---@class paseo.Config.Review
---@field agents boolean  Whether `:Paseo explain` and `:Paseo ask` list the
---                       other Paseo agents working in this tree, so the review
---                       agent can interrogate them about who made a change.
---                       Off means the prompt is the reference and nothing else.

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
      zindex = 30,
      backdrop = true,
      tab_keys = true,
    },

    sidebar = {
      width = 40,
      min_width = 60,
      composer = 8,
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
      width = 84,
      height = 78,
      -- row and col are deliberately absent: absent means centred.
      list = 22,
      zindex = 45,
      backdrop = true,
      keys = {
        next = "<C-j>",
        prev = "<C-k>",
        list = "<C-h>",
        terminal = "<C-l>",
      },
      presets = {},
    },
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

  vim.validate("review.agents", config.review.agents, "boolean")
  vim.validate("ui.surface", config.ui.surface, function(v)
    return v == "float" or v == "sidebar"
  end, '"float" or "sidebar"')
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
  vim.validate("ui.terminal.zindex", config.ui.terminal.zindex, "number")
  config.ui.terminal.zindex = math.max(10, math.floor(config.ui.terminal.zindex))
  vim.validate("ui.terminal.backdrop", config.ui.terminal.backdrop, "boolean")
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
