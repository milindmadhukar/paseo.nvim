--- The background-work list `gb` opens: the one chooser (|paseo.ui.choose|),
--- LIVE, like the subagent one (|paseo.ui.subagents|).
---
--- Every push from |paseo.background| repaints it, the elapsed times tick
--- while anything runs, and the cursor stays on the item it was on. `x` stops
--- the item under the cursor -- a heartbeat only after asking, because
--- stopping one DELETES its schedule; the daemon has no pause on this path.

local background = require "paseo.background"
local subagents = require "paseo.subagents"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

---@type { handle: paseo.Chooser, agent_id: string, host_id: string|nil, title: string|nil, timer: uv.uv_timer_t|nil }|nil
local view

local attached = false

---@return boolean
function M.is_open()
  return view ~= nil and not view.handle.closed and api.nvim_win_is_valid(view.handle.win)
end

---The glyph, highlight and word for an item's state.
---@param item paseo.BackgroundItem
---@return string glyph, string hl, string word
function M.state(item)
  local stop = background.stopping(item)
  if stop and stop.status == "pending" then
    return widgets.spinner(), "PaseoDim", "stopping"
  end
  if stop and stop.status == "error" then
    return "✗", "PaseoToolFail", "stop failed"
  end
  if item.gone then
    return "•", "PaseoDim", "not running"
  end
  if background.runs(item) then
    return widgets.spinner(), "PaseoToolRunning", "running"
  end
  return "•", "PaseoDim", "waiting"
end

---The rows, and the title over them.
---@param agent_id string
---@param host_id string|nil
---@param label? string  The agent's title, for the heading.
---@return paseo.ChooseItem[] items, string title
function M.items(agent_id, host_id, label)
  local list = background.list(agent_id, host_id)
  local out = {}
  for _, item in ipairs(list) do
    local glyph, hl, word = M.state(item)
    local title, command = background.text(item)
    local cells = { { glyph .. " ", hl }, { title, "PaseoText" } }
    if command then
      cells[#cells + 1] = { "  " .. command, "PaseoDim" }
    end
    local stop = background.stopping(item)
    if stop and stop.status == "error" and stop.error then
      cells[#cells + 1] = { "  " .. stop.error, "PaseoToolFail" }
    end
    local elapsed = (not item.gone) and subagents.duration(subagents.seconds(item.startedAt)) or nil
    out[#out + 1] = {
      id = item.stopToken or item.id,
      value = item,
      cells = cells,
      -- The same three columns the subagent list has: state, how long, kind.
      right = {
        { ("%-11s"):format(word), hl },
        { (" %7s  %-9s"):format(elapsed or "", item.kind), "PaseoDim" },
      },
    }
  end
  local running = select(1, background.counts(agent_id, host_id))
  local summary = running > 0 and ("%d of %d running"):format(running, #list) or tostring(#list)
  local head = "Background work · " .. summary
  if label and label ~= "" then
    head = head .. " · " .. label
  end
  return out, head
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

---Does anything on the list tick?
---@return boolean
local function ticking()
  if not view then
    return false
  end
  for _, item in ipairs(background.list(view.agent_id, view.host_id)) do
    local stop = background.stopping(item)
    if (background.runs(item) and not item.gone) or (stop and stop.status == "pending") then
      return true
    end
  end
  return false
end

---Repaint from |paseo.background|.
function M.draw()
  if not M.is_open() then
    return
  end
  local items, title = M.items(view.agent_id, view.host_id, view.title)
  view.handle.update(items, { title = title })
  if ticking() then
    if not view.timer then
      view.timer = vim.uv.new_timer()
      -- A second is enough for an elapsed time; the spinner turns on it too.
      view.timer:start(250, 250, vim.schedule_wrap(function()
        if not (M.is_open() and ticking()) then
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

local function attach()
  if attached then
    return
  end
  attached = true
  background.on_change(function(_, agent_id)
    if view and (agent_id == nil or agent_id == view.agent_id) then
      M.draw()
    end
  end)
end

---Stop `item` for the agent on the list, asking first for a heartbeat.
---@param item paseo.BackgroundItem|nil
function M.stop(item)
  if not (view and item) then
    return
  end
  if item.gone then
    return background.dismiss(item)
  end
  if not item.canStop then
    return vim.notify("paseo: this background work cannot be stopped from here", vim.log.levels.WARN)
  end
  local agent_id, host_id = view.agent_id, view.host_id
  local function go()
    background.stop(agent_id, host_id, item, function(err)
      if err then
        vim.notify("paseo: could not stop — " .. err, vim.log.levels.ERROR)
      end
    end)
  end
  if item.kind == "heartbeat" then
    -- One chooser at a time: a chooser closes when its window is left, and
    -- closing hands focus back -- which, with the question already open over
    -- it, closed the question too. So the list goes, the question is asked,
    -- and the list comes back with the answer.
    local title = background.text(item)
    local label = view.title
    M.close()
    vim.schedule(function()
      require("paseo.ui.choose").confirm(
        ("Stop the heartbeat %q? This deletes its schedule."):format(title),
        { no = "Keep it", yes = "Delete the heartbeat" },
        function(yes)
          if yes then
            go()
          end
          vim.schedule(function()
            M.open(agent_id, host_id, { title = label })
          end)
        end
      )
    end)
    return
  end
  go()
end

---Open the list for an agent.
---@param agent_id string
---@param host_id string|nil
---@param opts? { title?: string }
function M.open(agent_id, host_id, opts)
  attach()
  M.close()
  background.follow(agent_id, host_id)
  local label = opts and opts.title or nil
  local items, title = M.items(agent_id, host_id, label)
  local handle = require("paseo.ui.choose").open {
    title = title,
    items = items,
    empty = "nothing running in the background",
    numbers = false,
    width = math.max(48, math.min(110, vim.o.columns - 8)),
    verbs = {
      { "x", "stop", function(row)
        M.stop(row and row.value or nil)
      end },
      { "r", "refresh", function()
        if view then
          background.follow(view.agent_id, view.host_id)
        end
      end },
    },
    -- <CR> on a row says what it is in full: a long command does not fit.
    on_pick = function(row)
      local item = row.value
      local text, command = background.text(item)
      vim.notify(
        ("paseo: %s · %s%s"):format(item.kind, text, command and ("\n" .. command) or ""),
        vim.log.levels.INFO
      )
      vim.schedule(function()
        M.open(agent_id, host_id, opts)
      end)
    end,
    on_cancel = function()
      stop_clock()
      view = nil
    end,
  }
  view = { handle = handle, agent_id = agent_id, host_id = host_id, title = label }
  M.draw()
  return view
end

---The item under the cursor.
---@return paseo.BackgroundItem|nil
function M.current()
  if not M.is_open() then
    return nil
  end
  local row = view.handle.current()
  return row and row.value or nil
end

-- Exposed for the tests.
function M._view()
  return view
end

return M
