--- References: the thing you point an agent at.
---
--- A reference is a path, a line range, and the text in it. The path is
--- resolved against the WORKSPACE root when there is one, so `clm_api/app/
--- main.py:42-58` disambiguates across member repos -- inside a workspace,
--- `app/main.py` alone could be any of six files.

local repos = require "paseo.repos"

local M = {}

---@class paseo.Ref
---@field repo paseo.Repo|nil  nil when the file is not in a git repo at all.
---@field root string       Directory an agent should work in.
---@field path string       Relative to the workspace root, else to the repo,
---                         else just the file name.
---@field lnum integer      1-based, inclusive.
---@field end_lnum integer  1-based, inclusive.
---@field lines string[]    The referenced text.
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
    lnum = first,
    end_lnum = last,
    lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false),
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
        -- which carries the removed text -- is the only useful content.
        if hunk.added.count == 0 and hunk.lines then
          ref.lines = hunk.lines
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

---The reference rendered for an agent: a location line, then the text in a
---fenced block tagged with the buffer's filetype so the agent gets syntax.
---@param ref paseo.Ref
---@return string
function M.render(ref)
  local ft = vim.bo.filetype
  -- A hunk's own body is already diff-shaped; tagging it as the file's
  -- language would be a lie the agent then reads as broken code.
  local fence = ref.kind == "hunk" and #ref.lines > 0 and ref.lines[1]:match "^[-+@]" and "diff"
    or ft

  return table.concat({
    ref.repo and ("%s (%s)"):format(M.format(ref), ref.repo.name) or M.format(ref),
    "",
    "```" .. (fence ~= "" and fence or ""),
    table.concat(ref.lines, "\n"),
    "```",
  }, "\n")
end

return M
