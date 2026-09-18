--- The only module that shells out to git.
---
--- Both formats parsed here have a trap in them, and both traps are the kind
--- that produce *plausible* wrong answers rather than errors, so they are
--- written down once, here, rather than rediscovered at each call site.

local M = {}

---@class paseo.Change
---@field repo paseo.Repo
---@field path string        Relative to `repo.worktree`.
---@field orig_path string?  Rename source, relative to `repo.worktree`.
---@field index string       X of the XY status code; "?" when untracked.
---@field worktree string    Y of the XY status code; "?" when untracked.
---@field untracked boolean

---@class paseo.Hunk
---@field repo paseo.Repo
---@field path string   Relative to `repo.worktree`.
---@field lnum integer  The line `gitsigns.stage_hunk()` acts on. See `hunks()`.
---@field added integer
---@field removed integer
---@field kind "add"|"change"|"delete"|"new"
---@field file_deleted boolean  The whole file is gone. Such a hunk CANNOT be
---                             staged through gitsigns -- see `stage()`.

---Run git in `repo`, returning stdout or nil.
---
---`core.quotePath=false` is not cosmetic: with it on -- the default -- git
---renders any non-ASCII path as a C-quoted escape ("a/\303\274..."), and every
---path in the diff headers below would need unquoting before it named a real
---file.
---@param repo paseo.Repo
---@param args string[]
---@return string|nil stdout, string|nil stderr
local function git(repo, args)
  local cmd = { "git", "-C", repo.worktree, "-c", "core.quotePath=false" }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    return nil, res.stderr
  end
  return res.stdout, nil
end

