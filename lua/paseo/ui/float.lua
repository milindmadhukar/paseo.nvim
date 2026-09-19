--- The full-screen surface: the conversation, plus everything about the
--- session, on tabs.
---
--- The DEFAULT surface. The sidebar is for asking a question beside your code;
--- this is for the rest of the time -- when you want to see what the agent is
--- doing, what it has cost, what is changed on disk, which sessions are running
--- and where, and to change the mode without a `vim.ui.select` prompt covering
--- the thing you are reading.
---
--- Structure, from the bottom up: a dimmed backdrop, a volt-drawn chrome window
--- carrying the header, the tab bar and the active panel, and -- on the
--- conversation tab only -- the real conversation and composer buffers floated
--- on top. The chrome is volt's; the conversation is never volt's, because
--- virtual text cannot be yanked.
---
--- The chrome is FOUR volt sections rather than one, and that is not tidiness:
--- the header repaints ten times a second while a turn runs, and a single
--- section would drag the Changes panel -- which shells out to `git status` per
--- repo -- through every one of those frames.

local render = require "paseo.ui.render"
local sidebar = require "paseo.ui.sidebar"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.float"

---@type table|nil
local state

M.TABS = { "Chat", "Session", "Sessions", "Changes", "Usage", "Workspaces" }

-- ------------------------------------------------------------------ geometry

---Where the surface sits, how big it is, and how it stacks.
---
---The z-index is the half worth explaining. It used to be 100, which is ABOVE
---the 50 that `nvim_open_win` and plenary's popup hand out by default -- so
---every telescope picker, diff preview and `vim.ui.select` opened from the
---dashboard rendered underneath it and looked like nothing had happened.
---Sitting below the default means the things you open on top of the dashboard
---are on top of it. The one window that must never be covered -- the
---permission dialog -- asks for its own z-index well above both.
---@return table
local function geometry()
  local config = require "paseo.config"
  local ui = config.get().ui.float
  local columns, lines = vim.o.columns, vim.o.lines

  -- Floored at a size the layout still works in -- below this the tab bar and
  -- the composer stop fitting -- and capped at the editor, so neither a tiny
  -- terminal nor an over-large setting can put the border off screen.
  local w = math.min(columns, math.max(60, config.cells(ui.width, columns, 94)))
  local h = math.min(lines, math.max(20, config.cells(ui.height, lines, 86)))

  -- Centred when `row`/`col` say nothing. `(total - size) / 2` is exactly the
  -- formula floaterm centres with, so a config that gives both the same size
  -- gets both in the same place and switching between them does not jump.
  --
  -- These two are CELLS rather than percentages: they are window coordinates,
  -- not sizes, and "row 3" is what you mean when you pin a window.
  local row = type(ui.row) == "number" and math.floor(ui.row) or math.floor((lines - h) / 2)
  local col = type(ui.col) == "number" and math.floor(ui.col) or math.floor((columns - w) / 2)

  -- The composer is measured from the bottom, so the conversation gets what is
  -- left. Clamped to leave the conversation at least five rows: a composer
  -- taller than the box would give it a negative height.
  local composer = type(ui.composer) == "number" and math.floor(ui.composer) or 7
  composer = math.max(1, math.min(composer, h - 10))

  local z = ui.zindex or 30
  return {
    width = w,
    height = h,
    row = math.max(0, math.min(row, lines - h)),
    col = math.max(0, math.min(col, columns - w)),
    composer = composer,
    backdrop = ui.backdrop ~= false,
    -- The panes are ABOVE the chrome they sit on and below anything opened
    -- over the whole surface.
    z_backdrop = math.max(1, z - 5),
    z_chrome = z,
    z_panes = z + 5,
  }
end

-- -------------------------------------------------------------------- chrome

---Jump to a tab, as a click action.
---@param name string
---@return fun()
local function goto_tab(name)
  return function()
    M.select(name)
  end
end

