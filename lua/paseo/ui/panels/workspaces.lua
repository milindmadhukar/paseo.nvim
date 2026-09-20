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

  -- Widths from the data, not guessed: project names run from `kora` to
  -- `openfin` and a fixed column is either ragged or truncating.
  local w_project, w_name = 0, 0
  for _, ws in ipairs(list) do
    w_project = math.max(w_project, vim.api.nvim_strwidth(ws.project or ""))
    w_name = math.max(w_name, vim.api.nvim_strwidth(ws.name or ""))
  end
  w_project = math.min(w_project, 20)
  w_name = math.min(w_name, 28)

  local lines = { { { "  Workspaces", "PaseoHeader" } }, {} }

  if #list == 0 then
    lines[#lines + 1] = { { "  no workspaces yet", "PaseoDim" } }
  end

  for _, ws in ipairs(list) do
    local dir = vim.fn.resolve(ws.directory or ""):gsub("/+$", "")
    local mine = dir ~= "" and (here == dir or vim.startswith(here, dir .. "/"))
    local click = function()
      if not ws.directory or ws.directory == "" then
        return vim.notify("paseo: that workspace has no directory", vim.log.levels.WARN)
      end
      require("paseo.ui.chat").open { root = ws.directory, title = ws.name }
    end
    local id = "workspaces." .. (ws.directory or ws.name or "")
    local action = widgets.hover(id, "body", click)
    local row = {
      { mine and "  " .. widgets.icons.mine .. " " or "    ", mine and "PaseoAgent" or nil },
      -- A swatch per project, hashed off its name, so a list of twenty
      -- workspaces groups by eye before it is read.
      widgets.swatch(ws.project or ws.name or ""),
      { " " .. ("%-" .. w_project .. "s  "):format(ws.project or ""), "PaseoDim" },
      { ("%-" .. w_name .. "s  "):format(ws.name or ""), mine and "PaseoAgent" or nil },
      { ("%-9s"):format(shape(ws)), "PaseoBadge" },
      { "  " .. agents.summary(ws.directory or ""), "PaseoDim" },
    }

    local row_hl = widgets.row_hl(id, mine)
    if row_hl then
      lines[#lines + 1] = widgets.fill_row(row, width, row_hl, action)
    else
      for _, cell in ipairs(row) do
        cell[3] = action
      end
      lines[#lines + 1] = row
    end
  end

  lines[#lines + 1] = {}
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

  -- The repos of the unit of work this session is in -- `:Paseo repos`, which
  -- is otherwise a notification you have to ask for.
  lines[#lines + 1] = {}
  lines[#lines + 1] = { { "  This unit of work", "PaseoHeader" } }
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

return M
