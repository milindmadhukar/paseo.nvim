--- Workspaces and repos: the other half of the plugin, on the dashboard.
---
--- The full-screen surface is meant to be the whole of Paseo without the app,
--- and until this panel existed it stopped at the agent session -- everything about
--- the unit of work the agent session runs IN was only reachable through a telescope
--- picker, which is a different window, over the top, that you have to dismiss.
---
--- Creating a workspace and the full picker still hand off to the commands
--- that already do that properly, rather than reimplementing the manifest
--- dance in a panel.
---
--- Drawn by |paseo.ui.list|, the same view the Sessions and Changes tabs use.
--- This panel had NO KEYMAPS AT ALL -- rows lit under the pointer and answered
--- a click, and there was no way to reach one from the keyboard -- which is
--- most of why the dashboard read as two different applications depending on
--- which tab you happened to be standing on.

local agents = require "paseo.agents"
local icons = require "paseo.ui.icons"
local list = require "paseo.ui.list"
local render = require "paseo.ui.render"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Workspaces"

---The key ALPHABET. Bound from this constant, never from the rows we happen to
---have -- keys are taken on arrival, before the daemon has answered.
---
---`x` is a different key from `d` on purpose. Archiving retires ONE unit of
---work; forgetting drops Paseo's record of a whole directory tree. One key
---that did both depending on which row you were standing on is the shape of a
---mistake.
local KEYS = { new = "n", picker = "o", archive = "d", forget = "x" }

---Module-level rather than per-chat: the list is the DAEMON's, identical for
---every chat, and a fetch per chat would be a round trip per chat for the same
---answer.
---@type { list: table[]|nil, err: string|nil }|nil
local cache
local loading = false

---Ask the daemon, then redraw.
---@param _chat? table  Unused: the list is the daemon's, not a chat's.
---@param done? fun()
function M.load(_chat, done)
  if loading then
    return
  end
  loading = true
  -- The status column is push-fed; without a subscription every row reads "…"
  -- forever. Idempotent, so calling it on every panel open is free.
  agents.watch()
  require("paseo.workspaces").list(function(result, err)
    loading = false
    cache = { list = result, err = err }
    vim.schedule(function()
      if done then
        done()
      else
        require("paseo.ui.float").rebuild()
      end
    end)
  end)
end

---Forget what we fetched, so the next draw asks again.
function M.invalidate()
  cache = nil
end