---The session header: the same cells the sidebar puts in its winbar.
---
---It lives in the CHROME rather than on the conversation window's winbar, and
---that is the fix for "the dashboard does not say which model it is on": a
---winbar belongs to a window, the conversation window only exists on the Chat
---tab, and every other tab therefore had no header at all. Here it is drawn
---once, above the tabs, and is true on all six of them.
---@return table[][]
local function header_lines()
  if not state then
    return { {} }
  end
  local line = sidebar.header(state.chat)

  -- Everything the header names is a thing the Session panel can change, so
  -- the header is the shortest route to it. Cells carry volt's third element;
  -- `volt.events.add` on this buffer is what turns that into a click.
  for _, cell in ipairs(line) do
    cell[3] = goto_tab "Session"
  end

  return { render.truncate(line, state.geometry.width - 2) }
end

---The tab bar and the rule under it.
---
---Each tab is numbered in the bar itself. The footer used to advertise "1-5
---jump" and nothing on screen said which number was which, so the hint was
---unusable even where the keys worked.
---@return table[][]
local function tab_lines()
  if not state then
    return { {}, {} }
  end
  -- Two spaces between tabs rather than a `│` rule: six numbered names plus
  -- five separators is 70 columns, which is exactly the inner width of the
  -- surface in an 80-column terminal -- so the last tab was the one truncated
  -- away, and the last tab is the one you had not discovered yet.
  local tabs = { { "  ", "PaseoDim" } }
  for i, name in ipairs(M.TABS) do
    local active = name == state.tab
    local click = goto_tab(name)
    tabs[#tabs + 1] = { ("%d "):format(i), "PaseoKey", click }
    tabs[#tabs + 1] = { name, active and "PaseoHeader" or "PaseoDim", click }
    tabs[#tabs + 1] = { "  ", nil }
  end
  return {
    render.truncate(tabs, state.geometry.width - 2),
    { { string.rep("─", state.geometry.width - 2), "PaseoBorder" } },
  }
end

---The active panel, padded to the space between the tabs and the footer.
---@return table[][]
local function body_lines()
  if not state then
    return { {} }
  end
  local g = state.geometry
  local height = g.height - 4
  local lines = {}

  if state.tab ~= "Chat" then
    local ok, panel = pcall(require, "paseo.ui.panels." .. state.tab:lower())
    local body = ok and panel.lines(state.chat, g.width - 4) or {
      { { "  this panel is unavailable", "PaseoToolFail" } },
    }
    for _, line in ipairs(body) do
      local row = { { "  ", nil } }
      vim.list_extend(row, render.truncate(vim.deepcopy(line), g.width - 4))
      lines[#lines + 1] = row
    end
  end
  -- On the Chat tab there is nothing to draw: the conversation is a real
  -- buffer floated over exactly this area.

  -- Pad out: volt draws one extmark per row at a row computed in `gen_data`
  -- and clears nothing first, so a panel that shrank leaves the previous
  -- draw's rows behind with nothing to overwrite them.
  while #lines < height do
    lines[#lines + 1] = {}
  end
  while #lines > height do
    table.remove(lines)
  end
  return lines
end

---@return table[][]
local function footer_lines()
  local last = tostring(#M.TABS)
  return {
    {
      { "  ", "PaseoDim" },
      { "1-" .. last, "PaseoKey" },
      { " tabs · ", "PaseoDim" },
      { "<Tab>", "PaseoKey" },
      { " cycle · ", "PaseoDim" },
      { "click", "PaseoKey" },
      { " anything · ", "PaseoDim" },
      { "<C-f>", "PaseoKey" },
      { " sidebar · ", "PaseoDim" },
      { "q", "PaseoKey" },
      { " close", "PaseoDim" },
    },
  }
end

---Every line of the chrome, in order. The no-volt fallback draws this.
---@return table[][]
local function chrome_lines()
  local lines = {}
  for _, section in ipairs { header_lines, tab_lines, body_lines, footer_lines } do
    vim.list_extend(lines, section())
  end
  return lines
end

---Redraw the chrome. The ONE entry point for any content change.
---
---Volt computes each section's row and the buffer height once, in `gen_data`,
---and `redraw` writes extmarks at those precomputed rows without clearing
---anything first. A panel whose content changed height therefore has to go all
---the way back through `gen_data`, or rows from the previous draw survive
---underneath the new ones.
function M.rebuild()
  if not state or not api.nvim_buf_is_valid(state.buf) then
    return
  end

  local g = state.geometry
  local ok = pcall(function()
    local volt = require "volt"
    api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
    volt.gen_data {
      {
        buf = state.buf,
        ns = ns,
        xpad = 1,
        layout = {
          -- Fresh tables every call: volt's `draw` strips the third element
          -- from every cell it is handed, so a cached line list loses its
          -- click targets after the first draw.
          {
            name = "header",
            lines = function()
              return render.to_volt(header_lines())
            end,
          },
          {
            name = "tabs",
            lines = function()
              return render.to_volt(tab_lines())
            end,
          },
          {
            name = "body",
            lines = function()
              return render.to_volt(body_lines())
            end,
          },
          {
            name = "footer",
            lines = function()
              return render.to_volt(footer_lines())
            end,
          },
        },
      },
    }
    vim.bo[state.buf].modifiable = true
    volt.set_empty_lines(state.buf, g.height, g.width)
    vim.bo[state.buf].modifiable = false
    volt.redraw(state.buf, "all")
  end)

  if not ok then
    -- No volt: draw the same cells as real text. The surface still works, it
    -- just cannot be clicked.
    render.to_buffer(state.buf, require("paseo.ui.hl").ns, 0, -1, chrome_lines())
    vim.bo[state.buf].modifiable = false
  end
end

---Repaint only what changes while a turn runs.
---
---Called from `sidebar.refresh`, which the spinner drives at 10 Hz. Going
---through `rebuild` here would rebuild the Changes panel -- one `git status`
---per repo -- ten times a second for the length of every turn.
---@param chat table
function M.refresh_header(chat)
  if not state or state.chat ~= chat or not api.nvim_buf_is_valid(state.buf) then
    return
  end
  local ok = pcall(function()
    local volt = require "volt"
    -- Usage is the other thing a running turn changes, and it is pure Lua --
    -- no subprocess -- so it can afford to ride along.
    volt.redraw(state.buf, state.tab == "Usage" and { "header", "body" } or { "header" })
  end)

  if not ok then
    -- No volt. Replace the header's one line of real text rather than falling
    -- back to `rebuild`, which would drag the Changes panel's `git status`
    -- through all ten frames a second.
    vim.bo[state.buf].modifiable = true
    render.to_buffer(state.buf, require("paseo.ui.hl").ns, 0, 1, header_lines())
    vim.bo[state.buf].modifiable = false
  end
end

-- --------------------------------------------------------------- child panes

---Tab navigation, bound where your cursor actually IS.
---
---This is why "1-5 jump" did nothing. The keys were mapped on the chrome
---buffer, and on the Chat tab -- the tab it opens on -- the chrome buffer never
---holds the cursor: `show_chat_panes` enters the composer. Every one of those
---keystrokes went to a buffer that had no such mapping.
---@param buf integer
---@param cycle boolean  Also take `<Tab>`/`<S-Tab>`.
local function bind_tabs(buf, cycle)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  -- A BARE DIGIT IS ALSO A COUNT, and these are ordinary buffers, so binding
  -- `3` costs you `3p` and `5j` in them for as long as the dashboard is up.
  -- That is the trade the footer is making, and it is the right one by default
  -- -- a seven-line prompt box is not where you type counts -- but it is a
  -- trade, so `ui.float.tab_keys = false` buys the counts back and leaves
  -- `<M-3>` and `<Tab>`, which collide with nothing.
  local digits = require("paseo.config").get().ui.float.tab_keys ~= false
  for i, name in ipairs(M.TABS) do
    local keys = digits and { tostring(i), ("<M-%d>"):format(i) } or { ("<M-%d>"):format(i) }
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, function()
        M.select(name)
      end, { buffer = buf, nowait = true, silent = true, desc = "paseo: tab " .. name })
    end
  end
  if not cycle then
    -- The conversation keeps its own `<Tab>`: expanding a tool card to see
    -- what the command printed is worth more there than a second way to cycle
    -- tabs, and `1`-`6` reach every tab anyway.
    return
  end
  vim.keymap.set("n", "<Tab>", function()
    M.cycle(1)
  end, { buffer = buf, nowait = true, silent = true, desc = "paseo: next tab" })
  vim.keymap.set("n", "<S-Tab>", function()
    M.cycle(-1)
  end, { buffer = buf, nowait = true, silent = true, desc = "paseo: previous tab" })
end

---Give the conversation and composer their keys back.
---
---These are buffers you KEEP -- the sidebar shows the same two -- so mappings
---left behind would still be swallowing digits long after the dashboard was
---closed, and a stale `<Tab>` would try to select a tab on a surface that no
---longer exists.
---@param buf integer
---@param cycle boolean
local function unbind_tabs(buf, cycle)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  for i = 1, #M.TABS do
    pcall(vim.keymap.del, "n", tostring(i), { buffer = buf })
    pcall(vim.keymap.del, "n", ("<M-%d>"):format(i), { buffer = buf })
  end
  if cycle then
    pcall(vim.keymap.del, "n", "<Tab>", { buffer = buf })
    pcall(vim.keymap.del, "n", "<S-Tab>", { buffer = buf })
  end
end

---Float the real conversation and composer over the Chat tab.
local function show_chat_panes()
  if not state then
    return
  end
  local g = state.geometry
  local chat = state.chat

  -- Buffer line 4 is the first body row -- header, tab bar, rule, then this --
  -- and buffer line N sits at screen row `g.row + N - 1`, because `g.row` is
  -- the chrome's first CONTENT row (the border is drawn outside it).
  local top = g.row + 3
  local composer_h = g.composer
  -- The last body row is `g.height - 1`: the footer owns `g.height`. So the
  -- composer's bottom border goes one row above the footer.
  local composer_row = g.row + g.height - (composer_h + 2)

  chat.win_conversation = api.nvim_open_win(chat.conversation, false, {
    relative = "editor",
    row = top,
    col = g.col + 2,
    width = g.width - 4,
    height = math.max(5, composer_row - 1 - top),
    style = "minimal",
    border = "none",
    zindex = g.z_panes,
  })
  chat.win_composer = api.nvim_open_win(chat.composer, true, {
    relative = "editor",
    row = composer_row,
    col = g.col + 2,
    width = g.width - 4,
    height = composer_h,
    style = "minimal",
    border = "rounded",
    zindex = g.z_panes,
  })

  for _, win in ipairs { chat.win_conversation, chat.win_composer } do
    for option, value in pairs {
      wrap = true,
      linebreak = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      -- Following the agent means the last line sits ON the last row. With a
      -- global `scrolloff` of 8 it cannot: the view stops eight rows early and
      -- the transcript never looks like it reached the bottom.
      scrolloff = 0,
      -- The header lives in the chrome now. A winbar here would draw it
      -- twice, one row apart.
      winbar = "",
    } do
      pcall(function()
        vim.wo[win][option] = value
      end)
    end
  end

  bind_tabs(chat.conversation, false)
  bind_tabs(chat.composer, true)

  M.refresh_header(chat)
  transcript.redraw(chat)
end

---@param chat table
local function hide_chat_panes(chat)
  if not chat then
    return
  end
  for _, win in ipairs { chat.win_composer, chat.win_conversation } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  chat.win_composer, chat.win_conversation = nil, nil
end

-- ------------------------------------------------------------------- tabs

---@param name string
function M.select(name)
  if not state or not vim.tbl_contains(M.TABS, name) then
    return
  end
  local was_chat = state.tab == "Chat"
  state.tab = name

  if name == "Chat" and not was_chat then
    show_chat_panes()
  elseif name ~= "Chat" then
    hide_chat_panes(state.chat)
    -- Arriving at a panel is the moment to refresh it. A panel that fetched
    -- once and cached the answer is a panel that shows you a workspace list
    -- from an hour ago -- or, if the daemon happened to be down then, an error
    -- for the rest of the session.
    local ok, panel = pcall(require, "paseo.ui.panels." .. name:lower())
    if ok and type(panel.load) == "function" then
      pcall(panel.load, state.chat)
    end
  end

  M.rebuild()
  if state.win and api.nvim_win_is_valid(state.win) and name ~= "Chat" then
    api.nvim_set_current_win(state.win)
  end
end

---@param step integer
function M.cycle(step)
  if not state then
    return
  end
  local at = 1
  for i, name in ipairs(M.TABS) do
    if name == state.tab then
      at = i
    end
  end
  M.select(M.TABS[(at - 1 + step) % #M.TABS + 1])
end

-- ------------------------------------------------------------- open / close

function M.close()
  if not state then
    return
  end
  local held = state
  state = nil

  unbind_tabs(held.chat.conversation, false)
  unbind_tabs(held.chat.composer, true)
  hide_chat_panes(held.chat)
  for _, win in ipairs { held.win, held.backdrop_win } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs { held.buf, held.backdrop } do
    if buf and api.nvim_buf_is_valid(buf) then
      -- Volt never clears its own state table; without this the chrome
      -- buffer's clickable and hoverable tables leak for the session.
      pcall(function()
        require("volt.state")[buf] = nil
      end)
      -- And its global on_key handler keeps dispatching against a dead buffer
      -- unless the buf is taken off its list.
      pcall(function()
        local bufs = require("volt.events").bufs
        for i, id in ipairs(bufs) do
          if id == buf then
            table.remove(bufs, i)
            break
          end
        end
      end)
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  held.chat.surface = nil
end

---@param chat table
function M.open(chat)
  -- Already up on this chat: go to the Chat tab and focus the composer rather
  -- than tearing the surface down and rebuilding it. "Open the chat" while
  -- sitting on the Usage panel means show me the conversation -- and it has to,
  -- because the caller goes on to put the cursor in `chat.win_composer`, which
  -- on any other tab does not exist.
  if M.is_open(chat) then
    M.select "Chat"
    if chat.win_composer and api.nvim_win_is_valid(chat.win_composer) then
      api.nvim_set_current_win(chat.win_composer)
    end
    return
  end
  M.close()

  local g = geometry()

  local backdrop, backdrop_win
  if g.backdrop then
    backdrop = api.nvim_create_buf(false, true)
    backdrop_win = api.nvim_open_win(backdrop, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = vim.o.columns,
      height = vim.o.lines,
      focusable = false,
      style = "minimal",
      border = "none",
      zindex = g.z_backdrop,
    })
    vim.wo[backdrop_win].winblend = 25
  end

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
    style = "minimal",
    border = "rounded",
    zindex = g.z_chrome,
  })

  state = {
    buf = buf,
    win = win,
    backdrop = backdrop,
    backdrop_win = backdrop_win,
    chat = chat,
    geometry = g,
    tab = "Chat",
  }
  chat.surface = "float"

  M.rebuild()
  pcall(function()
    local events = require "volt.events"
    events.add(buf)
    -- THE HALF THAT MAKES A CELL CLICKABLE WITH A MOUSE. `events.add` only
    -- binds `<CR>`; the `LeftMouse` dispatch lives behind `enable`, which
    -- `volt.run` calls and this surface -- which drives `gen_data`/`redraw`
    -- itself, to keep the conversation out of volt's hands -- never did. So
    -- the tab bar and every panel row had actions that no click reached.
    if not vim.g.extmarks_events then
      events.enable()
    end
  end)

  local map = function(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  for i, name in ipairs(M.TABS) do
    map(tostring(i), function()
      M.select(name)
    end)
  end
  map("<Tab>", function()
    M.cycle(1)
  end)
  map("<S-Tab>", function()
    M.cycle(-1)
  end)
  -- Swallow the paste keys. The chrome is not modifiable, and the realistic
  -- way to land here holding one is `3p` typed in the composer out of habit:
  -- the `3` switched tab and moved the cursor, and the `p` that followed it
  -- answered with `E21: Cannot make changes, 'modifiable' is off`, which
  -- blames the wrong thing entirely.
  map("p", function() end)
  map("P", function() end)
  map("q", M.close)
  map("<Esc>", M.close)
  map("<C-f>", function()
    M.close()
    chat.surface = "sidebar"
    sidebar.open(chat)
  end)

  show_chat_panes()
end

---@param chat table
---@return boolean
function M.is_open(chat)
  if not state then
    return false
  end
  -- Self-healing, because the chrome window can go away WITHOUT us: `:only`, a
  -- session restore, or another plugin's autocmd -- nvchad's dashboard closes
  -- every other window when the last real buffer is wiped. Left alone, the
  -- state outlives the window, `is_open` lies, and `open` then takes its
  -- "already up, just focus it" branch and puts nothing on screen.
  if not (state.win and api.nvim_win_is_valid(state.win)) then
    M.close()
    return false
  end
  return state.chat == chat
end

---The chat this surface is showing, if it is up.
---@return table|nil
function M.chat()
  return state and state.chat or nil
end

---The tab it is on, if it is up.
---@return string|nil
function M.tab()
  return state and state.tab or nil
end

return M
