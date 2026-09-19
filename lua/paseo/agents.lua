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
