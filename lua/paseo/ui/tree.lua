--- The session tree: everything running in the workspace on screen, down the
--- right of the dashboard -- each agent with its subagents under it, then the
--- terminals.
---
--- THE RAIL'S OTHER HALF. The rail on the left answers "which workspace"; this
--- answers "which session in it", without a tab of its own. That used to be
--- the Sessions tab, and moving between two agents in one workspace meant
--- leaving the conversation for a list, finding the row, and coming back -- and
--- the list was flat, so an agent's subagents were nowhere on it.
---
--- A TREE because agents have children. A provider subagent (Claude's Task
--- tool) and a Paseo subagent (an agent another agent started) both hang off
--- their parent, as they do in the app's track above the composer, and a Paseo
--- subagent can have children of its own.
---
--- A REAL BUFFER IN A WINDOW OF ITS OWN, for the reasons |paseo.ui.rail| gives:
--- the cursor is the selection, `j`/`k` move it, and `<CR>` opens what it is
--- on. The window belongs to |paseo.ui.float|; this module owns the buffer,
--- the rows and the keys.

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.tree"

M.FILETYPE = "paseo-sessions"

---How deep the tree is drawn. A subagent's subagent's subagent is real, and
---past that the indent eats the title.
M.MAX_DEPTH = 3

---@type integer|nil
local buf
---@type integer|nil
local win

---What was drawn, by buffer line: the session on it, or nil.
---@type table<integer, table>
local at_line = {}

---What the actions on this tree start from: set by the float each time it
---shows the tree, so keys pressed here act on the chat on screen.
---@type { chat: fun(): table|nil, session: fun(): table|nil, back: fun(), on_toggle: fun(), toggle?: string|false, focus?: string|false }|nil
local host

-- -------------------------------------------------------------- visibility

---@return string
local function state_path()
  return vim.fs.joinpath(vim.fn.stdpath "state", "paseo", "ui.json")
end

---@return table
local function read_state()
  local fd = io.open(state_path(), "r")
  if not fd then
    return {}
  end
  local text = fd:read "*a"
  fd:close()
  local ok, parsed = pcall(vim.json.decode, text)
  return (ok and type(parsed) == "table") and parsed or {}
end

---The tree's options: `ui.buffer.tree` over `ui.float.tree` on that mount.
---@param mount? "float"|"buffer"
---@return { enabled: boolean, width: integer, keys: table<string, string|false> }
function M.options(mount)
  local ui = require("paseo.config").get().ui
  local opts = ui.float.tree or {}
  if mount == "buffer" and ui.buffer and ui.buffer.tree then
    opts = vim.tbl_deep_extend("force", opts, ui.buffer.tree)
  end
  return opts
end

---@type boolean|nil
local shown

---Is the tree wanted? Your last toggle, or `enabled` if you never pressed it.
---@return boolean
function M.visible()
  if shown == nil then
    local saved = read_state().tree
    if type(saved) == "boolean" then
      shown = saved
    else
      shown = M.options().enabled ~= false
    end
  end
  return shown
end

---@param value boolean
function M.set_visible(value)
  shown = value
  local saved = read_state()
  saved.tree = value
  pcall(function()
    local path = state_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fd = assert(io.open(path, "w"))
    fd:write(vim.json.encode(saved))
    fd:close()
  end)
end

---For the tests.
function M.reset()
  shown = nil
end

-- -------------------------------------------------------------------- data

