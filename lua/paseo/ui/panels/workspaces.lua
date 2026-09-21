--- Workspaces and repos: the other half of the plugin, on the dashboard.
---
--- The full-screen surface is meant to be the whole of Paseo without the app,
--- and until this panel existed it stopped at the session -- everything about
--- the unit of work the session runs IN was only reachable through a telescope
--- picker, which is a different window, over the top, that you have to dismiss.
---
--- Read-mostly. Clicking a workspace opens a chat on it; creating one and the
--- full picker hand off to the commands that already do that properly, rather
--- than reimplementing the manifest dance in a panel.
---
--- The two destructive acts the app offers are here too, and they are
--- deliberately in different places: ARCHIVE retires one workspace and sits on
--- that workspace's row, under the pointer only; FORGET PROJECT drops Paseo's
--- record of a directory tree and sits on the group heading, beside the name it
--- would remove. Putting both on a row would make them read as two strengths of
--- the same act, which they are not.

local agents = require "paseo.agents"

local icons = require "paseo.ui.icons"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Workspaces"

---Module-level rather than per-chat: the list is the DAEMON's, identical for
---every chat, and a fetch per chat would be a round trip per chat for the same
---answer.
---@type { list: table[]|nil, err: string|nil }|nil
local cache
local loading = false

---Ask the daemon, then redraw.
---@param _chat? table  Unused: the list is the daemon's, not a chat's.
function M.load(_chat)
  if loading then
    return
  end
  loading = true
  -- The status column is push-fed; without a subscription every row reads "…"
  -- forever. Idempotent, so calling it on every panel open is free.
  agents.watch()
  require("paseo.workspaces").list(function(list, err)
    loading = false
    cache = { list = list, err = err }
    vim.schedule(function()
      require("paseo.ui.float").rebuild()
    end)
  end)
end

---Forget what we fetched, so the next draw asks again.
function M.invalidate()
  cache = nil
end

---Buffer line -> what is on it, rebuilt on every draw.
---
---A map rather than arithmetic on the cursor row, for the reason the Sessions
---panel gives: computing `row - <however many heading rows there happen to
---be>` means adding a line to the heading silently retargets a destructive
---key. Here the headings are data-dependent, so there is no constant to get
---wrong in the first place.
---@type table<integer, { kind: "workspace"|"group", ws: table|nil, name: string|nil,
---                       projects: string[]|nil }>
M._rows = {}

---@return integer  The buffer line the panel's first line is drawn on.
local function offset()
  return require("paseo.ui.float").body_row_offset()
end

---What the cursor is on.
---@return table|nil
local function under_cursor()
  local win = vim.api.nvim_get_current_win()
  return M._rows[vim.api.nvim_win_get_cursor(win)[1]]
end

---The group a cursor row belongs to, whether it is on the heading or on one
---of the workspaces under it.
---@param row table|nil
---@return table|nil
local function group_of(row)
  if not row then
    return nil
  end
  if row.kind == "group" then
    return row
  end
  local key = row.ws and (row.ws.group or row.ws.project)
  if not key then
    return nil
  end
  for _, entry in pairs(M._rows) do
    if entry.kind == "group" and entry.name == key then
      return entry
    end
  end
  return nil
end

