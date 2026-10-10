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
---@field provider string|nil
---@field createdAt string|nil

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

---Start tracking `parent`'s subagents: the live stream, the agent directory
---the Paseo kind is read from, and the provider list as it stands now -- the
---stream only reports what CHANGES, and a subagent already running when the
---chat opened would otherwise never be counted.
---@param parent string
---@param host_id? string
function M.follow(parent, host_id)
  attach()
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
        provider = a.provider,
        createdAt = a.createdAt,
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

-- Exposed for deterministic tests; production updates arrive from the bridge.
M._provider = provider
M._key = key

return M
