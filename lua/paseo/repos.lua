--- The repo list.
---
--- CONSTRAINT, and the reason this module exists at all in a single-repo
--- feature set: `list()` returns a LIST of repos, even when there is exactly
--- one. Every caller -- the changed-files picker, the hunk quickfix builder,
--- the review tabs -- iterates it. Widening a workspace from one member to six
--- then changes this file and nothing else.
---
--- A "workspace" is one named unit of work spanning N git worktrees. It is a
--- directory `<project>/<config.workspaces.dir>/<name>/` and it is detected
--- from the filesystem, not from a registry: either that directory is itself a
--- worktree (a single-repo project), or its immediate children are (a
--- multi-repo project). Nothing needs to have created it for the detection to
--- work, which is what keeps this usable before `ws` exists.

local config = require "paseo.config"

local M = {}

---@class paseo.Repo
---@field name string     Display name. Derived from the COMMON dir, not the
---                       worktree's basename: a linked worktree is named after
---                       the workspace ("otp-rate-limit"), and what a picker
---                       row needs to say is which repo it is ("clm_api").
---@field worktree string Absolute path to the working tree, no trailing slash.
---@field gitdir string   Absolute path to the git dir. For a linked worktree
---                       this is `<repo>/.git/worktrees/<name>`, NOT the
---                       common dir -- which is the point: it is per-worktree,
---                       so it identifies the member.

---Resolved-path cache. `git rev-parse` is only a few milliseconds, but a
---picker's entry_maker calls this once per row and a quickfix builder once per
---hunk, so the fork tax adds up fast. Cleared by `invalidate()`.
---@type table<string, paseo.Repo|false>
local cache = {}

---@param args string[]
---@param cwd string
---@return string|nil stdout, trimmed; nil on any failure
local function git(args, cwd)
  local cmd = vim.list_extend({ "git", "-C", cwd }, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return (res.stdout or ""):gsub("%s+$", "")
end

---@param path string
---@return string absolute, symlink-resolved, no trailing slash
local function normalise(path)
  local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  -- resolve() follows symlinks, which matters because git reports real paths
  -- and a `~/Code` that is itself a symlink would otherwise never match.
  return (vim.fn.resolve(abs):gsub("/+$", ""))
end

---The git repository containing `path`, or nil if there is none.
---@param path? string  File or directory. Defaults to the current buffer's
---                     directory, falling back to the cwd.
---@return paseo.Repo|nil
function M.resolve(path)
  path = path and normalise(path) or nil

  if not path then
    local name = vim.api.nvim_buf_get_name(0)
    path = (name ~= "" and vim.bo.buftype == "") and normalise(vim.fs.dirname(name))
      or normalise(assert(vim.uv.cwd()))
  end

  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)

  local hit = cache[dir]
  if hit ~= nil then
    return hit or nil
  end

  -- One fork for all three. --path-format=absolute is what makes
  -- --git-common-dir absolute; on its own it can come back relative.
  local query = { "rev-parse", "--path-format=absolute" }
  vim.list_extend(query, { "--show-toplevel", "--git-dir", "--git-common-dir" })
  local out = git(query, dir)
  local worktree, gitdir, common = unpack(vim.split(out or "", "\n", { trimempty = true }))
  if not worktree or not gitdir then
    cache[dir] = false
    return nil
  end

  -- `<repo>/.git` -> `repo`. Bare repos end in `.git` with no parent to strip,
  -- so fall back to the worktree's basename there.
  local canonical = vim.fs.basename(vim.fs.dirname(normalise(common or gitdir)))
  if canonical == "" or canonical == "/" then
    canonical = vim.fs.basename(worktree)
  end

  local repo = {
    name = canonical,
    worktree = normalise(worktree),
    gitdir = normalise(gitdir),
  }
  cache[dir] = repo
  return repo
end

---The workspace directory containing `path`, if any.
---
---Recognised by shape: some ancestor's PARENT is named `config.workspaces.dir`.
---So `~/Code/openfin/.workspaces/otp-rate-limit/clm/app/main.py` yields
---`~/Code/openfin/.workspaces/otp-rate-limit`.
---@param path? string  Defaults to the cwd.
---@return string|nil root
function M.workspace_root(path)
  local marker = config.get().workspaces.dir
  local dir = path and normalise(path) or normalise(assert(vim.uv.cwd()))
  while dir and dir ~= "/" do
    local parent = vim.fs.dirname(dir)
    if vim.fs.basename(parent) == marker then
      return dir
    end
    dir = parent
  end
  return nil
end

---Every repo in the unit of work containing `path`.
---
---Inside a workspace: its member worktrees, sorted by name. Outside one: the
---single repo containing `path`. Either way, a list -- possibly empty, never
---nil.
---@param opts? { path?: string }
---@return paseo.Repo[]
function M.list(opts)
  opts = opts or {}

  local start = opts.path and normalise(opts.path) or normalise(assert(vim.uv.cwd()))

  local root = M.workspace_root(start)
  if not root then
    local repo = M.resolve(start)
    return repo and { repo } or {}
  end

  -- The workspace directory is itself a worktree: a single-repo project, whose
  -- worktree was placed directly at `<project>/.workspaces/<name>`.
  local self_repo = M.resolve(root)
  if self_repo and self_repo.worktree == root then
    return { self_repo }
  end

  ---@type paseo.Repo[]
  local repos = {}
  for entry, kind in vim.fs.dir(root) do
    if kind == "directory" or kind == "link" then
      local member = M.resolve(vim.fs.joinpath(root, entry))
      -- Guard against a plain subdirectory: `resolve` would walk up and hand
      -- back some enclosing repo rather than nil.
      if member and member.worktree == normalise(vim.fs.joinpath(root, entry)) then
        repos[#repos + 1] = member
      end
    end
  end

  table.sort(repos, function(a, b)
    return a.name < b.name
  end)
  return repos
end

---The repo owning a buffer, or nil.
---@param bufnr? integer
---@return paseo.Repo|nil
function M.current(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" then
    return M.resolve()
  end
  return M.resolve(name)
end

---`path` made relative to `repo.worktree`, or left alone if it is outside it.
---@param repo paseo.Repo
---@param path string
---@return string
function M.relative(repo, path)
  local abs = normalise(path)
  if abs == repo.worktree then
    return "."
  end
  local prefix = repo.worktree .. "/"
  return vim.startswith(abs, prefix) and abs:sub(#prefix + 1) or abs
end

---Drop the resolved-path cache. Called on DirChanged; call it by hand after
---creating or removing a worktree under the current tree.
function M.invalidate()
  cache = {}
end

return M
