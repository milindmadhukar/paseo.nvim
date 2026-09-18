--- The hunk quickfix list.
---
--- One entry per HUNK, not per file, because the unit of review is a hunk: `]q`
--- has to step onto something you can read and then stage, and a file entry
--- lands you at line 1 of a 400-line file with no idea what changed.
---
--- This is built from `git diff` rather than `gitsigns.setqflist`, which cannot
--- do it: that function ends in `vim.fn.setqflist({}, ' ', …)` -- a REPLACE, not
--- an append -- and collects repos from attached buffers plus `uv.cwd()`
--- (`actions/qflist.lua`). At the start of a review, with no buffers open, it
--- sees exactly one repo. Ours has to span the workspace.

local git = require "paseo.git"

local M = {}

---The hunks behind the current list, indexed the same way. `quickfixtextfunc`
---receives indices, not entries, so it needs somewhere to look them up, and the
---stage-under-cursor action needs the `file_deleted` flag that a quickfix entry
---has nowhere to carry.
---@type paseo.Hunk[]
local current = {}

---@param hunk paseo.Hunk
---@return string
local function counts(hunk)
  if hunk.kind == "new" then
    return "new file"
  end
  return ("+%d -%d"):format(hunk.added, hunk.removed)
end

---Render the list. Registered as `quickfixtextfunc` so the entries keep real
---`filename`/`lnum` values -- which is what makes `]q`, `:cc` and gitsigns all
---work -- while still displaying as `clm_api  app/main.py:42  +7 -2`.
---@param info table
---@return string[]
function M.textfunc(info)
  local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
  local lines = {}

  -- Column-align the repo name only when there is more than one, so a
  -- single-repo review does not pay for a column it does not need.
  local width = 0
  local multi = false
  local first
  for i = info.start_idx, info.end_idx do
    local hunk = current[i]
    if hunk then
      first = first or hunk.repo.name
      multi = multi or hunk.repo.name ~= first
      width = math.max(width, #hunk.repo.name)
    end
  end

  for i = info.start_idx, info.end_idx do
    local hunk, item = current[i], items[i]
    if hunk and item then
      local prefix = multi and (("%-" .. width .. "s  "):format(hunk.repo.name)) or ""
      lines[#lines + 1] = ("%s%s:%d  %s"):format(prefix, hunk.path, hunk.lnum, counts(hunk))
    elseif item then
      lines[#lines + 1] = item.text or ""
    end
  end

  return lines
end

---@param hunks paseo.Hunk[]
---@return table[] quickfix items
local function items_of(hunks)
  local items = {}
  for _, hunk in ipairs(hunks) do
    items[#items + 1] = {
      -- Absolute: the list outlives whatever cwd built it, and in a workspace
      -- the entries come from several different worktrees.
      filename = vim.fs.joinpath(hunk.repo.worktree, hunk.path),
      lnum = hunk.lnum,
      col = 1,
      text = ("%s  %s"):format(hunk.path, counts(hunk)),
      type = hunk.kind == "delete" and "W" or "I",
    }
  end
  return items
end

---Replace the quickfix list with one entry per hunk.
---@param changes paseo.Change[]  Grouped by repo internally; order is preserved.
---@param opts? { open?: boolean, title?: string }
---@return integer count
function M.set(changes, opts)
  opts = opts or {}

  -- Group by repo so `git diff` runs once per repo rather than once per file.
  ---@type table<string, { repo: paseo.Repo, changes: paseo.Change[] }>
  local by_repo, order = {}, {}
  for _, change in ipairs(changes) do
    local key = change.repo.worktree
    if not by_repo[key] then
      by_repo[key] = { repo = change.repo, changes = {} }
      order[#order + 1] = key
    end
    table.insert(by_repo[key].changes, change)
  end

  current = {}
  for _, key in ipairs(order) do
    local group = by_repo[key]
    vim.list_extend(current, git.hunks(group.repo, group.changes))
  end

  vim.fn.setqflist({}, " ", {
    title = opts.title or "paseo: hunks",
    items = items_of(current),
    quickfixtextfunc = M.textfunc,
  })

  if opts.open ~= false and #current > 0 then
    vim.cmd "botright copen"
    vim.cmd "wincmd p"
  end

  return #current
end

---The hunk behind quickfix entry `idx` (1-based), or the one under the cursor.
---@param idx? integer
---@return paseo.Hunk|nil
function M.hunk(idx)
  if not idx then
    idx = vim.fn.getqflist({ idx = 0 }).idx
  end
  return current[idx]
end

---Stage the hunk the quickfix list is currently on, then advance.
---
---Goes through `git.stage`, not `gitsigns.stage_hunk`, so the cases gitsigns
---structurally cannot handle -- a whole-file deletion, an untracked file --
---still work from the list.
---@param opts? { advance?: boolean }
function M.stage(opts)
  opts = opts or {}
  local hunk = M.hunk()
  if not hunk then
    vim.notify("paseo: no hunk under the cursor", vim.log.levels.WARN)
    return
  end

  git.stage(hunk, function(err)
    if err then
      vim.notify("paseo: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify(("staged %s:%d"):format(hunk.path, hunk.lnum), vim.log.levels.INFO)
    if opts.advance ~= false then
      pcall(vim.cmd.cnext)
    end
  end)
end

---Every changed file in the current unit of work, expanded into hunks.
---@param opts? { open?: boolean }
---@return integer count
function M.all(opts)
  local repos = require("paseo.repos").list()
  ---@type paseo.Change[]
  local changes = {}
  for _, repo in ipairs(repos) do
    vim.list_extend(changes, git.status(repo))
  end

  local count = M.set(changes, opts)
  if count == 0 then
    vim.notify("paseo: nothing changed", vim.log.levels.INFO)
  end
  return count
end

return M