---Changed files in one repo: staged, unstaged and untracked, in one pass.
---
---PARSING TRAP: with `-z` the records are NUL-terminated, but a `2 ` (rename or
---copy) record is TWO NUL-terminated fields -- the record, then `origPath`. A
---naive split-on-NUL therefore reads the rename source as the next record and
---desyncs everything after it. Ignored files are not requested at all.
---@param repo paseo.Repo
---@return paseo.Change[]
function M.status(repo)
  local out = git(repo, { "status", "--porcelain=v2", "-z", "--untracked-files=all" })
  if not out then
    return {}
  end

  local fields = vim.split(out, "\0", { trimempty = true })
  ---@type paseo.Change[]
  local changes = {}
  local i = 1

  while i <= #fields do
    local record = fields[i]
    local kind = record:sub(1, 1)
    i = i + 1

    if kind == "1" or kind == "2" then
      -- `1 XY sub mH mI mW hH hI path`
      -- `2 XY sub mH mI mW hH hI Xscore path` + a separate origPath field.
      -- The path is everything after the 8th (resp. 9th) space-separated
      -- field, and may itself contain spaces, so it is taken by offset rather
      -- than by splitting.
      local nfields = kind == "1" and 8 or 9
      local pos = 1
      for _ = 1, nfields do
        pos = record:find(" ", pos, true)
        if not pos then
          break
        end
        pos = pos + 1
      end

      if pos then
        local xy = record:sub(3, 4)
        local change = {
          repo = repo,
          path = record:sub(pos),
          index = xy:sub(1, 1),
          worktree = xy:sub(2, 2),
          untracked = false,
        }
        if kind == "2" then
          change.orig_path = fields[i]
          i = i + 1
        end
        changes[#changes + 1] = change
      end
    elseif kind == "u" then
      -- Unmerged: `u XY sub m1 m2 m3 mW h1 h2 h3 path`, 10 fields before path.
      local pos = 1
      for _ = 1, 10 do
        pos = record:find(" ", pos, true)
        if not pos then
          break
        end
        pos = pos + 1
      end
      if pos then
        changes[#changes + 1] = {
          repo = repo,
          path = record:sub(pos),
          index = "U",
          worktree = "U",
          untracked = false,
        }
      end
    elseif kind == "?" then
      changes[#changes + 1] = {
        repo = repo,
        path = record:sub(3),
        index = "?",
        worktree = "?",
        untracked = true,
      }
    end
    -- `!` (ignored) is never emitted: --untracked-files=all does not imply it.
  end

  table.sort(changes, function(a, b)
    return a.path < b.path
  end)
  return changes
end

---Parse a unified hunk header.
---
---`@@ -a,b +c,d @@` -- but a count of 1 is OMITTED, so `@@ -2 +2 @@` means
---`-2,1 +2,1`. Reading a missing count as 0 turns every single-line change
---into a phantom deletion.
---@param header string
---@return integer? c, integer? d, integer? b
local function parse_header(header)
  local c, d = header:match "^@@ %-%d+,?%d* %+(%d+),?(%d*) @@"
  if not c then
    return nil
  end
  local b = header:match "^@@ %-%d+,(%d+)"
  return tonumber(c), d == "" and 1 or tonumber(d), b and tonumber(b) or 1
end

---Every hunk in `repo`, as quickfix-ready positions.
---
---THE DELETE-HUNK RULE, which is the whole reason this is not
---`gitsigns.setqflist`: for `@@ -a,b +c,0 @@` the line to jump to is `c`, NOT
---`c + 1`. `gitsigns.stage_hunk()` acts on `added.start`, and for a pure
---deletion that is the line *above* the removed block -- `hunks.lua:51` sets
---`vend = added.start + max(added.count - 1, 0)`, so a delete occupies exactly
---one line. Off by one and staging misses every deletion in the list.
---
---A deletion at the top of a file gives `c = 0`, which is not a valid quickfix
---line; it clamps to 1, which is also where gitsigns' `find_hunk` looks for a
---beginning-of-file deletion.
---
---Untracked files never reach git diff -- they are one synthetic "new file"
---entry each, which is what a whole new file is anyway.
---@param repo paseo.Repo
---@param changes? paseo.Change[]  Restrict to these; default: the whole repo.
---@return paseo.Hunk[]
function M.hunks(repo, changes)
  ---@type paseo.Hunk[]
  local hunks = {}
  local paths, untracked = nil, {}

  if changes then
    paths = {}
    for _, change in ipairs(changes) do
      if change.untracked then
        untracked[#untracked + 1] = change.path
      else
        paths[#paths + 1] = change.path
        -- A rename's source has to be in the pathspec too. Without it git sees
        -- only the destination, rename detection has nothing to pair it with,
        -- and a pure rename reports as a whole-file add.
        if change.orig_path then
          paths[#paths + 1] = change.orig_path
        end
      end
    end
  end

  if not paths or #paths > 0 then
    local args = { "diff", "-U0", "--no-color", "HEAD" }
    if paths then
      args[#args + 1] = "--"
      vim.list_extend(args, paths)
    end

    local out = git(repo, args)
    local path, old_path, file_deleted

    for _, line in ipairs(vim.split(out or "", "\n")) do
      if vim.startswith(line, "diff --git ") then
        path, old_path, file_deleted = nil, nil, false
      elseif vim.startswith(line, "--- ") then
        -- A path containing a space is followed by a tab; nothing follows it.
        old_path = line ~= "--- /dev/null" and line:sub(7):gsub("\t$", "") or nil
      elseif vim.startswith(line, "+++ ") then
        -- `+++ /dev/null` means the file was deleted: name it by its old path.
        file_deleted = line == "+++ /dev/null"
        path = not file_deleted and line:sub(7):gsub("\t$", "") or old_path
      elseif path and vim.startswith(line, "@@ ") then
        local c, d, b = parse_header(line)
        if c then
          hunks[#hunks + 1] = {
            repo = repo,
            path = path,
            lnum = math.max(c, 1),
            added = d,
            removed = b,
            kind = (d == 0 and "delete") or (b == 0 and "add") or "change",
            file_deleted = file_deleted or false,
          }
        end
      end
    end
  end

  for _, path in ipairs(untracked) do
    hunks[#hunks + 1] = {
      repo = repo,
      path = path,
      lnum = 1,
      added = 0,
      removed = 0,
      kind = "new",
      file_deleted = false,
    }
  end

  return hunks
end

---Stage a hunk.
---
---Routes to gitsigns for anything editable, and to `git add` for the one case
---gitsigns structurally cannot do: a WHOLE-FILE DELETION. The file is gone from
---disk, so no buffer can be opened on it and nothing can attach -- staging it
---through the hunk UI silently does nothing. Found by staging every hunk this
---module reports and checking the index afterwards; `tobedeleted.txt` was the
---only one that did not land.
---
---`git add` is correct for a removal: it records the deletion in the index.
---@param hunk paseo.Hunk
---@param callback? fun(err?: string)
function M.stage(hunk, callback)
  callback = callback or function() end

  if hunk.file_deleted or hunk.kind == "new" then
    -- Untracked files go the same way: there is nothing for gitsigns to stage
    -- hunk-by-hunk in a file git has never seen.
    local out, err = git(hunk.repo, { "add", "--", hunk.path })
    return callback(out == nil and (err or "git add failed") or nil)
  end

  local abs = vim.fs.joinpath(hunk.repo.worktree, hunk.path)
  vim.cmd.edit(vim.fn.fnameescape(abs))
  vim.api.nvim_win_set_cursor(0, { hunk.lnum, 0 })

  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    return callback "gitsigns is not available"
  end
  gs.stage_hunk(nil, nil, callback)
end

---The diff of one file, for a previewer. Working tree against HEAD, so staged
---and unstaged changes appear together -- which is what you are reviewing.
---
---An untracked file has no HEAD side, so it goes through `--no-index` against
---/dev/null. That exits 1 by design ("the files differ"), which is why this
---does not go through `git()`.
---@param change paseo.Change
---@param opts? { context?: integer }
---@return string[] lines
function M.diff_text(change, opts)
  opts = opts or {}
  local context = opts.context or 3
  local repo = change.repo

  local cmd = { "git", "-C", repo.worktree, "-c", "core.quotePath=false", "diff", "--no-color" }
  vim.list_extend(cmd, { "-U" .. context })

  if change.untracked then
    vim.list_extend(cmd, { "--no-index", "--", "/dev/null", change.path })
  else
    vim.list_extend(cmd, { "HEAD", "--", change.path })
    if change.orig_path then
      cmd[#cmd + 1] = change.orig_path
    end
  end

  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, cwd = repo.worktree }):wait()
  end)
  if not ok then
    return { "paseo: " .. tostring(res) }
  end

  local out = res.stdout or ""
  if out == "" then
    return { ("paseo: no diff for %s"):format(change.path), "", (res.stderr or "") }
  end
  return vim.split(out, "\n", { trimempty = true })
end

return M
