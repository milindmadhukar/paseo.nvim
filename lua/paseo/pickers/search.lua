--- Search everything: workspaces, agents, every prompt you sent, past chats.
---
--- The app's Ctrl+K, as one fuzzy list. The app's own palette matches names
--- only -- workspace and agent titles -- and its find-in-chat is one agent at a
--- time. This goes one further with what the daemon will hand over cheaply:
--- each chat's PROMPT INDEX, every message you sent it, so a chat is found by
--- what you asked as well as by what it came to be called.
---
--- THIS PROJECT ONLY, unless asked for all (`:Paseo search all`): the project
--- is the one |paseo.workspaces|.here says the cwd is in -- the main checkout,
--- so every worktree Paseo cut from it counts, or the manifested multi-repo
--- project around an assembled workspace -- and its workspaces are the ones
--- |paseo.workspaces|.scope gives the rail and `:Paseo workspaces`. Agents and
--- their prompts follow their workspace; past chats are filtered by the daemon
--- itself, on the project's ids.
---
--- One list, not sections: you type, the sorter ranks, and a prompt row sits
--- beside the agent it belongs to. Telescope when it is installed, for its
--- sorter and its preview window; |paseo.ui.choose| when it is not, which has
--- neither, so it says so once.
---
--- Nothing here waits on the slow part. The picker opens on the workspaces and
--- the live directory, and the prompt lists and archived agents land in ONE
--- refresh when they have all answered: a refresh per agent re-sorts the list
--- under your cursor a dozen times while you type.

local api = vim.api

local M = {}

---How long (ms) a chat's prompt list, and the archived agents, are kept: enough
---that the second `<C-k>` in a minute opens on everything at once.
M.TTL = 30000

---Items of history a preview draws.
M.PREVIEW_ITEMS = 40

---Where a kind is drawn, and how its tag reads.
M.TAGS = { agent = "agent", workspace = "ws", prompt = "prompt", archived = "archived" }

---Kinds in the order an empty query lists them: what is live and doing
---something first, what is history last.
local ORDER = { agent = 1, workspace = 2, prompt = 3, archived = 4 }

local BUCKET_RANK = { needs_input = 1, failed = 2, running = 3, attention = 4, done = 5, none = 6 }

local ns = api.nvim_create_namespace "paseo.search.preview"

---@class paseo.SearchRow
---@field kind "agent"|"workspace"|"prompt"|"archived"
---@field key string          Unique across the list.
---@field title string
---@field detail string       The dim second column.
---@field ordinal string      What the sorter matches.
---@field mark string         The status slot.
---@field mark_hl string
---@field host_id string|nil
---@field agent table|nil     The agent it is, or is in.
---@field ws table|nil        The workspace it is, or is in.
---@field seq integer|nil     A prompt's timeline seq.
---@field epoch string|nil
---@field time string|nil     When, for ordering prompts and past chats.

---Collapse whitespace: a prompt is a paragraph, a row is one line.
---@param text any
---@return string
local function line(text)
  return vim.trim(tostring(text or ""):gsub("%s+", " "))
end