---The agents of the workspace the chat is in.
---
---BY WORKSPACE ID when the chat's agent carries one: several workspaces can
---share a directory (every `paseo run` in a checkout makes one), and listing
---by directory would mix their agents. By directory otherwise -- a draft has
---no agent yet, and an older sidecar sends no id.
---@param chat table
---@return table[]
function M.workspace_agents(chat)
  local agents = require "paseo.agents"
  local me = chat.agent_id and agents.get(chat.agent_id, chat.host_id)
  local list
  if me and me.workspaceId then
    list = {}
    for _, agent in ipairs(agents.all(chat.host_id)) do
      if agent.workspaceId == me.workspaceId then
        list[#list + 1] = agent
      end
    end
  else
    list = agents.for_root(chat.local_root or chat.root, chat.host_id)
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

---Ask for an agent's provider subagents, once per connection -- and never
---the one to start a bridge. |paseo.subagents|.track keeps the memo.
---@param id string
---@param host_id string|nil
local function follow(id, host_id)
  pcall(require("paseo.subagents").track, id, host_id)
end

---The workspace's sessions as a tree: `{ kind, item, depth, last, children }`
---nodes in drawing order, agents first, then terminals.
---@param chat table
---@return table[] agents, table[] terminals
function M.nodes(chat)
  local subagents = require "paseo.subagents"
  local list = M.workspace_agents(chat)

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
    local node = { kind = kind, item = item, depth = depth, last = last, prefix = prefix }
    out[#out + 1] = node
    local id = item.id
    if depth >= M.MAX_DEPTH or not id then
      return
    end
    -- Provider subagents are only known to a session that asked. Every agent
    -- drawn asks once; the rows fill in when the answer lands.
    -- The chat follows its own agent already (|paseo.ui.chat| `initialise`).
    if (kind == "agent" or item.kind == "paseo") and id ~= chat.agent_id then
      follow(id, chat.host_id)
    end
    local children = (kind == "agent" or item.kind == "paseo") and subagents.list(id, chat.host_id) or {}
    node.children = #children
    local running = 0
    for _, child in ipairs(children) do
      if child.running then
        running = running + 1
      end
    end
    node.running = running
    -- Below the root, every level's prefix carries the bar of the level above
    -- it unless that level was the last of its siblings.
    local below = depth == 0 and "" or (prefix .. (last and "  " or "│ "))
    for i, child in ipairs(children) do
      walk("subagent", child, depth + 1, i == #children, below)
    end
  end
  for _, agent in ipairs(top) do
    walk("agent", agent, 0, false, "")
  end

  local terms = require("paseo.terminals").for_root(chat.root, chat.host_id)
  return out, terms
end

-- ----------------------------------------------------------------- drawing

---The glyph for an agent: the rail's, from the same bucket rule.
---@param agent table
---@return string glyph, string hl
local function agent_glyph(agent)
  return require("paseo.ui.rail").status(require("paseo.agents").bucket(agent))
end

---The glyph for a subagent row.
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

---The provider, short: `claude` out of `claude/opus-4`.
---@param provider string|nil
---@return string|nil
local function short(provider)
  if type(provider) ~= "string" or provider == "" then
    return nil
  end
  return (provider:match "^([^/]+)" or provider)
end

---Which session the surface is showing.
---@param chat table
---@return { kind: string, id: string|nil }
local function on_screen(chat)
  local session = host and host.session and host.session()
  -- An agent session with no id is the chat's own -- a draft whose first
  -- message has since made it one.
  if not session or (session.kind == "agent" and not session.id) then
    return { kind = "agent", id = chat.agent_id }
  end
  return session
end

---One row: the bar for "on screen", the tree prefix, the glyph, the title,
---and what is left over for the right-hand column.
---@param width integer
---@param mine boolean
---@param prefix string
---@param glyph string
---@param glyph_hl string
---@param title string
---@param title_hl string|nil
---@param right table[]|nil
---@return table[]
local function row(width, mine, prefix, glyph, glyph_hl, title, title_hl, right)
  local left = {
    { mine and icons.marker.mine or " ", "PaseoAgent" },
    { prefix, "PaseoBorder" },
    { glyph .. " ", glyph_hl },
  }
  local used = render.width(left)
  local meta = right or {}
  local meta_w = render.width(meta)
  -- The title is what you read: the metadata goes before it does.
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

---The lines, as |paseo.ui.render| means a line, and what is on each.
---@param chat table|nil
---@param width integer
---@return table[][] lines, table<integer, table> rows
function M.lines(chat, width)
  local out, rows = {}, {}
  if not chat then
    return { { { "sessions", "PaseoHeader" } } }, rows
  end
  local nodes, terms = M.nodes(chat)
  local here = on_screen(chat)

  local count = #nodes + #terms
  local title = render.truncate({ { "sessions", "PaseoHeader" } }, math.max(1, width - 4))
  title[#title + 1] = { count > 0 and ("  " .. count) or "", "PaseoDim" }
  out[1] = title
  out[2] = {}

  if #nodes == 0 then
    if chat.draft then
      out[#out + 1] = row(width, true, "", icons.status.pending, "PaseoDim", "new session", "PaseoText")
      out[#out + 1] = { { "  starts on your first message", "PaseoDim" } }
    else
      out[#out + 1] = { { "no agents here yet", "PaseoDim" } }
    end
  end

  for _, node in ipairs(nodes) do
    local item = node.item
    local prefix = node.depth == 0 and "" or (node.prefix .. (node.last and "└ " or "├ "))
    if node.kind == "agent" then
      local glyph, hl = agent_glyph(item)
      local mine = here.kind == "agent" and here.id == item.id
      local right = {}
      if (node.children or 0) > 0 then
        local text = node.running > 0 and ("%d/%d"):format(node.running, node.children) or tostring(node.children)
        right[#right + 1] = { text .. " ", node.running > 0 and "PaseoBlue0" or "PaseoDim" }
      end
      local provider = short(item.provider)
      if provider then
        right[#right + 1] = { provider, "PaseoDim" }
      end
      out[#out + 1] = row(width, mine, prefix, glyph, hl, item.title or item.id:sub(1, 8), nil, right)
    else
      local glyph, hl = subagent_glyph(item)
      local mine = item.kind == "paseo" and here.kind == "agent" and here.id == item.id
      out[#out + 1] = row(width, mine, prefix, glyph, hl, item.title or "subagent", "PaseoDim", nil)
    end
    rows[#out] = node
  end

  if #terms > 0 then
    out[#out + 1] = {}
    out[#out + 1] = { { icons.panel.Terminals .. " terminals", "PaseoYellow1" } }
    for _, item in ipairs(terms) do
      local glyph = require("paseo.terminals").glyph(item)
      local mine = here.kind == "terminal" and here.id == item.id
      out[#out + 1] = row(width, mine, "", glyph[1], glyph[2], require("paseo.terminals").label(item), nil, nil)
      rows[#out] = { kind = "terminal", item = item, depth = 0 }
    end
  end

  -- THE KEYS, where you are looking when you want them: this is the place
  -- you start things from, and a list that does not say how is a dead end.
  out[#out + 1] = {}
  out[#out + 1] = {
    { "a", "PaseoBlue1" },
    { " agent  ", "PaseoDim" },
    { "w", "PaseoBlue1" },
    { " workspace  ", "PaseoDim" },
    { "t", "PaseoBlue1" },
    { " term", "PaseoDim" },
  }
  return out, rows
end

---Is anything on the tree turning? The float's spinner clock asks.
---@return boolean
function M.spinning()
  if not (M.win() and host and host.chat) then
    return false
  end
  local chat = host.chat()
  if not chat then
    return false
  end
  local agents = require "paseo.agents"
  for _, node in ipairs((M.nodes(chat))) do
    if node.kind == "agent" and agents.bucket(node.item) == "running" then
      return true
    end
    if node.kind == "subagent" and node.item.running then
      return true
    end
  end
  return false
end

---@return integer|nil
function M.win()
  return win and api.nvim_win_is_valid(win) and win or nil
end

---Paint the buffer. Cheap: the spinner clock calls it ten times a second.
function M.draw()
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local width = M.win() and api.nvim_win_get_width(win) or 32
  local chat = host and host.chat and host.chat() or nil
  local lines, rows = M.lines(chat, width)
  local text = {}
  for i, line in ipairs(lines) do
    local parts = {}
    for _, cell in ipairs(line) do
      parts[#parts + 1] = cell[1]
    end
    text[i] = table.concat(parts)
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local col = 0
    for _, cell in ipairs(line) do
      local len = #cell[1]
      if cell[2] and len > 0 then
        api.nvim_buf_set_extmark(buf, ns, i - 1, col, { end_col = col + len, hl_group = cell[2] })
      end
      col = col + len
    end
  end
  at_line = rows

  if M.win() then
    local line = api.nvim_win_get_cursor(win)[1]
    if not at_line[line] then
      M.seat()
    end
  end
end

---Cursor on the session on screen, or the first one.
function M.seat()
  if not M.win() then
    return
  end
  local chat = host and host.chat and host.chat()
  local here = chat and on_screen(chat) or {}
  local first, mine
  for line = 1, api.nvim_buf_line_count(buf) do
    local node = at_line[line]
    if node then
      first = first or line
      local kind = node.kind == "subagent" and "agent" or node.kind
      if not mine and kind == here.kind and node.item.id == here.id then
        mine = line
      end
    end
  end
  local line = mine or first
  if line then
    pcall(api.nvim_win_set_cursor, win, { line, 0 })
  end
end

---The node under the cursor.
---@return table|nil
function M.current()
  if not M.win() then
    return nil
  end
  return at_line[api.nvim_win_get_cursor(win)[1]]
end

---@param step integer
local function move(step)
  if not M.win() then
    return
  end
  local line = api.nvim_win_get_cursor(win)[1]
  local last = api.nvim_buf_line_count(buf)
  local at = line + step
  while at >= 1 and at <= last do
    if at_line[at] then
      return pcall(api.nvim_win_set_cursor, win, { at, 0 })
    end
    at = at + step
  end
end

-- ----------------------------------------------------------------- actions

---Open the session under the cursor on the dashboard.
function M.open_current()
  local node = M.current()
  local chat = host and host.chat and host.chat()
  if not (node and chat) then
    return
  end
  local float = require "paseo.ui.float"
  if node.kind == "terminal" then
    return float.show_session { kind = "terminal", id = node.item.id, hostId = node.item.hostId or chat.host_id }
  end
  if node.kind == "agent" or node.item.kind == "paseo" then
    return float.show_session { kind = "agent", id = node.item.id, hostId = chat.host_id }
  end
  -- A provider subagent can be watched, not told: the read-only viewer.
  local parent = node.item.parent == chat.agent_id and chat
    or { agent_id = node.item.parent, host_id = chat.host_id, root = chat.root }
  require("paseo.pickers.subagents").open_one(node.item, parent)
end

---Start something in this workspace: `here`, `workspace` or `terminal`.
---@param kind "here"|"workspace"|"terminal"
function M.start(kind)
  local chat = host and host.chat and host.chat()
  if not chat then
    return
  end
  local start = require "paseo.start"
  start.new(start.context(chat), kind)
end

---Archive the agent, or kill the terminal, under the cursor -- asked first.
function M.remove_current()
  local node = M.current()
  local chat = host and host.chat and host.chat()
  if not (node and chat) then
    return
  end
  if node.kind == "terminal" then
    return require("paseo.terminals").kill(node.item.id, node.item.hostId or chat.host_id)
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
    end, chat.host_id)
  end)
end

-- ------------------------------------------------------------------ buffer

---The tree's buffer, made once and kept.
---@return integer
function M.buf()
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  pcall(api.nvim_buf_set_name, buf, "paseo://sessions")

  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. desc })
    end
  end
  local function back()
    if host then
      host.back()
    end
  end
  map("j", function()
    move(1)
  end, "next session")
  map("k", function()
    move(-1)
  end, "previous session")
  map("<Down>", function()
    move(1)
  end, "next session")
  map("<Up>", function()
    move(-1)
  end, "previous session")
  map("<CR>", M.open_current, "open this session")
  map("o", M.open_current, "open this session")
  map("<2-LeftMouse>", M.open_current, "open this session")
  map("a", function()
    M.start "here"
  end, "new agent in this workspace")
  map("w", function()
    M.start "workspace"
  end, "new agent in a new workspace")
  map("t", function()
    M.start "terminal"
  end, "new terminal in this workspace")
  map("c", function()
    M.start "terminal"
  end, "new terminal in this workspace")
  map("y", function()
    local node = M.current()
    if node and node.kind ~= "terminal" then
      require("paseo.agents").copy_id { id = node.item.id, title = node.item.title }
    end
  end, "copy the agent ID")
  map("R", function()
    local node = M.current()
    if node and node.kind == "terminal" then
      require("paseo.terminals").rename(node.item.id, node.item.hostId)
    end
  end, "rename this terminal")
  map("d", M.remove_current, "archive this agent / kill this terminal")
  map("r", M.draw, "redraw")
  map("<Esc>", back, "back to the conversation")
  map("q", back, "back to the conversation")
  api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = api.nvim_create_augroup("paseo.tree", { clear = true }),
    buffer = buf,
    desc = "paseo: the tree's cursor band only while it has focus",
    callback = function(args)
      if M.win() then
        vim.wo[win].cursorline = args.event == "WinEnter"
      end
    end,
  })
  return buf
end

---Open the window, or move the one that is up.
---@param config table  A window config, built by |paseo.ui.float|.
---@param opts { chat: fun(): table|nil, session: fun(): table|nil, back: fun(), on_toggle: fun(), toggle?: string|false, focus?: string|false }
function M.show(config, opts)
  local b = M.buf()
  -- The toggle and focus keys follow the mount, so they are (re)bound here.
  if host then
    for _, lhs in ipairs { host.toggle, host.focus } do
      if lhs then
        pcall(vim.keymap.del, "n", lhs, { buffer = b })
      end
    end
  end
  host = opts
  if opts.focus then
    vim.keymap.set("n", opts.focus, opts.back, { buffer = b, nowait = true, silent = true, desc = "paseo: back to the conversation" })
  end
  if opts.toggle then
    vim.keymap.set("n", opts.toggle, opts.on_toggle, { buffer = b, nowait = true, silent = true, desc = "paseo: hide the session tree" })
  end

  if M.win() then
    pcall(api.nvim_win_set_config, win, config)
  else
    win = api.nvim_open_win(
      b,
      false,
      vim.tbl_extend("force", { style = "minimal", border = "none", focusable = true }, config)
    )
    for option, value in pairs {
      winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal,EndOfBuffer:PaseoNormal,CursorLine:PaseoRowHover",
      cursorline = false,
      wrap = false,
      scrolloff = 2,
      sidescrolloff = 0,
    } do
      pcall(function()
        vim.wo[win][option] = value
      end)
    end
  end
  -- What it draws from: the directories are push-fed, and without a
  -- subscription an empty one reads as "nothing here".
  local chat = opts.chat()
  if chat then
    pcall(require("paseo.agents").watch, nil, chat.host_id)
    pcall(require("paseo.terminals").watch, chat.root, function()
      vim.schedule(M.draw)
    end, chat.host_id)
  end
  M.draw()
  M.seat()
end

function M.hide()
  if M.win() then
    pcall(api.nvim_win_close, win, true)
  end
  win = nil
end

return M
