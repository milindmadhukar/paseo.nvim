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

---How old the last `git status` may be before a draw asks for a fresh one.
---The panel's whole job is to be current, but a draw is not the place to
---wait for git: it runs on every resize and animation frame.
M.TTL = 1500

---What `git status` said last, per chat root: drawn from, never waited on.
---@type table<string, { sections: paseo.ListSection[], at: integer }>
local cache = {}
---Roots with a `git status` out right now.
---@type table<string, fun()[]>
local running = {}

---@param results { repo: paseo.Repo, changes: paseo.Change[] }[]
---@return paseo.ListSection[]
local function build(results)
  local out = {}
  for _, result in ipairs(results) do
    local repo, changes = result.repo, result.changes
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
            -- In a tab of its own: the panel is a split on the agent's tab,
            -- and editing over it would take the panel's window. The agent's
            -- tab stays where it was, a `gT` away.
            vim.cmd.tabedit(vim.fn.fnameescape(file))
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

---`git status` in every repo of the unit of work, all at once and off the
---main loop; `done` when the last answers. Asked twice while out, it runs once.
---@param root string
---@param done? fun()
local function refresh(root, done)
  if running[root] then
    if done then
      table.insert(running[root], done)
    end
    return
  end
  running[root] = done and { done } or {}
  local list = repos.list { path = root }
  local results, pending = {}, #list
  local function finish()
    cache[root] = { sections = build(results), at = vim.uv.now() }
    local waiting = running[root] or {}
    running[root] = nil
    for _, fn in ipairs(waiting) do
      fn()
    end
  end
  if pending == 0 then
    return finish()
  end
  for i, repo in ipairs(list) do
    git.status_async(repo, function(changes)
      results[i] = { repo = repo, changes = changes }
      pending = pending - 1
      -- `results[i]`: in repo order, not the order git answered in.
      if pending == 0 then
        finish()
      end
    end)
  end
end

---The sections to draw: what git said last (nil before it has said anything,
---which the list view draws as "loading…"). A stale answer is drawn as it is
---and a fresh one asked for, which redraws the panel when it lands.
---@param chat table
---@param redraw fun()
---@return paseo.ListSection[]|nil
local function sections(chat, redraw)
  local hit = cache[chat.root]
  if hit and vim.uv.now() - hit.at > M.TTL and not running[chat.root] then
    refresh(chat.root, redraw)
  end
  return hit and hit.sections or nil
end

---@param chat table
---@return paseo.ListSource
local function source(chat)
  return {
    chat = chat,
    -- `git status` runs OFF the main loop (see `refresh`), so the panel is
    -- up the moment you ask for it and fills in when git answers.
    sections = function()
      return sections(chat, function()
        require("paseo.ui.native").redraw_panels()
      end)
    end,
    load = function(_, done)
      refresh(chat.root, done)
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
        require("paseo.ui.native").redraw_panels()
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
  if drawn == nil then
    return v:lines(width, height)
  end
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

---Opening the panel (and `r`): ask git again, drawing what it said last --
---or "loading…" -- until it answers.
---@param chat table
function M.load(chat)
  refresh(chat.root, function()
    require("paseo.ui.native").redraw_panels()
  end)
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
