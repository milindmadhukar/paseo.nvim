--- The live agent directory.
---
--- Kept as a table the picker can read synchronously, fed by PUSH from the
--- sidecar. That is the whole reason the sidecar exists: at 2.4 seconds per CLI
--- call a polled status column is unobtainable, and the column is what makes
--- the workspace picker a dashboard rather than a list of directories.

local bridge = require "paseo.bridge"
local hosts = require "paseo.hosts"
local paths = require "paseo.paths"

local M = {}

---@type table<string, table<string, table>>  host id -> agent id -> agent
local agents = {}
local subscribed = {}
local listening = false
local listeners = {}
---Called with the agents that LEFT the directory; see `M.on_gone`.
local gone_listeners = {}

---Bumped on every change to the directory. Everything derived from it --
---the sorted list, the agents under a root, a workspace's agents -- is kept
---until the next bump, because the rail asks the same questions of the same
---directory once per row per frame: fifty workspaces made a frame of 150
---ms, ten frames a second, out of answers that had not changed.
local generation = 0
---@type table<string, table[]>
local memo = {}

local function bump()
  generation = generation + 1
  memo = {}
end

---Which version of the directory this is. Anything that keeps an answer
---derived from it compares this to know whether the answer is still good.
---@return integer
function M.generation()
  return generation
end

