--- The full-screen surface: the conversation, plus everything about the
--- session, on tabs.
---
--- The sidebar is for asking a question beside your code. This is for the other
--- half of the time -- when you want to see what the agent is doing, what it
--- has cost, what is changed on disk, and to change the mode without a
--- `vim.ui.select` prompt covering the thing you are reading.
---
--- Structure, from the bottom up: a dimmed backdrop, a volt-drawn chrome window
--- carrying the tab bar and the active panel, and -- on the conversation tab
--- only -- the real conversation and composer buffers floated on top. The
--- chrome is volt's; the conversation is never volt's, because virtual text
--- cannot be yanked.

local render = require "paseo.ui.render"
local sidebar = require "paseo.ui.sidebar"
local transcript = require "paseo.ui.transcript"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.float"

---@type table|nil
local state

M.TABS = { "Chat", "Session", "Sessions", "Changes", "Usage" }

-- ------------------------------------------------------------------ geometry

local function geometry()
  local w = math.max(60, vim.o.columns - 8)
  local h = math.max(20, vim.o.lines - 6)
  return {
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
  }
end

-- -------------------------------------------------------------------- chrome

---The tab bar plus the active panel's lines.
---@return table[][]
local function chrome_lines()
  if not state then
    return { {} }
  end
  local g = state.geometry
  local lines = {}

  local tabs = { { " ", "PaseoDim" } }
  for _, name in ipairs(M.TABS) do
    local active = name == state.tab
    tabs[#tabs + 1] = { " " .. name .. " ", active and "PaseoHeader" or "PaseoDim" }
    tabs[#tabs + 1] = { " ", nil }
  end
  lines[#lines + 1] = tabs
  lines[#lines + 1] = { { string.rep("─", g.width - 2), "PaseoBorder" } }

  if state.tab == "Chat" then
    -- The conversation is a real buffer floated on top of this area; nothing
    -- to draw here but the space it occupies.
    for _ = 1, g.height - 4 do
      lines[#lines + 1] = {}
    end
  else
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

  -- Pad out to the window height: volt fills the buffer with exactly `h` blank
  -- lines and draws one extmark per row, so a section that shrinks leaves the
  -- previous draw's extmarks behind with nothing to overwrite them.
  while #lines < g.height - 1 do
    lines[#lines + 1] = {}
  end

  lines[#lines + 1] = {
    { "  ", "PaseoDim" },
    { "<Tab>", "PaseoKey" },
    { " next tab · ", "PaseoDim" },
    { "1-5", "PaseoKey" },
    { " jump · ", "PaseoDim" },
    { "<C-f>", "PaseoKey" },
    { " sidebar · ", "PaseoDim" },
    { "q", "PaseoKey" },
    { " close", "PaseoDim" },
  }

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
          {
            name = "chrome",
            -- Fresh tables every call: volt's `draw` strips the third element
            -- from every cell it is handed.
            lines = function()
              return render.to_volt(chrome_lines())
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

-- --------------------------------------------------------------- child panes

---Float the real conversation and composer over the Chat tab.
local function show_chat_panes()
  if not state then
    return
  end
  local g = state.geometry
  local chat = state.chat

  local conv_h = g.height - 13
  chat.win_conversation = api.nvim_open_win(chat.conversation, false, {
    relative = "editor",
    row = g.row + 3,
    col = g.col + 2,
    width = g.width - 4,
    height = math.max(5, conv_h),
    style = "minimal",
    border = "none",
    zindex = 110,
  })
  chat.win_composer = api.nvim_open_win(chat.composer, true, {
    relative = "editor",
    row = g.row + g.height - 9,
    col = g.col + 2,
    width = g.width - 4,
    height = 7,
    style = "minimal",
    border = "rounded",
    zindex = 110,
  })

  for _, win in ipairs { chat.win_conversation, chat.win_composer } do
    for option, value in pairs {
      wrap = true,
      linebreak = true,
      number = false,
      relativenumber = false,
      signcolumn = "no",
    } do
      pcall(function()
        vim.wo[win][option] = value
      end)
    end
  end

  sidebar.refresh(chat)
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
  elseif name ~= "Chat" and was_chat then
    hide_chat_panes(state.chat)
  end

  M.rebuild()
  if state.win and api.nvim_win_is_valid(state.win) and name ~= "Chat" then
    api.nvim_set_current_win(state.win)
  end
end

-- ------------------------------------------------------------- open / close

function M.close()
  if not state then
    return
  end
  local held = state
  state = nil

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
  M.close()

  local g = geometry()

  local backdrop = api.nvim_create_buf(false, true)
  local backdrop_win = api.nvim_open_win(backdrop, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    focusable = false,
    style = "minimal",
    border = "none",
    zindex = 90,
  })
  vim.wo[backdrop_win].winblend = 25

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
    style = "minimal",
    border = "rounded",
    zindex = 100,
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
    require("volt.events").add(buf)
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
    local at = 1
    for i, name in ipairs(M.TABS) do
      if name == state.tab then
        at = i
      end
    end
    M.select(M.TABS[at % #M.TABS + 1])
  end)
  map("q", M.close)
  map("<Esc>", M.close)
  map("<C-f>", function()
    M.close()
    require("paseo.ui.chat").open { root = chat.root, agent_id = chat.agent_id }
  end)

  show_chat_panes()
end

---@param chat table
---@return boolean
function M.is_open(chat)
  return state ~= nil and state.chat == chat
end

return M
