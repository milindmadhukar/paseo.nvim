--- Configuration: defaults, user merge, and the accessor everything else uses.
---
--- The table is deliberately small. Options land here only once something
--- actually reads them -- a key that exists but is ignored is worse than no key,
--- because it reads like a promise.

local M = {}

---@class paseo.Config
---@field backend "paseo"|"local"  Where agents run. See README, "Backend seam".
---@field paseo paseo.Config.Paseo
---@field ui paseo.Config.UI
---@field workspaces paseo.Config.Workspaces
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
---@field float paseo.Config.UI.Float
---@field sidebar paseo.Config.UI.Sidebar

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
---                       telescope picker, the diff preview and every
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

---@class paseo.Config.Workspaces
---@field dir string      Directory, relative to a project root, holding the
---                       assembled worktrees. Flipping this is the one knob
---                       that moves them out of the project tree.
---@field branch_prefix string  Prefix for the branch a new workspace works on.
---                       A manifest carries its own `branch_prefix` and that
---                       wins; this is for the case that has no manifest --
---                       a plain git repo, where Paseo cuts the worktree.

---@class paseo.Config.Review
---@field context integer Lines of context asked of `git diff` when building the
---                       hunk quickfix list. 0 is required: a hunk header's
---                       line numbers only mean "the hunk" at -U0.

---@type paseo.Config
local defaults = {
  backend = "paseo",

  paseo = {
    -- url, home, password and provider are all deliberately absent rather than
    -- nil-valued: absent means "work it out", and a discovered endpoint is
    -- right on a host that moved the daemon. Set `url` to pin it.
  },

  ui = {
    surface = "float",

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
  },

  workspaces = {
    dir = ".workspaces",
    branch_prefix = "ws/",
  },

  review = {
    context = 0,
  },
}

---@type paseo.Config
local config = vim.deepcopy(defaults)

---Merge user options over the defaults.
---@param opts? table
---@return paseo.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.validate("backend", config.backend, function(v)
    return v == "paseo" or v == "local"
  end, '"paseo" or "local"')
  vim.validate("review.context", config.review.context, "number")
  vim.validate("ui.surface", config.ui.surface, function(v)
    return v == "float" or v == "sidebar"
  end, '"float" or "sidebar"')
  vim.validate("ui.sidebar.position", config.ui.sidebar.position, function(v)
    return v == "right" or v == "left"
  end, '"right" or "left"')
  vim.validate("ui.expand", config.ui.expand, function(v)
    return v == "running" or v == "always" or v == "never"
  end, '"running", "always" or "never"')
  -- Clamped rather than merely validated: `nvim_open_win` rejects anything
  -- below 1 outright, and the backdrop sits five below this.
  vim.validate("ui.float.zindex", config.ui.float.zindex, "number")
  config.ui.float.zindex = math.max(10, math.floor(config.ui.float.zindex))
  -- Validated here rather than at the window, where a bad value would surface
  -- as `nvim_open_win` complaining about a width -- true, and no help at all in
  -- finding the key that caused it.
  for where, keys in pairs {
    float = { "width", "height", "row", "col", "composer" },
    sidebar = { "width", "min_width", "composer" },
  } do
    for _, key in ipairs(keys) do
      vim.validate(("ui.%s.%s"):format(where, key), config.ui[where][key], function(v)
        return v == nil or type(v) == "number" or type(v) == "function"
      end, "a percentage of the editor (1-100), or a function returning cells")
    end
  end

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