---@param parts any[]
---@param sep? string
---@return string
local function join(parts, sep)
  local out, seen = {}, {}
  -- `maxn`, not `ipairs`: the parts are optional, so the list has holes.
  -- Each once: a workspace called `main` on branch `main` is `main`, not
  -- `main · main`.
  for i = 1, table.maxn(parts) do
    local s = line(parts[i])
    if s ~= "" and not seen[s] then
      seen[s] = true
      out[#out + 1] = s
    end
  end
  return table.concat(out, sep or " · ")
end

---@param ws table|nil
---@return string
local function ws_title(ws)
  return ws and (ws.title or ws.name) or ""
end

---@param agent table
---@return boolean
local function is_subagent(agent)
  local label = require("paseo.subagents").PARENT_LABEL
  return agent.labels ~= nil and agent.labels[label] ~= nil
end

---The status slot, as the rail draws it, but still: a picker row is not
---repainted every frame, so a spinner would be one frozen frame of one.
---@param bucket string
---@return string mark, string hl
local function badge(bucket)
  if bucket == "none" then
    return " ", "PaseoDim"
  end
  local mark, hl = require("paseo.ui.rail").badge(bucket)
  if bucket == "running" then
    mark = "●"
  end
  return mark, hl
end

---The rows, built from what has been gathered. Pure: everything it reads is
---in `data`, which is what lets the ordering be tested without a daemon.
---@param data { agents?: table[], workspaces?: table[], prompts?: table<string, { agent: table, epoch?: string, prompts: table[] }>, archived?: table[], bucket?: fun(agent: table): string, ws_bucket?: fun(ws: table): string }
---@return paseo.SearchRow[]
function M.rows(data)
  local bucket = data.bucket or function(agent)
    return require("paseo.agents").bucket(agent)
  end
  local ws_bucket = data.ws_bucket or function(ws)
    return require("paseo.ui.rail").bucket(ws)
  end

  local by_id = {}
  for _, ws in ipairs(data.workspaces or {}) do
    if ws.id then
      by_id[(ws.hostId or "") .. "\0" .. ws.id] = ws
    end
  end
  local function home(agent)
    return agent.workspaceId and by_id[(agent.hostId or "") .. "\0" .. agent.workspaceId]
  end

  local rows = {}

  -- LIVE AGENTS, the most urgent first: what the rail would draw at the top.
  local live = {}
  for _, agent in ipairs(data.agents or {}) do
    if not is_subagent(agent) then
      live[#live + 1] = { agent = agent, bucket = bucket(agent) }
    end
  end
  table.sort(live, function(a, b)
    local ra, rb = BUCKET_RANK[a.bucket] or 9, BUCKET_RANK[b.bucket] or 9
    if ra ~= rb then
      return ra < rb
    end
    return (a.agent.createdAt or "") > (b.agent.createdAt or "")
  end)
  for _, entry in ipairs(live) do
    local agent, ws = entry.agent, home(entry.agent)
    local mark, hl = badge(entry.bucket)
    local title = line(agent.title) ~= "" and line(agent.title) or agent.id:sub(1, 12)
    rows[#rows + 1] = {
      kind = "agent",
      key = "agent:" .. (agent.hostId or "") .. ":" .. agent.id,
      title = title,
      detail = join { ws_title(ws), ws and ws.branch, agent.provider },
      ordinal = join({ title, ws_title(ws), ws and ws.branch, agent.provider, agent.cwd and vim.fs.basename(agent.cwd) }, " "),
      mark = mark,
      mark_hl = hl,
      host_id = agent.hostId,
      agent = agent,
      ws = ws,
    }
  end

  -- WORKSPACES, in the order they are listed everywhere else.
  for _, ws in ipairs(data.workspaces or {}) do
    local mark, hl = badge(ws_bucket(ws))
    local title = ws_title(ws) ~= "" and ws_title(ws) or vim.fs.basename(ws.directory or "")
    rows[#rows + 1] = {
      kind = "workspace",
      key = "ws:" .. (ws.hostId or "") .. ":" .. (ws.id or ws.directory or title),
      title = title,
      detail = join { ws.project, ws.branch },
      ordinal = join({ title, ws.name ~= title and ws.name or nil, ws.project, ws.branch }, " "),
      mark = mark,
      mark_hl = hl,
      host_id = ws.hostId,
      ws = ws,
    }
  end

  -- EVERY PROMPT, newest first, under the agent it was sent to.
  local prompts = {}
  for _, list in pairs(data.prompts or {}) do
    local agent = list.agent
    for _, prompt in ipairs(list.prompts or {}) do
      local text = line(prompt.preview)
      if text ~= "" and prompt.seq then
        prompts[#prompts + 1] = { agent = agent, epoch = list.epoch, prompt = prompt, text = text }
      end
    end
  end
  table.sort(prompts, function(a, b)
    local ta, tb = a.prompt.timestamp or "", b.prompt.timestamp or ""
    if ta ~= tb then
      return ta > tb
    end
    return a.prompt.seq > b.prompt.seq
  end)
  for _, entry in ipairs(prompts) do
    local agent = entry.agent
    local title = line(agent.title) ~= "" and line(agent.title) or agent.id:sub(1, 12)
    rows[#rows + 1] = {
      kind = "prompt",
      key = ("prompt:%s:%s:%d"):format(agent.hostId or "", agent.id, entry.prompt.seq),
      title = entry.text,
      detail = title,
      ordinal = entry.text .. " " .. title,
      mark = ">",
      mark_hl = "PaseoDim",
      host_id = agent.hostId,
      agent = agent,
      ws = home(agent),
      seq = entry.prompt.seq,
      epoch = entry.epoch,
      time = entry.prompt.timestamp,
    }
  end

  -- PAST CHATS, as history returned them: most recently touched first.
  for _, agent in ipairs(data.archived or {}) do
    local title = line(agent.title) ~= "" and line(agent.title) or agent.id:sub(1, 12)
    local ws_name = agent.workspaceName or ws_title(home(agent))
    rows[#rows + 1] = {
      kind = "archived",
      key = "archived:" .. (agent.hostId or "") .. ":" .. agent.id,
      title = title,
      detail = join { ws_name, agent.branch, agent.projectName ~= ws_name and agent.projectName or nil },
      ordinal = join({ title, ws_name, agent.branch, agent.projectName }, " "),
      mark = "•",
      mark_hl = "PaseoDim",
      host_id = agent.hostId,
      agent = agent,
      time = agent.updatedAt,
    }
  end

  -- Stable within a kind: the order above is the order each kind was built in.
  for i, row in ipairs(rows) do
    row.index = i
  end
  table.sort(rows, function(a, b)
    if ORDER[a.kind] ~= ORDER[b.kind] then
      return ORDER[a.kind] < ORDER[b.kind]
    end
    return a.index < b.index
  end)
  return rows
end

-- ------------------------------------------------------------------- scope

---@param path string|nil
---@return string
local function normal(path)
  if not path or path == "" then
    return ""
  end
  return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

---@param path string
---@param dir string
---@return boolean
local function inside(path, dir)
  return dir ~= "" and (path == dir or vim.startswith(path, dir .. "/"))
end

---@class paseo.SearchScope
---@field all boolean
---@field root string|nil       The project, as a local directory.
---@field label string
---@field workspaces table[]    This project's workspaces.
---@field contains fun(agent: table): boolean
---@field hosts table<string, { projectIds: string[], projectRoots: string[] }>|nil

---What one search covers: the project at `root`, or every project.
---
---A live agent is this project's when its workspace is; one the daemon has
---placed in no workspace, when its directory is in the project or in one of
---its workspaces. Per host, the project's ids and its root in the HOST's
---spelling go to the daemon, which filters history on them.
---@param list table[]  Every host's workspaces.
---@param opts? { all?: boolean, root?: string }
---@return paseo.SearchScope
function M.scope(list, opts)
  opts = opts or {}
  if opts.all then
    return {
      all = true,
      label = "all projects",
      workspaces = list,
      contains = function()
        return true
      end,
    }
  end
  local hosts = require "paseo.hosts"
  local workspaces = require "paseo.workspaces"
  local root = normal(opts.root or workspaces.here())
  local scoped = workspaces.scope(list, root)

  local ids, dirs, per_host = {}, { root }, {}
  for _, host in ipairs(hosts.all()) do
    local remote_root = not host.local_host and hosts.to_remote(host.id, root) or nil
    per_host[host.id] = { projectIds = {}, projectRoots = { remote_root or root } }
  end
  for _, ws in ipairs(scoped) do
    if ws.id then
      ids[(ws.hostId or "") .. "\0" .. ws.id] = true
    end
    dirs[#dirs + 1] = normal(ws.local_directory or ws.directory)
    local entry = ws.hostId and per_host[ws.hostId]
    if entry and ws.projectId and not vim.tbl_contains(entry.projectIds, ws.projectId) then
      entry.projectIds[#entry.projectIds + 1] = ws.projectId
    end
  end

  return {
    all = false,
    root = root,
    label = vim.fs.basename(root),
    workspaces = scoped,
    hosts = per_host,
    contains = function(agent)
      if agent.workspaceId and agent.workspaceId ~= vim.NIL then
        return ids[(agent.hostId or "") .. "\0" .. agent.workspaceId] == true
      end
      local cwd = agent.cwd and normal(hosts.to_local(agent.hostId, agent.cwd) or agent.cwd) or ""
      for _, dir in ipairs(dirs) do
        if inside(cwd, dir) then
          return true
        end
      end
      return false
    end,
  }
end

-- ------------------------------------------------------------------ gather

---Every live agent's prompt list and every host's archived agents, each from
---the store when it is fresh enough. `done` is called ONCE, when all of them
---have answered -- or failed, which counts as answering with nothing.
---
---With a `scope`, the archived agents are that project's, filtered by the
---daemon, and `known` says whether any host has a project there at all.
---@param live table[]
---@param done fun(prompts: table<string, table>, archived: table[], known: boolean)
---@param scope? paseo.SearchScope
function M.gather(live, done, scope)
  local bridge = require "paseo.bridge"
  local store = require "paseo.store"
  local hosts = require "paseo.hosts"
  scope = scope and not scope.all and scope or nil

  local prompts, archived = {}, {}
  local known = scope == nil or #scope.workspaces > 0
  local left = 1
  local function settle()
    left = left - 1
    if left == 0 then
      done(prompts, archived, known)
    end
  end

  for _, agent in ipairs(live) do
    if not is_subagent(agent) then
      left = left + 1
      local key = ("search.prompts:%s:%s"):format(agent.hostId or "", agent.id)
      store.get(key, M.TTL, function(finish)
        bridge.request("timeline.prompts", { agentId = agent.id }, function(err, result)
          finish(not err and result or nil, err, not err)
        end, agent.hostId)
      end, function(result)
        if result and result.prompts and #result.prompts > 0 then
          prompts[(agent.hostId or "") .. ":" .. agent.id] =
            { agent = agent, epoch = result.epoch, prompts = result.prompts }
        end
        settle()
      end)
    end
  end

  for _, host in ipairs(hosts.all()) do
    left = left + 1
    local req = { limit = 200 }
    local key = "search.archived:" .. host.id
    if scope then
      local where = scope.hosts and scope.hosts[host.id] or { projectIds = {}, projectRoots = { scope.root } }
      req.projectIds, req.projectRoots = where.projectIds, where.projectRoots
      key = key .. ":" .. scope.root
    end
    store.get(key, M.TTL, function(finish)
      bridge.request("agents.history", req, function(err, result)
        finish(not err and result or nil, err, not err)
      end, host.id)
    end, function(result)
      if result and type(result.projectIds) == "table" and #result.projectIds > 0 then
        known = true
      end
      for _, agent in ipairs(result and result.entries or {}) do
        agent.hostId = agent.hostId or host.id
        archived[#archived + 1] = agent
      end
      settle()
    end)
  end

  settle()
end

---The live agents a scope covers, as they are now.
---@param scope paseo.SearchScope
---@return table[]
local function live_agents(scope)
  return vim.tbl_filter(scope.contains, require("paseo.agents").all "*")
end

---What there is to search right now, without waiting for anything.
---@param scope paseo.SearchScope
---@param extra? { prompts?: table, archived?: table[] }
---@return paseo.SearchRow[]
local function snapshot(scope, extra)
  extra = extra or {}
  return M.rows {
    agents = live_agents(scope),
    workspaces = scope.workspaces,
    prompts = extra.prompts,
    archived = extra.archived,
  }
end

-- ----------------------------------------------------------------- preview

---A preview's lines: a header saying what this is, then the conversation as
---the chat draws it -- the same cards, folded, so a preview reads like the
---chat it opens.
---@param row paseo.SearchRow
---@param items table[]|nil  Timeline items; nil while they load.
---@param width integer
---@param err? string
---@return table[][]
function M.preview_lines(row, items, width, err)
  local timeline = require "paseo.ui.timeline"
  local out = {}
  local head = row.kind == "prompt" and row.detail or row.title
  out[#out + 1] = { { head, "PaseoText" } }
  local sub
  if row.kind == "workspace" then
    sub = { row.detail }
  elseif row.kind == "prompt" then
    sub = { ws_title(row.ws), row.ws and row.ws.branch, "from this message on" }
  elseif row.kind == "archived" then
    sub = { "archived", row.detail }
  else
    sub = { row.detail, row.agent and row.agent.status }
  end
  local cells = { { join(sub), "PaseoDim" } }
  if row.kind == "workspace" and row.ws then
    local rail = require "paseo.ui.rail"
    local stat = rail.diff_stat(row.ws)
    if #stat > 0 then
      cells[#cells + 1] = { "  " }
      vim.list_extend(cells, stat)
    end
    local meta = rail.meta(row.ws)
    if meta then
      cells[#cells + 1] = { "  " }
      vim.list_extend(cells, meta)
    end
  end
  out[#out + 1] = cells

  if err then
    out[#out + 1] = { { "" } }
    out[#out + 1] = { { err, "PaseoDim" } }
    return out
  end
  if not items then
    out[#out + 1] = { { "" } }
    out[#out + 1] = { { "loading…", "PaseoDim" } }
    return out
  end
  if #items == 0 then
    out[#out + 1] = { { "" } }
    out[#out + 1] = { { row.kind == "workspace" and "no agents here yet" or "nothing said yet", "PaseoDim" } }
    return out
  end
  local prev
  for _, item in ipairs(items) do
    local ok, built = pcall(timeline.card, item, {
      width = math.max(20, width),
      expanded = false,
      gap = not timeline.stacks(prev, item.kind),
    })
    if ok and built then
      vim.list_extend(out, built.lines)
      prev = item.kind
    end
  end
  return out
end

---The agent a row previews: its own, or a workspace's newest.
---@param row paseo.SearchRow
---@return table|nil
local function preview_agent(row)
  if row.agent then
    return row.agent
  end
  local ws = row.ws
  if not (ws and ws.id) then
    return nil
  end
  local newest
  for _, agent in ipairs(require("paseo.agents").all(ws.hostId)) do
    if agent.workspaceId == ws.id and not is_subagent(agent) then
      if not newest or (agent.createdAt or "") > (newest.createdAt or "") then
        newest = agent
      end
    end
  end
  return newest
end

---Fetch the items a row previews. Kept for the picker's lifetime in `cache`,
---so moving back over a row is instant.
---@param row paseo.SearchRow
---@param cache table
---@param done fun(items: table[]|nil, err: string|nil)
local function preview_items(row, cache, done)
  local agent = preview_agent(row)
  if not agent then
    return done({}, nil)
  end
  local key = row.kind == "prompt" and row.key or ("tail:" .. (agent.hostId or "") .. ":" .. agent.id)
  local kept = cache[key]
  if kept then
    return done(kept.items, kept.err)
  end
  local req = { agentId = agent.id, limit = M.PREVIEW_ITEMS }
  if row.kind == "prompt" and row.seq and row.epoch then
    -- From the prompt ON: the page after the item before it.
    req.direction = "after"
    req.cursor = { epoch = row.epoch, seq = row.seq - 1 }
  end
  require("paseo.bridge").request("timeline.history", req, function(err, result)
    vim.schedule(function()
      local entry = err and { err = "could not load the conversation: " .. tostring(err) }
        or { items = result and result.items or {} }
      cache[key] = entry
      done(entry.items, entry.err)
    end)
  end, row.host_id or agent.hostId)
end

-- -------------------------------------------------------------------- open

---Open what a row is.
---@param row paseo.SearchRow
function M.pick(row)
  local native = package.loaded["paseo.ui.native"]
  local on_tab = native and native.on_tab()
  if row.kind == "workspace" then
    return require("paseo.workspaces").open(row.ws)
  end
  local agent = row.agent
  if not agent then
    return
  end
  if on_tab then
    return native.show_session {
      kind = "agent",
      id = agent.id,
      hostId = row.host_id,
      at = row.seq,
      cwd = agent.cwd,
      title = agent.title,
    }
  end
  require("paseo.ui.chat").open {
    root = agent.cwd,
    host_id = row.host_id,
    remote = true,
    agent_id = agent.id,
    title = agent.title,
    at = row.seq,
  }
end

---The widest title column worth giving: the longest title, within reason.
---@param rows paseo.SearchRow[]
---@return integer
local function title_width(rows)
  local widest = 12
  for _, row in ipairs(rows) do
    widest = math.max(widest, vim.fn.strdisplaywidth(row.title))
  end
  return math.min(widest, math.floor(vim.o.columns * 0.35))
end

---@param scope paseo.SearchScope
---@param extra? { prompts?: table, archived?: table[] }
local function telescope(scope, extra)
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local previewers = require "telescope.previewers"
  local entry_display = require "telescope.pickers.entry_display"

  local rows = snapshot(scope, extra)
  local displayer = entry_display.create {
    separator = " ",
    items = { { width = 8 }, { width = 1 }, { width = title_width(rows) }, { remaining = true } },
  }
  local function finder(list)
    return finders.new_table {
      results = list,
      entry_maker = function(row)
        return {
          value = row,
          ordinal = row.ordinal,
          display = function(entry)
            local r = entry.value
            return displayer {
              { M.TAGS[r.kind], "PaseoDim" },
              { r.mark, r.mark_hl },
              { r.title, "PaseoText" },
              { r.detail, "PaseoDim" },
            }
          end,
        }
      end,
    }
  end

  local cache = {}
  local previewer = previewers.new_buffer_previewer {
    title = "Paseo",
    define_preview = function(self, entry)
      local row = entry.value
      local buf, win = self.state.bufnr, self.state.winid
      local width = (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_width(win) or 80
      local function paint(items, err)
        -- A buffer per preview, so a late answer can only ever land in the
        -- buffer it was asked for -- which may no longer be on screen, and
        -- that is fine.
        if not api.nvim_buf_is_valid(buf) then
          return
        end
        require("paseo.ui.render").to_buffer(buf, ns, 0, -1, M.preview_lines(row, items, width, err))
        vim.bo[buf].modifiable = false
        -- A chat's END is the news; a prompt's preview starts at the prompt.
        if items and row.kind ~= "prompt" and win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
          pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(buf), 0 })
        end
      end
      paint(nil)
      preview_items(row, cache, paint)
    end,
  }

  local picker = pickers.new({}, {
    prompt_title = "Paseo search · " .. scope.label,
    results_title = "workspaces · agents · prompts · past chats",
    finder = finder(rows),
    sorter = conf.generic_sorter {},
    previewer = previewer,
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          vim.schedule(function()
            M.pick(entry.value)
          end)
        end
      end)
      return true
    end,
  })
  picker:find()
  if extra then
    return
  end

  M.gather(live_agents(scope), function(prompts, archived)
    vim.schedule(function()
      -- Still open? `<Esc>` before the last answer leaves nothing to refresh.
      if not (picker.prompt_bufnr and api.nvim_buf_is_valid(picker.prompt_bufnr)) then
        return
      end
      picker:refresh(finder(snapshot(scope, { prompts = prompts, archived = archived })), {
        reset_prompt = false,
      })
    end)
  end, scope)
end

---Without telescope: the plugin's own chooser. No sorter and no preview, but
---every row, and `/` searches them.
---@param scope paseo.SearchScope
---@param extra? { prompts?: table, archived?: table[] }
local function fallback(scope, extra)
  local choose = require "paseo.ui.choose"
  local function items(rows)
    local out = {}
    for i, row in ipairs(rows) do
      out[i] = {
        id = row.key,
        value = row,
        cells = {
          { ("%-8s "):format(M.TAGS[row.kind]), "PaseoDim" },
          { row.mark .. " ", row.mark_hl },
          { row.title, "PaseoText" },
        },
        right = { { row.detail, "PaseoDim" } },
      }
    end
    return out
  end
  local handle = choose.open {
    title = "Paseo search · " .. scope.label,
    prompt = "install telescope.nvim to fuzzy-match these, with a preview",
    items = items(snapshot(scope, extra)),
    numbers = false,
    on_pick = function(item)
      M.pick(item.value)
    end,
  }
  if extra then
    return
  end
  M.gather(live_agents(scope), function(prompts, archived)
    vim.schedule(function()
      if handle and not handle.closed then
        handle.update(items(snapshot(scope, { prompts = prompts, archived = archived })))
      end
    end)
  end, scope)
end

---Is telescope there to use?
---@return boolean
function M.has_telescope()
  return (pcall(require, "telescope.pickers"))
end

---@param scope paseo.SearchScope
---@param extra? { prompts?: table, archived?: table[] }
local function show(scope, extra)
  if M.has_telescope() then
    telescope(scope, extra)
  else
    fallback(scope, extra)
  end
end

---`:Paseo search`: open it, on this project (`all`: on every project).
---
---With nothing live here, the history decides: this project's past chats
---alone are worth a list, and with none of those either it says so rather
---than opening on nothing -- or on everything.
---@param opts? { all?: boolean, root?: string }
function M.open(opts)
  opts = opts or {}
  if api.nvim_get_mode().mode ~= "n" then
    pcall(vim.cmd.stopinsert)
  end
  local agents = require "paseo.agents"
  agents.watch_all(function()
    require("paseo.workspaces").list_all(function(list)
      vim.schedule(function()
        local scope = M.scope(list or {}, opts)
        if scope.all or #scope.workspaces > 0 or #live_agents(scope) > 0 then
          return show(scope)
        end
        M.gather({}, function(prompts, archived, known)
          vim.schedule(function()
            if #archived > 0 then
              return show(scope, { prompts = prompts, archived = archived })
            end
            local why = known and ("nothing to search in %s yet"):format(scope.label)
              or ("%s is not in a Paseo project"):format(vim.fn.fnamemodify(scope.root, ":~"))
            vim.notify("paseo: " .. why .. " — `:Paseo search all` searches every project", vim.log.levels.INFO)
          end)
        end, scope)
      end)
    end)
  end)
end

return M
