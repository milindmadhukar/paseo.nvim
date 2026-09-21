--- The full-screen surface: the conversation, plus everything about the
--- agent session, on dashboard tabs.
---
--- The DEFAULT surface. The sidebar is for asking a question beside your code;
--- this is for the rest of the time -- when you want to see what the agent is
--- doing, what it has cost, what is changed on disk, which agent sessions are running
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

local icons = require "paseo.ui.icons"
local layout = require "paseo.ui.layout"
local render = require "paseo.ui.render"
local style = require "paseo.ui.style"
local widgets = require "paseo.ui.widgets"
local sidebar = require "paseo.ui.sidebar"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.float"

---@type table|nil
local state

M.TABS = { "Chat", "Agents & terminals", "Settings", "Changes", "Usage", "Workspaces" }

--- Tab name -> the module under `paseo.ui.panels` that draws it. Only the tabs
--- whose name is not simply the module name capitalised need an entry; the
--- list tab is spelled for what it holds, which is both kinds of session.
local PANEL_MODULE = { ["Agents & terminals"] = "sessions" }

---@param name string
---@return string
local function panel_module(name)
  return PANEL_MODULE[name] or name:lower()
end

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
  -- left. A CEILING it grows to rather than a height it stands at -- see
  -- `M.resize_composer`. Clamped to leave the conversation at least five rows.
  local composer = type(ui.composer) == "number" and math.floor(ui.composer) or 7
  composer = math.max(1, math.min(composer, h - 10))

  local z = ui.zindex or 30
  return {
    width = w,
    height = h,
    -- Whether the chrome window has a frame, which decides where its first
    -- CONTENT row is -- `nvim_open_win` is handed the border's row, not the
    -- content's. |paseo.ui.layout|.screen_row is the one place that matters,
    -- and everything floated over the body is positioned through it.
    border = select(1, style.window_border()) ~= "none",
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

---The agent-session header: the same cells the sidebar puts in its winbar.
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

  -- Everything the header names is a thing the Settings panel can change, so
  -- the header is the shortest route to it. Cells carry volt's third element;
  -- `volt.events.add` on this buffer is what turns that into a click.
  for _, cell in ipairs(line) do
    cell[3] = goto_tab "Settings"
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
  -- One pill per tab, number and name inside the same background, so a tab is
  -- a shape you can aim at rather than two differently-coloured words that
  -- happen to sit next to each other.
  --
  -- Truncation is not a neutral failure here: the bar is the only place that
  -- says which number is which tab, and the tab that falls off the end is
  -- always the last one, which is the one you had not discovered yet. Six
  -- pills fit an 80-column terminal with two columns to spare; a SEVENTH does
  -- not. So when they do not fit, the pills you are not on keep their number
  -- and lose their name -- which still says which key goes where, and is the
  -- one thing this row exists to say. The row count never changes, because
  -- `g.height - 4` and the composer geometry are both measured against it.
  local inner = state.geometry.width - 2

  ---A pill's text at a given level of detail.
  ---@param i integer
  ---@param name string
  ---@param level "full"|"named"|"icon"|"number"
  ---@return string
  local function pill(i, name, level)
    local icon = icons.panel[name] or ""
    if level == "full" then
      return (" %d %s %s "):format(i, icon, name)
    end
    if level == "named" then
      return (" %d %s "):format(i, name)
    end
    if level == "icon" then
      return (" %d %s "):format(i, icon)
    end
    return (" %d "):format(i)
  end

  ---@param level "full"|"named"|"icon"|"number"
  ---@return integer
  local function measure(level)
    local width = -1 -- the gap before the first pill is never drawn
    for i, name in ipairs(M.TABS) do
      -- At the narrowest level the ACTIVE tab still keeps its name: the row
      -- has to say where you are even when it cannot say where everything
      -- else is.
      local at = (level == "number" and name == state.tab) and "named" or level
      width = width + 1 + vim.fn.strwidth(pill(i, name, at))
    end
    return width
  end

  -- Truncation is not a neutral failure here: the bar is the only place that
  -- says which number is which tab, and the tab that falls off the end is
  -- always the last one, which is the one you had not discovered yet. So the
  -- bar DEGRADES instead, a step at a time, and every level still says which
  -- key goes where -- the one thing this row exists to say.
  --
  --   full    1 󰭻 Chat      number, icon and name
  --   named   1 Chat        the icon goes first: the name is the thing you
  --                         read, the icon is the thing you recognise, and a
  --                         name you cannot read is worth less than one you can
  --   icon    1 󰭻           seven of these fit in 41 columns
  --   number  1             with the active tab alone keeping its name
  --
  -- The row count never changes at any level, because the body height and the
  -- composer geometry are both measured against it.
  local level = "number"
  for _, candidate in ipairs { "full", "named", "icon" } do
    if measure(candidate) <= inner then
      level = candidate
      break
    end
  end

  local tabs = {}
  for i, name in ipairs(M.TABS) do
    local active = name == state.tab
    local id = "paseo:tab:" .. name
    local hovered = vim.g.nvmark_hovered == id
    -- Gap BEFORE each pill but the first, never after the last.
    if i > 1 then
      tabs[#tabs + 1] = { " ", nil }
    end
    tabs[#tabs + 1] = {
      pill(i, name, (level == "number" and active) and "named" or level),
      (active or hovered) and "PaseoChipFocus" or "PaseoChipOff",
      -- Hover paints a tab exactly as focus does, so pointing at one and
      -- being on one look like the same state, because they are.
      { click = goto_tab(name), hover = { id = id, redraw = "tabs" } },
    }
  end

  -- NO rule under the tabs, in any style. It used to be drawn for the framed
  -- ones, and that was the "three frame weights in one window" complaint in
  -- miniature: the float's own edge, a full-bleed rule directly under the
  -- pills, and a box around every card below it. The pills are a row of filled
  -- shapes and delimit the bar perfectly well by themselves -- which is why
  -- the unframed styles never wanted it and why the framed ones do not either.
  --
  -- The ROW stays. Dropping it would shift every section below, and volt
  -- records each section's start row when the layout is measured and never
  -- recomputes it on redraw.
  return { render.truncate(tabs, inner), {} }
end

---Which session the Chat tab is showing, and the others you could be in.
---
---THE ROW THAT SAYS WHERE YOU ARE. A terminal session has no composer to type
---into and no transcript to read, so without this the dashboard could be
---showing a PTY with nothing on screen saying which one, and no visible way
---back. Drawn on EVERY tab, like the header, because "which session am I in"
---is not a question that stops being worth answering when you look at Usage.
---
---EXACTLY ONE ROW, ALWAYS. volt records each section's start row once, in
---`gen_data`, and `redraw` writes extmarks at those rows without clearing
---anything -- so a strip that grew by a chip on hover would draw past the end
---of the buffer and `handle_hover` would raise "Invalid 'line': out of range"
---from inside `vim.on_key`. It degrades instead, the way the tab bar does.
---@return table[][]
local function strip_lines()
  if not state then
    return { {} }
  end
  local chat = state.chat
  local here = state.session or { kind = "agent", id = chat.agent_id }

  local items = {}
  for _, agent in ipairs(require("paseo.agents").for_root(chat.root)) do
    items[#items + 1] = {
      kind = "agent",
      id = agent.id,
      label = agent.title or agent.id,
      icon = icons.panel.Sessions,
    }
  end
  for _, item in ipairs(require("paseo.terminals").for_root(chat.root)) do
    items[#items + 1] = {
      kind = "terminal",
      id = item.id,
      label = require("paseo.terminals").label(item),
      icon = icons.panel.Terminals,
    }
  end

  local line = { { "  " } }
  if #items == 0 then
    line[#line + 1] = { "no sessions here yet", "PaseoDim" }
    line[#line + 1] = { "   " }
  end

  -- Named, then glyph-and-nothing, then dropped for a count. Same ladder as
  -- the tab bar, and for the same reason: the row has to keep saying where you
  -- are even when it cannot say where everything else is.
  local inner = state.geometry.width - 2
  local function build(level)
    local out = { { "  " } }
    local dropped = 0
    for _, item in ipairs(items) do
      local mine = item.kind == here.kind and item.id == here.id
      local text
      if level == "full" or mine then
        text = (" %s %s "):format(item.icon, item.label)
      elseif level == "icon" then
        text = (" %s "):format(item.icon)
      else
        dropped = dropped + 1
        text = nil
      end
      if text then
        local id = "float.strip." .. item.kind .. "." .. item.id
        out[#out + 1] = {
          text,
          mine and "PaseoChipFocus" or (widgets.hovered(id) and "PaseoChipFocus" or "PaseoChipOff"),
          widgets.hover(id, "strip", function()
            M.show_session { kind = item.kind, id = item.id }
          end),
        }
        out[#out + 1] = { " " }
      end
    end
    if dropped > 0 then
      out[#out + 1] = { (" +%d "):format(dropped), "PaseoChipOff" }
    end
    return out
  end

  for _, level in ipairs { "full", "icon", "count" } do
    local built = build(level)
    if render.width(built) <= inner - 14 or level == "count" then
      line = built
      break
    end
  end

  -- The way out, at the far end, always. `<C-s>` is bound in TERMINAL mode as
  -- well as normal, which is the only way it is worth having: a key you must
  -- first press `<C-\><C-n>` to reach is a key you do not reach.
  local keys = require("paseo.config").get().ui.terminal.keys
  return { widgets.row(line, widgets.hints { { keys.sessions, "sessions" } }, inner) }
end

---The active panel, padded to the space between the tabs and the footer.
---@return table[][]
local function body_lines()
  if not state then
    return { {} }
  end
  local g = state.geometry
  local height = layout.rows(g.height).body_height
  local lines = {}

  if state.tab ~= "Chat" then
    local ok, panel = pcall(require, "paseo.ui.panels." .. panel_module(state.tab))
    -- The height is passed as well as the width. A panel that can tighten
    -- itself -- Agent drops the breathing room inside its cards -- needs to
    -- know how many rows it is being given, and the rest simply ignore it.
    local body = ok and panel.lines(state.chat, g.width - 4, height)
      or {
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
  -- One builder for every hint bar in the plugin. This row had been copied
  -- into five files and they had already drifted -- this one advertised
  -- "1-5 jump" while there were six tabs.
  local widgets = require "paseo.ui.widgets"
  local pairs_ = {
    { "1-" .. #M.TABS, "tabs" },
    { "<Tab>", "cycle" },
    { "<C-f>", "sidebar" },
    { "<C-c>", "stop" },
    { "<C-t>", "speak" },
    { "q", "close" },
  }

  if not state then
    return { widgets.hints(pairs_) }
  end

  -- Sized to what is left after the elapsed count, and DEGRADING rather than
  -- truncating: the hint that falls off the end is the least important one,
  -- whereas a row cut to fit loses whichever end the renderer happens to cut.
  local status = sidebar.status(state.chat)
  local hints = widgets.hints(pairs_, nil, state.geometry.width - 2 - render.width(status) - 2)

  -- The spinner and the elapsed count, right-aligned against the hints. Here
  -- rather than in the header for two reasons: this is the row your eye goes
  -- back to while you wait, and it is the only changing field on it -- in the
  -- header it pushed the provider sideways every time the count gained a
  -- digit.
  --
  -- The footer rather than the composer's border, even though the composer is
  -- where you are looking: the composer only exists on the Chat tab, and a
  -- turn keeps running while you read the Changes panel.
  return {
    widgets.row(hints, status, state.geometry.width - 2, "PaseoNormal"),
  }
end

---Redraw the chrome. The ONE entry point for any content change.
---
---Volt computes each section's row and the buffer height once, in `gen_data`,
---and `redraw` writes extmarks at those precomputed rows without clearing
---anything first. A panel whose content changed height therefore has to go all
---the way back through `gen_data`, or rows from the previous draw survive
---underneath the new ones.
---The chrome buffer, for a panel that has to schedule a redraw of itself.
---
---A panel is handed a width and a height, not a buffer -- but an animated
---readout has to tell volt WHICH buffer to repaint when its timer fires, and
---there is only ever one dashboard.
---@return integer|nil
function M.chrome_buf()
  return state and api.nvim_buf_is_valid(state.buf) and state.buf or nil
end

function M.rebuild()
  if not state or not api.nvim_buf_is_valid(state.buf) then
    return
  end

  local volt = require "volt"
  local g = state.geometry

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
          name = "strip",
          lines = function()
            return render.to_volt(strip_lines())
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
end

---Repaint only what changes while a turn runs.
---
---Called from `sidebar.refresh`, which the spinner drives at 10 Hz. Going
---through `rebuild` here would rebuild the Changes panel -- one `git status`
---per repo -- ten times a second for the length of every turn.
---
---The FOOTER is in the list because that is where the spinner and the elapsed
---count live. Leaving it out is how the status would tick once and then sit
---frozen at `0s` for the rest of the turn.
---@param chat table
function M.refresh_header(chat)
  if not state or state.chat ~= chat or not api.nvim_buf_is_valid(state.buf) then
    return
  end
  local sections = { "header", "strip", "footer" }
  -- Usage is the other thing a running turn changes, and it is pure Lua -- no
  -- subprocess -- so it can afford to ride along.
  if state.tab == "Usage" then
    sections[#sections + 1] = "body"
  end
  require("volt").redraw(state.buf, sections)
end

-- --------------------------------------------------------------- child panes

---Tab navigation, bound where your cursor actually IS.
---
---This is why "1-5 jump" did nothing. The keys were mapped on the chrome
---buffer, and on the Chat tab -- the tab it opens on -- the chrome buffer never
---holds the cursor: `show_agent_panes` enters the composer. Every one of those
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

---What the composer's bottom border says: how to send it.
---
---How to send is the one question every chat composer gets asked, and the
---answer was only in `:help paseo`. BOTH keys, because they are not
---interchangeable: `<CR>` sends from normal mode and inserts a newline from
---insert mode, so the key that always works is `<C-s>` -- and a hint naming
---only `<CR>` would be actively wrong for anyone still typing.
---@return table[]
local function composer_hint()
  return {
    { " ", "PaseoComposerHint" },
    { icons.spell "<CR>", "PaseoComposerKey" },
    { " / ", "PaseoComposerHint" },
    { icons.spell "<C-s>", "PaseoComposerKey" },
    { " send ", "PaseoComposerHint" },
  }
end

---How many rows the composer wants for what is in it.
---
---An input that stands at its full configured height over an empty buffer is
---the "opaque rectangle" complaint in one line: seven rows of flat card colour
---is the largest and emptiest shape on the screen, and none of it is telling
---you anything. So the box GROWS with the prompt, from one row up to the
---configured maximum, which is what every chat composer does and what makes it
---read as a field rather than as a panel.
---
---Wrapped lines count. `wrap` is on, so one 300-column paragraph is four rows
---on screen and asking the buffer for its line count would say one -- and the
---box would stay a single row with the cursor off the bottom of it.
---@param chat table
---@param g table
---@return integer
local function composer_rows(chat, g)
  if not (chat.composer and api.nvim_buf_is_valid(chat.composer)) then
    return 1
  end

  local width = math.max(1, layout.panes(g).width)
  local rows = 0
  for _, line in ipairs(api.nvim_buf_get_lines(chat.composer, 0, -1, false)) do
    rows = rows + math.max(1, math.ceil(api.nvim_strwidth(line) / width))
  end

  return math.max(1, math.min(rows, g.composer))
end

---Re-seat the two panes for the composer's current height.
---
---Only the panes move. The chrome underneath is a fixed stack whose rows volt
---measured once, and the body it draws on the Chat tab is blank anyway -- the
---conversation is a real buffer floated over exactly that area -- so growing
---the composer costs two `nvim_win_set_config` calls and no redraw.
---@param chat table
function M.resize_composer(chat)
  if not state or state.chat ~= chat or state.tab ~= "Chat" then
    return
  end
  local win, conversation = chat.win_composer, chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end

  local g = state.geometry
  local panes = layout.panes(g, composer_rows(chat, g))
  if api.nvim_win_get_height(win) == panes.composer then
    return
  end

  pcall(api.nvim_win_set_config, win, {
    relative = "editor",
    row = panes.composer_row,
    col = panes.col,
    width = panes.width,
    height = panes.composer,
  })
  if conversation and api.nvim_win_is_valid(conversation) then
    pcall(api.nvim_win_set_config, conversation, {
      relative = "editor",
      row = panes.top,
      col = panes.col,
      width = panes.width,
      height = panes.conversation,
    })
    -- The conversation follows the agent, and it just got taller. Without this
    -- the extra rows open up BELOW the last line and the transcript stops
    -- looking like it reached the bottom.
    transcript.follow(chat)
  end
end

---Float the real conversation and composer over the Chat tab.
local function show_agent_panes()
  if not state then
    return
  end
  local g = state.geometry
  local chat = state.chat

  -- Where each pane goes is `ui/layout.lua`'s arithmetic, not ours: the same
  -- numbers decide how many rows the body gets and which row the terminals
  -- panel maps a click to, and they were three independent copies.
  local panes = layout.panes(g, composer_rows(chat, g))

  chat.win_conversation = api.nvim_open_win(chat.conversation, false, {
    relative = "editor",
    row = panes.top,
    col = panes.col,
    width = panes.width,
    height = panes.conversation,
    style = "minimal",
    border = "none",
    zindex = g.z_panes,
  })
  chat.win_composer = api.nvim_open_win(chat.composer, true, {
    relative = "editor",
    row = panes.composer_row,
    col = panes.col,
    width = panes.width,
    height = panes.composer,
    style = "minimal",
    border = "rounded",
    -- The border row is the only chrome an input field gets for free, so it
    -- carries both things the box has to say: what it is, and how to send it.
    -- Written INTO the frame rather than on a row of its own -- a hint bar
    -- under the composer would cost a row of the conversation to say something
    -- that is true the whole time.
    title = { { " " .. icons.marker.prompt .. " ", "PaseoComposerLabel" } },
    title_pos = "left",
    footer = composer_hint(),
    footer_pos = "right",
    zindex = g.z_panes,
  })

  -- The surface reads as ONE sheet: the conversation shares the chrome's
  -- background, and the composer is a raised card -- the same tier the Agent
  -- panel's cards sit on, so "where you type" is visibly a control and not
  -- more transcript.
  --
  -- The border is drawn rather than hidden, and that is the fix for "it is an
  -- opaque rectangle". Painted fg == bg it was a ring of padding, so the whole
  -- control was one flat slab of card colour with no edge and no affordance;
  -- a quiet rule around it is what makes the same box read as a field you type
  -- in. `PaseoComposerBorder` is one group for exactly this, so `ui.theme` can
  -- have it back.
  pcall(function()
    vim.wo[chat.win_conversation].winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal"
    vim.wo[chat.win_composer].winhl =
      "Normal:PaseoCard,NormalFloat:PaseoCard,FloatBorder:PaseoComposerBorder"
  end)

  -- Grow and shrink with what is typed. `TextChangedP` is in the list because
  -- a completion popup inserting a multi-line snippet changes the buffer
  -- without either of the other two firing.
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = api.nvim_create_augroup("PaseoComposerGrow", { clear = true }),
    buffer = chat.composer,
    desc = "paseo: grow the composer with its content",
    callback = function()
      M.resize_composer(chat)
    end,
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

---The keys a PTY buffer gets while it is the Chat tab.
---
---DIGITS ARE DELIBERATELY NOT AMONG THEM. A bare `5` in a terminal costs you
---`50k` to scroll back, and `<M-5>` reaches the same tab. `<Esc>` is never
---bound at all: it belongs to the PTY, so vim running inside one can still
---leave insert mode.
---
---Bound in TERMINAL mode as well as normal, which is the only way any of it is
---worth having -- a key you must press `<C-\><C-n>` to reach first is a key
---you do not reach, and the whole point of this surface is that a terminal is
---a session like any other rather than a place you get stuck in.
---@param buf integer
local function bind_terminal(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local keys = require("paseo.config").get().ui.terminal.keys
  local function map(mode, lhs, fn, desc)
    if not lhs then
      return
    end
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  for i, name in ipairs(M.TABS) do
    map({ "n", "t" }, ("<M-%d>"):format(i), function()
      M.select(name)
    end, "paseo: tab " .. name)
  end
  map({ "n", "t" }, keys.sessions, function()
    M.select "Agents & terminals"
  end, "paseo: the session list")
  map({ "n", "t" }, keys.next, function()
    M.cycle_session(1)
  end, "paseo: next session")
  map({ "n", "t" }, keys.prev, function()
    M.cycle_session(-1)
  end, "paseo: previous session")
  -- Normal mode only. `q` in terminal mode is a letter, and `<C-c>` is SIGINT
  -- and belongs to whatever is running -- which is the difference between a
  -- terminal you work in and a terminal you visit.
  map("n", "q", M.close, "paseo: close the dashboard")
end

---A terminal session: the PTY, filling the whole panel area.
---
---No composer, so no border either -- a bordered window costs two rows the
---body does not have. The chat panes get away with one because the composer's
---bottom border deliberately lands ON the last body row.
local function show_terminal_pane()
  if not state then
    return
  end
  local terminals = require "paseo.terminals"
  local terminal = require "paseo.ui.terminal"
  local item = terminals.get(state.session.id)
  if not item then
    -- The terminal died while we were pointed at it -- a directory update that
    -- no longer lists it, never a process exiting under us. Fall back rather
    -- than leaving the tab blank.
    state.session = { kind = "agent", id = state.chat.agent_id }
    return show_agent_panes()
  end

  local g = state.geometry
  local pane = layout.panes(g).body
  state.term_win = api.nvim_open_win(api.nvim_create_buf(false, true), true, {
    relative = "editor",
    row = pane.row,
    col = pane.col,
    width = pane.width,
    height = pane.height,
    style = "minimal",
    border = "none",
    zindex = g.z_panes,
  })
  pcall(function()
    vim.wo[state.term_win].winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal"
  end)

  local view = terminal.ensure(item, state.term_win)
  terminal.show(view, state.term_win)
  bind_terminal(view.buf)

  M.refresh_header(state.chat)
  -- Entered, and in insert. Landing on the chrome instead would send every
  -- keystroke to the tab bar.
  api.nvim_set_current_win(state.term_win)
  vim.cmd.startinsert()
end

---Whatever the current session needs on the Chat tab.
local function show_panes()
  if not state then
    return
  end
  if state.session and state.session.kind == "terminal" then
    return show_terminal_pane()
  end
  show_agent_panes()
end

local function hide_panes()
  if not state then
    return
  end
  local chat = state.chat
  -- Out of terminal mode BEFORE the window goes, or the editor is left in a
  -- mode the next surface did not ask for.
  if state.term_win and api.nvim_get_current_win() == state.term_win then
    pcall(vim.cmd.stopinsert)
  end
  -- Built by appending rather than as a literal. `ipairs` stops at the first
  -- nil, and these three are nil independently -- so `{ composer, conversation,
  -- term_win }` with the first two already cleared iterates NOTHING, and the
  -- PTY window survives the dashboard that owned it.
  local doomed = {}
  for _, win in pairs {
    composer = chat and chat.win_composer,
    conversation = chat and chat.win_conversation,
    terminal = state.term_win,
  } do
    doomed[#doomed + 1] = win
  end
  for _, win in ipairs(doomed) do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  if chat then
    chat.win_composer, chat.win_conversation = nil, nil
  end
  state.term_win = nil
end

-- ------------------------------------------------------------------- tabs

---The panel module for a tab, if it has one.
---
---Chat has none -- it is the conversation, floated over the body -- and a tab
---whose module fails to load must not take the surface down with it.
---@param name string
---@return table|nil
local function panel_for(name)
  local ok, panel = pcall(require, "paseo.ui.panels." .. panel_module(name))
  return ok and panel or nil
end

---Give a panel the chrome buffer's keys, and take them back again.
---
---The six panels SHARE one buffer, so a panel that binds `<CR>` has to unbind
---it on the way out or the Changes tab inherits it and tries to apply a
---agent setting. `attach`/`detach` are both optional: the panel contract has
---always been pcall-and-optional.
---@param name string
---@param method "attach"|"detach"
local function panel_keys(name, method)
  if not state then
    return
  end
  local panel = panel_for(name)
  if panel and type(panel[method]) == "function" then
    pcall(panel[method], state.chat, state.buf)
  end
end

---@param name string
function M.select(name)
  if not state or not vim.tbl_contains(M.TABS, name) then
    return
  end
  local was_chat = state.tab == "Chat"
  local leaving = state.tab
  if leaving ~= name then
    panel_keys(leaving, "detach")
  end
  state.tab = name

  if name == "Chat" and not was_chat then
    show_panes()
  elseif name ~= "Chat" then
    hide_panes()
    -- Arriving at a panel is the moment to refresh it. A panel that fetched
    -- once and cached the answer is a panel that shows you a workspace list
    -- from an hour ago -- or, if the daemon happened to be down then, an error
    -- for the rest of the session.
    local panel = panel_for(name)
    if panel and type(panel.load) == "function" then
      pcall(panel.load, state.chat)
    end
    panel_keys(name, "attach")
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

---Move a tab page off a window we are about to close.
---
---Closing a float that is another TAB PAGE'S CURRENT WINDOW leaves that tab
---pointing at a window which no longer exists. Neovim does not recover: the
---next `:tabclose`, or merely switching back, dies with `E315: ml_get: Invalid
---lnum` -- and with the four windows this surface opens, it takes the whole
---process down instead.
---
---The dashboard is always its tab's current window, so this is one keystroke
---away: open the chat, `gt`, close it. `workspaces.open` with the default
---`"tab"` does exactly that shape of thing on every workspace switch, which is
---what turned a latent crash into a routine one.
---
---`nvim_tabpage_set_win` is 0.11. On 0.10 the only way to move another tab
---page's cursor is to stand on it, and `noautocmd` keeps that round trip from
---looking like navigation to a config that chdirs on `TabEnter`.
---@param wins integer[]  Windows about to be closed.
local function reseat(wins)
  local doomed = {}
  for _, win in ipairs(wins) do
    if win and api.nvim_win_is_valid(win) then
      doomed[win] = true
    end
  end

  local here = api.nvim_get_current_tabpage()
  local tabs = {}
  for win in pairs(doomed) do
    local tab = api.nvim_win_get_tabpage(win)
    if tab ~= here then
      tabs[tab] = true
    end
  end

  for tab in pairs(tabs) do
    if api.nvim_tabpage_is_valid(tab) and doomed[api.nvim_tabpage_get_win(tab)] then
      local keep
      for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
        -- A normal window for preference: seating the tab on another float is
        -- the same bug one step along.
        if not doomed[win] and api.nvim_win_get_config(win).relative == "" then
          keep = win
          break
        end
      end
      if keep and api.nvim_tabpage_set_win then
        pcall(api.nvim_tabpage_set_win, tab, keep)
      elseif keep then
        local there = api.nvim_tabpage_get_number(tab)
        vim.cmd("noautocmd tabnext " .. there)
        pcall(api.nvim_set_current_win, keep)
        vim.cmd("noautocmd tabnext " .. api.nvim_tabpage_get_number(here))
      end
    end
  end
end

function M.close()
  if not state then
    return
  end
  reseat {
    state.win,
    state.backdrop_win,
    state.chat.win_conversation,
    state.chat.win_composer,
    -- THE PTY WINDOW BELONGS IN HERE. It is a float on this tab page and it is
    -- routinely the tab's current window -- you were typing in it. Left out,
    -- closing the dashboard from another tab leaves this one pointing at a
    -- window that no longer exists, and the next `:tabclose` dies with `E315:
    -- ml_get: Invalid lnum` or takes the process down outright.
    state.term_win,
  }
  -- Before `state` goes: `panel_keys` reads it, and a panel left attached
  -- would have its mappings outlive the buffer they were bound to. So does
  -- `hide_panes`, which is why the windows go here rather than below.
  panel_keys(state.tab, "detach")
  hide_panes()

  local held = state
  state = nil

  -- Before the buffer goes. A tween's timer redraws a named section every
  -- frame, and one left running against a deleted buffer is an error a frame
  -- forever rather than once.
  require("paseo.ui.animate").stop_all()

  -- The PTY windows are shut, so there is nothing left showing the terminal
  -- buffers and the daemon can stop base64-ing them across the pipe at a
  -- surface nobody is looking at. The cost is that reopening replays the
  -- scrollback, because `terminal.ensure` is only idempotent while the buffer
  -- lives; that is the cheaper half of the trade.
  require("paseo.ui.terminal").detach_all()

  if held.augroup then
    pcall(api.nvim_del_augroup_by_id, held.augroup)
  end

  unbind_tabs(held.chat.conversation, false)
  unbind_tabs(held.chat.composer, true)
  for _, win in ipairs { held.win, held.backdrop_win } do
    if win and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs { held.buf, held.backdrop } do
    if buf and api.nvim_buf_is_valid(buf) then
      -- Volt never clears its own state table; without this the chrome
      -- buffer's clickable and hoverable tables leak for the session.
      require("volt.state")[buf] = nil
      -- And its global on_key handler keeps dispatching against a dead buffer
      -- unless the buf is taken off its list.
      local bufs = require("volt.events").bufs
      for i, id in ipairs(bufs) do
        if id == buf then
          table.remove(bufs, i)
          break
        end
      end
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
    -- AND ON THE CONVERSATION, not on whatever the Chat tab was last left on.
    -- `state.session` survives a trip through the panels, so: `<C-s>` out of a
    -- terminal to the session list, an agent picked out of that list, and the
    -- Chat tab came back showing the same PTY -- a key that visibly did
    -- nothing. The session pointer is what "open the chat" moves.
    if not (state.session and state.session.kind == "agent") then
      state.session = { kind = "agent", id = chat.agent_id }
      hide_panes()
    end
    M.select "Chat"
    -- `select` only opens the panes when it is CHANGING tab, so the case
    -- above -- already on Chat, terminal panes just closed -- needs them
    -- opened here.
    if not (chat.win_composer and api.nvim_win_is_valid(chat.win_composer)) then
      show_panes()
    end
    if chat.win_composer and api.nvim_win_is_valid(chat.win_composer) then
      api.nvim_set_current_win(chat.win_composer)
    end
    return
  end
  M.close()

  -- The background tiers the whole surface is drawn on. Idempotent, and
  -- re-derived on `ColorScheme` -- but a user who opens the dashboard before
  -- anything else has touched the highlights still gets them.
  require("paseo.ui.hl").setup()

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

  local edge, edge_hl = style.window_border()

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
    style = "minimal",
    border = edge,
    zindex = g.z_chrome,
  })

  -- On the default -- `ui.style`'s "invisible" -- `PaseoNormalBorder` is
  -- fg == bg, so `nvim_open_win`'s border glyphs render as solid colour and
  -- the box becomes a one-cell padding ring in the surface's own background.
  -- That is the single change that stops the dashboard looking like a framed
  -- rectangle and starts it looking like a card. The other border settings
  -- paint the same glyphs in `PaseoBorder` and you get a visible edge.
  vim.wo[win].winhl = ("Normal:PaseoNormal,NormalFloat:PaseoNormal,FloatBorder:%s"):format(edge_hl)

  state = {
    buf = buf,
    win = win,
    backdrop = backdrop,
    backdrop_win = backdrop_win,
    chat = chat,
    geometry = g,
    tab = "Chat",
    -- What the Chat tab is showing. A sibling of `chat` rather than something
    -- folded into it: `state.chat` is identity-compared by `is_open`,
    -- `refresh_header` and every panel, and none of them should have to learn
    -- that a session might be a PTY.
    session = { kind = "agent", id = chat.agent_id },
  }
  chat.surface = "float"

  M.rebuild()

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
  map(require("paseo.config").get().ui.terminal.keys.sessions, function()
    M.select "Agents & terminals"
  end)

  -- THE DASHBOARD DID NOT FOLLOW A RESIZE. It registered no autocmds at all,
  -- so making the terminal bigger left a float at its old size with the panes
  -- floating wherever they had been. That was survivable while everything on
  -- it was redrawn text; it is not once a PTY is one of the panes, because a
  -- terminal that is not told its size renders to the wrong one.
  state.augroup = api.nvim_create_augroup("paseo.float", { clear = true })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = state.augroup,
    callback = function()
      vim.schedule(M.relayout)
    end,
    desc = "paseo: re-fit the dashboard",
  })

  show_panes()
end

---The size a PTY should run at here, for a terminal that does not exist yet.
---
---A terminal created before the surface is up gets the daemon's default and is
---resized the moment it is shown, which is a visible reflow; asking first
---costs nothing.
---@return { rows: integer, cols: integer }|nil
function M.body_size()
  if not state then
    return nil
  end
  local pane = layout.panes(state.geometry).body
  return { rows = pane.height, cols = pane.width }
end

---The session the Chat tab is showing.
---@return { kind: "agent"|"terminal", id: string|nil }|nil
function M.session()
  return state and state.session
end

---Show a session on the Chat tab.
---
---An agent that is not the one this surface is on is not ours to show: it is a
---different `paseo.Chat`, and |paseo.ui.chat|.open is the thing that knows how
---to subscribe to it, fetch its timeline and reseat this window. Anything else
----- the agent we already have, or any terminal -- is a repaint.
---@param session { kind: "agent"|"terminal", id: string|nil }
function M.show_session(session)
  if not state then
    return
  end
  if session.kind == "agent" and session.id and session.id ~= state.chat.agent_id then
    return require("paseo.ui.chat").open { root = state.chat.root, agent_id = session.id }
  end

  hide_panes()
  state.session = { kind = session.kind, id = session.id }
  if state.tab ~= "Chat" then
    -- `select` shows the panes itself, and detaches whatever panel we are
    -- leaving on the way.
    return M.select "Chat"
  end
  show_panes()
  M.rebuild()
end

---Step to the next or previous session in this workspace.
---
---Agents first, then terminals, which is the order the strip and the Sessions
---list both draw them in -- three orderings of one list is how they start
---disagreeing.
---@param step integer
function M.cycle_session(step)
  if not state then
    return
  end
  local chat = state.chat
  local order = {}
  for _, agent in ipairs(require("paseo.agents").for_root(chat.root)) do
    order[#order + 1] = { kind = "agent", id = agent.id }
  end
  for _, item in ipairs(require("paseo.terminals").for_root(chat.root)) do
    order[#order + 1] = { kind = "terminal", id = item.id }
  end
  if #order == 0 then
    return
  end

  local here = state.session or {}
  local at = 1
  for i, item in ipairs(order) do
    if item.kind == here.kind and item.id == here.id then
      at = i
    end
  end
  M.show_session(order[(at - 1 + step) % #order + 1])
end

---Re-fit everything to the editor's new size.
---
---A full `rebuild` rather than a `redraw`: the width changed, and volt records
---each section's rows and widths once, in `gen_data`.
function M.relayout()
  if not state or not api.nvim_win_is_valid(state.win) then
    return
  end
  local g = geometry()

  -- NOTHING MOVED, NOTHING TO RE-FIT. `WinResized` fires for any window on
  -- the tab page, not just for the editor changing size -- and one of those
  -- windows is a modal of ours: the new-agent screen opens and then sizes
  -- itself to its content the moment the model's features land. Re-fitting
  -- for that tore the panes down and reopened them, and `show_agent_panes`
  -- enters the composer as it does on a cold open, so the cursor was pulled
  -- out of the modal you were looking at and the only way back in was a
  -- click.
  local old = state.geometry
  if
    old
    and old.row == g.row
    and old.col == g.col
    and old.width == g.width
    and old.height == g.height
  then
    return
  end
  state.geometry = g

  pcall(api.nvim_win_set_config, state.win, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  })
  if state.backdrop_win and api.nvim_win_is_valid(state.backdrop_win) then
    pcall(api.nvim_win_set_config, state.backdrop_win, {
      relative = "editor",
      row = 0,
      col = 0,
      width = vim.o.columns,
      height = vim.o.lines,
    })
  end

  -- The panes are laid out from the geometry, so they are cheapest to close
  -- and reopen -- and on any tab but Chat there are none.
  if state.tab == "Chat" then
    -- WHATEVER HAD THE CURSOR KEEPS IT. The panes are recreated here, so
    -- their window ids change: the composer and the terminal are followed to
    -- their new windows, and anything else that was focused -- the chrome, or
    -- a modal floating over all of it -- is simply put back.
    local chat = state.chat
    local was = api.nvim_get_current_win()
    local composer = chat and was == chat.win_composer
    local conversation = chat and was == chat.win_conversation
    local terminal = was == state.term_win

    hide_panes()
    show_panes()

    local back = (composer and chat.win_composer)
      or (conversation and chat.win_conversation)
      or (terminal and state.term_win)
      or (api.nvim_win_is_valid(was) and was)
      or nil
    if back and api.nvim_win_is_valid(back) then
      -- `show_terminal_pane` lands in insert mode, which belongs to the PTY
      -- and to nothing else: leaving it set would send the next keystroke
      -- into a window that is not a terminal.
      if back ~= state.term_win and api.nvim_get_mode().mode ~= "n" then
        pcall(vim.cmd.stopinsert)
      end
      pcall(api.nvim_set_current_win, back)
    end
  end

  M.rebuild()
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
  -- AND ON THE TAB PAGE YOU ARE LOOKING AT. A float belongs to the tab it was
  -- opened on, so after `workspaces.open`'s default `tabnew` the previous
  -- dashboard is still a perfectly valid window -- just an invisible one. Left
  -- unasked, `chat.toggle` saw "already open", took its close branch, and the
  -- first press of the chat key in a new workspace did nothing you could see.
  -- The second one opened it, which reads as a key that needs pressing twice.
  if api.nvim_win_get_tabpage(state.win) ~= api.nvim_get_current_tabpage() then
    return false
  end
  return state.chat == chat
end

---Is this chat's dashboard up AT ALL -- on any tab page?
---
---The other question, and not the one `is_open` answers. `is_open` means "is
---it usable from where you are standing", because its callers go on to focus
---a window or to decide that a toggle should close. This one means "is there
---a chat on screen somewhere", which is what |paseo.ui.chat|.follow needs:
---the whole point of following is to move a surface that is on the tab you
---just LEFT onto the one you are on now, and a tab-aware test would answer
---"nothing open" at exactly that moment and leave it behind.
---@param chat table
---@return boolean
function M.showing(chat)
  if not state then
    return false
  end
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
