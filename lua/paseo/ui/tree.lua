--- The sessions of one workspace, as a tree: its agents, each with its
--- subagents nested under it, then its terminals.
---
--- DRAWN BY THE RAIL, under the workspace's own row, the way the app's
--- sidebar nests a workspace's agents under it. This module owns no window
--- and draws nothing: it decides which sessions belong to a workspace, how
--- they nest, what state each one is in, and what opening or archiving one
--- does. |paseo.ui.rail| decides which nodes are open and where the rows go.
---
--- A TREE because agents have children. A provider subagent (Claude's Task
--- tool) and a Paseo subagent (an agent another agent started) both hang off
--- their parent, as they do in the app's track above the composer, and a Paseo
--- subagent can have children of its own -- so an agent folds the way a
--- directory does in a file tree.

local M = {}

---How deep the tree goes. Past this the indent eats the title.
M.MAX_DEPTH = 3

-- -------------------------------------------------------------------- data

---The agents of a workspace: |paseo.agents|.for_workspace -- by workspace id,
---since every `paseo run` in a checkout makes a workspace of its own on the
---SAME directory -- in the order they were started.
---@param ws { id?: string, directory?: string, hostId?: string }
---@param host_id? string
---@return table[]
function M.workspace_agents(ws, host_id)
  local list = require("paseo.agents").for_workspace(ws, host_id)
  -- In the order they were started, so a new one lands at the bottom rather
  -- than wherever its title sorts.
  table.sort(list, function(a, b)
    if (a.createdAt or "") ~= (b.createdAt or "") then
      return (a.createdAt or "") < (b.createdAt or "")
    end
    return a.id < b.id
  end)
  return list
end

---A workspace's terminals. Following a directory's terminals is a
---subscription; asked only while the bridge is up, never to start one.
---@param ws table
---@param host_id? string
---@return table[]
function M.workspace_terminals(ws, host_id)
  local terminals = require "paseo.terminals"
  local dir = ws.directory
  if not dir or dir == "" then
    return {}
  end
  host_id = ws.hostId or host_id
  if require("paseo.bridge").running(host_id) then
    pcall(terminals.watch, dir, nil, host_id)
  end
  return terminals.for_root(dir, host_id)
end

---@class paseo.TreeNode
---@field kind "agent"|"subagent"|"terminal"
---@field item table      The agent, subagent or terminal.
---@field ws table        The workspace it is under.
---@field depth integer   0 for a workspace's own sessions.
---@field parent paseo.TreeNode|nil
---@field kids paseo.TreeNode[]  Its subagents, in order. Empty for a leaf.
---@field running integer How many of `kids` are running.

---A stable key for a node, for remembering whether it is open.
---@param node paseo.TreeNode
---@return string
function M.key(node)
  return node.kind .. ":" .. tostring(node.item.id or node.item.title or "?")
end

