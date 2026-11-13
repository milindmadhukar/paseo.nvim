--- The subagent list `gs` opens: a float over the chat, LIVE.
---
--- It used to be a telescope picker, and a picker is a snapshot. Its rows were
--- built once, from whatever the list said the moment you pressed `gs`, with a
--- fixed clock glyph for "running" -- so nothing on it moved while a subagent
--- worked, and one that finished while you were reading still said running.
---
--- This is a plain buffer in a window of its own, the way the workspace rail
--- is: the cursor is the selection, `<CR>` opens what it is on. Every push
--- from |paseo.subagents| repaints it, and while anything on it is running a
--- 10Hz clock turns the spinner and the elapsed time -- and stops the moment
--- nothing is.

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local subagents = require "paseo.subagents"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.subagents"

M.FILETYPE = "paseo-subagents"

---The one list on screen. There is one `gs` at a time, so one of these.
---@type { buf: integer, win: integer, parent: table, rows: table<integer, paseo.Subagent>, timer: uv.uv_timer_t|nil }|nil
local view

---@type boolean
local attached = false

---The glyph, highlight and word for a subagent's state. Public so the tests
---can hold it: a running one is a spinner frame, never a still glyph.
---@param s paseo.Subagent
---@return string glyph, string hl, string word
function M.state(s)
  -- Before running: a subagent blocked on you is technically still running,
  -- and a spinner over it says the one thing that is not happening.
  if s.waiting then
    return icons.status.waiting, "PaseoBadge", "needs you"
  end
  if s.running then
    return widgets.spinner(), "PaseoToolRunning", "running"
  end
  if s.status == "failed" or s.status == "error" then
    return icons.status.failed, "PaseoToolFail", "failed"
  end
  if s.status == "canceled" or s.status == "cancelled" then
    return icons.status.canceled, "PaseoDim", "canceled"
  end
  if s.kind == "paseo" and s.status ~= "completed" and s.status ~= "closed" then
    -- An agent started through Paseo does not finish: it goes idle and waits
    -- for the next message, which is what it would be wrong to call "done".
    return icons.status.idle, "PaseoToolOk", "idle"
  end
  return icons.status.completed, "PaseoToolOk", "done"
end

---How long it has run, or ran for.
---@param s paseo.Subagent
---@return string|nil
local function elapsed(s)
  local to = (not s.running) and s.updatedAt or nil
  if not s.running and not to then
    return nil
  end
  return subagents.duration(subagents.seconds(s.createdAt, to))
end

---@return boolean
function M.is_open()
  return view ~= nil and api.nvim_win_is_valid(view.win) and api.nvim_buf_is_valid(view.buf)
end

