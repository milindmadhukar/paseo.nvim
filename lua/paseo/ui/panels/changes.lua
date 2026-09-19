--- What is changed on disk, across every repo in the unit of work.
---
--- The review half of the plugin, visible from the agent half: after a turn
--- that edited files, this is the answer to "what did it actually do".

local git = require "paseo.git"
local repos = require "paseo.repos"

local M = {}

M.title = "Changes"

---@param change table
---@return table
local function status_cell(change)
  if change.untracked then
    return { "?? ", "PaseoToolRunning" }
  end
  local staged = change.index ~= "." and change.index ~= " "
  return {
    (change.index or " ") .. (change.worktree or " ") .. " ",
    staged and "PaseoAdd" or "PaseoDel",
  }
end

---@param chat table
---@param width integer
---@return table[][]
function M.lines(chat, width)
  local lines = {}
  local total = 0

  for _, repo in ipairs(repos.list { path = chat.root }) do
    local changes = git.status(repo)
    if #changes > 0 then
      lines[#lines + 1] = {
        { "  " .. repo.name, "PaseoHeader" },
        { ("   %d changed"):format(#changes), "PaseoDim" },
      }
      for _, change in ipairs(changes) do
        total = total + 1
        -- `change.path` is relative to the repo's worktree, and with several
        -- repos in one unit of work the cwd is not any of them.
        local file = vim.fs.joinpath(repo.worktree, change.path)
        -- The dashboard closes on the way. A file opened underneath a
        -- full-screen float is a file you cannot see, and this panel exists to
        -- answer "what did it just edit" -- an answer you then want to READ.
        local click = function()
          require("paseo.ui.float").close()
          vim.cmd.edit(vim.fn.fnameescape(file))
        end
        local status = status_cell(change)
        lines[#lines + 1] = {
          { "    ", nil, click },
          { status[1], status[2], click },
          { repos.relative(repo, change.path) or change.path, "PaseoPath", click },
        }
      end
      lines[#lines + 1] = {}
    end
  end

  if total == 0 then
    lines[#lines + 1] = { { "  nothing changed", "PaseoDim" } }
    return lines
  end

  lines[#lines + 1] = {
    { "  ", "PaseoDim" },
    { ":Paseo changes", "PaseoKey" },
    { " to open one · ", "PaseoDim" },
    { ":Paseo hunks", "PaseoKey" },
    { " for the quickfix list · ", "PaseoDim" },
    { ":Paseo review", "PaseoKey" },
    { " for the diff panel", "PaseoDim" },
  }
  return lines
end

return M
