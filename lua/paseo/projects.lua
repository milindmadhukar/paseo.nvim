--- When a folder becomes a Paseo project.
---
--- THE DAEMON NEVER ASKS. The first session started in a directory it has not
--- seen registers that directory as a project, so `nvim ~`, `a` and a prompt
--- used to make your home directory one -- found out later, in the app's
--- sidebar. This module is the one place that decides, before anything is
--- created:
---
---   `/`, `$HOME`, or above it   refused: no session starts
---   known to the daemon         goes, as it always did
---   a git repo, or a worktree   goes: that is a project whatever is said
---   under a ws manifest         goes: the manifest says so already
---   anything else               asked, once: "Add … to Paseo as a project?"
---
--- Once added the daemon knows it, so it is never asked again; remove the
--- project and it is asked again, which is the point. See |paseo-new-folder|.

local M = {}

---@param path string|nil
---@return string
local function normalise(path)
  if not path or path == "" then
    return ""
  end
  return (vim.fn.resolve(vim.fn.fnamemodify(vim.fn.expand(path), ":p")):gsub("/+$", ""))
end

---What kind of directory `root` is, from the disk alone.
---@param root string  A LOCAL directory: the project root, as |paseo.workspaces|.here answers.
---@return "refuse"|"repo"|"manifest"|"plain"
function M.classify(root)
  local dir = normalise(root)
  local home = normalise(vim.env.HOME or vim.uv.os_homedir())
  if dir == "" or dir == "/" or dir == home or vim.startswith(home .. "/", dir .. "/") then
    return "refuse"
  end
  if require("paseo.registry").project_root(dir) then
    return "manifest"
  end
  if require("paseo.gitfs").main_checkout(dir) then
    return "repo"
  end
  return "plain"
end

-- ------------------------------------------------------------- the daemon

---Per host: the roots the daemon has, and when that was asked. A hit is kept
---until something changes it (`M.invalidate`); a miss is asked again after a
---few seconds, so a project added from the app is seen without a restart.
---@type table<string, { roots: table<string, string>, at: number }>
local cache = {}
local MISS_TTL = 5000

---@param host_id? string
---@return string
local function key(host_id)
  return host_id or "local"
end

---Forget what the daemon said, for `host_id` (or every host): after a
---session is created, or a project removed.
---@param host_id? string
function M.invalidate(host_id)
  if host_id then
    cache[key(host_id)] = nil
  else
    cache = {}
  end
end

---Does the daemon on `host_id` have a project at `root` (its own path)?
---
---`cb(true|false)`, or `cb(nil, err)` when it could not be asked.
---@param root string
---@param host_id? string
---@param cb fun(known: boolean|nil, err: string|nil)
function M.known(root, host_id, cb)
  local want = normalise(root)
  local hit = cache[key(host_id)]
  if hit and (hit.roots[want] or (vim.uv.now() - hit.at) < MISS_TTL) then
    return cb(hit.roots[want] ~= nil)
  end
  require("paseo.bridge").request("project.list", {}, function(err, result)
    vim.schedule(function()
      if err then
        return cb(nil, tostring(err))
      end
      local roots = {}
      for _, p in ipairs((result or {}).projects or {}) do
        if p.root then
          roots[normalise(p.root)] = p.id or true
        end
      end
      cache[key(host_id)] = { roots = roots, at = vim.uv.now() }
      cb(roots[want] ~= nil)
    end)
  end, host_id)
end

---Say the daemon has `root` now -- a "yes" to the question, so a start that
---fails after it does not ask again.
---@param root string
---@param host_id? string
local function accept(root, host_id)
  local entry = cache[key(host_id)] or { roots = {}, at = vim.uv.now() }
  entry.roots[normalise(root)] = entry.roots[normalise(root)] or true
  cache[key(host_id)] = entry
end

-- ---------------------------------------------------------------- the gate

---@class paseo.ProjectWhere
---@field root string        Where it starts, as the daemon sees it.
---@field local_root? string The same directory on this machine.
---@field host_id? string

---Where `where` is, on this machine and on the daemon: the project root in
---both spellings, or nil when there is no local directory to judge.
---@param where paseo.ProjectWhere
---@return string|nil local_project, string|nil daemon_project
function M.resolve(where)
  local hosts = require "paseo.hosts"
  local host = hosts.get(where.host_id)
  local remote = host ~= nil and not host.local_host
  local dir = where.local_root or (not remote and where.root) or (remote and hosts.to_local(host.id, where.root))
  if not dir or dir == "" then
    return nil, nil
  end
  local project = require("paseo.workspaces").here(dir)
  if not remote then
    return project, project
  end
  return project, hosts.to_remote(host.id, project)
end

---What starting a session at `where` would do to the project list, as one
---word: "go" (nothing to ask), "ask" (a folder the daemon has never seen), or
---"refuse". `cb(verdict, local_project)`.
---@param where paseo.ProjectWhere
---@param cb fun(verdict: "go"|"ask"|"refuse", project: string|nil)
function M.verdict(where, cb)
  local project, daemon_root = M.resolve(where)
  if not project then
    -- A remote directory with no local spelling: nothing to judge it by on
    -- this disk, so it is left to the daemon, as it always was.
    return cb("go", nil)
  end
  local kind = M.classify(project)
  if kind == "refuse" then
    return cb("refuse", project)
  end
  if kind ~= "plain" then
    return cb("go", project)
  end
  M.known(daemon_root or project, where.host_id, function(known)
    -- Could not ask: ask YOU, rather than add it unseen or refuse outright.
    cb(known and "go" or "ask", project)
  end)
end

---Before anything that would make a session at `where`: refuse, ask, or go.
---
---`cb(true)` to go ahead; `cb(false, "cancelled")` when refused or declined
----- said here already, so the caller only has to hand the draft back.
---@param where paseo.ProjectWhere
---@param cb fun(ok: boolean, err: string|nil)
function M.ensure(where, cb)
  M.verdict(where, function(verdict, project)
    local label = project and vim.fn.fnamemodify(project, ":~") or "this folder"
    if verdict == "go" then
      return cb(true)
    end
    if verdict == "refuse" then
      vim.notify(("paseo: %s is not a project — :cd into one first"):format(label), vim.log.levels.WARN)
      return cb(false, "cancelled")
    end
    -- By its NAME: a chooser is narrow, and a long path loses its end -- the
    -- part that says which folder. The whole path is on the screen behind.
    require("paseo.ui.pick").confirm(
      ("Add %s to Paseo as a project?"):format(project and vim.fs.basename(project) or label),
      { yes = "Add it" },
      function(yes)
        if not yes then
          return cb(false, "cancelled")
        end
        local _, daemon_root = M.resolve(where)
        accept(daemon_root or project, where.host_id)
        cb(true)
      end
    )
  end)
end

return M
