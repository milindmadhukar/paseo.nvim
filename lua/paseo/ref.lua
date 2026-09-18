--- References: the thing you point an agent at.
---
--- A reference is a path, a line range, and the text in it. The path is
--- resolved against the WORKSPACE root when there is one, so `clm_api/app/
--- main.py:42-58` disambiguates across member repos -- inside a workspace,
--- `app/main.py` alone could be any of six files.

local repos = require "paseo.repos"

local M = {}

---@class paseo.Ref
---@field repo paseo.Repo
---@field path string       Relative to the workspace root, else to the repo.
---@field lnum integer      1-based, inclusive.
---@field end_lnum integer  1-based, inclusive.
---@field lines string[]    The referenced text.
---@field kind "cursor"|"visual"|"hunk"|"file"

---`path` as it should be written to an agent.
---@param repo paseo.Repo
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
  return repos.relative(repo, abs)
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

  local repo = repos.resolve(name)
  if not repo then
    return nil
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  first = math.max(first, 1)
  last = math.min(math.max(last, first), total)

  return {
    repo = repo,
    path = display_path(repo, vim.fn.fnamemodify(name, ":p")),
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

---The last visual selection.
---
---`'<` and `'>` rather than the live cursor: by the time a mapping runs, visual
---mode has already been left, and the marks are the only record of it.
---@return paseo.Ref|nil
function M.visual()
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
    ("%s (%s)"):format(M.format(ref), ref.repo.name),
    "",
    "```" .. (fence ~= "" and fence or ""),
    table.concat(ref.lines, "\n"),
    "```",
  }, "\n")
end

return M
