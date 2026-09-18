--- Workspaces, as Paseo sees them.
---
--- PASEO IS THE SOURCE OF TRUTH. A workspace created in the app, or by
--- `paseo workspace create`, is exactly as real as one this plugin assembled --
--- listing only our own registry made half of them invisible.
---
--- Our registry adds one thing Paseo cannot know: that a given directory is
--- several worktrees rather than one checkout. So the two are merged, keyed on
--- the directory.

local bridge = require "paseo.bridge"
local registry = require "paseo.registry"

local M = {}

---@class paseo.PaseoWorkspace
---@field id string
---@field name string
---@field directory string
---@field project string
---@field kind string          "directory" | "worktree"
---@field status string
---@field branch string|nil
---@field ownedWorktree boolean  Paseo cut this worktree itself.
---@field members { name: string, path: string }[]  From our registry; may be empty.
---@field assembled boolean    We assembled it out of N worktrees.

---@param path string|nil
---@return string
local function normalise(path)
  if not path or path == "" then
    return ""
  end
  return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

---Every workspace, Paseo's merged with ours.
---@param callback fun(list: paseo.PaseoWorkspace[]|nil, err: string|nil)
function M.list(callback)
  bridge.ensure(function(err)
    if err then
      return callback(nil, err)
    end

    bridge.request("workspaces.list", { limit = 200 }, function(list_err, result)
      if list_err then
        return callback(nil, list_err)
      end

      -- Our registry, indexed by directory, so a Paseo workspace pointed at an
      -- assembled directory picks up its members.
      local assembled = {}
      for _, ws in ipairs(registry.list()) do
        assembled[normalise(ws.root)] = ws
      end

      local out = {}
      for _, ws in ipairs(result.entries or {}) do
        if not ws.archivingAt then
          local ours = assembled[normalise(ws.directory)]
          out[#out + 1] = vim.tbl_extend("force", ws, {
            members = ours and registry.active(ours) or {},
            assembled = ours ~= nil,
          })
        end
      end

      table.sort(out, function(a, b)
        if (a.project or "") ~= (b.project or "") then
          return (a.project or "") < (b.project or "")
        end
        return (a.name or "") < (b.name or "")
      end)
      callback(out, nil)
    end)
  end)
end

---Create a workspace.
---
---If the directory's project has a manifest, the worktrees are ASSEMBLED first
---and Paseo is pointed at the result. Otherwise Paseo is asked for a plain
---workspace on the directory. Either way it ends up as an ordinary Paseo
---workspace -- that is the seam.
---@param opts { name: string, root?: string }
---@param callback fun(id: string|nil, err: string|nil)
function M.create(opts, callback)
  local root = opts.root or assert(vim.uv.cwd())
  local project = registry.project_root(root)

  local directory = root
  if project then
    local manifest = require("paseo.workspace.manifest").load(project)
    if manifest then
      if registry.find(opts.name, project) then
        return callback(nil, ("a workspace called %q already exists here"):format(opts.name))
      end
      local ws, err =
        require("paseo.workspace").create(manifest, { name = opts.name, root = project })
      if not ws then
        return callback(nil, err)
      end
      registry.add(ws)
      directory = ws.root
    end
  end

  bridge.ensure(function(err)
    if err then
      return callback(nil, err)
    end
    -- `open` rather than `create`: it reuses the active workspace for that
    -- exact directory, so assembling twice does not litter the app with
    -- duplicates pointing at the same place.
    bridge.request("workspace.open", { cwd = directory }, function(open_err, result)
      if open_err then
        return callback(nil, open_err)
      end
      callback(result.id, nil)
    end)
  end)
end

---Archive a workspace, and dismantle its worktrees if we assembled them.
---@param ws paseo.PaseoWorkspace
---@param opts? { force: boolean }
---@param callback fun(err: string|nil)
function M.archive(ws, opts, callback)
  opts = opts or {}

  -- Ours first: `workspace.remove` refuses when a member holds work that
  -- exists nowhere else, and that refusal must not be lost behind an archive
  -- that already happened.
  if ws.assembled then
    local ours
    for _, entry in ipairs(registry.list()) do
      if normalise(entry.root) == normalise(ws.directory) then
        ours = entry
      end
    end
    if ours then
      local ok, err = require("paseo.workspace").remove(ours, { force = opts.force })
      if not ok then
        return callback(err)
      end
      registry.remove(ours.name, ours.project)
    end
  end

  bridge.request("workspace.archive", { workspaceId = ws.id }, function(err)
    callback(err)
  end)
end

---Sessions -- the agents -- in a workspace.
---@param ws paseo.PaseoWorkspace
---@param callback fun(sessions: table[]|nil, err: string|nil)
function M.sessions(ws, callback)
  bridge.ensure(function(err)
    if err then
      return callback(nil, err)
    end
    bridge.request("agents.list", { limit = 200 }, function(list_err, result)
      if list_err then
        return callback(nil, list_err)
      end
      local dir = normalise(ws.directory)
      local out = {}
      for _, agent in ipairs(result.entries or {}) do
        -- Matched on workspaceId when the daemon reports one, and on directory
        -- otherwise: agents created before this plugin existed have a cwd but
        -- may predate the workspace they now sit in.
        if agent.workspaceId == ws.id or normalise(agent.cwd) == dir then
          out[#out + 1] = agent
        end
      end
      table.sort(out, function(a, b)
        return (a.title or a.id) < (b.title or b.id)
      end)
      callback(out, nil)
    end)
  end)
end

---Start a new session in a workspace.
---@param ws paseo.PaseoWorkspace
---@param opts? { title?: string }
---@param callback fun(id: string|nil, err: string|nil)
function M.new_session(ws, opts, callback)
  opts = opts or {}
  bridge.request("agent.create", {
    workspaceId = ws.id,
    provider = require("paseo.config").get().paseo.provider,
    title = opts.title,
  }, function(err, result)
    callback(result and result.id, err)
  end)
end

return M
