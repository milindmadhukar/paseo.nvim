--- The changed-files picker: the entry point to the review loop.
---
--- Follows the `finders.new_table` + `entry_maker` + `attach_mappings` shape
--- the rest of this config already uses. Two things make it worth having over
--- `Telescope git_status`: it spans every repo in the unit of work rather than
--- one, and `<C-q>` expands into HUNKS rather than files.

local git = require "paseo.git"
local repos = require "paseo.repos"

local M = {}

---Two-character status, rendered so the eye can sort it. Index status first,
---worktree second -- the same order git prints, so `MM` means "staged edits
---and further unstaged edits", which is the case worth noticing.
---@param change paseo.Change
---@return string
local function code(change)
  if change.untracked then
    return "??"
  end
  local function glyph(c)
    return (c == nil or c == "." or c == "") and " " or c
  end
  return glyph(change.index) .. glyph(change.worktree)
end

---@param changes paseo.Change[]
---@param multi boolean  Whether to show the repo column.
---@param width integer
local function entry_maker(multi, width)
  return function(change)
    local repo = multi and (("%-" .. width .. "s "):format(change.repo.name)) or ""
    local rename = change.orig_path and (" ← " .. change.orig_path) or ""
    local display = ("%s %s%s%s"):format(code(change), repo, change.path, rename)
    return {
      value = change,
      display = display,
      -- The repo name is in the ordinal on purpose: typing `clm_api` filters
      -- to that member, which is the fastest way to review one repo at a time.
      ordinal = ("%s %s %s"):format(change.repo.name, change.path, change.orig_path or ""),
      path = vim.fs.joinpath(change.repo.worktree, change.path),
    }
  end
end

---@return paseo.Change[]
local function collect()
  local out = {}
  for _, repo in ipairs(repos.list()) do
    vim.list_extend(out, git.status(repo))
  end
  return out
end

---The previewer: a DIFF, not the file.
---
---`git diff HEAD` rather than plain `git diff`, so staged and unstaged changes
---appear together -- what you are reviewing is the whole change, not the half
---of it you have not staged yet.
local function previewer()
  local ok, previewers = pcall(require, "telescope.previewers")
  if not ok then
    return nil
  end

  return previewers.new_buffer_previewer {
    title = "Diff vs HEAD",
    define_preview = function(self, entry)
      local lines = git.diff_text(entry.value, { context = 3 })
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = "diff"
    end,
  }
end

---@param opts? table  Telescope options.
function M.open(opts)
  opts = opts or {}

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.notify("paseo: telescope is not available", vim.log.levels.ERROR)
    return
  end

  local finders = require "telescope.finders"
  local actions = require "telescope.actions"
  local state = require "telescope.actions.state"
  local conf = require("telescope.config").values

  local changes = collect()
  if #changes == 0 then
    vim.notify("paseo: nothing changed", vim.log.levels.INFO)
    return
  end

  local first, multi, width = changes[1].repo.name, false, 0
  for _, change in ipairs(changes) do
    multi = multi or change.repo.name ~= first
    width = math.max(width, #change.repo.name)
  end

  ---Selected entries, or the one under the cursor when nothing is marked.
  ---@return paseo.Change[]
  local function selection(bufnr)
    local picker = state.get_current_picker(bufnr)
    local marked = picker and picker:get_multi_selection() or {}
    if #marked > 0 then
      return vim.tbl_map(function(entry)
        return entry.value
      end, marked)
    end
    local entry = state.get_selected_entry()
    return entry and { entry.value } or {}
  end

  pickers
    .new(opts, {
      prompt_title = multi and "Changes (workspace)" or "Changes",
      finder = finders.new_table {
        results = changes,
        entry_maker = entry_maker(multi, width),
      },
      -- generic_sorter, not file_sorter: the ordinal leads with a repo name,
      -- and the path sorter would score that as a directory component.
      sorter = conf.generic_sorter(opts),
      previewer = previewer(),
      attach_mappings = function(bufnr, map)
        -- <CR> opens the file on its FIRST HUNK rather than line 1. Landing on
        -- line 1 of a 400-line file tells you nothing about what changed.
        actions.select_default:replace(function()
          local entry = state.get_selected_entry()
          actions.close(bufnr)
          if not entry then
            return
          end
          local hunks = git.hunks(entry.value.repo, { entry.value })
          vim.cmd.edit(vim.fn.fnameescape(entry.path))
          if hunks[1] then
            pcall(vim.api.nvim_win_set_cursor, 0, { hunks[1].lnum, 0 })
          end
        end)

        local function to_quickfix()
          local picked = selection(bufnr)
          actions.close(bufnr)
          require("paseo.qf").set(picked, { title = "paseo: hunks" })
        end

        map({ "i", "n" }, "<C-q>", to_quickfix)
        map({ "i", "n" }, "<C-a>", function()
          actions.close(bufnr)
          require("paseo.qf").all()
        end)
        return true
      end,
    })
    :find()
end

return M
