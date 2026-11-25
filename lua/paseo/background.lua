--- An agent's BACKGROUND WORK: what it left running after its turn.
---
--- A Claude `run_in_background` shell or a Codex/OpenCode monitor, and (Paseo
--- 0.17) the daemon's own: a heartbeat schedule aimed at the agent, or a PR/MR
--- watch. The Paseo app lists them in a pill above the composer, each with a
--- Stop; this is the list `gb` opens.
---
--- Two sources, on purpose:
---  * The COUNT is on the agent itself (`agent.backgroundWork`, from the
---    directory), so the rail can say "this workspace is still running" for
---    agents nobody has opened. |paseo.agents|.bucket reads it.
---  * The ITEMS are asked for per agent and then pushed whole on every change
---    (`agent.background_work.update`); there is no delta. That is this module.
---
--- A heartbeat counts and does not RUN: `running` is the daemon's
--- `runningCount`, which leaves heartbeats out, and only that makes an idle
--- agent look busy -- as `isAgentRunning` does in the app.

local bridge = require "paseo.bridge"
local hosts = require "paseo.hosts"

local M = {}

---@class paseo.BackgroundItem
---@field id string
---@field kind string            "shell", "monitor", "heartbeat", or a provider's own.
---@field description string|nil
---@field command string|nil
---@field startedAt string|nil
---@field canStop boolean
---@field stopToken string|nil

--- `items[host:agent]` = the last list the daemon sent.
local items = {}
--- Agents whose list was asked for on this connection, by `host:agent`.
local followed = {}
--- Stops in flight or failed, by stop token: `{ status = "pending"|"error", item, agent, error }`.
local stops = {}
local listeners = {}
local attached = false

---@param host_id string|nil
---@param agent_id string
local function key(host_id, agent_id)
  return hosts.key((hosts.get(host_id) or {}).id or host_id or "?", agent_id)
end

local function changed(host_id, agent_id)
  for _, fn in ipairs(listeners) do
    pcall(fn, host_id, agent_id)
  end
end

---Call `fn(host_id, agent_id)` whenever an agent's list may have changed.
---@param fn fun(host_id: string|nil, agent_id: string|nil)
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

---Replace an agent's list. A stop whose item has gone is done; one whose item
---is still there stays pending until it goes or the request fails.
---@param host_id string|nil
---@param agent_id string
---@param list paseo.BackgroundItem[]
function M._apply(host_id, agent_id, list)
  items[key(host_id, agent_id)] = list or {}
  for token, entry in pairs(stops) do
    if entry.agent == agent_id and entry.status == "pending" then
      local present = false
      for _, item in ipairs(list or {}) do
        if item.stopToken == token then
          present = true
        end
      end
      if not present then
        stops[token] = nil
      end
    end
  end
  changed(host_id, agent_id)
end

local function list_now(agent_id, host_id)
  bridge.request("background.list", { agentId = agent_id }, function(err, result)
    if err or not result then
      return
    end
    vim.schedule(function()
      M._apply(host_id, agent_id, result.items or {})
    end)
  end, host_id)
end

local function attach()
  if attached then
    return
  end
  attached = true
  bridge.on("background", function(payload)
    vim.schedule(function()
      if payload.agentId then
        M._apply(payload.hostId, payload.agentId, payload.items or {})
      end
    end)
  end)
  -- The stream came back after a reconnect: whatever changed in the gap was
  -- never pushed. List again, for every agent this host was asked about.
  bridge.on("background_resync", function(payload)
    vim.schedule(function()
      local prefix = key(payload.hostId, "")
      for k, agent_id in pairs(followed) do
        if vim.startswith(k, prefix) then
          list_now(agent_id, payload.hostId)
        end
      end
    end)
  end)
end

---Follow `agent_id`'s background work: the live stream (one per connection;
---asking again is free) and the list as it stands now, which the stream would
---never send for work that was already running.
---@param agent_id string
---@param host_id? string
function M.follow(agent_id, host_id)
  if not agent_id then
    return
  end
  attach()
  followed[key(host_id, agent_id)] = agent_id
  bridge.request("background.follow", {}, function(err, result)
    if err or not (result and result.supported) then
      return
    end
    list_now(agent_id, host_id)
  end, host_id)
end

