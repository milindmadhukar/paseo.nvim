--- The workspace rail: the project's workspaces, down the left of every
--- native tab, each with what its agents are doing -- AS A FILE TREE.
---
--- The desktop app's sidebar, and for the same reason it has one: it answers
--- "which of them wants me" without leaving the conversation you are in -- a
--- spinner where an agent is working, a yellow `!` where one is waiting on you,
--- red where a turn failed, green where it finished -- and, beside each
--- workspace, what the app's row says too: the lines it has changed (`+120 -7`)
--- and, on a line of its own, its pull request and whether CI passed.
---
--- SHAPED AND DRIVEN LIKE nvim-tree. A workspace is a folder; its agents and
--- terminals are what is in it, and an agent with subagents is a folder too.
--- `l`/`h` open and close, `<CR>` opens a session, `P` `<` `>` `J` `K` `W` `E`
--- move and fold the way nvim-tree's do, `g?` lists them. Every REAL line is
--- a row you can stand on -- the pull request line, the hints, "no sessions
--- yet" are virtual lines -- so `j`/`k`, counts, `gg`/`G` and `/` are Vim's
--- own, with nothing remapped to skip over decoration. The cursor sits on the
--- name, as nvim-tree's `hijack_cursor` puts it.
---
--- A REAL BUFFER IN A WINDOW OF ITS OWN (filetype `paseo-rail`), so the
--- cursor IS the selection and 'cursorline' paints it.
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

local ns_right = api.nvim_create_namespace "paseo.rail.right"

---What was drawn, by buffer line: a |paseo.RailRow|, or nil for a line that
---is not one (the heading, a message).
---@type table<integer, paseo.RailRow>
local rows = {}

---The buffer line of the workspace on screen, from the last build.
---@type integer|nil
local current_line

---The buffer line of the session on screen, when its workspace is open.
---@type integer|nil
local session_line

---Which nodes you opened or closed, by key: a workspace's id (or directory),
---or `ws/kind:id` for a session with subagents. Absent means the default --
---see `M.is_expanded` and `node_open`.
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

---What a pushed workspace may change on a row without moving it. A change to
---anything else -- its name (the list is sorted by it), its pin, whether it
---is a background one, archiving it -- is a refetch.
local PATCHABLE = {
  "status",
  "statusEnteredAt",
  "branch",
  "diffStat",
  "dirty",
  "ahead",
  "behind",
  "pr",
  "forge",
  "title",
  "kind",
  "ownedWorktree",
}

---Write a pushed workspace over its row in place. False when it is not a row
---here, or changed in a way that moves it.
---@param pushed table|nil  The sidecar's `describeWorkspace`.
---@param host_id? string
---@return boolean
function M.patch(pushed, host_id)
  if not (cache.list and pushed and pushed.id) then
    return false
  end
  for _, ws in ipairs(cache.list) do
    if ws.id == pushed.id and (not host_id or not ws.hostId or ws.hostId == host_id) then
      if
        pushed.archivingAt
        or (pushed.name or "") ~= (ws.name or "")
        or (pushed.pinned == true) ~= (ws.pinned == true)
        or (pushed.background == true) ~= (ws.background == true)
      then
        return false
      end
      for _, field in ipairs(PATCHABLE) do
        ws[field] = pushed[field]
      end
      return true
    end
  end
  return false
end