---A copy of a kept list. Callers sort what they are handed (the tree sorts a
---workspace's agents by start time), and the kept one must not move.
local function copy(list)
  local out = {}
  for i = 1, #list do
    out[i] = list[i]
  end
  return out
end

---Render from the SNAPSHOT first, then apply updates. The snapshot always
---arrives before any update, so starting from an empty table and waiting for
---upserts would show nothing until something changed.
local function apply(payload)
  local host_id = payload.hostId or hosts.selected()
  agents[host_id] = agents[host_id] or {}
  local directory = agents[host_id]
  local gone = {}
  if payload.kind == "snapshot" then
    local before = directory
    directory = {}
    agents[host_id] = directory
    for _, agent in ipairs(payload.entries or {}) do
      agent.hostId = host_id
      directory[agent.id] = agent
    end
    -- Missing from a fresh snapshot is gone too: archived while the
    -- connection was down (a laptop asleep, a daemon restarted).
    for id in pairs(before) do
      if not directory[id] then
        gone[#gone + 1] = before[id]
      end
    end
  elseif payload.kind == "upsert" and payload.agent then
    payload.agent.hostId = host_id
    directory[payload.agent.id] = payload.agent
  elseif payload.kind == "remove" and payload.id then
    -- The directory is the daemon's NON-archived agents, so leaving it means
    -- archived (or deleted). The daemon says so more than once; once is news.
    if directory[payload.id] then
      gone[#gone + 1] = directory[payload.id]
    end
    directory[payload.id] = nil
  elseif payload.kind == "error" then
    local host = hosts.get(host_id)
    vim.notify(
      ("paseo: agent directory on %s: %s"):format(host and host.label or host_id, payload.error),
      vim.log.levels.WARN
    )
    subscribed[host_id] = nil
    return
  end

  bump()
  for _, fn in ipairs(listeners) do
    pcall(fn, directory, host_id)
  end
  if #gone > 0 then
    for _, fn in ipairs(gone_listeners) do
      pcall(fn, gone, host_id)
    end
  end
end

-- Exposed for deterministic tests; production updates arrive from `watch`.
M._apply = apply

---Start following the directory. Safe to call repeatedly.
---@param callback? fun(err: string|nil)
---@param host_id? string
function M.watch(callback, host_id)
  callback = callback or function() end
  local host = hosts.get(host_id)
  if not host then
    return callback("unknown Paseo host " .. tostring(host_id))
  end
  host_id = host.id
  if subscribed[host_id] then
    return callback(nil)
  end

  bridge.ensure(function(err)
    if err then
      return callback(err)
    end
    if not listening then
      listening = true
      bridge.on("agents", apply)
    end
    bridge.request("agents.subscribe", { hostId = host_id }, function(sub_err)
      subscribed[host_id] = not sub_err
      callback(sub_err)
    end, host_id)
  end, host_id)
end

---Watch every configured host. Failures are reported per host and do not stop peers.
function M.watch_all(callback)
  callback = callback or function() end
  local left = hosts.count()
  if left == 0 then
    return callback(nil)
  end
  for _, host in ipairs(hosts.all()) do
    M.watch(function()
      left = left - 1
      if left == 0 then
        callback(nil)
      end
    end, host.id)
  end
end

---Call `fn(agents, host_id)` when agents LEAVE the directory: archived or
---deleted, whether by you, the app, the CLI, or another agent -- and seen as
---a removal, or as missing from a fresh snapshot after a reconnect. Handed
---the agents as they last were, so a caller can still say which one went.
---@param fn fun(agents: table[], host_id: string)
function M.on_gone(fn)
  gone_listeners[#gone_listeners + 1] = fn
end

---Call `fn` whenever the directory changes.
---@param fn fun(agents: table<string, table>)
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

---One agent from the directory, by id.
---@param id string
---@param host_id? string
---@return table|nil
function M.get(id, host_id)
  host_id = (hosts.get(host_id) or {}).id
  return host_id and agents[host_id] and agents[host_id][id] or nil
end

---@param host_id string|nil  Already resolved, or "*".
---@return table[]
local function collect(host_id)
  local source
  if host_id == "*" then
    source = {}
    for _, directory in pairs(agents) do
      for key, agent in pairs(directory) do
        source[(agent.hostId or "?") .. ":" .. key] = agent
      end
    end
  else
    source = (host_id and agents[host_id]) or {}
  end
  local out = {}
  for _, agent in pairs(source) do
    out[#out + 1] = agent
  end
  table.sort(out, function(a, b)
    return (a.title or a.id) < (b.title or b.id)
  end)
  return out
end

---Every non-archived agent session in the subscribed directory.
---@return table[]
function M.all(host_id)
  if host_id ~= "*" then
    host_id = (hosts.get(host_id) or {}).id
  end
  local k = "all\0" .. tostring(host_id)
  local kept = memo[k]
  if not kept then
    kept = collect(host_id)
    memo[k] = kept
  end
  return copy(kept)
end

---@return boolean
function M.ready(host_id)
  if host_id == "*" then
    for _, host in ipairs(hosts.all()) do
      if not subscribed[host.id] then
        return false
      end
    end
    return true
  end
  host_id = (hosts.get(host_id) or {}).id
  return host_id and subscribed[host_id] == true or false
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

---Is a status one of the working ones?
---@param status string|nil
---@return boolean
function M.working(status)
  return WORKING[status] == true
end

---Agent sessions whose work is live, or whose work is waiting on the user.
---@return table[]
function M.active(host_id)
  return vim.tbl_filter(function(agent)
    return agent.requiresAttention or WORKING[agent.status] == true
  end, M.all(host_id))
end

---Is anything the daemon knows about actually WORKING?
---
---Narrower than `M.active`, which also counts a session waiting on you: this
---is the question "does anything on screen need animating", and a permission
---prompt sitting there does not move.
---@return boolean
function M.busy(host_id)
  for _, agent in ipairs(M.all(host_id)) do
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
function M.state(root, host_id)
  local list = M.for_root(root, host_id)
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

---The desktop app's answer to "what is this agent doing", as one of five
---buckets -- the rule its workspace sidebar is drawn from, ported from
---`@getpaseo/protocol`'s `deriveAgentStateBucket` so the two agree on what a
---workspace is doing.
---
---Wider than `M.state` in the two places that matter for a sidebar: a turn
---that FAILED is its own answer rather than "idle", and one that finished
---while you were elsewhere is `attention` rather than `done`. Both depend on
---fields an older sidecar does not send, and without them this degrades to
---exactly `M.state`'s three answers rather than to anything wrong.
---@param agent table
---@return "needs_input"|"failed"|"running"|"attention"|"done"
function M.bucket(agent)
  if (agent.pendingPermissionCount or 0) > 0 or agent.requiresAttention or agent.attentionReason == "permission" then
    return "needs_input"
  end
  if agent.status == "error" or agent.attentionReason == "error" then
    return "failed"
  end
  -- `WORKING` rather than the app's bare `running`: `initializing` and
  -- `queued` are busy too, and a dot that sits still while an agent boots
  -- says it has finished.
  if WORKING[agent.status] then
    return "running"
  end
  if agent.daemonAttention then
    return "attention"
  end
  return "done"
end

---Most urgent first. A workspace answers with its most urgent agent: one
---waiting on a permission among three running says the permission.
local BUCKET_RANK = { needs_input = 1, failed = 2, running = 3, attention = 4, done = 5 }

---The agents a workspace (or a bare root) holds: |paseo.agents|.for_workspace
---for a workspace, |paseo.agents|.for_root for a directory.
---@param where string|table
---@param host_id? string
---@return table[]
local function held(where, host_id)
  if type(where) == "table" then
    return M.for_workspace(where, host_id)
  end
  return M.for_root(where, host_id)
end
M.held = held

---One bucket for every agent in a workspace, or `"none"` with no agents at
---all. Pass the WORKSPACE, not its directory, wherever there is one: see
---`M.for_workspace` for why the directory alone answers for the wrong rows.
---@param where string|table  A workspace, or a root directory.
---@return "needs_input"|"failed"|"running"|"attention"|"done"|"none"
function M.workspace_bucket(where, host_id)
  local best
  for _, agent in ipairs(held(where, host_id)) do
    local bucket = M.bucket(agent)
    if not best or BUCKET_RANK[bucket] < BUCKET_RANK[best] then
      best = bucket
    end
  end
  return best or "none"
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
function M.for_root(root, host_id)
  host_id = (hosts.get(host_id) or {}).id
  local k = "root\0" .. tostring(host_id) .. "\0" .. root
  local kept = memo[k]
  if not kept then
    local local_host = host_id and hosts.get(host_id).local_host
    root = local_host and paths.canonical(root) or (root:gsub("/+$", ""))
    kept = {}
    for _, agent in pairs((host_id and agents[host_id]) or {}) do
      if agent.cwd then
        local cwd = local_host and (paths.resolve(agent.cwd):gsub("/+$", ""))
          or (agent.cwd:gsub("/+$", ""))
        if cwd == root or vim.startswith(cwd, root .. "/") then
          kept[#kept + 1] = agent
        end
      end
    end
    table.sort(kept, function(a, b)
      return (a.title or a.id) < (b.title or b.id)
    end)
    memo[k] = kept
  end
  return copy(kept)
end

---Agents by workspace id, in `M.all`'s order: built once per generation, so
---a workspace's agents are a lookup rather than a pass over everyone.
---@param host_id string|nil
---@return table<string, table[]>
local function by_workspace(host_id)
  local k = "byws\0" .. tostring(host_id)
  local kept = memo[k]
  if not kept then
    kept = {}
    for _, agent in ipairs(M.all(host_id)) do
      if agent.workspaceId then
        kept[agent.workspaceId] = kept[agent.workspaceId] or {}
        table.insert(kept[agent.workspaceId], agent)
      end
    end
    memo[k] = kept
  end
  return kept
end

---The agents of one workspace.
---
---BY WORKSPACE ID for every agent that carries one. Every `paseo run` -- and
---every agent the app starts -- in a checkout makes a workspace of its own on
---the SAME directory: fifteen of them on one repository is ordinary. Matched by
---directory, each of those rows answered for all fifteen workspaces' agents,
---so three running agents set every row in the project spinning.
---
---By directory only for what has no id to match on: an agent from an older
---sidecar, or a workspace with no id (a `ws` checkout the daemon has not
---registered).
---
---`ws.directory` and never `ws.local_directory`: agents' cwds are the
---daemon's paths, and a remote host's workspace is mapped to a local one only
---for the editor's sake.
---@param ws { id?: string, directory?: string, hostId?: string }
---@param host_id? string
---@return table[]
function M.for_workspace(ws, host_id)
  host_id = ws.hostId or host_id
  local dir = ws.directory or ""
  local in_dir = dir ~= "" and M.for_root(dir, host_id) or {}
  if not ws.id then
    return in_dir
  end
  local out = {}
  local seen = {}
  host_id = (hosts.get(host_id) or {}).id
  for _, agent in ipairs(by_workspace(host_id)[ws.id] or {}) do
    out[#out + 1] = agent
    seen[agent] = true
  end
  for _, agent in ipairs(in_dir) do
    if agent.workspaceId == nil and not seen[agent] then
      out[#out + 1] = agent
    end
  end
  return out
end

---A one-line summary of a workspace's (or a root's) agents, for a picker
---column.
---@param where string|table  A workspace, or a root directory.
---@return string
function M.summary(where, host_id)
  local host = hosts.get(type(where) == "table" and where.hostId or host_id)
  local list = held(where, host and host.id)
  if #list == 0 then
    return host and subscribed[host.id] and "" or "…"
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
