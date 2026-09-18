--- Reading `ws`'s registry.
---
--- THE ONLY FILE LUA READS DIRECTLY. Everything else about workspaces goes
--- through `ws … --json`, but a picker cannot afford a fork just to draw its
--- rows -- so this one file is parsed in-process and cached on mtime.

local M = {}

local cache = { mtime = nil, data = nil, path = nil }

---@return string
function M.path()
  local state = vim.env.XDG_STATE_HOME
  if not state or state == "" then
    state = vim.fs.joinpath(vim.env.HOME, ".local", "state")
  end
  return vim.fs.joinpath(state, "ws", "registry.json")
end

---@class paseo.Workspace
---@field name string
---@field project string
---@field root string
---@field branch string
---@field repos { name: string, path: string, origin: string, branch: string, base: string?, state: string }[]
---@field paseoWorkspaceId string?
---@field createdAt string

---Every workspace `ws` knows about.
---
---An absent registry is not an error: it means `ws` has never run, which is the
---normal state for someone using only the review half of this plugin.
---@return paseo.Workspace[]
function M.list()
  local path = M.path()
  local stat = vim.uv.fs_stat(path)
  if not stat then
    cache = { mtime = nil, data = nil, path = path }
    return {}
  end

  local mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec
  if cache.path == path and cache.mtime == mtime and cache.data then
    return cache.data
  end

  local fd = io.open(path, "r")
  if not fd then
    return {}
  end
  local text = fd:read "*a"
  fd:close()

  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    vim.notify("paseo: " .. path .. " is not valid JSON", vim.log.levels.WARN)
    return {}
  end

  local workspaces = decoded.workspaces or {}
  cache = { mtime = mtime, data = workspaces, path = path }
  return workspaces
end

---The workspace containing `path`, if any.
---@param path? string  Defaults to the cwd.
---@return paseo.Workspace|nil
function M.containing(path)
  local target =
    vim.fn.resolve(vim.fn.fnamemodify(path or assert(vim.uv.cwd()), ":p")):gsub("/+$", "")
  for _, ws in ipairs(M.list()) do
    local root = vim.fn.resolve(ws.root):gsub("/+$", "")
    if target == root or vim.startswith(target, root .. "/") then
      return ws
    end
  end
  return nil
end

---Active members of a workspace.
---@param ws paseo.Workspace
---@return { name: string, path: string }[]
function M.active(ws)
  local out = {}
  for _, repo in ipairs(ws.repos or {}) do
    if repo.state == "active" and repo.path and repo.path ~= "" then
      out[#out + 1] = repo
    end
  end
  return out
end

---Drop the cache.
function M.invalidate()
  cache = { mtime = nil, data = nil, path = nil }
end

---Write the registry ATOMICALLY: a temp file and a rename.
---
---Two Neovim instances, one per workspace, is the intended way to use this --
---so concurrent writers are ordinary rather than exceptional, and a
---half-written registry loses every workspace rather than one.
---@param workspaces paseo.Workspace[]
---@return boolean ok, string|nil err
local function save(workspaces)
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  table.sort(workspaces, function(a, b)
    if a.project ~= b.project then
      return a.project < b.project
    end
    return a.name < b.name
  end)

  local temp = path .. ".tmp." .. vim.uv.getpid()
  local fd, err = io.open(temp, "w")
  if not fd then
    return false, err
  end
  fd:write(vim.json.encode { version = 1, workspaces = workspaces } .. "\n")
  fd:close()

  local ok, rename_err = vim.uv.fs_rename(temp, path)
  M.invalidate()
  return ok == true, rename_err
end

---Record a workspace, replacing any entry with the same name and project.
---@param ws paseo.Workspace
---@return boolean ok, string|nil err
function M.add(ws)
  local all = vim.deepcopy(M.list())
  for index, existing in ipairs(all) do
    if existing.name == ws.name and existing.project == ws.project then
      all[index] = ws
      return save(all)
    end
  end
  all[#all + 1] = ws
  return save(all)
end

---Drop a workspace.
---@param name string
---@param project? string
---@return boolean removed
function M.remove(name, project)
  local all = vim.deepcopy(M.list())
  for index, ws in ipairs(all) do
    if ws.name == name and (not project or ws.project == project) then
      table.remove(all, index)
      save(all)
      return true
    end
  end
  return false
end

---The workspace with this name.
---@param name string
---@param project? string
---@return paseo.Workspace|nil
function M.find(name, project)
  for _, ws in ipairs(M.list()) do
    if ws.name == name and (not project or ws.project == project) then
      return ws
    end
  end
  return nil
end

---The nearest ancestor of `start` holding a manifest.
---@param start? string
---@return string|nil
function M.project_root(start)
  local dir = vim.fn.fnamemodify(start or assert(vim.uv.cwd()), ":p")
  local manifest = require "paseo.workspace.manifest"
  while dir and dir ~= "/" do
    if vim.uv.fs_stat(manifest.path(dir)) then
      return (dir:gsub("/+$", ""))
    end
    dir = vim.fs.dirname(dir)
  end
  return nil
end

return M