---@param ws table
---@return string
local function shape(ws)
  if ws.assembled then
    return ("%d repos"):format(#(ws.members or {}))
  end
  return ws.ownedWorktree and "worktree" or "local"
end

---@param chat table
---@param width integer
---@return table[][]
function M.lines(chat, width)
  if not cache then
    M.load()
    return { { { "  loading workspaces…", "PaseoDim" } } }
  end
  if cache.err then
    return {
      { { "  " .. cache.err, "PaseoToolFail" } },
      {},
      {
        { "  :checkhealth paseo", "PaseoKey" },
        { " reports every endpoint it tried", "PaseoDim" },
      },
    }
  end

  local here = vim.fn.resolve(vim.fn.fnamemodify(chat.root, ":p")):gsub("/+$", "")
  local list = cache.list or {}
  M._rows = {}

  -- GROUPED, the way the app groups them, and NOT the way the daemon reports
  -- them. A `ws` workspace at `<project>/.workspaces/<name>` is a plain
  -- directory, so the daemon registers it as its own top-level project named
  -- after the workspace -- which drew `billing` as a sibling of `openfin`
  -- rather than as something inside it. `workspaces.group` recovers the real
  -- parent from the path; the list arrives already sorted by it.
  local groups, order = {}, {}
  for _, ws in ipairs(list) do
    local key = ws.group or ws.project or ""
    if not groups[key] then
      groups[key] = { name = key, rows = {}, projects = {} }
      order[#order + 1] = key
    end
    local group = groups[key]
    group.rows[#group.rows + 1] = ws
    -- A group can span SEVERAL daemon projects -- the real one and every
    -- invented one under it -- and removing the group has to mean all of them.
    if ws.projectId and not vim.tbl_contains(group.projects, ws.projectId) then
      group.projects[#group.projects + 1] = ws.projectId
    end
  end

  -- Widths from the data, not guessed: names run from `ui` to
  -- `Fetch latest and prune merged branches`, and a fixed column is either
  -- ragged or truncating.
  local w_name = 0
  for _, ws in ipairs(list) do
    w_name = math.max(w_name, vim.api.nvim_strwidth(ws.name or ""))
  end
  w_name = math.min(w_name, 34)

  local lines = {
    {
      { "  " .. icons.panel.Workspaces .. "  ", "PaseoBlue1" },
      { "Workspaces", "PaseoHeader" },
    },
    {},
  }

  if #list == 0 then
    lines[#lines + 1] = { { "  no workspaces yet", "PaseoDim" } }
  end

  for _, key in ipairs(order) do
    local group = groups[key]

    -- The group heading, with the project's own swatch on it. Removing the
    -- project is offered HERE, beside the name it would remove, rather than
    -- on a workspace row -- where it would read as an action on that
    -- workspace and would be the wrong act entirely.
    local remove_id = "workspaces.project." .. key
    local remove = function()
      require("paseo.workspaces").remove_project(group.projects, key, function()
        M.invalidate()
        require("paseo.ui.float").rebuild()
      end)
    end
    local heading = {
      { "  " },
      widgets.swatch(key),
      { " " .. key, "PaseoHeader" },
    }
    -- ONLY UNDER THE POINTER. A destructive action spelled out on every group
    -- heading, permanently, is three invitations to lose a project record in
    -- a list you are reading for something else. The key -- `x` -- is how you
    -- get here without a mouse, and it is advertised once, at the bottom.
    if #group.projects > 0 and widgets.hovered(remove_id) then
      heading[#heading + 1] = { "  " .. icons.ui.remove, "PaseoToolFail", remove }
      heading[#heading + 1] = { " forget project", "PaseoDim", remove }
    end
    if #group.projects > 0 then
      lines[#lines + 1] = widgets.hovered(remove_id)
          and widgets.fill_row(heading, width, "PaseoRowHover")
        or heading
      for _, cell in ipairs(lines[#lines]) do
        cell[3] = cell[3] or widgets.hover(remove_id, "body")
      end
    else
      lines[#lines + 1] = heading
    end
    -- AFTER the append, so `#lines` is this line's own panel index. Panel
    -- line `i` is drawn on buffer line `i + offset()`; an entry recorded one
    -- line early puts `d` on a group heading over the first workspace under
    -- it, which archives the wrong thing without ever looking wrong.
    M._rows[#lines + offset()] = { kind = "group", name = key, projects = group.projects }

    for _, ws in ipairs(group.rows) do
      local dir = vim.fn.resolve(ws.directory or ""):gsub("/+$", "")
      local mine = dir ~= "" and (here == dir or vim.startswith(here, dir .. "/"))
      local open = function()
        if not ws.directory or ws.directory == "" then
          return vim.notify("paseo: that workspace has no directory", vim.log.levels.WARN)
        end
        require("paseo.ui.chat").open { root = ws.directory, title = ws.name }
      end
      local archive = function()
        require("paseo.workspaces").confirm_archive(ws, function()
          M.invalidate()
          require("paseo.ui.float").rebuild()
        end)
      end

      local id = "workspaces." .. (ws.directory or ws.name or "")
      local action = widgets.hover(id, "body", open)
      local row = {
        { mine and "    " .. widgets.icons.mine .. " " or "      ", mine and "PaseoAgent" or nil },
        { ("%-" .. w_name .. "s  "):format(ws.name or ""), mine and "PaseoAgent" or nil },
        { ("%-9s"):format(shape(ws)), "PaseoBadge" },
        { "  " .. agents.summary(ws.directory or ""), "PaseoDim" },
      }
      -- Archiving is offered only on the row under the pointer: a column of
      -- destructive glyphs down the side of a list is a column of mistakes.
      if widgets.hovered(id) then
        row[#row + 1] = { "   " .. icons.ui.archive .. " archive", "PaseoDim", archive }
      end

      local row_hl = widgets.row_hl(id, mine)
      if row_hl then
        lines[#lines + 1] = widgets.fill_row(row, width, row_hl, action)
        -- `fill_row` gives every cell the row's own action; the archive cell
        -- keeps the one it came with.
        for _, cell in ipairs(lines[#lines]) do
          if (cell[1] or ""):find("archive", 1, true) then
            cell[3] = archive
          end
        end
      else
        for _, cell in ipairs(row) do
          cell[3] = cell[3] or action
        end
        lines[#lines + 1] = row
      end
      M._rows[#lines + offset()] = { kind = "workspace", ws = ws }
    end

    lines[#lines + 1] = {}
  end

  local new = function()
    require("paseo.pickers.workspaces").create()
  end
  local picker = function()
    require("paseo.pickers.workspaces").open()
  end
  lines[#lines + 1] = {
    { "  " .. icons.ui.new .. " ", "PaseoKey", new },
    { "new workspace here", "PaseoDim", new },
    { "      " .. icons.ui.more .. " ", "PaseoKey", picker },
    { "open, sessions, archive", "PaseoDim", picker },
  }
  -- The keys, said once. The row affordances are for the pointer; this is for
  -- everyone else, and it is why `forget project` is not written out three
  -- times above.
  lines[#lines + 1] = {
    { "      " },
    { "<CR>", "PaseoKey" },
    { " open · ", "PaseoDim" },
    { "d", "PaseoKey" },
    { " archive · ", "PaseoDim" },
    { "x", "PaseoKey" },
    { " forget project", "PaseoDim" },
  }

  -- The repos of the unit of work this session is in -- `:Paseo repos`, which
  -- is otherwise a notification you have to ask for.
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  " .. icons.ui.repo .. "  ", "PaseoBlue1" },
    { "This unit of work", "PaseoHeader" },
  }
  lines[#lines + 1] = {}
  local repos = require("paseo.repos").list { path = chat.root }
  if #repos == 0 then
    lines[#lines + 1] = { { "    not inside a git repository", "PaseoDim" } }
  end
  for _, repo in ipairs(repos) do
    lines[#lines + 1] = {
      { "    " },
      widgets.swatch(repo.name),
      { " " .. repo.name, nil },
      { "   " .. vim.fn.fnamemodify(repo.worktree, ":~"), "PaseoPath" },
    }
  end

  return lines
end

---What this panel has bound on the shared chrome buffer.
---@type table[]|nil
local bound

---@param _chat table
---@param buf integer
function M.attach(_chat, buf)
  local function refresh()
    M.invalidate()
    require("paseo.ui.float").rebuild()
  end

  -- Through |paseo.ui.keys|, which gives back what it displaced: the panels
  -- share one chrome buffer and volt binds `<CR>` on it at open, so deleting
  -- our own would leave the key dead on every other tab.
  bound = require("paseo.ui.keys").take(buf, {
    {
      "<CR>",
      function()
        local row = under_cursor()
        local ws = row and row.ws
        if not (ws and ws.directory and ws.directory ~= "") then
          return
        end
        require("paseo.ui.chat").open { root = ws.directory, title = ws.name }
      end,
      "paseo: open this workspace",
    },
    {
      "d",
      function()
        local row = under_cursor()
        if not (row and row.ws) then
          return
        end
        require("paseo.workspaces").confirm_archive(row.ws, refresh)
      end,
      "paseo: archive this workspace",
    },
    -- A different key from `d` on purpose. Archiving retires one unit of work
    -- and forgetting drops the daemon's record of a whole tree; one key that
    -- did both depending on which line you were on is the shape of a mistake.
    {
      "x",
      function()
        local group = group_of(under_cursor())
        if not (group and group.projects and #group.projects > 0) then
          return
        end
        require("paseo.workspaces").remove_project(group.projects, group.name, refresh)
      end,
      "paseo: forget this project",
    },
  })
end

---@param _chat table
---@param buf integer
function M.detach(_chat, buf)
  local saved = bound
  bound = nil
  require("paseo.ui.keys").release(buf, saved)
end

return M
