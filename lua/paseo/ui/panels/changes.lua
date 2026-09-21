--- What is changed on disk, across every repo in the unit of work.
---
--- The one review surface the plugin still owns, and it earns its place from
--- the agent half: after a turn that edited files, this is the answer to "what
--- did it actually do". Everything else -- the changed-files picker, the hunk
--- quickfix list, staging -- is yours to build on |paseo-git|.
---
--- One section per repo, drawn by |paseo.ui.list|, which is where the focus
--- ring, `j`/`k`, `<CR>` and the hint bar come from. This panel used to own a
--- `buffer line -> file` map and read the cursor; the rows were clickable and
--- keyboard-reachable only by accident.

local git = require "paseo.git"
local icons = require "paseo.ui.icons"
local list = require "paseo.ui.list"
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

---`git status` per repo, as sections.
---
---Read straight rather than cached: this is the panel whose whole job is to be
---current, and it is only consulted while the tab is on screen.
---@param chat table
---@return paseo.ListSection[]
local function sections(chat)
  local out = {}
  for _, repo in ipairs(repos.list { path = chat.root }) do
    local changes = git.status(repo)
    if #changes > 0 then
      local rows = {}
      for _, change in ipairs(changes) do
        -- `change.path` is relative to the repo's worktree, and with several
        -- repos in one unit of work the cwd is not any of them.
        local file = vim.fs.joinpath(repo.worktree, change.path)
        local status = status_cell(change)
        rows[#rows + 1] = {
          id = file,
          cells = {
            { status[1], status[2] },
            { repos.relative(repo, change.path) or change.path, "PaseoPath" },
          },
          activate = function()
            -- The dashboard closes on the way. A file opened underneath a
            -- full-screen float is a file you cannot see, and this panel
            -- exists to answer "what did it just edit" -- an answer you then
            -- want to READ.
            require("paseo.ui.float").close()
            vim.cmd.edit(vim.fn.fnameescape(file))
          end,
        }
      end

      out[#out + 1] = {
        id = "repo." .. repo.worktree,
        title = repo.name,
        -- Hashed off the name, so the same repo is the same colour in every
        -- session.
        swatch = repo.name,
        summary = { { ("   %d changed"):format(#changes), "PaseoDim" } },
        rows = rows,
      }
    end
  end
  return out
end

---@param chat table
---@return paseo.ListSource
local function source(chat)
  return {
    chat = chat,
    -- `git status` is synchronous and there is nothing to fetch, so this never
    -- answers nil -- the list view's loading branch is for the panels that
    -- talk to the daemon.
    sections = function()
      return sections(chat)
    end,
    load = function(_, done)
      done()
    end,
    hints = {
      { ":Paseo ask hunk", "ask about a hunk" },
    },
  }
end

---One view per chat, rebuilt when the chat changes.
---@type paseo.ListView|nil
local view

---@param chat table
---@return paseo.ListView
local function view_for(chat)
  if not view or view.source.chat ~= chat then
    view = list.new(source(chat), {
      redraw = function()
        require("paseo.ui.float").rebuild()
      end,
    })
  end
  return view
end

---@param chat table
---@param width integer
---@param height? integer
---@return table[][]
function M.lines(chat, width, height)
  local v = view_for(chat)
  local drawn = v:sections()
  if #drawn == 0 then
    return {
      {
        { "  " .. icons.status.completed .. "  ", "PaseoToolOk" },
        { "nothing changed", "PaseoDim" },
      },
    }
  end
  return v:lines(width, height)
end

---@param chat table
---@param buf integer
function M.attach(chat, buf)
  view_for(chat):bind(buf)
end

---@param _chat table
---@param buf integer
function M.detach(_chat, buf)
  if view then
    view:unbind(buf)
  end
end

return M