---@param ws table
---@return string
local function shape(ws)
  if ws.assembled then
    return ("%d repos"):format(#(ws.members or {}))
  end
  return ws.ownedWorktree and "worktree" or "local"
end

---What a workspace is DOING, as one cell.
---
---Four answers, and the glyphs come from the registry so a running workspace
---and a running tool card are the same shape. The spinner is the only one that
---moves, and it is the only one that has to: a filled circle and a hollow one
---are both finished states and say all they have to say standing still.
---@param state "attention"|"working"|"idle"|"none"
---@return table  A single cell.
local function status_cell(state)
  if state == "attention" then
    return { icons.status.permission .. " ", "PaseoDanger" }
  end
  if state == "working" then
    return { widgets.spinner() .. " ", "PaseoToolRunning" }
  end
  if state == "idle" then
    -- OPENED, and nothing running in it. A filled circle, against the hollow
    -- one below for a workspace you have never started an agent in -- the
    -- difference the `agents.summary` text could only make by being absent.
    return { icons.status.completed .. " ", "PaseoToolOk" }
  end
  return { icons.status.pending .. " ", "PaseoDim" }
end

---The row's columns: what it is doing, the name, the badge for what KIND of
---workspace it is, and what its agents are doing in words.
---
---`render.truncate` and `render.pad` rather than `string.format`, because both
---of them count display columns -- see the widths in `sections`.
---@param ws table
---@param mine boolean
---@param w_name integer
---@param w_shape integer
---@return table[]
local function name_and_badge(ws, mine, w_name, w_shape)
  local hl = mine and "PaseoAgent" or nil
  local cells = { status_cell(agents.state(ws.directory or "")) }
  vim.list_extend(cells, render.pad(render.truncate({ { ws.name or "", hl } }, w_name), w_name, hl))
  cells[#cells + 1] = { "  ", hl }
  -- Padded in the badge's own highlight, which is what `%-9s` did by having
  -- the spaces inside the same cell.
  vim.list_extend(cells, render.pad({ { shape(ws), "PaseoBadge" } }, w_shape, "PaseoBadge"))
  cells[#cells + 1] = { "  " .. agents.summary(ws.directory or ""), "PaseoDim" }
  return cells
end

---@param ws table
local function archive(ws)
  -- Asked first, and BY NAME: archiving dismantles the worktrees Paseo cut,
  -- which is not a thing to find out about afterwards.
  vim.ui.select({ "no", "yes" }, {
    prompt = ("Archive %s?"):format(ws.name or ws.directory or "this workspace"),
  }, function(choice)
    if choice ~= "yes" then
      return
    end
    require("paseo.workspaces").archive(ws, {}, function(err)
      vim.schedule(function()
        if err then
          return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
        end
        M.invalidate()
        require("paseo.ui.float").rebuild()
      end)
    end)
  end)
end

---Forget a project -- Paseo's record of it, never the files.
---
---This is how you get rid of the top-level project the daemon invents for a
---`<project>/.workspaces/<name>` directory: that directory is not a git repo,
---so opening it registers it as a project of its own, named after the
---workspace. A GROUP here may therefore span several project records -- the
---real one and every invented one under it -- so this removes all of them.
---@param group table
local function forget(group)
  local ids = group.projects or {}
  if #ids == 0 then
    return vim.notify("paseo: no project to forget", vim.log.levels.WARN)
  end
  require("paseo.workspaces").remove_project(ids, group.name, function()
    M.invalidate()
    require("paseo.ui.float").rebuild()
  end)
end

---@param chat table
---@return paseo.ListSection[]|nil
local function sections(chat)
  if not cache then
    return nil
  end
  if cache.err then
    return {
      {
        id = "workspaces",
        icon = icons.panel.Workspaces,
        title = "Workspaces",
        summary = { { "  " .. cache.err, "PaseoToolFail" } },
        empty = ":checkhealth paseo reports every endpoint it tried",
        rows = {},
      },
    }
  end

  -- Where you are STANDING, not what the chat is pointed at. Those are the
  -- same thing right up until you switch workspace without opening a chat, at
  -- which point `chat.root` is the workspace you left and this list puts the
  -- marker on the wrong row.
  local here = vim.fn.resolve(vim.fn.fnamemodify(vim.fn.getcwd(), ":p")):gsub("/+$", "")
  local known = cache.list or {}

  -- Widths from the data, not guessed: names run from `ui` to
  -- `fetch-latest-and-prune`, and a fixed column is either ragged or
  -- truncating.
  --
  -- MEASURED AND APPLIED IN THE SAME UNIT, which is the half that was wrong.
  -- The widths came from `nvim_strwidth` -- display columns -- and were
  -- applied with `("%-34s"):format(...)`, which pads to a count of BYTES. Any
  -- name with a multibyte character in it was padded short and put the badge
  -- beside it out of line with every other row. `%-Ns` also does not
  -- truncate, so the clamp below did nothing to a name longer than it and the
  -- badge was simply shoved right by the overflow -- which is the ragged
  -- column you see with one long workspace name in the list.
  local w_name, w_shape = 0, 0
  for _, ws in ipairs(known) do
    w_name = math.max(w_name, vim.api.nvim_strwidth(ws.name or ""))
    w_shape = math.max(w_shape, vim.api.nvim_strwidth(shape(ws)))
  end
  w_name = math.min(w_name, 34)

  -- A SECTION PER PROJECT, and by the project the workspace LIVES IN rather
  -- than the one the daemon has it filed under. An assembled workspace is a
  -- plain directory -- it has to be, since a git worktree is per repo and a
  -- unit of work spanning four repos has nowhere else to live -- so opening
  -- `~/Code/openfin/.workspaces/billing` registers that directory as its own
  -- top-level project called `billing`, drawn as a SIBLING of `openfin`
  -- rather than as something inside it. `workspaces.group` recovers the real
  -- parent from the path; the list arrives already sorted by it.
  local groups, order = {}, {}
  for _, ws in ipairs(known) do
    local key = ws.group or ws.project or ""
    if not groups[key] then
      groups[key] = { name = key, rows = {}, projects = {} }
      order[#order + 1] = key
    end
    local group = groups[key]
    if ws.projectId and not vim.tbl_contains(group.projects, ws.projectId) then
      group.projects[#group.projects + 1] = ws.projectId
    end

    local dir = vim.fn.resolve(ws.directory or ""):gsub("/+$", "")
    local mine = dir ~= "" and (here == dir or vim.startswith(here, dir .. "/"))
    group.rows[#group.rows + 1] = {
      id = "ws." .. (ws.directory or ws.name or ""),
      active = mine,
      -- The gutter -- the indent and the "you are in this one" bar -- belongs
      -- to |paseo.ui.list|, which draws it outside the focus band.
      cells = name_and_badge(ws, mine, w_name, w_shape),
      activate = function()
        if not ws.directory or ws.directory == "" then
          return vim.notify("paseo: that workspace has no directory", vim.log.levels.WARN)
        end
        require("paseo.ui.chat").open { root = ws.directory, title = ws.name }
      end,
      keys = {
        [KEYS.archive] = function()
          archive(ws)
        end,
        -- Bound on the ROW as well as on the heading, because "forget the
        -- project this is in" is the question you have from a workspace.
        [KEYS.forget] = function()
          forget(group)
        end,
      },
    }
  end

  -- The repos of the unit of work this session is in -- `:Paseo repos`, which
  -- is otherwise a notification you have to ask for. A READOUT, so `j` and `k`
  -- step over it: there is nothing here to stand on.
  local repo_rows = {}
  for _, repo in ipairs(require("paseo.repos").list { path = chat.root }) do
    repo_rows[#repo_rows + 1] = {
      id = "repo." .. repo.worktree,
      skip = true,
      cells = {
        widgets.swatch(repo.name),
        { " " .. repo.name, nil },
        { "   " .. vim.fn.fnamemodify(repo.worktree, ":~"), "PaseoPath" },
      },
    }
  end

  local out = {}
  for _, key in ipairs(order) do
    local group = groups[key]
    out[#out + 1] = {
      id = "group." .. key,
      -- The project's own hashed colour block in place of an icon, so twenty
      -- workspaces group by eye before they are read.
      swatch = key,
      title = key ~= "" and key or "Workspaces",
      -- AND A LINE UNDER IT. The swatch and a blank line were the whole of the
      -- separation, which reads as one list that happens to have headings in
      -- it rather than as one group per project -- the complaint was that
      -- there is no isolation between projects, and the grouping was already
      -- here. This is what makes it visible.
      rule = true,
      rows = group.rows,
    }
  end
  if #out == 0 then
    out[1] = {
      id = "workspaces",
      icon = icons.panel.Workspaces,
      title = "Workspaces",
      empty = "no workspaces yet",
      rows = {},
    }
  end

  out[#out + 1] = {
    id = "repos",
    icon = icons.ui.repo,
    title = "This unit of work",
    empty = "not inside a git repository",
    rows = repo_rows,
  }
  return out
end

---@param chat table
---@return paseo.ListSource
local function source(chat)
  return {
    chat = chat,
    keys = KEYS,
    loading = "loading workspaces…",
    hints = {
      { KEYS.new, "new" },
      { KEYS.picker, "picker" },
      { KEYS.archive, "archive" },
      { KEYS.forget, "forget project" },
    },
    verbs = {
      [KEYS.new] = function()
        require("paseo.pickers.workspaces").create()
      end,
      -- Everything this panel deliberately does not reimplement -- searching,
      -- sessions, archiving in bulk -- is one key away rather than nowhere.
      [KEYS.picker] = function()
        require("paseo.pickers.workspaces").open()
      end,
    },
    sections = function()
      return sections(chat)
    end,
    load = function(_, done)
      M.load(chat, done)
    end,
  }
end

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
  return view_for(chat):lines(width, height)
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
