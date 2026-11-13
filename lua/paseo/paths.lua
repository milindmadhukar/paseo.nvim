--- Path spelling, memoised.
---
--- `vim.fn.resolve` is a readlink walk per component, and the rail asked it
--- for every agent's cwd under every workspace on every draw -- seven and a
--- half thousand calls a frame for fifty workspaces, ten frames a second while
--- anything ran. Whether a directory is a symlink does not change between two
--- frames, so the answer is kept.
---
--- Only ABSOLUTE paths are kept: a relative one means something different
--- after a `:cd`. |M.invalidate| forgets everything -- called where the
--- plugin itself makes or removes directories (a workspace created or torn
--- down), which is when an answer can actually go stale.

local M = {}

---@type table<string, string>
local resolved = {}
local size = 0
-- A bound, not a cache policy: a session that visits thousands of paths
-- starts again rather than growing without end.
local LIMIT = 4096

local function absolute(path)
  local c = path:sub(1, 1)
  return c == "/" or c == "~"
end

---`vim.fn.resolve(path)`, remembered for absolute paths.
---@param path string
---@return string
function M.resolve(path)
  if not absolute(path) then
    return vim.fn.resolve(path)
  end
  local hit = resolved[path]
  if hit then
    return hit
  end
  hit = vim.fn.resolve(path)
  if size >= LIMIT then
    resolved, size = {}, 0
  end
  resolved[path] = hit
  size = size + 1
  return hit
end

---@type table<string, string>
local canon = {}
local canon_size = 0

---The one spelling two paths are compared in: absolute, `~` expanded,
---symlinks resolved, no trailing slash.
---@param path string
---@return string
function M.canonical(path)
  if not absolute(path) then
    return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
  end
  local hit = canon[path]
  if hit then
    return hit
  end
  hit = (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
  if canon_size >= LIMIT then
    canon, canon_size = {}, 0
  end
  canon[path] = hit
  canon_size = canon_size + 1
  return hit
end

---Forget every answer.
function M.invalidate()
  resolved, size = {}, 0
  canon, canon_size = {}, 0
end

return M