---The workspace's sessions as a forest: its agents, each with its subagents
---as `kids` (recursively), then its terminals.
---@param ws table
---@param chat? table  The chat on screen -- its own agent's subagents are
---                    already followed by the chat.
---@return paseo.TreeNode[]
function M.forest(ws, chat)
  local subagents = require "paseo.subagents"
  local host_id = ws.hostId or (chat and chat.host_id)
  local list = M.workspace_agents(ws, host_id)

  -- A Paseo subagent whose parent is listed hangs off the parent, not off the
  -- workspace: it is listed once, where it belongs.
  local ids = {}
  for _, agent in ipairs(list) do
    ids[agent.id] = true
  end

  local function build(kind, item, depth, parent)
    local node =
      { kind = kind, item = item, depth = depth, parent = parent, ws = ws, kids = {}, running = 0 }
    local id = item.id
    if depth >= M.MAX_DEPTH or not id then
      return node
    end
    local parent_kind = kind == "agent" or item.kind == "paseo"
    if not parent_kind then
      return node
    end
    -- Provider subagents are only known to a session that asked; `track`
    -- asks once per connection, and never starts a bridge to do it.
    if not (chat and id == chat.agent_id) then
      pcall(subagents.track, id, host_id)
    end
    for _, child in ipairs(subagents.list(id, host_id) or {}) do
      node.kids[#node.kids + 1] = build("subagent", child, depth + 1, node)
      if child.running then
        node.running = node.running + 1
      end
    end
    return node
  end

  local out = {}
  for _, agent in ipairs(list) do
    local parent = agent.labels and agent.labels[subagents.PARENT_LABEL]
    if not (parent and ids[parent]) then
      out[#out + 1] = build("agent", agent, 0, nil)
    end
  end
  for _, item in ipairs(M.workspace_terminals(ws, host_id)) do
    out[#out + 1] = { kind = "terminal", item = item, depth = 0, ws = ws, kids = {}, running = 0 }
  end
  return out
end

---Every node of a forest, depth first, whether or not it is drawn.
---@param forest paseo.TreeNode[]
---@return paseo.TreeNode[]
function M.flatten(forest)
  local out = {}
  local function walk(node)
    out[#out + 1] = node
    for _, kid in ipairs(node.kids) do
      walk(kid)
    end
  end
  for _, node in ipairs(forest) do
    walk(node)
  end
  return out
end

-- ------------------------------------------------------------------- state

---A session's status slot: the same marks a workspace leads with
---(|paseo.ui.rail|.badge), from its agent's state -- or, for a provider
---subagent, from what its parent reports of it. A terminal is `$`.
---@param node paseo.TreeNode
---@return string mark, string hl
function M.mark(node)
  local item = node.item
  if node.kind == "terminal" then
    return "$", "PaseoTreeTerminal"
  end
  local bucket
  if node.kind == "agent" or item.kind == "paseo" then
    local agent = node.kind == "agent" and item or require("paseo.agents").get(item.id)
    bucket = agent and require("paseo.agents").bucket(agent) or nil
  end
  if bucket == nil then
    if item.running then
      bucket = "running"
    elseif item.status == "failed" or item.status == "error" then
      bucket = "failed"
    else
      bucket = "done"
    end
  end
  return require("paseo.ui.rail").badge(bucket)
end

---What a session's row is called.
---@param node paseo.TreeNode
---@return string
function M.title(node)
  if node.kind == "terminal" then
    return require("paseo.terminals").label(node.item)
  end
  if node.kind == "agent" then
    return node.item.title or tostring(node.item.id):sub(1, 8)
  end
  return node.item.title or "subagent"
end

---Is anything at or under `node` running? A folded agent says so on its row.
---@param node paseo.TreeNode
---@return boolean
function M.busy(node)
  if node.running > 0 or (node.kind == "subagent" and node.item.running) then
    return true
  end
  for _, kid in ipairs(node.kids) do
    if M.busy(kid) then
      return true
    end
  end
  return false
end

---Which session the Paseo tab is showing.
---@param chat? table
---@return { kind?: string, id?: string }
function M.on_screen(chat)
  -- The middle window shows one agent: the chat's own -- a draft's too, once its
  -- first message has made it one.
  if chat then
    return { kind = "agent", id = chat.agent_id }
  end
  return {}
end

---Is `node` the session on screen?
---@param node table
---@param here { kind?: string, id?: string }
---@return boolean
function M.is_on_screen(node, here)
  if not here.id then
    return false
  end
  if node.kind == "terminal" then
    return here.kind == "terminal" and here.id == node.item.id
  end
  if node.kind == "subagent" and node.item.kind ~= "paseo" then
    return false
  end
  return here.kind == "agent" and here.id == node.item.id
end

---Is the session on screen at or under `node`?
---@param node paseo.TreeNode
---@param here { kind?: string, id?: string }
---@return boolean
function M.holds(node, here)
  if M.is_on_screen(node, here) then
    return true
  end
  for _, kid in ipairs(node.kids) do
    if M.holds(kid, here) then
      return true
    end
  end
  return false
end

-- ----------------------------------------------------------------- actions

---Open a session in the Paseo tab's middle window: an agent or a terminal as
---a buffer of the row, a subagent as a peek -- a provider one in the
---read-only viewer.
---@param node table
---@param chat table  The chat on screen.
function M.open(node, chat)
  local native = require "paseo.ui.native"
  local host_id = node.ws and node.ws.hostId or chat.host_id
  if node.kind == "terminal" then
    return native.show_session {
      kind = "terminal",
      id = node.item.id,
      hostId = node.item.hostId or host_id,
    }
  end
  if node.kind == "agent" or node.item.kind == "paseo" then
    return native.show_session { kind = "agent", id = node.item.id, hostId = host_id }
  end
  -- A provider subagent can be watched, not told: the read-only viewer.
  local parent = node.item.parent == chat.agent_id and chat
    or { agent_id = node.item.parent, host_id = host_id, root = chat.root }
  require("paseo.pickers.subagents").open_one(node.item, parent)
end

---Archive the agent, or kill the terminal -- asked first.
---@param node table
---@param chat table
function M.remove(node, chat)
  local host_id = node.ws and node.ws.hostId or chat.host_id
  if node.kind == "terminal" then
    return require("paseo.terminals").kill(node.item.id, node.item.hostId or host_id)
  end
  if node.kind == "subagent" and node.item.kind ~= "paseo" then
    return vim.notify("paseo: a provider subagent ends with its parent's turn", vim.log.levels.INFO)
  end
  local id = node.item.id
  vim.ui.select({ "no", "yes" }, { prompt = "Archive this agent?" }, function(choice)
    if choice ~= "yes" then
      return
    end
    require("paseo.bridge").request("agent.archive", { agentId = id }, function(err)
      vim.schedule(function()
        vim.notify(
          err and ("paseo: " .. err) or "paseo: archived",
          err and vim.log.levels.ERROR or vim.log.levels.INFO
        )
      end)
    end, host_id)
  end)
end

---What starting something "in" `ws` means: the chat's own context when it is
---the workspace on screen, the workspace's otherwise.
---@param ws table|nil
---@param chat table
---@param showing boolean  `ws` is the workspace on screen.
---@return paseo.StartContext
function M.context(ws, chat, showing)
  local start = require "paseo.start"
  local own = start.context(chat)
  if showing or not ws then
    return own
  end
  return {
    root = ws.directory,
    local_root = ws.local_directory,
    host_id = ws.hostId or chat.host_id,
    preferred = own.preferred,
    workspace_id = ws.id,
  }
end

return M
