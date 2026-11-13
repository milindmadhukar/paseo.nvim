--- What git would answer about a directory, read off the disk instead of
--- asked of a `git` process.
---
--- Which repository a directory is in, its git dir, its common dir, and the
--- branch it has checked out are all FILES: a `.git` directory, or a `.git`
--- file saying `gitdir: <path>`; a `commondir` file in a linked worktree's git
--- dir; `HEAD`. Asking `git rev-parse` for them is a fork and a few
--- milliseconds each, on the main loop -- and the new-task screen asked
--- several times before it could draw, plus once per directory while it
--- looked for repositories below a project (330 ms for six of them).
---
--- What this does not do: `GIT_DIR`/`GIT_WORK_TREE` in the environment,
--- `core.worktree`, and ceiling directories. None of the plugin's callers
--- runs under those, and a caller that might can still ask git.

local M = {}

---@param path string
---@return string|nil
local function first_line(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local line = f:read "*l"
  f:close()
  return line
end

---Absolute, `..` collapsed, symlinks resolved, no trailing slash.
---@param path string
---@return string
local function clean(path)
  return (vim.fn.resolve(vim.fn.simplify(path)):gsub("/+$", ""))
end

---@class paseo.GitLocation
---@field worktree string  The checkout's root (`--show-toplevel`).
---@field gitdir string    Its git dir (`--git-dir`): per worktree.
---@field common string    The repository's common dir (`--git-common-dir`).

---The repository `dir` is in, as git would find it: the nearest ancestor (or
---`dir` itself) with a `.git` in it.
---@param dir string  An absolute directory.
---@return paseo.GitLocation|nil
function M.find(dir)
  local d = (dir:gsub("/+$", ""))
  if d == "" then
    d = "/"
  end
  while true do
    local dotgit = d .. "/.git"
    local stat = vim.uv.fs_stat(dotgit)
    if stat and stat.type == "directory" then
      -- A `.git` directory without a HEAD is not a repository (a half-made
      -- one, or something named `.git` that is not git's).
      if vim.uv.fs_stat(dotgit .. "/HEAD") then
        local git = clean(dotgit)
        return { worktree = clean(d), gitdir = git, common = git }
      end
    elseif stat and stat.type == "file" then
      local line = first_line(dotgit)
      local target = line and line:match "^gitdir:%s*(.-)%s*$"
      if target and target ~= "" then
        if target:sub(1, 1) ~= "/" then
          target = d .. "/" .. target
        end
        local gitdir = clean(target)
        local common = gitdir
        local rel = first_line(gitdir .. "/commondir")
        if rel and rel ~= "" then
          common = clean(rel:sub(1, 1) == "/" and rel or (gitdir .. "/" .. rel))
        end
        return { worktree = clean(d), gitdir = gitdir, common = common }
      end
    end
    local parent = vim.fs.dirname(d)
    if not parent or parent == d then
      return nil
    end
    d = parent
  end
end

---Is `dir` itself the root of a checkout (not merely inside one)?
---@param dir string
---@return boolean
function M.is_root(dir)
  local stat = vim.uv.fs_stat((dir:gsub("/+$", "")) .. "/.git")
  if not stat then
    return false
  end
  local found = M.find(dir)
  return found ~= nil and found.worktree == clean(dir)
end

---The branch checked out in a worktree, from its HEAD; nil when detached.
---@param gitdir string  The worktree's git dir (`paseo.GitLocation.gitdir`).
---@return string|nil
function M.branch(gitdir)
  local head = first_line(gitdir .. "/HEAD")
  return head and head:match "^ref:%s*refs/heads/(.+)$" or nil
end

---The main checkout of the repository a directory is in: the common dir's
---parent, when the common dir is a `.git`. Nil for a bare repository, or no
---repository at all.
---@param dir string
---@return string|nil
function M.main_checkout(dir)
  local found = M.find(dir)
  if not found or vim.fs.basename(found.common) ~= ".git" then
    return nil
  end
  return vim.fs.dirname(found.common)
end

return M
