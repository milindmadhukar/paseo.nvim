--- The subagents of an agent session -- both kinds.
---
--- A PROVIDER subagent is the provider's own: Claude's Task tool, Codex's
--- spawned agents. The daemon tracks a descriptor and a timeline for each and
--- pushes both, but it is driven by its parent -- the protocol has no message
--- that sends one anything -- so it can be watched and not told.
---
--- A PASEO subagent is an agent another agent started through Paseo. The daemon
--- links it to its parent with a label, `paseo.parent-agent-id`, and that is the
--- whole difference: it is an ordinary agent, with a chat of its own that takes
--- messages like any other.
---
--- The Paseo app draws both as one track above the composer. So does this: one
--- list, one count, and the kind decides what opening a row does.

local bridge = require "paseo.bridge"
local hosts = require "paseo.hosts"

local M = {}

--- The label that makes an agent a Paseo subagent. Paseo's own constant
--- (`PARENT_AGENT_ID_LABEL` in @getpaseo/protocol's agent-labels).
M.PARENT_LABEL = "paseo.parent-agent-id"

---@class paseo.Subagent
---@field kind "provider"|"paseo"
---@field id string
---@field parent string           The parent AGENT's id.
---@field title string
---@field detail string|nil       What it was asked to do, when that differs.
---@field status string
---@field running boolean
---@field waiting boolean|nil     A Paseo subagent blocked on a permission.
---@field provider string|nil
---@field createdAt string|nil
---@field updatedAt string|nil   For a finished one, roughly when it finished.

--- Provider descriptors, per parent: `provider[host:parent][id] = descriptor`.
local provider = {}
local listeners = {}
local attached = false

---@param host_id string|nil
---@param parent string
local function key(host_id, parent)
  return hosts.key((hosts.get(host_id) or {}).id or host_id or "?", parent)
end

---@param host_id string|nil
---@param parent string|nil  nil when the change could concern any parent.
local function changed(host_id, parent)
  for _, fn in ipairs(listeners) do
    pcall(fn, host_id, parent)
  end
end

---Call `fn(host_id, parent)` whenever a list may have changed. `parent` is nil
---when the agent directory moved, which can add or finish a Paseo subagent of
---any parent.
---@param fn fun(host_id: string|nil, parent: string|nil)
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

local function attach()
  if attached then
    return
  end
  attached = true

  bridge.on("subagent", function(payload)
    vim.schedule(function()
      if payload.kind == "upsert" and payload.subagent then
        local subagent = payload.subagent
        local k = key(payload.hostId, subagent.parentAgentId)
        provider[k] = provider[k] or {}
        provider[k][subagent.id] = subagent
        changed(payload.hostId, subagent.parentAgentId)
      elseif payload.kind == "remove" and payload.parentAgentId then
        local k = key(payload.hostId, payload.parentAgentId)
        if provider[k] then
          provider[k][payload.subagentId] = nil
        end
        changed(payload.hostId, payload.parentAgentId)
      end
    end)
  end)

  require("paseo.agents").on_change(function(_, host_id)
    changed(host_id, nil)
  end)
end

---Parents whose provider list has been asked for on this connection, so the
---rail can call `track` on every agent it draws, every redraw, for free.
---@type table<string, boolean>
local tracked = {}

---Start tracking `parent`'s subagents: the live stream, the agent directory
---the Paseo kind is read from, and the provider list as it stands now -- the
---stream only reports what CHANGES, and a subagent already running when the
---chat opened would otherwise never be counted.
---@param parent string
---@param host_id? string
function M.follow(parent, host_id)
  attach()
  tracked[key(host_id, parent)] = true
  require("paseo.agents").watch(nil, host_id)
  bridge.request("subagents.follow", {}, function(err)
    if err then
      return
    end
    bridge.request("subagents.list", { agentId = parent }, function(list_err, result)
      if list_err or not result then
        return
      end
      vim.schedule(function()
        local k = key(host_id, parent)
        provider[k] = {}
        for _, subagent in ipairs(result.subagents or {}) do
          provider[k][subagent.id] = subagent
        end
        changed(host_id, parent)
      end)
    end, host_id)
  end, host_id)
end

---`follow`, once per parent per connection. For the callers that count the
---subagents of agents nobody has opened a chat on -- the workspace rail -- and
---would otherwise only ever see the Paseo kind, which needs no asking.
---@param parent string
---@param host_id? string
function M.track(parent, host_id)
  if not parent or tracked[key(host_id, parent)] then
    return
  end
  if not require("paseo.bridge").running() then
    return
  end
  M.follow(parent, host_id)
end

---Forget what was asked: the bridge reconnected, and the next `track` has to
---ask the new connection.
function M.untrack()
  tracked = {}
end

---@param text string|nil
---@return string|nil
local function line(text)
  if not text then
    return nil
  end
  text = vim.trim((text:gsub("%s+", " ")))
  return text ~= "" and text or nil
end

---Every subagent of `parent`, both kinds, oldest first.
---@param parent string|nil
---@param host_id? string
---@return paseo.Subagent[]
function M.list(parent, host_id)
  if not parent then
    return {}
  end
  local agents = require "paseo.agents"
  local out = {}

  for _, s in pairs(provider[key(host_id, parent)] or {}) do
    -- The app's label: the description when there is one -- it is what the
    -- parent asked for, "Explore the auth flow" -- else the title, which for
    -- Claude is the subagent type.
    local title = line(s.description) or line(s.title) or "subagent"
    local detail = line(s.subtitle) or (line(s.description) and line(s.title)) or nil
    out[#out + 1] = {
      kind = "provider",
      id = s.id,
      parent = parent,
      title = title,
      detail = detail ~= title and detail or nil,
      status = s.status or "running",
      running = s.status == "running",
      provider = s.provider,
      createdAt = s.createdAt,
      updatedAt = s.updatedAt,
    }
  end

  for _, a in ipairs(agents.all(host_id)) do
    if a.labels and a.labels[M.PARENT_LABEL] == parent then
      out[#out + 1] = {
        kind = "paseo",
        id = a.id,
        parent = parent,
        title = line(a.title) or "agent",
        status = a.status or "idle",
        running = agents.working(a.status),
        -- Blocked on a permission: answered in the parent's chat, which
        -- relays it (|paseo.ui.permission|.relay).
        waiting = (a.pendingPermissionCount or 0) > 0 or nil,
        provider = a.provider,
        createdAt = a.createdAt,
        updatedAt = a.updatedAt,
        cwd = a.cwd,
      }
    end
  end

  table.sort(out, function(a, b)
    if (a.createdAt or "") ~= (b.createdAt or "") then
      return (a.createdAt or "") < (b.createdAt or "")
    end
    return a.id < b.id
  end)
  return out
end

---How many are running, and how many there are.
---@param parent string|nil
---@param host_id? string
---@return integer running, integer total
function M.counts(parent, host_id)
  local running, total = 0, 0
  for _, s in ipairs(M.list(parent, host_id)) do
    total = total + 1
    if s.running then
      running = running + 1
    end
  end
  return running, total
end

---Subagents of every agent working under `root`: what the workspace rail
---badges a row with. A Paseo subagent working in the same workspace as its
---parent is ONE subagent, not also an agent with subagents of its own counted
---twice -- the parent's list is what it is counted in.
---@param root string
---@param host_id? string
---@return integer running, integer total
function M.counts_under(root, host_id)
  local running, total = 0, 0
  for _, agent in ipairs(require("paseo.agents").for_root(root, host_id)) do
    M.track(agent.id, host_id)
    local r, t = M.counts(agent.id, host_id)
    running, total = running + r, total + t
  end
  return running, total
end

---Seconds since an ISO-8601 UTC stamp, or nil when it is not one.
---
---Both sides are read as local time on purpose -- see the usage panel's
---`until_text` -- so the zone offset cancels in the subtraction.
---@param iso string|nil
---@param to? string|nil  Measure to this stamp rather than to now.
---@return integer|nil
function M.seconds(iso, to)
  local function epoch(stamp)
    if type(stamp) ~= "string" then
      return nil
    end
    local y, mo, d, h, mi, sec = stamp:match "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
    if not y then
      return nil
    end
    return os.time {
      year = tonumber(y),
      month = tonumber(mo),
      day = tonumber(d),
      hour = tonumber(h),
      min = tonumber(mi),
      sec = tonumber(sec),
      isdst = false,
    }
  end
  local from = epoch(iso)
  if not from then
    return nil
  end
  local upto = epoch(to)
  if not upto then
    local utc = os.date "!*t"
    utc.isdst = false
    upto = os.time(utc)
  end
  return math.max(0, upto - from)
end

---`42s`, `3m 05s`, `1h 12m`.
---@param seconds integer|nil
---@return string|nil
function M.duration(seconds)
  if not seconds then
    return nil
  end
  if seconds < 60 then
    return ("%ds"):format(seconds)
  end
  if seconds < 3600 then
    return ("%dm %02ds"):format(math.floor(seconds / 60), seconds % 60)
  end
  return ("%dh %02dm"):format(math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

---For the tests: listen again on the next `follow`, so a suite that stubs
---the bridge gets the handler -- the rail tracks parents as it draws, so an
---earlier suite may already have attached to the real one.
function M._reset()
  attached = false
  tracked = {}
end

-- Exposed for deterministic tests; production updates arrive from the bridge.
M._provider = provider
M._key = key

return M
