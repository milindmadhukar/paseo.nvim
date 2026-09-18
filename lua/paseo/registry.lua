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

---Drop the cache. Called after `ws create`/`ws rm`, which change the file
---behind our back.
function M.invalidate()
  cache = { mtime = nil, data = nil, path = nil }
end

return M
