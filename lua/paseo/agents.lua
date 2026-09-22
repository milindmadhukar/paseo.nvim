--- The live agent directory.
---
--- Kept as a table the picker can read synchronously, fed by PUSH from the
--- sidecar. That is the whole reason the sidecar exists: at 2.4 seconds per CLI
--- call a polled status column is unobtainable, and the column is what makes
--- the workspace picker a dashboard rather than a list of directories.

local bridge = require "paseo.bridge"

local M = {}

---@type table<string, table>  agent id -> agent
local agents = {}
local subscribed = false
local listeners = {}

---Render from the SNAPSHOT first, then apply updates. The snapshot always
---arrives before any update, so starting from an empty table and waiting for
---upserts would show nothing until something changed.
local function apply(payload)
  if payload.kind == "snapshot" then
    agents = {}
    for _, agent in ipairs(payload.entries or {}) do
      agents[agent.id] = agent
    end
  elseif payload.kind == "upsert" and payload.agent then
    agents[payload.agent.id] = payload.agent
  elseif payload.kind == "remove" and payload.id then
    agents[payload.id] = nil
  elseif payload.kind == "error" then
    vim.notify("paseo: agent directory: " .. tostring(payload.error), vim.log.levels.WARN)
    subscribed = false
    return
  end

  for _, fn in ipairs(listeners) do
    pcall(fn, agents)
  end
end

-- Exposed for deterministic tests; production updates arrive from `watch`.
M._apply = apply

---Start following the directory. Safe to call repeatedly.
---@param callback? fun(err: string|nil)
function M.watch(callback)
  callback = callback or function() end
  if subscribed then
    return callback(nil)
  end

  bridge.ensure(function(err)
    if err then
      return callback(err)
    end
    bridge.on("agents", apply)
    bridge.request("agents.subscribe", {}, function(sub_err)
      subscribed = not sub_err
      callback(sub_err)
    end)
  end)
end

---Call `fn` whenever the directory changes.
---@param fn fun(agents: table<string, table>)
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

---One agent from the directory, by id.
---@param id string
---@return table|nil
function M.get(id)
  return agents[id]
end

---Every non-archived agent session in the subscribed directory.
---@return table[]
function M.all()
  local out = {}
  for _, agent in pairs(agents) do
    out[#out + 1] = agent
  end
  table.sort(out, function(a, b)
    return (a.title or a.id) < (b.title or b.id)
  end)
  return out
end

---@return boolean
function M.ready()
  return subscribed
end

---The statuses that mean the agent is DOING something, as the daemon spells
---them. One table, because two lists of these drift and then two surfaces
---disagree about whether the same session is busy.
local WORKING = {
  running = true,
  starting = true,
  initializing = true,
  queued = true,
  working = true,
  busy = true,
  in_progress = true,
}

---Agent sessions whose work is live, or whose work is waiting on the user.
---@return table[]
function M.active()
  return vim.tbl_filter(function(agent)
    return agent.requiresAttention or WORKING[agent.status] == true
  end, M.all())
end

---Is anything the daemon knows about actually WORKING?
---
---Narrower than `M.active`, which also counts a session waiting on you: this
---is the question "does anything on screen need animating", and a permission
---prompt sitting there does not move.
---@return boolean
function M.busy()
  for _, agent in ipairs(M.all()) do
    if WORKING[agent.status] == true then
      return true
    end
  end
  return false
end

---What the agents under `root` are doing, as ONE word.
---
---The question a workspace row asks: it has no room for a list of sessions and
---you are not reading it for one, you are looking down the column for the one
---that needs you.
---
---`"none"` is "you have never opened an agent here" and is deliberately not
---`"idle"` -- a workspace with a finished session in it and one you have never
---touched are different answers, and the glyphs for them differ.
---@param root string
---@return "attention"|"working"|"idle"|"none"
function M.state(root)
  local list = M.for_root(root)
  if #list == 0 then
    return "none"
  end
  local working = false
  for _, agent in ipairs(list) do
    -- Needing you OUTRANKS being busy, and is checked across the whole list
    -- before anything else is answered: a workspace with one agent waiting on
    -- a permission and three running says the permission.
    if agent.requiresAttention then
      return "attention"
    end
    working = working or WORKING[agent.status] == true
  end
  return working and "working" or "idle"
end

---Copy an agent id for Paseo's cross-agent prompting workflow.
---@param agent table
---@return boolean
function M.copy_id(agent)
  if not (agent and agent.id) then
    return false
  end
  vim.fn.setreg('"', agent.id)
  pcall(vim.fn.setreg, "+", agent.id)
  vim.notify(
    ("paseo: copied agent ID for %s\n%s"):format(agent.title or "agent", agent.id),
    vim.log.levels.INFO
  )
  return true
end

---Agents whose cwd is at or below `root`.
---
---Matched by cwd rather than by workspace id because `ws` assembles the
---directory and Paseo only ever sees a plain local workspace pointed at it --
---the daemon has no idea the directory is six worktrees.
---@param root string
---@return table[]
function M.for_root(root)
  root = vim.fn.resolve(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
  local out = {}
  for _, agent in pairs(agents) do
    if agent.cwd then
      local cwd = vim.fn.resolve(agent.cwd):gsub("/+$", "")
      if cwd == root or vim.startswith(cwd, root .. "/") then
        out[#out + 1] = agent
      end
    end
  end
  table.sort(out, function(a, b)
    return (a.title or a.id) < (b.title or b.id)
  end)
  return out
end

---A one-line summary of a root's agents, for a picker column.
---@param root string
---@return string
function M.summary(root)
  local list = M.for_root(root)
  if #list == 0 then
    return subscribed and "" or "…"
  end

  local attention, busy = 0, 0
  for _, agent in ipairs(list) do
    if agent.requiresAttention then
      attention = attention + 1
    elseif agent.status and agent.status ~= "idle" then
      busy = busy + 1
    end
  end

  if attention > 0 then
    return ("! %d needs you"):format(attention)
  end
  if busy > 0 then
    return ("· %d running"):format(busy)
  end
  return ("%d idle"):format(#list)
end

return M
