--- The subagent list `gs` opens: the one chooser (|paseo.ui.choose|), LIVE.
---
--- A snapshot will not do for a list of things that are running: every push
--- from |paseo.subagents| repaints it, and while anything on it is running a
--- 10Hz clock turns the spinner and the elapsed time -- and stops the moment
--- nothing is. The cursor stays on the subagent it was on.

local icons = require "paseo.ui.icons"
local subagents = require "paseo.subagents"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

---The one list on screen. There is one `gs` at a time, so one of these.
---@type { handle: paseo.Chooser, buf: integer, win: integer, parent: table, rows: table<integer, paseo.Subagent>, timer: uv.uv_timer_t|nil }|nil
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
  return view ~= nil and not view.handle.closed and api.nvim_win_is_valid(view.win)
end

---The rows, and the title over them.
---@param parent table  The parent's chat.
---@return paseo.ChooseItem[] items, string title
function M.items(parent)
  local list = subagents.list(parent.agent_id, parent.host_id)
  local running = 0
  local out = {}
  for _, s in ipairs(list) do
    if s.running then
      running = running + 1
    end
    local glyph, hl, word = M.state(s)
    local label = { { glyph .. " ", hl }, { s.title, "PaseoText" } }
    if s.detail then
      label[#label + 1] = { "  " .. s.detail, "PaseoDim" }
    end
    -- Three fixed columns on the right -- the state, how long, which kind --
    -- so they read down the list as columns. The kind says what <CR> does: a
    -- chat, or the read-only view.
    out[#out + 1] = {
      id = s.kind .. ":" .. s.id,
      value = s,
      cells = label,
      right = {
        { ("%-9s"):format(word), hl },
        { (" %7s  %-8s"):format(elapsed(s) or "", s.kind), "PaseoDim" },
      },
    }
  end
  local summary = running > 0 and ("%d of %d running"):format(running, #list) or tostring(#list)
  return out, "Subagents · " .. summary
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

---`view.rows` as line -> subagent, from the chooser's line -> index.
---@param items paseo.ChooseItem[]
local function remap(items)
  view.rows = {}
  for line, index in pairs(view.handle.rows) do
    view.rows[line] = items[index].value
  end
end

---Repaint from |paseo.subagents|. Cheap -- a handful of short lines -- so the
---clock calls it ten times a second.
function M.draw()
  if not M.is_open() then
    return
  end
  local items, title = M.items(view.parent)
  view.handle.update(items, { title = title })
  remap(items)

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
    held.handle.close()
  end
end

---The subagent under the cursor.
---@return paseo.Subagent|nil
function M.current()
  if not M.is_open() then
    return nil
  end
  local row = view.handle.current()
  return row and row.value or nil
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

  local items, title = M.items(parent)
  local handle = require("paseo.ui.choose").open {
    title = title,
    items = items,
    empty = "none yet — they appear here as the agent starts them",
    width = math.max(40, math.min(96, vim.o.columns - 8)),
    on_pick = function(row)
      stop_clock()
      view = nil
      require("paseo.pickers.subagents").open_one(row.value, parent)
    end,
    on_cancel = function()
      stop_clock()
      view = nil
    end,
  }
  view = { handle = handle, buf = handle.buf, win = handle.win, parent = parent, rows = {} }
  remap(items)
  M.draw()
  return view
end

-- Exposed for the tests.
function M._view()
  return view
end

return M
