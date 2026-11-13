--- The workspace list, in the one chooser (|paseo.ui.choose|).
---
--- Rows come from PASEO, not from our own registry: a workspace made in the
--- app is exactly as real as one this plugin assembled, and listing only ours
--- made half of them invisible. Our registry contributes the one thing Paseo
--- cannot know -- that a directory is several worktrees rather than one
--- checkout.
---
--- The status column is decorated from the live agent directory, by push. That
--- is the payoff for the sidecar: at a second per CLI call a polled column is
--- unobtainable, and the column is the difference between a dashboard and a
--- list of directories.

local agents = require "paseo.agents"
local workspaces = require "paseo.workspaces"

local M = {}

---One row of the chooser.
---@param ws paseo.PaseoWorkspace
---@param widths { project: integer, name: integer }
---@return paseo.ChooseItem
local function item(ws, widths)
  local shape = ws.assembled and ("%d repos"):format(#ws.members)
    or (ws.ownedWorktree and "worktree" or "local")
  return {
    id = ws.id or ws.directory,
    value = ws,
    cells = {
      -- The GROUP, not the daemon's project: a `ws` workspace is registered
      -- as its own top-level project named after itself. See `workspaces.group`.
      { ("%-" .. widths.project .. "s  "):format((ws.group or ws.project or "?"):sub(1, widths.project)), "PaseoDim" },
      { (ws.name or "?"):sub(1, widths.name), "PaseoText" },
    },
    right = { { ("%-8s  "):format(shape), "PaseoDim" }, { agents.summary(ws), "PaseoDim" } },
  }
end

---The chooser on screen, so the one agent listener can repaint it.
---@type { handle: paseo.Chooser, rows: fun(): paseo.ChooseItem[] }|nil
local open_list
local listening = false

---Said once per session, at the only moment it is relevant.
---
---A HINT, NEVER AN INSTALL. Writing into `~/.claude/skills` changes the
---behaviour of a DIFFERENT program, and no Neovim plugin gets to do that as a
---side effect of a command about worktrees. The plugin's own stance is the
---opposite one: `:Paseo ws init` shows you the manifest and makes you save it.
---The problem was only ever discovery, and one line of it is the whole fix.
local hinted = false

---@param plan paseo.Strategy|nil
function M.hint_skills(plan)
  if hinted or not plan or (plan.kind ~= "assemble" and plan.kind ~= "discover") then
    return
  end
  hinted = true

  local skills = require "paseo.skills"
  local bundled = skills.bundled()
  if #bundled == 0 then
    return
  end
  for _, dir in ipairs(skills.targets "global" or {}) do
    for _, skill in ipairs(bundled) do
      local at = skills.inspect(skill, dir)
      if at == "ours_link" or at == "ours_copy" then
        return
      end
    end
  end

  vim.notify(
    "paseo: this plugin ships skills that teach an agent this layout — "
      .. "`:lua require('paseo.skills').install()`",
    vim.log.levels.INFO
  )
end

---@param opts? table  `all = true` lists every project's workspaces.
function M.open(opts)
  opts = opts or {}

  -- Start watching BEFORE the list draws, so the first paint shows "…"
  -- rather than a wrong "0 idle".
  agents.watch(function() end)
  if not listening then
    listening = true
    -- Push, not polling: the status column updates while the list is open.
    agents.on_change(function()
      vim.schedule(function()
        if open_list and not open_list.handle.closed then
          open_list.handle.update(open_list.rows())
        end
      end)
    end)
  end

  workspaces.list(function(list, err)
    if err then
      return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    end

    vim.schedule(function()
      -- THIS project's workspaces, unless asked for all of them: Paseo knows
      -- every project on the machine. `a` flips between the two. A project
      -- with none yet is an EMPTY list, not every project's.
      local here = workspaces.here()
      local label = vim.fn.fnamemodify(here, ":t")
      local scoped = not opts.all and workspaces.scope(list, here) or list
      local empty_here = not opts.all and #scoped == 0 and #list > 0
      list = scoped

      if #list == 0 and not empty_here then
        vim.notify("paseo: no workspaces yet", vim.log.levels.INFO)
        return require("paseo.new").open(nil, { where = "worktree" })
      end

      local widths = { project = 0, name = 0 }
      for _, ws in ipairs(list) do
        widths.project = math.min(22, math.max(widths.project, #(ws.group or ws.project or "")))
        widths.name = math.min(38, math.max(widths.name, #(ws.name or "")))
      end
      local function rows()
        local out = {}
        for i, ws in ipairs(list) do
          out[i] = item(ws, widths)
        end
        return out
      end

      ---A verb on the row under the cursor, after the list has closed.
      local function on_row(fn)
        return function(row, handle)
          handle.close()
          if row then
            fn(row.value)
          end
        end
      end

      local handle = require("paseo.ui.choose").open {
        title = ("Workspaces · %s"):format(opts.all and "all projects" or label),
        items = rows(),
        empty = "none yet in " .. label .. " — n for a new one, a for every project's",
        numbers = false,
        on_pick = function(row)
          workspaces.open(row.value)
        end,
        verbs = {
          -- The agent sessions inside it -- tabs in Paseo's presentation.
          { "s", "agents", on_row(function(ws)
            require("paseo.pickers.sessions").open(ws)
          end) },
          { "n", "new", function(row, handle)
            handle.close()
            -- Here, unless the row says otherwise: in an empty list there is
            -- no row, and the project it was opened for is the one meant.
            local root = row and row.value.projectRoot or (not opts.all and here) or nil
            local ctx = require("paseo.new").context()
            if ctx and root then
              ctx = { root = root, local_root = root, host_id = ctx.host_id, preferred = ctx.preferred }
            end
            require("paseo.new").open(ctx, { where = "worktree" })
          end },
          { "d", "archive", on_row(function(ws)
            workspaces.confirm_archive(ws, function()
              M.open(opts)
            end)
          end) },
          { "a", opts.all and "this project" or "all", function(_, handle)
            handle.close()
            M.open(vim.tbl_extend("force", opts, { all = not opts.all }))
          end },
          -- Review it without leaving this window: tcd into the workspace so
          -- the repo list widens to the member worktrees, then hand off.
          -- WHAT "review" MEANS IS NOT OURS TO DECIDE: this fires a
          -- `User PaseoReview` autocmd with the root in `data` and stops.
          { "r", "review", on_row(function(ws)
            if not ws.directory then
              return
            end
            vim.cmd.tcd(vim.fn.fnameescape(ws.directory))
            require("paseo.repos").invalidate()
            -- `focus = false`: the cursor belongs in whatever review opens.
            require("paseo.ui.chat").follow(ws.directory, { focus = false })
            vim.api.nvim_exec_autocmds("User", {
              pattern = "PaseoReview",
              data = { root = ws.directory },
            })
          end) },
        },
      }
      open_list = { handle = handle, rows = rows }
    end)
  end)
end

return M
