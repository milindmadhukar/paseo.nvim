--- References: the thing you point an agent at.
---
--- A reference is a path and a line range. The path is resolved against the
--- WORKSPACE root when there is one, so `clm_api/app/main.py:42-58`
--- disambiguates across member repos -- inside a workspace, `app/main.py`
--- alone could be any of six files.
---
--- IT DOES NOT CARRY THE TEXT, and that is the point. Inlining the lines makes
--- the prompt scale with the size of the thing you asked about -- a long hunk,
--- or a newly created file, which gitsigns reports as one all-added hunk and
--- which therefore used to paste the file in whole. The agent can open the
--- file, and reading it gets surrounding context and the file's CURRENT state
--- rather than a snapshot taken when you pressed the key.
---
--- THE ONE EXCEPTION IS A PURE DELETION. Its text is not in the file any more,
--- so there is nothing to go and read; `render()` quotes those lines because
--- otherwise the agent reads the code that SURVIVED and explains the wrong
--- thing with full confidence. See `hunk()` and `detached`.

local repos = require "paseo.repos"

local M = {}

---@class paseo.Ref
---@field repo paseo.Repo|nil  nil when the file is not in a git repo at all.
---@field root string       Directory an agent should work in.
---@field path string       Relative to the workspace root, else to the repo,
---                         else just the file name. A LABEL, for the human and
---                         for disambiguation -- not necessarily resolvable
---                         against `root`, which is the member worktree.
---@field abs string        The absolute path. THIS is what an agent opens: in
---                         a workspace `path` is workspace-relative while
---                         `root` is the member worktree, so resolving one
---                         against the other yields `clm_api/clm_api/...`.
---@field lnum integer      1-based, inclusive.
---@field end_lnum integer  1-based, inclusive.
---@field lines string[]    The referenced text. Only rendered when `detached`.
---@field detached boolean  `lines` are NOT what is in the file at `lnum` --
---                         they are a diff body for a pure deletion.
---@field modified boolean  The buffer has unsaved changes, so what the agent
---                         reads off disk is not what you are looking at.
---@field kind "cursor"|"visual"|"hunk"|"file"

---`path` as it should be written to an agent.
---@param repo paseo.Repo|nil
---@param abs string
---@return string
local function display_path(repo, abs)
  local root = repos.workspace_root(abs)
  if root then
    local prefix = root .. "/"
    if vim.startswith(abs, prefix) then
      return abs:sub(#prefix + 1)
    end
  end
  if repo then
    return repos.relative(repo, abs)
  end
  -- No repo: the absolute path shortened at $HOME is the only honest answer,
  -- and it is still something an agent can open.
  return vim.fn.fnamemodify(abs, ":~")
end

---@param bufnr integer
---@param first integer
---@param last integer
---@param kind string
---@return paseo.Ref|nil
local function build(bufnr, first, last, kind)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end

  -- A REPO IS NOT REQUIRED. It was, and that silently made "ask about this
  -- file" impossible for anything outside a git repository -- a scratch file, a
  -- config under ~/.config, a note. The repo only decides how the path is
  -- written and where the agent runs; neither needs version control.
  local absolute = vim.fn.fnamemodify(name, ":p")
  local repo = repos.resolve(absolute)

  local total = vim.api.nvim_buf_line_count(bufnr)
  first = math.max(first, 1)
  last = math.min(math.max(last, first), total)

  return {
    repo = repo,
    root = repo and repo.worktree or vim.fs.dirname(absolute),
    path = display_path(repo, absolute),
    abs = absolute,
    lnum = first,
    end_lnum = last,
    lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false),
    detached = false,
    -- Captured HERE, not in render(): render reads no buffer state at all, so
    -- it cannot quietly describe whichever buffer happens to be current by the
    -- time it runs.
    modified = vim.bo[bufnr].modified,
    kind = kind,
  }
end

---The line under the cursor.
---@return paseo.Ref|nil
function M.cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return build(0, lnum, lnum, "cursor")
end

---The visual selection.
---
---`getpos("v")` and the cursor, NOT the `'<` / `'>` marks.
---
---A `<cmd>` mapping fires while visual mode is still ACTIVE, and the marks are
---only written when you leave visual mode -- so they still hold the PREVIOUS
---selection. Reading them sent the agent whichever lines were selected last
---time, silently and with no error. Verified: select 2-3, leave, select line 4,
---and the marks still read 2-3 while `getpos("v")` reads 4.
---
---The marks remain the fallback, for a `:<C-u>` style mapping or a call made
---after visual mode has already ended.
---@return paseo.Ref|nil
function M.visual()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local anchor = vim.fn.getpos("v")[2]
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    return build(0, math.min(anchor, cursor), math.max(anchor, cursor), "visual")
  end

  local first = vim.api.nvim_buf_get_mark(0, "<")[1]
  local last = vim.api.nvim_buf_get_mark(0, ">")[1]
  if first == 0 or last == 0 then
    return nil
  end
  return build(0, math.min(first, last), math.max(first, last), "visual")
