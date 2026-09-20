--- What is changed on disk, across every repo in the unit of work.
---
--- The one review surface the plugin still owns, and it earns its place from
--- the agent half: after a turn that edited files, this is the answer to "what
--- did it actually do". Everything else -- the changed-files picker, the hunk
--- quickfix list, staging -- is yours to build on |paseo-git|.

local git = require "paseo.git"
local icons = require "paseo.ui.icons"
local repos = require "paseo.repos"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Changes"

---Buffer line -> the file on it, rebuilt on every draw.
---
---Same shape as the Sessions panel's, and for the same reason: a map is
---checkable against a real draw, where arithmetic on the cursor row is a
---second copy of the chrome's layout that has to be kept in step by hand.
---@type table<integer, string>
M._rows = {}

---@return integer  The buffer line the panel's first line is drawn on.
local function offset()
  return require("paseo.ui.float").body_row_offset()
end

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
  M._rows = {}

  for _, repo in ipairs(repos.list { path = chat.root }) do
    local changes = git.status(repo)
    if #changes > 0 then
      -- A colour swatch per repo, hashed off the name so the same repo is the
      -- same colour in every session. With several repos in one unit of work
      -- the headings were four identical blue lines and the only thing telling
      -- them apart was reading them.
      lines[#lines + 1] = {
        { "  " },
        widgets.swatch(repo.name),
        { " " .. repo.name, "PaseoHeader" },
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
        local id = "changes." .. file
        local action = widgets.hover(id, "body", click)
        local row = {
          { "    " },
          { status[1], status[2] },
          { repos.relative(repo, change.path) or change.path, "PaseoPath" },
        }

        local row_hl = widgets.row_hl(id)
        if row_hl then
          lines[#lines + 1] = widgets.fill_row(row, width, row_hl, action)
        else
          for _, cell in ipairs(row) do
            cell[3] = action
          end
          lines[#lines + 1] = row
        end
        M._rows[#lines + offset()] = file
      end
      lines[#lines + 1] = {}
    end
  end

  if total == 0 then
    lines[#lines + 1] = {
      { "  " .. icons.status.completed .. "  ", "PaseoToolOk" },
      { "nothing changed", "PaseoDim" },
    }
    return lines
  end

  lines[#lines + 1] = {}
  local hints = { { "  " } }
  vim.list_extend(hints, widgets.hints { { "<CR>", "open this file" } })
  vim.list_extend(hints, {
    { "   ·   ", "PaseoDim" },
    { ":Paseo ask hunk", "PaseoKey" },
    { " on a hunk to ask about it", "PaseoDim" },
  })
  lines[#lines + 1] = hints
  return lines
end

---What this panel has bound on the shared chrome buffer.
---@type table[]|nil
local bound

---@param _chat table
---@param buf integer
function M.attach(_chat, buf)
  -- The rows were clickable and only clickable: the footer said "click a file
  -- to open it", in a plugin whose entire premise is that you do not have to.
  --
  -- Through |paseo.ui.keys|, which gives back what it displaced. The panels
  -- share one chrome buffer and volt binds `<CR>` on it at open, so a panel
  -- that merely DELETED its own `<CR>` would leave the key dead on every other
  -- one for the rest of the session.
  bound = require("paseo.ui.keys").take(buf, {
    {
      "<CR>",
      function()
        local file = M._rows[vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]]
        if not file then
          return
        end
        -- The dashboard closes on the way, the same as the click does. A file
        -- opened underneath a full-screen float is a file you cannot see, and
        -- this panel exists to answer "what did it just edit" -- an answer you
        -- then want to READ.
        require("paseo.ui.float").close()
        vim.cmd.edit(vim.fn.fnameescape(file))
      end,
      "paseo: open the changed file under the cursor",
    },
  })
end

---@param _chat table
---@param buf integer
function M.detach(_chat, buf)
  require("paseo.ui.keys").release(buf, bound)
  bound = nil
end

return M
