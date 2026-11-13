--- The workspace rail: the project's workspaces, down the left of every
--- native tab, each with what its agents are doing.
---
--- The desktop app's sidebar, and for the same reason it has one: it answers
--- "which of them wants me" without leaving the conversation you are in -- a
--- spinner where an agent is working, a yellow `!` where one is waiting on you,
--- red where a turn failed, green where it finished.
---
--- A REAL BUFFER IN A WINDOW OF ITS OWN. The cursor IS the selection: `j`/`k`
--- move it, 'cursorline' paints it, `<CR>` opens what it is on, and none of
--- that needs a focus model on top. (It was made a buffer of its own beside
--- volt's chrome, which reset the cursor after every click and owned `<CR>` --
--- see |paseo.ui.list|'s header for what that cost the list tabs.)
---
--- The window belongs to |paseo.ui.native|, which splits one on every tab and
--- hands it over with `M.adopt`. This module owns the buffer, the data and the
--- drawing, and outlives any one tab so the list is not refetched on every
--- open.

local icons = require "paseo.ui.icons"
local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace "paseo.rail"

M.FILETYPE = "paseo-rail"

---@type integer|nil
local buf

---What was drawn, by buffer line: the workspace on it, or nil for a line that
---is not one (the heading, the gap under it, a message).
---@type table<integer, table>
local at_line = {}

---The buffer line of the workspace on screen, from the last `M.lines`.
---@type integer|nil
local current_line

---What was drawn under each EXPANDED workspace: its sessions, by buffer line
----- a |paseo.ui.tree| node, which knows its workspace.
---@type table<integer, table>
local session_at = {}

---The buffer line of the session on screen, when its workspace is expanded.
---@type integer|nil
local session_line

---Which workspaces you opened or closed, by id. Absent means the default:
---the workspace on screen open, every other one closed.
---@type table<string, boolean>
local expanded = {}

---The last fetch. `root` is the project it was scoped to, so a fetch that
---lands after you have moved project is not drawn as this one's.
local cache = { root = nil, list = nil, err = nil, loading = false }

---Called when the list changes size. The old float set it to have its
---spinner clock re-checked; nothing sets it now.
---@type fun()|nil
M.on_change = nil

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

---@param state table
local function write_state(state)
  local path = state_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if not fd then
    return
  end
  fd:write(vim.json.encode(state))
  fd:close()
end

---The rail's options: `ui.float.rail`, with `ui.buffer.rail` over it when
---asked for the old buffer mount -- the inheritance every dashboard option
---had. The native surface asks with no mount.
---@param mount? "float"|"buffer"
---@return { enabled: boolean, width: integer, keys: table<string, string|false> }
function M.options(mount)
  local ui = require("paseo.config").get().ui
  local opts = ui.float.rail or {}
  if mount == "buffer" and ui.buffer and ui.buffer.rail then
    opts = vim.tbl_deep_extend("force", opts, ui.buffer.rail)
  end
  return opts
end

---Read once per session and then held: the file is the memory across
---restarts, not the source of truth while one is running.
---@type boolean|nil
local shown

---Is the rail wanted? Your last toggle, or `enabled` if you have never
---pressed it.
---@return boolean
function M.visible()
  if shown == nil then
    local saved = read_state().rail
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
  local state = read_state()
  state.rail = value
  pcall(write_state, state)
end

---For the tests: forget what was read, so the next `visible` reads again.
function M.reset()
  shown = nil
  expanded = {}
  cache = { root = nil, list = nil, err = nil, loading = false }
end

-- ------------------------------------------------------------------- data

---The project the rail lists: where you are standing, not what the chat is
---pointed at -- see |paseo.ui.panels.workspaces| for why those differ.
---@return string
local function project_root()
  return require("paseo.workspaces").here()
end

local following = false

---Refetch when the daemon says a workspace changed -- created, archived, or
---TITLED, which happens after creation: the daemon names a workspace from its
---first prompt in the background, so the list fetched when it was made still
---says `main`. Debounced, because one creation is several updates.
function M.follow()
  if following then
    return
  end
  following = true
  local pending = false
  require("paseo.bridge").on("workspaces_changed", function()
    if pending then
      return
    end
    pending = true
    vim.defer_fn(function()
      pending = false
      if M.win() then
        cache.loading = false
        M.load()
      end
    end, 250)
  end)
end

---Fetch the project's workspaces, and draw them when they land.
---
---Asked when the rail is shown, again when you press `r` in it, and whenever
---the sidecar says a workspace changed (`M.follow`) -- the daemon streams that,
---but only the FACT is forwarded; the list is refetched here. What the agents
---are doing comes from |paseo.agents| and needs no fetch.
---@param done? fun()
function M.load(done)
  M.follow()
  -- NEVER THE ONE TO START THE BRIDGE. A rail is only ever open beside a
  -- chat that has already asked for it, so a bridge that is not up yet is one
  -- that is on its way -- and the first agent snapshot it delivers asks again
  -- (`M.directory_changed`). Starting it from here would mean a list in a
  -- column was enough to spawn a sidecar and dial a daemon.
  if not require("paseo.bridge").running() then
    return
  end
  local root = project_root()
  if cache.loading and cache.root == root then
    return
  end
  if cache.root ~= root then
    cache.list = nil
  end
  cache.root, cache.loading = root, true
  local ws = require "paseo.workspaces"
  -- And the agents, which the rail draws from as much as from the list.
  -- Nothing else on a native tab is sure to have asked, and without it the
  -- rail would have no statuses to show.
  pcall(require("paseo.agents").watch)
  ws.list(function(list, err)
    vim.schedule(function()
      if cache.root ~= root then
        return
      end
      cache.loading = false
      cache.err = err
      if list then
        cache.list = M.arrange(ws.scope(list, root))
      end
      M.draw()
      if done then
        done()
      end
      if M.on_change then
        M.on_change()
      end
    end)
  end)
end

---What the rail shows of a project's workspaces, in the order it shows them.
---
---BACKGROUND ONES HIDDEN, as the app's sidebar hides them unless "Show
---background" is on: workspaces agents and plugins make for themselves, which
---are not places you went. `ui.float.rail.show_background` shows them.
---
---PINNED ONES FIRST, in the order they came; everything else after, in its
---own. A pin set in the app leads here too -- it is the daemon's, not ours.
---@param list table[]
---@return table[]
function M.arrange(list)
  local show_background = require("paseo.config").get().ui.float.rail.show_background
  local pinned, rest = {}, {}
  for _, ws in ipairs(list) do
    if show_background or not ws.background then
      table.insert(ws.pinned and pinned or rest, ws)
    end
  end
  return vim.list_extend(pinned, rest)
end

---Pin or unpin the workspace under the cursor.
function M.toggle_pin()
  local ws = M.current()
  if not (ws and ws.id) then
    return
  end
  require("paseo.bridge").request(
    "workspace.pin",
    { workspaceId = ws.id, pinned = not ws.pinned },
    function(err)
      vim.schedule(function()
        if err then
          return vim.notify("paseo: could not pin — " .. tostring(err), vim.log.levels.ERROR)
        end
        cache.loading = false
        M.load()
      end)
    end,
    ws.hostId
  )
end

-- ---------------------------------------------------------------- drawing

---The glyph and highlight for a workspace's bucket. Public so the tests can
---hold the mapping to what the desktop app draws.
---@param bucket string  |paseo.agents|.workspace_bucket's answer.
---@return string glyph, string hl
function M.status(bucket)
  if bucket == "running" then
    return widgets.spinner(), "PaseoBlue0"
  end
  if bucket == "needs_input" then
    return icons.status.waiting, "PaseoBadge"
  end
  if bucket == "failed" then
    return icons.status.idle, "PaseoToolFail"
  end
  if bucket == "attention" then
    -- Finished while you were somewhere else: news, not a problem.
    return icons.status.idle, "PaseoBlue0"
  end
  if bucket == "done" then
    return icons.status.idle, "PaseoToolOk"
  end
  -- Never opened an agent here.
  return icons.status.pending, "PaseoDim"
end

---A workspace's state, SUBAGENTS INCLUDED.
---
---|paseo.agents|.workspace_bucket reads the agents and nothing else, and a
---parent whose turn has handed work to a subagent can be idle while the
---subagent is still going -- so the row went green, "done", over work that was
---still running. A running subagent makes a quiet workspace a running one.
---What outranks running still does: a request waiting on you, a failure.
---@param ws table
---@return string
function M.bucket(ws)
  local bucket = require("paseo.agents").workspace_bucket(ws, ws.hostId)
  if bucket == "done" or bucket == "attention" or bucket == "none" then
    local running = require("paseo.subagents").counts_under(ws, ws.hostId)
    if running > 0 then
      return "running"
    end
  end
  return bucket
end

---The subagent count a row ends with, or nil when the workspace's agents have
---none: the robot and `2`, or `1/3` while some run -- running first, because
---that is the news, in the colour a running tool card is.
---@param ws table
---@return table[]|nil
function M.subagent_badge(ws)
  local running, total = require("paseo.subagents").counts_under(ws, ws.hostId)
  if total == 0 then
    return nil
  end
  local numbers = running > 0 and ("%d/%d"):format(running, total) or tostring(total)
  return {
    { icons.tool.sub_agent .. " " .. numbers, running > 0 and "PaseoToolRunning" or "PaseoDim" },
  }
end

---@param path string
---@return string
local function canonical(path)
  return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

---@param ws table
---@param path string
---@return boolean
local function contains(ws, path)
  local dir = ws.local_directory or ws.directory or ""
  if dir == "" then
    return false
  end
  dir = canonical(dir)
  path = canonical(path)
  return path == dir or vim.startswith(path, dir .. "/")
end

---The chat whose surface the rail is drawn beside: the native tab's
---(|paseo.ui.native|).
---@return table|nil
function M.host_chat()
  local native = package.loaded["paseo.ui.native"]
  return native and native.chat() or nil
end

---The workspace the native tab is showing, as a key into the list.
---
---BY WORKSPACE ID when the agent on screen has one, and only then by
---directory. The directory alone cannot say which: every `paseo run` in a
---repository makes a workspace of its own on the SAME directory, so a rail
---that marked "the one my cwd is in" marked all of them -- two green bars, and
---no way to tell which one the conversation beside it belonged to.
---@return { id: string|nil, dir: string|nil }
function M.showing()
  local chat = M.host_chat()
  if chat then
    local agent = chat.agent_id and require("paseo.agents").get(chat.agent_id, chat.host_id)
    return {
      id = agent and agent.workspaceId or nil,
      dir = (agent and agent.cwd) or chat.local_root or chat.root,
    }
  end
  return { dir = vim.fn.getcwd() }
end

---Which row of `list` is the workspace on screen: its index, or nil.
---
---ONE ROW, whichever rule finds it: the id if anything carries it, else the
---first workspace whose directory holds the chat's, else the first holding the
---cwd.
---@param list table[]
---@return integer|nil
function M.current_index(list)
  local showing = M.showing()
  if showing.id then
    for i, ws in ipairs(list) do
      if ws.id == showing.id then
        return i
      end
    end
  end
  for _, path in ipairs { showing.dir, vim.fn.getcwd() } do
    if path and path ~= "" then
      for i, ws in ipairs(list) do
        if contains(ws, path) then
          return i
        end
      end
    end
  end
  return nil
end

---Is `ws` drawn open, its sessions under it?
---@param ws table
---@param here boolean  It is the workspace on screen.
---@return boolean
function M.is_expanded(ws, here)
  local key = ws.id or ws.directory or ws.name
  local set = key and expanded[key]
  if set == nil then
    return here
  end
  return set
end

---The lines, as |paseo.ui.render| means a line, and what is on each:
---`rows` the workspace rows, `sessions` the session rows under the open ones.
---@param width integer
---@return table[][] lines, table<integer, table> rows, table<integer, table> sessions
function M.lines(width)
  current_line, session_line = nil, nil
  local sessions = {}
  local out, rows = {}, {}
  local name = cache.root and vim.fs.basename(cache.root) or "workspaces"
  local count = cache.list and ("  " .. #cache.list) or ""
  local title = render.truncate({ { name, "PaseoHeader" } }, math.max(1, width - #count - 1))
  title[#title + 1] = { count, "PaseoDim" }
  out[1] = title
  out[2] = {}

  if not cache.list then
    out[3] = {
      { cache.err and "unavailable" or "loading…", cache.err and "PaseoToolFail" or "PaseoDim" },
    }
    return out, rows, sessions
  end
  if #cache.list == 0 then
    out[3] = { { "no workspaces", "PaseoDim" } }
    return out, rows, sessions
  end

  local chat = M.host_chat()
  local tree = require "paseo.ui.tree"

  local current = M.current_index(cache.list)
  for i, ws in ipairs(cache.list) do
    local here = i == current
    local glyph, hl = M.status(M.bucket(ws))
    local open = M.is_expanded(ws, here)
    local line = {
      -- The bar that says "you are in this one", in the same glyph the list
      -- tabs use, so the two read as one vocabulary.
      { here and icons.marker.mine or " ", "PaseoAgent" },
      -- Open or closed: `<Tab>` (or `l`/`h`) on the row says which.
      { open and "▾ " or "▸ ", "PaseoDim" },
      { glyph .. " ", hl },
    }
    local badge = M.subagent_badge(ws)
    local name_width = math.max(1, width - 5 - (badge and render.width(badge) + 1 or 0))
    -- The pin is part of the name cell, so it truncates with the name rather
    -- than pushing the badge off the row.
    local pin = ws.pinned and (icons.ui.pin .. " ") or ""
    local name = render.truncate(
      { { pin, "PaseoDim" }, { ws.name or "", here and "PaseoAgent" or "PaseoText" } },
      name_width
    )
    if badge then
      -- Right-aligned, so a column of them reads as a column.
      name = render.pad(name, name_width + 1)
      vim.list_extend(name, badge)
    end
    vim.list_extend(line, name)
    out[#out + 1] = line
    rows[#out] = ws
    if here then
      current_line = #out
    end

    -- ITS SESSIONS, UNDER IT: agents, their subagents nested under them, then
    -- its terminals. One sidebar, the way the app's is -- the workspaces and
    -- what is running in each, rather than a second column for the second
    -- question.
    if open then
      local drafting = here and chat and chat.draft ~= nil
      local tree_lines, nodes = tree.lines(ws, chat, width, drafting)
      local base = #out
      for i, tline in ipairs(tree_lines) do
        out[base + i] = tline
        local node = nodes[i]
        if node then
          sessions[base + i] = node
          if not session_line and tree.is_on_screen(node, tree.on_screen(chat)) then
            session_line = base + i
          end
        end
      end
    end
  end

  -- THE KEYS, where you are looking when you want them: this is where things
  -- start from, and a list that does not say how is a dead end.
  out[#out + 1] = {}
  out[#out + 1] = {
    { "a", "PaseoBlue1" },
    { " agent  ", "PaseoDim" },
    { "w", "PaseoBlue1" },
    { " workspace  ", "PaseoDim" },
    { "t", "PaseoBlue1" },
    { " term", "PaseoDim" },
  }
  return out, rows, sessions
end

---The agent directory moved. Repaint, and fetch the list if there is none
---yet: the first snapshot is also the first sign the bridge is up.
function M.directory_changed()
  if not M.win() then
    return
  end
  if not cache.list and not cache.loading then
    return M.load()
  end
  M.draw()
end

---Does anything on the rail turn? The native surface's spinner clock asks.
---@return boolean
function M.spinning()
  if not (M.win() and cache.list) then
    return false
  end
  for _, ws in ipairs(cache.list) do
    if M.bucket(ws) == "running" then
      return true
    end
  end
  return false
end

---@type integer|nil
local win

---`win` is a native tab's split (see `M.adopt`), not a float of ours: this
---module must neither move it nor close it.
local adopted = false

---The rail's window, if it is up.
---@return integer|nil
function M.win()
  return win and api.nvim_win_is_valid(win) and win or nil
end

---Paint the buffer from the cache. Cheap -- a dozen short lines -- so the
---spinner clock calls it ten times a second without a second thought.
function M.draw()
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local width = M.win() and api.nvim_win_get_width(win) or 32
  local lines, rows, sessions = M.lines(width)
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
  -- THE ROW YOU ARE ON, across the whole width: a bar in the gutter and a
  -- green name said it, and said it about every workspace sharing the
  -- directory. A band says it at a glance, from across the surface.
  if current_line then
    api.nvim_buf_set_extmark(
      buf,
      ns,
      current_line - 1,
      0,
      { line_hl_group = "PaseoRowCurrent", priority = 10 }
    )
  end
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
  session_at = sessions

  -- KEEP THE CURSOR ON A ROW. Rewriting the lines leaves it where it was by
  -- number, which is right while the list is the same list -- and on the
  -- heading the first time, which is not.
  if M.win() then
    local line = api.nvim_win_get_cursor(win)[1]
    if not (at_line[line] or session_at[line]) then
      M.seat()
    end
  end
end

---Put the cursor on the workspace you are in, or the first one -- or, with
---`session`, on the session on screen when its workspace is open.
---@param opts? { session?: boolean }
function M.seat(opts)
  if not M.win() then
    return
  end
  if opts and opts.session and session_line then
    return pcall(api.nvim_win_set_cursor, win, { session_line, 0 })
  end
  local first
  for line = 1, api.nvim_buf_line_count(buf) do
    if at_line[line] then
      first = line
      break
    end
  end
  local line = current_line or first
  if line then
    pcall(api.nvim_win_set_cursor, win, { line, 0 })
  end
end

---The workspace under the cursor -- nil on a session row.
---@return table|nil
function M.current()
  if not M.win() then
    return nil
  end
  return at_line[api.nvim_win_get_cursor(win)[1]]
end

---The session under the cursor, a |paseo.ui.tree| node, or nil.
---@return table|nil
function M.current_session()
  if not M.win() then
    return nil
  end
  return session_at[api.nvim_win_get_cursor(win)[1]]
end

---The workspace the cursor is in: its own row, or the row of the session
---under it.
---@return table|nil
function M.current_workspace()
  local node = M.current_session()
  return node and node.ws or M.current()
end

---Open the workspace on screen, if you had closed it: `<C-s>` lands on the
---session on screen, which has to be drawn to be landed on.
function M.reveal()
  if not cache.list then
    return
  end
  local i = M.current_index(cache.list)
  local ws = i and cache.list[i]
  if ws then
    expanded[ws.id or ws.directory or ws.name] = true
  end
end

---Open or close a workspace's sessions.
---@param want? boolean  Nil toggles.
function M.expand(want)
  local ws = M.current_workspace()
  if not ws then
    return
  end
  local key = ws.id or ws.directory or ws.name
  local here = cache.list
    and M.current_index(cache.list)
    and cache.list[M.current_index(cache.list)] == ws
  local now = M.is_expanded(ws, here or false)
  if want == nil then
    want = not now
  end
  expanded[key] = want
  M.draw()
  -- Closing from a session row leaves the cursor on the workspace it was in.
  if not want and M.win() then
    for line, row_ws in pairs(at_line) do
      if row_ws == ws then
        pcall(api.nvim_win_set_cursor, win, { line, 0 })
        break
      end
    end
  end
end

---Step to the next row -- a workspace or a session -- skipping the rest.
---@param step integer
local function move(step)
  if not M.win() then
    return
  end
  local line = api.nvim_win_get_cursor(win)[1]
  local last = api.nvim_buf_line_count(buf)
  local at = line + step
  while at >= 1 and at <= last do
    if at_line[at] or session_at[at] then
      return pcall(api.nvim_win_set_cursor, win, { at, 0 })
    end
    at = at + step
  end
end

---Open what is under the cursor. A session opens on a native tab of its own;
---a workspace opens an agent on one, from a native tab, and otherwise gets the
---full switch, tab and `tcd` and all, exactly as the picker does it.
function M.open_current()
  local node = M.current_session()
  if node then
    local chat = M.host_chat()
    if chat then
      require("paseo.ui.tree").open(node, chat)
    end
    return
  end
  local ws = M.current()
  if not ws then
    return
  end
  -- On a native tab a workspace is somewhere to OPEN AN AGENT, in a tab of
  -- its own -- not a directory to switch this tab into.
  local native = package.loaded["paseo.ui.native"]
  if native and native.chat() then
    return native.open_workspace(ws)
  end
  require("paseo.workspaces").open(ws)
end

---Start something in the workspace under the cursor.
---@param kind "here"|"workspace"|"terminal"
function M.start(kind)
  local chat = M.host_chat()
  if not chat then
    return
  end
  local ws = M.current_workspace()
  local showing = false
  if ws and cache.list then
    local i = M.current_index(cache.list)
    showing = i ~= nil and cache.list[i] == ws
  end
  require("paseo.start").new(require("paseo.ui.tree").context(ws, chat, showing), kind)
end

---Act on the session under the cursor, if there is one.
---@param fn fun(node: table, chat: table)
local function on_session(fn)
  return function()
    local node = M.current_session()
    local chat = M.host_chat()
    if node and chat then
      fn(node, chat)
    end
  end
end

-- ----------------------------------------------------------------- buffer

---The rail's buffer, made once and kept: it outlives any one tab so the
---list is there the moment the next one opens.
---@param keys { back: fun(), toggle?: string|false, focus?: string|false, sessions?: string|false, on_toggle: fun() }
---@return integer
function M.buf(keys)
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  pcall(api.nvim_buf_set_name, buf, "paseo://workspaces")

  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set(
        "n",
        lhs,
        fn,
        { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. desc }
      )
    end
  end
  map("j", function()
    move(1)
  end, "next row")
  map("k", function()
    move(-1)
  end, "previous row")
  map("<Down>", function()
    move(1)
  end, "next row")
  map("<Up>", function()
    move(-1)
  end, "previous row")
  map("<CR>", M.open_current, "open this workspace or session")
  map("o", M.open_current, "open this workspace or session")
  map("<2-LeftMouse>", M.open_current, "open this workspace or session")
  map("<Tab>", function()
    M.expand()
  end, "open or close this workspace's sessions")
  map("za", function()
    M.expand()
  end, "open or close this workspace's sessions")
  map("l", function()
    M.expand(true)
  end, "open this workspace's sessions")
  map("h", function()
    M.expand(false)
  end, "close this workspace's sessions")
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
  map(
    "y",
    on_session(function(node)
      if node.kind ~= "terminal" then
        require("paseo.agents").copy_id { id = node.item.id, title = node.item.title }
      end
    end),
    "copy the agent ID"
  )
  map(
    "R",
    on_session(function(node, chat)
      if node.kind == "terminal" then
        require("paseo.terminals").rename(node.item.id, node.item.hostId or chat.host_id)
      end
    end),
    "rename this terminal"
  )
  map(
    "d",
    on_session(function(node, chat)
      require("paseo.ui.tree").remove(node, chat)
    end),
    "archive this agent / kill this terminal"
  )
  map("r", function()
    M.load()
  end, "refetch the workspaces")
  map("P", M.toggle_pin, "pin or unpin this workspace")
  -- Back to where you were typing. `<Esc>` too: in a list, it is "I am done
  -- here".
  map("<Esc>", keys.back, "back to the conversation")
  map("q", keys.back, "back to the conversation")
  map(keys.focus, keys.back, "back to the conversation")
  map(keys.sessions, keys.back, "back to the conversation")
  map(keys.toggle, keys.on_toggle, "hide the workspace rail")
  api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = api.nvim_create_augroup("paseo.rail", { clear = true }),
    buffer = buf,
    desc = "paseo: the rail's cursor band only while it has focus",
    callback = function(args)
      if M.win() then
        vim.wo[win].cursorline = args.event == "WinEnter"
      end
    end,
  })
  M.draw()
  return buf
end

---Open the window over `rect`, or move the one that is up.
---@param config table  A window config: `relative`, `row`, `col`, `width`,
---                     `height`, `zindex`. The old float built it; the native
---                     surface adopts a split instead (`M.adopt`).
---@param keys table  See `M.buf`.
function M.show(config, keys)
  local b = M.buf(keys)
  if adopted then
    win, adopted = nil, false
  end
  if M.win() then
    pcall(api.nvim_win_set_config, win, config)
  else
    win = api.nvim_open_win(
      b,
      false,
      vim.tbl_extend("force", { style = "minimal", border = "none", focusable = true }, config)
    )
    M.style(win)
  end
  M.draw()
  M.seat()
  -- A list from before you moved project is the wrong list, and one that
  -- never landed is no list: fetch. Otherwise draw what is cached at once and
  -- refetch underneath it, so the rail is never blank while it asks.
  M.load()
end

---The rail's window options, on a window that shows its buffer.
---@param w integer
function M.style(w)
  for option, value in pairs {
    -- `EndOfBuffer` too: under a light theme like `morning` it carries a
    -- background of its own, and every row below the list came out grey.
    winhl = "Normal:PaseoNormal,NormalFloat:PaseoNormal,EndOfBuffer:PaseoNormal,CursorLine:PaseoRowHover",
    -- Off until you are IN it. The row you are standing in already has
    -- the bar and the green; a band on it as well, while the cursor is in
    -- the composer, says the rail has focus when it does not.
    cursorline = api.nvim_get_current_win() == w,
    wrap = false,
    scrolloff = 2,
    sidescrolloff = 0,
  } do
    pcall(function()
      vim.wo[w][option] = value
    end)
  end
end

---Make `w` THE rail window: the native surface's split, which this module
---did not open and must not move. One per native tab, so whichever tab is
---entered adopts its own.
---@param w integer
function M.adopt(w)
  win, adopted = w, true
  M.style(w)
  -- On the native surface's base tier, like every other pane there, rather
  -- than the `PaseoNormal` sheet `M.style` paints a float with.
  local native = package.loaded["paseo.ui.native"]
  if native and native.WINHL then
    pcall(function()
      vim.wo[w].winhl = native.WINHL .. ",CursorLine:PaseoRowHover"
    end)
  end
  -- `minimal` is a float style; a split has to be told.
  for option, value in pairs {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    spell = false,
    list = false,
    fillchars = "eob: ",
  } do
    pcall(function()
      vim.wo[w][option] = value
    end)
  end
  M.draw()
  M.seat()
end

function M.hide()
  if adopted then
    win, adopted = nil, false
    return
  end
  if M.win() then
    pcall(api.nvim_win_close, win, true)
  end
  win = nil
end

return M