---The last list for `agent_id`, plus any item whose stop FAILED after it
---left -- so the failure stays on screen until it is dismissed, as the app
---keeps it.
---@param agent_id string
---@param host_id? string
---@return paseo.BackgroundItem[]
function M.list(agent_id, host_id)
  local out = vim.list_slice(items[key(host_id, agent_id)] or {})
  local present = {}
  for _, item in ipairs(out) do
    if item.stopToken then
      present[item.stopToken] = true
    end
  end
  for token, entry in pairs(stops) do
    if entry.agent == agent_id and entry.status == "error" and not present[token] then
      out[#out + 1] = vim.tbl_extend("force", entry.item, { gone = true })
    end
  end
  return out
end

---Has a list been received for this agent at all?
---@param agent_id string
---@param host_id? string
---@return boolean
function M.known(agent_id, host_id)
  return items[key(host_id, agent_id)] ~= nil
end

---How much there is, and how much of it runs, for an agent: the live list
---when there is one, else the summary on the agent.
---@param agent_id string
---@param host_id? string
---@return integer running, integer total
function M.counts(agent_id, host_id)
  local list = items[key(host_id, agent_id)]
  if list then
    local running = 0
    for _, item in ipairs(list) do
      if M.runs(item) then
        running = running + 1
      end
    end
    return running, #list
  end
  local agent = require("paseo.agents").get(agent_id, host_id)
  return M.summary_counts(agent)
end

---An agent summary's `backgroundWork`, as (running, total).
---@param agent table|nil
---@return integer running, integer total
function M.summary_counts(agent)
  local work = agent and agent.backgroundWork
  if type(work) ~= "table" then
    return 0, 0
  end
  return work.running or work.count or 0, work.count or 0
end

---Does an item RUN? A heartbeat is waiting for its next beat, not running.
---@param item paseo.BackgroundItem
---@return boolean
function M.runs(item)
  return item.kind ~= "heartbeat"
end

---A stop in flight or failed for this item, if any.
---@param item paseo.BackgroundItem
---@return { status: "pending"|"error", error?: string }|nil
function M.stopping(item)
  return item.stopToken and stops[item.stopToken] or nil
end

---Forget a failed stop of an item that has gone anyway.
---@param item paseo.BackgroundItem
function M.dismiss(item)
  if item.stopToken and stops[item.stopToken] then
    local agent = stops[item.stopToken].agent
    stops[item.stopToken] = nil
    changed(nil, agent)
  end
end

---Stop one item. The daemon refuses a token from before the item changed, so
---this never stops the wrong thing; the item leaves the list by the next
---update, which is what clears `pending`.
---@param agent_id string
---@param host_id string|nil
---@param item paseo.BackgroundItem
---@param callback? fun(err: string|nil)
function M.stop(agent_id, host_id, item, callback)
  if not (item.canStop and item.stopToken) then
    return callback and callback "this cannot be stopped from here"
  end
  local token = item.stopToken
  if stops[token] and stops[token].status == "pending" then
    return
  end
  stops[token] = { status = "pending", item = item, agent = agent_id }
  changed(host_id, agent_id)
  bridge.request("background.stop", {
    agentId = agent_id,
    itemId = item.id,
    stopToken = token,
  }, function(err)
    vim.schedule(function()
      if err then
        stops[token] = { status = "error", item = item, agent = agent_id, error = tostring(err) }
      elseif stops[token] and not M._present(agent_id, host_id, token) then
        stops[token] = nil
      end
      changed(host_id, agent_id)
      if callback then
        callback(err and tostring(err) or nil)
      end
    end)
  end, host_id)
end

---@param agent_id string
---@param host_id string|nil
---@param token string
---@return boolean
function M._present(agent_id, host_id, token)
  for _, item in ipairs(items[key(host_id, agent_id)] or {}) do
    if item.stopToken == token then
      return true
    end
  end
  return false
end

---The line a row leads with: the description, or the command, or the kind --
---the app's `backgroundWorkText` -- and the command under it only when it
---says something the title does not.
---@param item paseo.BackgroundItem
---@return string title, string|nil command
function M.text(item)
  local title = item.description or item.command or item.kind
  local command = item.command and item.command ~= title and item.command or nil
  return title, command
end

---Forget what was asked: the bridge reconnected.
function M.unfollow()
  followed = {}
end

---For the tests.
function M._reset()
  items, followed, stops = {}, {}, {}
  attached = false
end

return M