end

---The whole file.
---@return paseo.Ref|nil
function M.file()
  return build(0, 1, vim.api.nvim_buf_line_count(0), "file")
end

---The hunk under the cursor.
---
---GOTCHA: the public hunk type from `gitsigns.get_hunks()` omits `.vend`, so
---the end of the range has to be recomputed as
---`added.start + max(added.count - 1, 0)`. Take `added.count` at face value and
---a pure deletion -- `added.count == 0` -- produces an empty or inverted range
---and is never matched.
---@return paseo.Ref|nil
function M.hunk()
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    return nil
  end

  local hunks = gs.get_hunks(0)
  if not hunks or #hunks == 0 then
    return nil
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  for _, hunk in ipairs(hunks) do
    local first = hunk.added.start
    local last = first + math.max(hunk.added.count - 1, 0)
    if lnum >= first and lnum <= last then
      local ref = build(0, first, last, "hunk")
      if ref then
        -- A deletion has no added lines to quote, so the hunk's own body --
        -- which carries the removed text -- is the only useful content. Mark
        -- it detached: `render()` inlines exactly these, because they are the
        -- one thing an agent cannot recover by opening the file.
        if hunk.added.count == 0 and hunk.lines then
          ref.lines = hunk.lines
          ref.detached = true
        end
      end
      return ref
    end
  end

  return nil
end

---A reference from whatever the cursor is on, preferring the most specific.
---@param kind? "cursor"|"visual"|"hunk"|"file"
---@return paseo.Ref|nil
function M.get(kind)
  if kind then
    return M[kind] and M[kind]()
  end
  return M.hunk() or M.cursor()
end

---`clm_api/app/main.py:42-58`, or `…:42` for a single line.
---@param ref paseo.Ref
---@return string
function M.format(ref)
  if ref.lnum == ref.end_lnum then
    return ("%s:%d"):format(ref.path, ref.lnum)
  end
  return ("%s:%d-%d"):format(ref.path, ref.lnum, ref.end_lnum)
end

---The reference rendered for an agent.
---
---A LOCATION, not a quotation. The agent is told which file and which lines
---and left to open it -- which costs one tool call and buys the current file,
---its surroundings, and a prompt whose size does not track the size of the
---hunk.
---
---The absolute path is what it is told to open. `path` is the label: inside a
---workspace it is relative to the WORKSPACE, while the agent runs in a member
---worktree, so `clm_api/app/main.py` would resolve to
---`.../clm_api/clm_api/app/main.py` and the read would fail.
---@param ref paseo.Ref
---@return string
function M.render(ref)
  -- A whole-file reference names the file, not `main.py:1-772`: the range is
  -- the file's length, which says nothing and reads like a selection.
  local label = ref.kind == "file" and ref.path or M.format(ref)
  local lines = { ref.repo and ("%s (%s)"):format(label, ref.repo.name) or label, "" }

  if ref.detached then
    -- These lines are GONE. Quoting them is not an optimisation here, it is
    -- the only way the agent can see them at all -- and it has to be told so,
    -- because `lnum` for a pure deletion is the line ABOVE the removed block
    -- and reading it would show surviving code.
    lines[#lines + 1] = ("These lines were DELETED from %s. They are quoted below"):format(ref.abs)
    lines[#lines + 1] = "because they are no longer in the file -- do not go looking for them"
    lines[#lines + 1] = ("at line %d, which is the line ABOVE the removed block."):format(ref.lnum)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```diff"
    lines[#lines + 1] = table.concat(ref.lines, "\n")
    lines[#lines + 1] = "```"
  elseif ref.kind == "file" then
    lines[#lines + 1] = ("Read %s."):format(ref.abs)
  elseif ref.lnum == ref.end_lnum then
    lines[#lines + 1] = ("Read line %d of %s, and enough around it to answer."):format(
      ref.lnum,
      ref.abs
    )
  else
    lines[#lines + 1] = ("Read lines %d-%d of %s, and enough around them to answer."):format(
      ref.lnum,
      ref.end_lnum,
      ref.abs
    )
  end

  if ref.modified then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "NOTE: the buffer has unsaved changes, so the file on disk is behind what"
    lines[#lines + 1] = "I am looking at. Say so if what you read does not match the question."
  end

  return table.concat(lines, "\n")
end

return M