---The lines, as |paseo.ui.render| means a line, and the subagent on each.
---@param parent table  The parent's chat.
---@param width integer
---@return table[][] lines, table<integer, paseo.Subagent> rows
function M.lines(parent, width)
  local list = subagents.list(parent.agent_id, parent.host_id)
  local running = 0
  for _, s in ipairs(list) do
    if s.running then
      running = running + 1
    end
  end

  local out, rows = {}, {}
  local summary = running > 0 and ("%d of %d running"):format(running, #list) or ("%d"):format(#list)
  out[1] = {
    { " " .. icons.tool.sub_agent .. " Subagents", "PaseoHeader" },
    { "  " .. summary, running > 0 and "PaseoToolRunning" or "PaseoDim" },
  }
  out[2] = {}
  if #list == 0 then
    out[3] = { { "   none yet -- they appear here as the agent starts them", "PaseoDim" } }
    return out, rows
  end

  for _, s in ipairs(list) do
    local glyph, hl, word = M.state(s)
    local time = elapsed(s)
    -- Three fixed columns on the right -- the state, how long, which kind --
    -- so they read down the list as columns. The kind says what <CR> does: a
    -- chat, or the read-only view.
    local right_width = 9 + 1 + 7 + 2 + 8 + 1
    local left_width = math.max(8, width - right_width - 5)
    local label = { { s.title, "PaseoText" } }
    if s.detail then
      label[#label + 1] = { "  " .. s.detail, "PaseoDim" }
    end
    label = render.pad(render.truncate(label, left_width), left_width + 1)
    local line = { { "  " .. glyph .. " ", hl } }
    vim.list_extend(line, label)
    line[#line + 1] = { ("%-9s"):format(word), hl }
    line[#line + 1] = { (" %7s  %-8s "):format(time or "", s.kind), "PaseoDim" }
    out[#out + 1] = line
    rows[#out] = s
  end
  out[#out + 1] = {}
  out[#out + 1] = { { "  <CR> open   q close", "PaseoDim" } }
  return out, rows
end

local function stop_clock()
  if view and view.timer then
    view.timer:stop()
    if not view.timer:is_closing() then
      view.timer:close()
    end
    view.timer = nil
  end
end

---Does anything on the list turn?
---@return boolean
local function spinning()
  if not view then
    return false
  end
  for _, s in pairs(view.rows) do
    if s.running then
      return true
    end
  end
  return false
end

---Repaint from |paseo.subagents|. Cheap -- a handful of short lines -- so the
---clock calls it ten times a second.
function M.draw()
  if not M.is_open() then
    return
  end
  local width = api.nvim_win_get_width(view.win)
  local lines, rows = M.lines(view.parent, width)
  local text = {}
  for i, line in ipairs(lines) do
    local parts = {}
    for _, cell in ipairs(line) do
      parts[#parts + 1] = cell[1]
    end
    text[i] = table.concat(parts)
  end

  local cursor = api.nvim_win_get_cursor(view.win)[1]
  local was = view.rows[cursor]

  vim.bo[view.buf].modifiable = true
  api.nvim_buf_set_lines(view.buf, 0, -1, false, text)
  vim.bo[view.buf].modifiable = false
  api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local col = 0
    for _, cell in ipairs(line) do
      local len = #cell[1]
      if cell[2] and len > 0 then
        api.nvim_buf_set_extmark(view.buf, ns, i - 1, col, { end_col = col + len, hl_group = cell[2] })
      end
      col = col + len
    end
  end
  view.rows = rows

  -- The window grows with the list (a subagent started while it was open),
  -- up to most of the screen.
  local height = math.max(3, math.min(#lines, vim.o.lines - 6))
  if api.nvim_win_get_height(view.win) ~= height then
    pcall(api.nvim_win_set_config, view.win, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
    })
  end

  -- THE CURSOR STAYS ON THE SUBAGENT IT WAS ON, not on the line number: a new
  -- one sorts in by start time and would otherwise slide the selection.
  local target
  for line, s in pairs(rows) do
    if was and s.kind == was.kind and s.id == was.id then
      target = line
    end
  end
  if not target and not rows[cursor] then
    for line = 1, #lines do
      if rows[line] then
        target = line
        break
      end
    end
  end
  if target then
    pcall(api.nvim_win_set_cursor, view.win, { target, 0 })
  end

  -- The clock runs only while something turns.
  if spinning() then
    if not view.timer then
      view.timer = vim.uv.new_timer()
      view.timer:start(100, 100, vim.schedule_wrap(function()
        if not (M.is_open() and spinning()) then
          return stop_clock()
        end
        M.draw()
      end))
    end
  else
    stop_clock()
  end
end

function M.close()
  stop_clock()
  if view then
    local held = view
    view = nil
    if api.nvim_win_is_valid(held.win) then
      pcall(api.nvim_win_close, held.win, true)
    end
    if api.nvim_buf_is_valid(held.buf) then
      pcall(api.nvim_buf_delete, held.buf, { force = true })
    end
  end
end

---The subagent under the cursor.
---@return paseo.Subagent|nil
function M.current()
  if not M.is_open() then
    return nil
  end
  return view.rows[api.nvim_win_get_cursor(view.win)[1]]
end

---@param step integer
local function move(step)
  if not M.is_open() then
    return
  end
  local line = api.nvim_win_get_cursor(view.win)[1] + step
  local last = api.nvim_buf_line_count(view.buf)
  while line >= 1 and line <= last do
    if view.rows[line] then
      return pcall(api.nvim_win_set_cursor, view.win, { line, 0 })
    end
    line = line + step
  end
end

local function attach()
  if attached then
    return
  end
  attached = true
  subagents.on_change(function(_, parent)
    if view and (parent == nil or parent == view.parent.agent_id) then
      M.draw()
    end
  end)
end

---Open the list over `parent`'s chat.
---@param parent table  The parent's chat.
function M.open(parent)
  attach()
  M.close()

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  pcall(api.nvim_buf_set_name, buf, "paseo://subagents/" .. (parent.agent_id or "?"))

  local width = math.max(40, math.min(96, vim.o.columns - 8))
  local edge, edge_hl = require("paseo.ui.style").window_border()
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor(vim.o.lines / 3),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = 3,
    style = "minimal",
    border = edge,
    -- `ui.float.zindex` plus the room the old dashboard's panes took above it:
    -- over an ordinary float, under the permission dialog.
    zindex = (require("paseo.config").get().ui.float.zindex or 40) + 20,
  })
  require("paseo.ui.style").pin(win)
  for option, value in pairs {
    winhl = ("Normal:PaseoNormal,NormalFloat:PaseoNormal,EndOfBuffer:PaseoNormal,CursorLine:PaseoRowHover,FloatBorder:%s"):format(
      edge_hl
    ),
    cursorline = true,
    wrap = false,
  } do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end

  view = { buf = buf, win = win, parent = parent, rows = {} }

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. desc })
  end
  map("j", function()
    move(1)
  end, "next subagent")
  map("k", function()
    move(-1)
  end, "previous subagent")
  map("<Down>", function()
    move(1)
  end, "next subagent")
  map("<Up>", function()
    move(-1)
  end, "previous subagent")
  local function open_current()
    local s = M.current()
    if not s then
      return
    end
    local chat = view.parent
    M.close()
    require("paseo.pickers.subagents").open_one(s, chat)
  end
  map("<CR>", open_current, "open this subagent")
  map("o", open_current, "open this subagent")
  map("<2-LeftMouse>", open_current, "open this subagent")
  map("q", M.close, "close")
  map("<Esc>", M.close, "close")

  api.nvim_create_autocmd({ "BufLeave", "WinClosed" }, {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  M.draw()
  return view
end

-- Exposed for the tests.
function M._view()
  return view
end

return M