---Keep the list current from the daemon's workspace stream.
---
---An UPSERT carries the workspace whole -- the sidecar describes it as the
---list does -- and is written over its row: the diff stat changes every time
---an agent saves a file and CI every twenty seconds while it runs, and a
---refetch of the whole project for each would be most of the traffic. Anything
---that moves a row, a workspace that is new here, or a removal is a refetch,
---debounced, because one creation is several updates. (That is also how a
---workspace's TITLE lands: the daemon names it from the first prompt, after
---the list fetched at creation said `main`.)
function M.follow()
  if following then
    return
  end
  following = true
  local pending = false
  require("paseo.bridge").on("workspaces_changed", function(message)
    vim.schedule(function()
      if not M.win() then
        return
      end
      if message and message.kind == "upsert" and M.patch(message.workspace, message.hostId) then
        return M.draw()
      end
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

---The key a workspace's open/closed state is remembered under.
---@param ws table
---@return string
local function ws_key(ws)
  return tostring(ws.id or ws.directory or ws.name)
end

---Is `ws` drawn open, its sessions under it?
---@param ws table
---@param here boolean  It is the workspace on screen.
---@return boolean
function M.is_expanded(ws, here)
  local set = expanded[ws_key(ws)]
  if set == nil then
    return here
  end
  return set
end

---The key a session's open/closed state is remembered under.
---@param node paseo.TreeNode
---@return string
local function node_key(node)
  return ws_key(node.ws) .. "/" .. require("paseo.ui.tree").key(node)
end

---Is a session with subagents drawn open? Your last fold, or -- until you
---have folded it -- open while something under it is running or it holds the
---session on screen: the subagents worth seeing are the live ones, and a
---finished agent's twelve Task calls are not.
---@param node paseo.TreeNode
---@param here { kind?: string, id?: string }
---@return boolean
local function node_open(node, here)
  local set = expanded[node_key(node)]
  if set ~= nil then
    return set
  end
  local tree = require "paseo.ui.tree"
  return tree.busy(node) or (not tree.is_on_screen(node, here) and tree.holds(node, here))
end

---`+120 -7`: what the app's sidebar puts at the end of a workspace's row.
---Nothing for a workspace that has changed nothing -- a column of `+0 -0` is
---a column that says nothing on every row.
---@param ws table
---@return table[]
function M.diff_stat(ws)
  local stat = ws.diffStat
  if type(stat) ~= "table" then
    return {}
  end
  local add, del = tonumber(stat.additions) or 0, tonumber(stat.deletions) or 0
  if add == 0 and del == 0 then
    return {}
  end
  return { { "+" .. add, "PaseoTreeAdded" }, { " " }, { "-" .. del, "PaseoTreeRemoved" } }
end

---The line under a workspace: its pull request, and its CI. The app's
---sidebar meta row, minus what it has off by default (the branch, the
---project). Nil when there is no pull request -- which is most workspaces,
---and a line for each saying so would double the rail's height.
---@param ws table
---@return table[]|nil
function M.meta(ws)
  local pr = ws.pr
  if type(pr) ~= "table" or not pr.number then
    return nil
  end
  local glyph, hl, word = icons.ui.pull_request, "PaseoTreePrOpen", nil
  if pr.state == "merged" then
    glyph, hl, word = icons.ui.merged, "PaseoTreePrMerged", "merged"
  elseif pr.state == "closed" then
    glyph, hl, word = icons.tree.pr_closed, "PaseoTreePrClosed", "closed"
  elseif pr.draft then
    glyph, hl, word = icons.tree.pr_draft, "PaseoTreePrDraft", "draft"
  end
  local out = { { glyph .. " #" .. pr.number, hl } }
  if word then
    out[#out + 1] = { " " .. word, hl }
  end
  -- CI only while it can still matter: a merged or closed PR's checks are
  -- history.
  if pr.state == "open" and pr.checks then
    local check = ({
      passed = { icons.tree.passed, "PaseoTreeChecksPassed", "passed" },
      failed = { icons.tree.failed, "PaseoTreeChecksFailed", "failed" },
      running = { icons.tree.running, "PaseoTreeChecksRunning", "running" },
    })[pr.checks]
    if check then
      local text = check[3]
      if pr.checks == "running" and (pr.checksTotal or 0) > 0 then
        text = ("%d/%d"):format(pr.checksDone or 0, pr.checksTotal)
      end
      out[#out + 1] = { " " .. icons.marker.bullet .. " ", "PaseoTreeMeta" }
      out[#out + 1] = { check[1] .. " " .. text, check[2] }
    end
  end
  if pr.state == "open" and pr.review == "approved" then
    out[#out + 1] = { " " .. icons.marker.bullet .. " ", "PaseoTreeMeta" }
    out[#out + 1] = { "approved", "PaseoTreeChecksPassed" }
  elseif pr.state == "open" and pr.review == "changes_requested" then
    out[#out + 1] = { " " .. icons.marker.bullet .. " ", "PaseoTreeMeta" }
    out[#out + 1] = { "changes", "PaseoTreeChecksFailed" }
  end
  return out
end

---One row of the rail.
---@class paseo.RailRow
---@field kind "workspace"|"agent"|"subagent"|"terminal"|"draft"
---@field ws table                 The workspace it is, or is under.
---@field node paseo.TreeNode|nil  The session, on a session row.
---@field depth integer
---@field parent integer|nil       The line of the row it is under.
---@field open boolean|nil         Open or closed; nil for a leaf.
---@field key string               Stable across redraws.
---@field path string[]            Its key and every ancestor's, nearest last.
---@field name_col integer         Byte column the name starts at.

---The rail as nvim-tree draws a tree: one depth-first walk that produces the
---lines and, in the same order, what is on each -- so the two cannot disagree.
---@param width integer
---@return { lines: table[][], rows: table<integer, paseo.RailRow>, right: table<integer, table[]>, below: table<integer, table[][]>, current: integer|nil, session: integer|nil }
function M.build(width)
  local b = { lines = {}, rows = {}, right = {}, below = {} }
  local markers = M.options().indent_markers == true

  -- THE ROOT, as nvim-tree labels it (`root_folder_label = ":t"`): the
  -- project's name, and how many workspaces it has.
  local name = cache.root and vim.fs.basename(cache.root) or "workspaces"
  b.lines[1] = render.truncate({ { name, "PaseoTreeRoot" } }, math.max(1, width - 5))
  if cache.list then
    b.right[1] = { { tostring(#cache.list), "PaseoDim" } }
  end

  if not cache.list then
    b.lines[2] = {
      {
        "  " .. (cache.err and "unavailable" or "loading…"),
        cache.err and "PaseoToolFail" or "PaseoDim",
      },
    }
    return b
  end
  if #cache.list == 0 then
    b.lines[2] = { { "  no workspaces", "PaseoDim" } }
    return b
  end

  local chat = M.host_chat()
  local tree = require "paseo.ui.tree"
  local here_session = tree.on_screen(chat)

  ---Draw one row. `last` is, for each depth from 1, whether that ancestor
  ---(or this row, at its own depth) is the last of its siblings -- what the
  ---indent markers need to know which bars continue.
  local function emit(row, last, mine, glyph, glyph_hl, title, title_hl, right)
    local indent
    if markers and row.depth > 0 then
      local parts = {}
      for d = 1, row.depth do
        if d == row.depth then
          parts[#parts + 1] = last[d] and "└ " or "│ "
        else
          parts[#parts + 1] = last[d] and "  " or "│ "
        end
      end
      indent = table.concat(parts)
    else
      indent = ("  "):rep(row.depth)
    end
    local arrow = row.open == nil and "  "
      or ((row.open and icons.tree.open or icons.tree.closed) .. " ")
    local left = {
      -- The bar that says "you are in this one", in the glyph the rest of
      -- the plugin uses for it.
      { mine and icons.marker.mine or " ", "PaseoAgent" },
      { indent, "PaseoTreeIndent" },
      { arrow, "PaseoTreeArrow" },
      { glyph .. " ", glyph_hl },
    }
    local col = 0
    for _, cell in ipairs(left) do
      col = col + #cell[1]
    end
    row.name_col = col
    right = right or {}
    local right_w = render.width(right)
    local used = render.width(left)
    -- The name is what you read: the right-hand column goes before it does.
    if used + right_w + 6 > width then
      right, right_w = {}, 0
    end
    local room = math.max(1, width - used - (right_w > 0 and right_w + 1 or 0))
    vim.list_extend(
      left,
      render.truncate({ { title, mine and "PaseoTreeCurrent" or title_hl } }, room)
    )
    local line = #b.lines + 1
    b.lines[line] = left
    b.rows[line] = row
    if right_w > 0 then
      b.right[line] = right
    end
    return line
  end

  ---Something under a row that is not a row: a virtual line, indented to the
  ---row's name.
  local function below(line, chunks)
    local row = b.rows[line]
    local pad = row and render.width(vim.list_slice(b.lines[line], 1, 4)) or 2
    b.below[line] = b.below[line] or {}
    table.insert(b.below[line], vim.list_extend({ { (" "):rep(pad) } }, chunks))
  end

  local current = M.current_index(cache.list)
  for i, ws in ipairs(cache.list) do
    local here = i == current
    local open = M.is_expanded(ws, here)
    local glyph, hl = M.status(M.bucket(ws))
    local pin = ws.pinned and (icons.ui.pin .. " ") or ""
    local key = ws_key(ws)
    local ws_line = emit(
      { kind = "workspace", ws = ws, depth = 0, open = open, key = key, path = { key } },
      {},
      here,
      glyph,
      hl,
      pin .. (ws.name or ""),
      "PaseoTreeFolder",
      M.diff_stat(ws)
    )
    if here then
      b.current = ws_line
    end
    local meta = M.meta(ws)
    if meta then
      below(ws_line, meta)
    end

    -- ITS SESSIONS, UNDER IT: agents, their subagents folded under them, then
    -- its terminals -- one sidebar, the way the app's is.
    if open then
      local forest = tree.forest(ws, chat)
      local drafting = here and chat and chat.draft ~= nil
      local count = #forest + (drafting and 1 or 0)
      local index = 0
      local function walk(node, parent_line, path, last)
        local has_kids = #node.kids > 0
        local key_n = node_key(node)
        local row = {
          kind = node.kind,
          ws = ws,
          node = node,
          depth = node.depth + 1,
          parent = parent_line,
          key = key_n,
          path = vim.list_extend(vim.list_slice(path), { key_n }),
        }
        -- Not `has_kids and node_open(...) or nil`: a CLOSED node is `false`,
        -- which that turns into a leaf.
        if has_kids then
          row.open = node_open(node, here_session)
        end
        local mine = tree.is_on_screen(node, here_session)
        local g, ghl = tree.glyph(node)
        -- A folded agent says how many of its subagents run, since you can
        -- no longer see them: `1/3`, or `3` once they are done.
        local right
        if has_kids and not row.open then
          local text = node.running > 0 and ("%d/%d"):format(node.running, #node.kids)
            or tostring(#node.kids)
          right = {
            {
              icons.tool.sub_agent .. " " .. text,
              node.running > 0 and "PaseoToolRunning" or "PaseoDim",
            },
          }
        end
        local line = emit(
          row,
          last,
          mine,
          g,
          ghl,
          tree.title(node),
          node.kind == "subagent" and "PaseoTreeSubagent" or "PaseoTreeSession",
          right
        )
        if mine and not b.session then
          b.session = line
        end
        if row.open then
          for k, kid in ipairs(node.kids) do
            walk(kid, line, row.path, vim.list_extend(vim.list_slice(last), { k == #node.kids }))
          end
        end
      end
      for _, node in ipairs(forest) do
        index = index + 1
        walk(node, ws_line, { key }, { index == count })
      end
      -- A draft on this workspace: nothing is on the daemon yet, so say so
      -- where the agent will appear.
      if drafting then
        local dkey = key .. "/draft"
        emit(
          { kind = "draft", ws = ws, depth = 1, parent = ws_line, key = dkey, path = { key, dkey } },
          { true },
          true,
          icons.status.pending,
          "PaseoDim",
          "new session",
          "PaseoTreeSession"
        )
      end
      if count == 0 then
        below(ws_line, { { "  no sessions yet", "PaseoDim" } })
      end
    end
  end

  -- THE KEYS, where you are looking when you want them -- virtual, so no row
  -- has to be skipped to get past them.
  if M.options().hints ~= false then
    local last = #b.lines
    b.below[last] = b.below[last] or {}
    table.insert(b.below[last], { { "" } })
    table.insert(b.below[last], {
      { " a", "PaseoKey" },
      { " agent  ", "PaseoDim" },
      { "w", "PaseoKey" },
      { " workspace  ", "PaseoDim" },
      { "g?", "PaseoKey" },
      { " keys", "PaseoDim" },
    })
  end
  return b
end

---The lines, as |paseo.ui.render| means a line, and what is on each:
---`rows` the workspace rows, `sessions` the session rows under the open ones.
---(The shape this had before the rail was a tree, kept for what reads it.)
---@param width integer
---@return table[][] lines, table<integer, table> rows, table<integer, table> sessions
function M.lines(width)
  local b = M.build(width)
  local workspaces, sessions = {}, {}
  for line, row in pairs(b.rows) do
    if row.kind == "workspace" then
      workspaces[line] = row.ws
    elseif row.node then
      sessions[line] = row.node
    end
  end
  return b.lines, workspaces, sessions
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

---The row under the cursor.
---@return paseo.RailRow|nil, integer|nil line
local function cursor_row()
  if not M.win() then
    return nil
  end
  local line = api.nvim_win_get_cursor(win)[1]
  return rows[line], line
end

---Put the cursor on `line`, on the name -- where nvim-tree's `hijack_cursor`
---keeps it.
---@param line integer
local function place(line)
  if not M.win() then
    return
  end
  local row = rows[line]
  pcall(api.nvim_win_set_cursor, win, { line, row and row.name_col or 0 })
end

---The line now showing the row whose path was `path`, or its nearest
---ancestor that is still drawn: where the cursor goes when what it was on
---folded away or moved.
---@param path string[]
---@return integer|nil
local function find(path)
  local by_key = {}
  for line, row in pairs(rows) do
    by_key[row.key] = line
  end
  for i = #path, 1, -1 do
    if by_key[path[i]] then
      return by_key[path[i]]
    end
  end
  return nil
end

---Paint the buffer from the cache. Cheap -- a few dozen short lines -- so the
---spinner clock calls it ten times a second without a second thought.
---
---THE CURSOR STAYS ON WHAT IT WAS ON, not on the line number it was on: a
---workspace that grows a pull request line or an agent that gains a subagent
---above it moves everything under it, and the row you were pointing at should
---move with it. When that row is gone -- folded into its parent -- the cursor
---goes to the nearest ancestor still drawn, as nvim-tree's collapse does.
function M.draw()
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  local width = M.win() and api.nvim_win_get_width(win) or 32
  local held_path, held_col
  if M.win() then
    local row = cursor_row()
    if row then
      held_path = row.path
      held_col = api.nvim_win_get_cursor(win)[2] - row.name_col
    end
  end

  local b = M.build(width)
  local text = {}
  for i, line in ipairs(b.lines) do
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
  api.nvim_buf_clear_namespace(buf, ns_right, 0, -1)
  rows, current_line, session_line = b.rows, b.current, b.session

  -- THE ROW YOU ARE IN, across the whole width: the session on screen when
  -- its workspace is open, the workspace when it is not. A band says it at a
  -- glance, from across the surface.
  local band = session_line or current_line
  if band then
    api.nvim_buf_set_extmark(
      buf,
      ns,
      band - 1,
      0,
      { line_hl_group = "PaseoRowCurrent", priority = 10 }
    )
  end
  for i, line in ipairs(b.lines) do
    local col = 0
    for _, cell in ipairs(line) do
      local len = #cell[1]
      if cell[2] and len > 0 then
        api.nvim_buf_set_extmark(buf, ns, i - 1, col, { end_col = col + len, hl_group = cell[2] })
      end
      col = col + len
    end
  end
  -- The right-hand column -- a workspace's `+120 -7`, a folded agent's
  -- subagent count -- right-aligned as nvim-tree draws its right-aligned
  -- decorations, and combined so the cursor band shows through it.
  for line, chunks in pairs(b.right) do
    api.nvim_buf_set_extmark(buf, ns_right, line - 1, 0, {
      virt_text = chunks,
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
  end
  for line, extra in pairs(b.below) do
    api.nvim_buf_set_extmark(buf, ns_right, line - 1, 0, { virt_lines = extra })
  end

  if M.win() then
    local target = held_path and find(held_path)
    if target then
      local row = rows[target]
      local col = row.name_col
      -- Only the row it was on keeps its column; landing on an ancestor puts
      -- the cursor on that one's name.
      if row.path[#row.path] == held_path[#held_path] and held_col and held_col > 0 then
        col = col + held_col
      end
      pcall(api.nvim_win_set_cursor, win, { target, col })
    elseif not rows[api.nvim_win_get_cursor(win)[1]] then
      -- On the heading the first time, which is not a row.
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
    return place(session_line)
  end
  local first
  for line = 1, api.nvim_buf_line_count(buf) do
    if rows[line] then
      first = line
      break
    end
  end
  local line = current_line or first
  if line then
    place(line)
  end
end

---The workspace under the cursor -- nil on a session row.
---@return table|nil
function M.current()
  local row = cursor_row()
  return row and row.kind == "workspace" and row.ws or nil
end

---The session under the cursor, a |paseo.ui.tree| node, or nil.
---@return table|nil
function M.current_session()
  local row = cursor_row()
  return row and row.node or nil
end

---The workspace the cursor is in: its own row, or the row of the session
---under it.
---@return table|nil
function M.current_workspace()
  local row = cursor_row()
  return row and row.ws or nil
end

---Open the workspace on screen, and every agent above the session on screen,
---if you had closed them: `<C-s>` lands on that session, which has to be drawn
---to be landed on.
function M.reveal()
  if not cache.list then
    return
  end
  local i = M.current_index(cache.list)
  local ws = i and cache.list[i]
  if not ws then
    return
  end
  expanded[ws_key(ws)] = true
  local tree = require "paseo.ui.tree"
  local here = tree.on_screen(M.host_chat())
  for _, node in ipairs(tree.flatten(tree.forest(ws, M.host_chat()))) do
    if #node.kids > 0 and not tree.is_on_screen(node, here) and tree.holds(node, here) then
      expanded[node_key(node)] = true
    end
  end
end

---Open or close the row under the cursor.
---
---On a row that does not fold, closing closes the one it is in and lands on
---it, as nvim-tree's `parent_close` does -- so `h` anywhere inside a
---workspace walks back out of it.
---@param want? boolean  Nil toggles.
function M.expand(want)
  local row = cursor_row()
  if not row then
    return
  end
  if row.open == nil then
    if want == false and row.parent then
      place(row.parent)
      return M.expand(false)
    end
    return
  end
  if want == nil then
    want = not row.open
  end
  expanded[row.key] = want
  M.draw()
end

---`P`: up to the row this one is under.
function M.parent()
  local row = cursor_row()
  if row and row.parent then
    place(row.parent)
  end
end

---The rows that share this one's parent, in order, and where it is among
---them. A workspace's siblings are the other workspaces.
---@return integer[] lines, integer|nil index
local function siblings()
  local row, line = cursor_row()
  if not row then
    return {}, nil
  end
  local out, at = {}, nil
  for l = 1, api.nvim_buf_line_count(buf) do
    local other = rows[l]
    if other and other.parent == row.parent and other.depth == row.depth then
      out[#out + 1] = l
      if l == line then
        at = #out
      end
    end
  end
  return out, at
end

---`<` / `>`: the previous or next sibling, wrapping, as nvim-tree's do.
---@param step integer
function M.sibling(step)
  local list, at = siblings()
  if at then
    place(list[(at - 1 + step) % #list + 1])
  end
end

---`K` / `J`: the first or last sibling.
---@param last boolean
function M.edge(last)
  local list = siblings()
  if #list > 0 then
    place(list[last and #list or 1])
  end
end

---`W` / `E`: fold or unfold everything. Folding everything leaves the cursor
---on the workspace it was in.
---@param want boolean
function M.fold_all(want)
  if not cache.list then
    return
  end
  local tree = require "paseo.ui.tree"
  for _, ws in ipairs(cache.list) do
    expanded[ws_key(ws)] = want
    if want then
      for _, node in ipairs(tree.flatten(tree.forest(ws, M.host_chat()))) do
        if #node.kids > 0 then
          expanded[node_key(node)] = true
        end
      end
    end
  end
  if not want then
    for key in pairs(expanded) do
      if key:find("/", 1, true) then
        expanded[key] = false
      end
    end
  end
  M.draw()
end

---Open the workspace under the cursor as its own place: its agent on a
---native tab of its own, from a native tab, and otherwise the full switch,
---tab and `tcd` and all, exactly as the picker does it.
---@param ws table
local function open_workspace(ws)
  local native = package.loaded["paseo.ui.native"]
  if native and native.chat() then
    return native.open_workspace(ws)
  end
  require("paseo.workspaces").open(ws)
end

---`<CR>`: what nvim-tree's `<CR>` does. A session opens -- on a native tab of
---its own; a provider subagent in the read-only viewer. A workspace is a
---folder, and folds; `O` opens it as a place.
function M.open_current()
  local row = cursor_row()
  if not row then
    return
  end
  if row.node then
    local chat = M.host_chat()
    if chat then
      require("paseo.ui.tree").open(row.node, chat)
    end
    return
  end
  if row.kind == "workspace" then
    return M.expand()
  end
end

---`O`: the workspace under the cursor -- or the one the cursor is in -- opened
---as a place.
function M.open_workspace()
  local row = cursor_row()
  if row and row.node then
    return M.open_current()
  end
  local ws = row and row.ws
  if ws then
    open_workspace(ws)
  end
end

---`l`: in. Opens what is closed; on what is open, steps onto its first row;
---on a leaf, opens the session -- the vim-ish file tree's `l`.
function M.into()
  local row, line = cursor_row()
  if not row then
    return
  end
  if row.open == false then
    return M.expand(true)
  end
  if row.open == true then
    local next_row = rows[line + 1]
    if next_row and next_row.parent == line then
      place(line + 1)
    end
    return
  end
  M.open_current()
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

---The rail's keys: what each one does and what `g?` says about it, in one
---table, so the two cannot drift. nvim-tree's where it has one for the job.
---@param keys { back: fun(), toggle?: string|false, focus?: string|false, sessions?: string|false, on_toggle: fun() }
---@return { [1]: string|false|nil, [2]: fun(), [3]: string }[]
local function keymap(keys)
  return {
    { "<CR>", M.open_current, "open the session / fold the workspace" },
    { "o", M.open_current, "open the session / fold the workspace" },
    { "<2-LeftMouse>", M.open_current, "open the session / fold the workspace" },
    { "l", M.into, "unfold, step in, or open" },
    {
      "h",
      function()
        M.expand(false)
      end,
      "fold, or fold the one it is in",
    },
    {
      "<BS>",
      function()
        M.expand(false)
      end,
      "fold, or fold the one it is in",
    },
    {
      "<Tab>",
      function()
        M.expand()
      end,
      "fold or unfold",
    },
    {
      "za",
      function()
        M.expand()
      end,
      "fold or unfold",
    },
    { "O", M.open_workspace, "open the workspace as a place" },
    { "P", M.parent, "up to the parent" },
    {
      ">",
      function()
        M.sibling(1)
      end,
      "next sibling",
    },
    {
      "<",
      function()
        M.sibling(-1)
      end,
      "previous sibling",
    },
    {
      "J",
      function()
        M.edge(true)
      end,
      "last sibling",
    },
    {
      "K",
      function()
        M.edge(false)
      end,
      "first sibling",
    },
    {
      "W",
      function()
        M.fold_all(false)
      end,
      "fold everything",
    },
    {
      "E",
      function()
        M.fold_all(true)
      end,
      "unfold everything",
    },
    {
      "a",
      function()
        M.start "here"
      end,
      "new agent in this workspace",
    },
    {
      "w",
      function()
        M.start "workspace"
      end,
      "new agent in a new workspace",
    },
    {
      "t",
      function()
        M.start "terminal"
      end,
      "new terminal in this workspace",
    },
    {
      "c",
      function()
        M.start "terminal"
      end,
      "new terminal in this workspace",
    },
    {
      "y",
      on_session(function(node)
        if node.kind ~= "terminal" then
          require("paseo.agents").copy_id { id = node.item.id, title = node.item.title }
        end
      end),
      "copy the agent ID",
    },
    {
      -- `R`, not nvim-tree's `r`: `r` is re-fetch on every panel.
      "R",
      on_session(function(node, chat)
        if node.kind == "terminal" then
          require("paseo.terminals").rename(node.item.id, node.item.hostId or chat.host_id)
        end
      end),
      "rename this terminal",
    },
    {
      "d",
      on_session(function(node, chat)
        require("paseo.ui.tree").remove(node, chat)
      end),
      "archive this agent / kill this terminal",
    },
    {
      "r",
      function()
        M.load()
      end,
      "refetch the workspaces",
    },
    { "m", M.toggle_pin, "pin or unpin this workspace" },
    { "g?", M.help, "these keys" },
    -- Back to where you were typing. `<Esc>` too: in a list, it is "I am done
    -- here".
    { "<Esc>", keys.back, "back to the conversation" },
    { "q", keys.back, "back to the conversation" },
    { keys.focus, keys.back, "back to the conversation" },
    { keys.sessions, keys.back, "back to the conversation" },
    { keys.toggle, keys.on_toggle, "hide the workspace rail" },
  }
end

---@type table|nil
local bound

---`g?`: the keys, in a float over the rail, as nvim-tree's help is.
function M.help()
  if not bound then
    return
  end
  local lines, seen = {}, {}
  local by_desc, order = {}, {}
  for _, entry in ipairs(bound) do
    local lhs, desc = entry[1], entry[3]
    -- The mouse is not a key you need telling about.
    if lhs and not seen[lhs] and not lhs:find("Mouse", 1, true) then
      seen[lhs] = true
      if not by_desc[desc] then
        by_desc[desc] = {}
        order[#order + 1] = desc
      end
      table.insert(by_desc[desc], lhs)
    end
  end
  local width = 0
  for _, desc in ipairs(order) do
    local keys = table.concat(by_desc[desc], " ")
    lines[#lines + 1] = { keys, desc }
    width = math.max(width, vim.fn.strdisplaywidth(keys))
  end
  local text = {}
  for i, pair in ipairs(lines) do
    text[i] = (" %-" .. width .. "s  %s "):format(pair[1], pair[2])
  end
  local help = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(help, 0, -1, false, text)
  vim.bo[help].modifiable = false
  vim.bo[help].bufhidden = "wipe"
  vim.bo[help].filetype = "paseo-rail-help"
  for i = 1, #text do
    api.nvim_buf_set_extmark(
      help,
      ns,
      i - 1,
      1,
      { end_col = 1 + #lines[i][1], hl_group = "PaseoKey" }
    )
  end
  local w = 0
  for _, line in ipairs(text) do
    w = math.max(w, vim.fn.strdisplaywidth(line))
  end
  local float = api.nvim_open_win(help, true, {
    relative = "editor",
    row = 1,
    col = M.win() and api.nvim_win_get_position(win)[2] + 1 or 1,
    width = math.min(w, vim.o.columns - 4),
    height = math.min(#text, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    title = " paseo rail ",
  })
  vim.wo[float].winhl = "Normal:PaseoNormal,FloatBorder:PaseoBorder"
  for _, lhs in ipairs { "q", "<Esc>", "g?" } do
    vim.keymap.set("n", lhs, function()
      pcall(api.nvim_win_close, float, true)
    end, { buffer = help, nowait = true, silent = true })
  end
  api.nvim_create_autocmd("WinLeave", {
    buffer = help,
    once = true,
    callback = function()
      pcall(api.nvim_win_close, float, true)
    end,
  })
end

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
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  pcall(api.nvim_buf_set_name, buf, "paseo://workspaces")

  -- `nowait`: a global mapping that starts with one of these (`<leader>`-less
  -- `g` and `z` sequences, say) would otherwise hold the key for 'timeoutlen'.
  bound = keymap(keys)
  for _, entry in ipairs(bound) do
    if entry[1] then
      vim.keymap.set(
        "n",
        entry[1],
        entry[2],
        { buffer = buf, nowait = true, silent = true, desc = "paseo: " .. entry[3] }
      )
    end
  end

  local group = api.nvim_create_augroup("paseo.rail", { clear = true })
  api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = group,
    buffer = buf,
    desc = "paseo: the rail's cursor band only while it has focus",
    callback = function(args)
      if M.win() then
        vim.wo[win].cursorline = args.event == "WinEnter"
      end
    end,
  })
  -- THE CURSOR ON THE NAME, wherever a motion left it: nvim-tree's
  -- `hijack_cursor`. Normal mode only, so a visual selection can still be
  -- made, and not while a search is landing on its match.
  api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    desc = "paseo: keep the rail's cursor on the name",
    callback = function()
      if api.nvim_get_mode().mode ~= "n" then
        return
      end
      local ok, search = pcall(vim.fn.searchcount, { recompute = false })
      if ok and type(search) == "table" and search.exact_match == 1 then
        return
      end
      local cursor = api.nvim_win_get_cursor(0)
      local row = rows[cursor[1]]
      if row and cursor[2] < row.name_col then
        pcall(api.nvim_win_set_cursor, 0, { cursor[1], row.name_col })
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
