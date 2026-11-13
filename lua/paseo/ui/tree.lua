--- The sessions of one workspace, as a tree: its agents, each with its
--- subagents nested under it, then its terminals.
---
--- DRAWN BY THE RAIL, under the workspace's own row, the way the app's
--- sidebar nests a workspace's agents under it. This module owns no window:
--- it decides which sessions belong to a workspace, how each one's row reads,
--- and what opening or archiving one does. |paseo.ui.rail| decides which
--- workspaces are expanded and where the rows go.
---
--- A TREE because agents have children. A provider subagent (Claude's Task
--- tool) and a Paseo subagent (an agent another agent started) both hang off
--- their parent, as they do in the app's track above the composer, and a Paseo
--- subagent can have children of its own.

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local M = {}

---How deep the tree is drawn. Past this the indent eats the title.
M.MAX_DEPTH = 3

---The indent a workspace's sessions sit at, under its row.
M.INDENT = "    "

-- -------------------------------------------------------------------- data

---The agents of a workspace.
---
---BY WORKSPACE ID wherever the agents carry one: every `paseo run` in a
---checkout makes a workspace of its own on the SAME directory, so listing by
---directory would draw one checkout's agents under every one of them. By
---directory only when nothing in it carries an id -- an older sidecar.
---@param ws { id?: string, directory?: string, hostId?: string }
---@param host_id? string
---@return table[]
function M.workspace_agents(ws, host_id)
  local agents = require "paseo.agents"
  host_id = ws.hostId or host_id
  local dir = ws.directory or ""
  local in_dir = dir ~= "" and agents.for_root(dir, host_id) or {}
  local any_id = false
  for _, agent in ipairs(in_dir) do
    any_id = any_id or agent.workspaceId ~= nil
  end
  local list
  if ws.id and (any_id or #in_dir == 0) then
    list = {}
    for _, agent in ipairs(agents.all(host_id)) do
      if agent.workspaceId == ws.id then
        list[#list + 1] = agent
      end
    end
  else
    list = in_dir
  end
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

---The workspace's sessions as a tree: `{ kind, item, depth, last, prefix,
---children, running, ws }` nodes in drawing order, then its terminals.
---@param ws table
---@param chat? table  The chat on screen -- its own agent's subagents are
---                    already followed by the chat.
---@return table[] nodes, table[] terminals
function M.nodes(ws, chat)
  local subagents = require "paseo.subagents"
  local host_id = ws.hostId or (chat and chat.host_id)
  local list = M.workspace_agents(ws, host_id)

  -- A Paseo subagent whose parent is listed hangs off the parent, not off the
  -- workspace: it is listed once, where it belongs.
  local ids = {}
  for _, agent in ipairs(list) do
    ids[agent.id] = true
  end
  local top = {}
  for _, agent in ipairs(list) do
    local parent = agent.labels and agent.labels[subagents.PARENT_LABEL]
    if not (parent and ids[parent]) then
      top[#top + 1] = agent
    end
  end

  local out = {}
  local function walk(kind, item, depth, last, prefix)
    local node = { kind = kind, item = item, depth = depth, last = last, prefix = prefix, ws = ws }
    out[#out + 1] = node
    local id = item.id
    if depth >= M.MAX_DEPTH or not id then
      return
    end
    local parent_kind = kind == "agent" or item.kind == "paseo"
    -- Provider subagents are only known to a session that asked; `track`
    -- asks once per connection, and never starts a bridge to do it.
    if parent_kind and not (chat and id == chat.agent_id) then
      pcall(subagents.track, id, host_id)
    end
    local children = parent_kind and subagents.list(id, host_id) or {}
    node.children = #children
    local running = 0
    for _, child in ipairs(children) do
      if child.running then
        running = running + 1
      end
    end
    node.running = running
    -- Every level's prefix carries the bar of the level above it unless that
    -- level was the last of its siblings.
    local below = depth == 0 and "" or (prefix .. (last and "  " or "│ "))
    for i, child in ipairs(children) do
      walk("subagent", child, depth + 1, i == #children, below)
    end
  end
  for _, agent in ipairs(top) do
    walk("agent", agent, 0, false, "")
  end

  return out, M.workspace_terminals(ws, host_id)
end

-- ----------------------------------------------------------------- drawing

---@param agent table
---@return string glyph, string hl
local function agent_glyph(agent)
  return require("paseo.ui.rail").status(require("paseo.agents").bucket(agent))
end

---@param s paseo.Subagent
---@return string glyph, string hl
local function subagent_glyph(s)
  if s.running then
    return widgets.spinner(), "PaseoBlue0"
  end
  if s.status == "failed" or s.status == "error" then
    return icons.status.idle, "PaseoToolFail"
  end
  if s.status == "canceled" then
    return icons.status.canceled or icons.status.idle, "PaseoDim"
  end
  return icons.status.idle, "PaseoToolOk"
end

---Which session the native tab is showing.
---@param chat? table
---@return { kind?: string, id?: string }
function M.on_screen(chat)
  -- A native tab shows one agent: the chat's own.
  local session = nil
  -- An agent session with no id is the chat's own -- a draft whose first
  -- message has since made it one.
  if chat and (not session or (session.kind == "agent" and not session.id)) then
    return { kind = "agent", id = chat.agent_id }
  end
  return session or {}
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

---One session row: the bar for "on screen", the indent and tree prefix, the
---glyph, the title, and a right-hand count when there is room for one.
---@return table[]
local function row(width, mine, prefix, glyph, glyph_hl, title, title_hl, right)
  local left = {
    { mine and icons.marker.mine or " ", "PaseoAgent" },
    { M.INDENT .. prefix, "PaseoBorder" },
    { glyph .. " ", glyph_hl },
  }
  local used = render.width(left)
  local meta = right or {}
  local meta_w = render.width(meta)
  -- The title is what you read: the count goes before it does.
  if used + meta_w + 6 > width then
    meta, meta_w = {}, 0
  end
  local room = math.max(1, width - used - (meta_w > 0 and meta_w + 1 or 0))
  vim.list_extend(left, render.truncate({ { title, mine and "PaseoAgent" or title_hl or "PaseoText" } }, room))
  if meta_w > 0 then
    -- Padded in the surface's own colour: the default pad is a card's.
    return widgets.row(left, meta, width, "PaseoNormal")
  end
  return left
end

---A workspace's session rows, as |paseo.ui.render| lines, and the node on
---each (by index into the lines returned).
---@param ws table
---@param chat? table
---@param width integer
---@param draft? boolean  The chat on screen is a draft in this workspace.
---@return table[][] lines, table<integer, table> nodes
function M.lines(ws, chat, width, draft)
  local out, at = {}, {}
  local nodes, terms = M.nodes(ws, chat)
  local here = M.on_screen(chat)

  for _, node in ipairs(nodes) do
    local item = node.item
    local prefix = node.depth == 0 and "" or (node.prefix .. (node.last and "└ " or "├ "))
    local mine = M.is_on_screen(node, here)
    if node.kind == "agent" then
      local glyph, hl = agent_glyph(item)
      local right = {}
      if (node.children or 0) > 0 then
        local text = node.running > 0 and ("%d/%d"):format(node.running, node.children) or tostring(node.children)
        right[#right + 1] = { text, node.running > 0 and "PaseoToolRunning" or "PaseoDim" }
      end
      out[#out + 1] = row(width, mine, prefix, glyph, hl, item.title or item.id:sub(1, 8), nil, right)
    else
      local glyph, hl = subagent_glyph(item)
      out[#out + 1] = row(width, mine, prefix, glyph, hl, item.title or "subagent", "PaseoDim", nil)
    end
    at[#out] = node
  end

  -- A draft on this workspace: nothing is on the daemon yet, so say so where
  -- the agent will appear.
  if draft then
    out[#out + 1] = row(width, true, "", icons.status.pending, "PaseoDim", "new session", "PaseoText")
  end

  for _, item in ipairs(terms) do
    local glyph = require("paseo.terminals").glyph(item)
    local node = { kind = "terminal", item = item, depth = 0, ws = ws }
    out[#out + 1] = row(
      width,
      M.is_on_screen(node, here),
      "",
      icons.panel.Terminals,
      glyph[2] == "PaseoDim" and "PaseoYellow1" or glyph[2],
      require("paseo.terminals").label(item),
      nil,
      nil
    )
    at[#out] = node
  end

  if #out == 0 then
    out[1] = { { " " .. M.INDENT .. "no sessions yet", "PaseoDim" } }
  end
  return out, at
end

-- ----------------------------------------------------------------- actions

---Open a session on a native tab of its own; a provider subagent in the
---read-only viewer.
---@param node table
---@param chat table  The chat on screen.
function M.open(node, chat)
  local native = require "paseo.ui.native"
  local host_id = node.ws and node.ws.hostId or chat.host_id
  if node.kind == "terminal" then
    return native.show_session { kind = "terminal", id = node.item.id, hostId = node.item.hostId or host_id }
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
