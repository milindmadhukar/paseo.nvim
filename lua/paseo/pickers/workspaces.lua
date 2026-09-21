--- The workspace picker.
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

---@param ws paseo.PaseoWorkspace
---@param widths { project: integer, name: integer }
---@return string
local function display(ws, widths)
  local shape = ws.assembled and ("%d repos"):format(#ws.members)
    or (ws.ownedWorktree and "worktree" or "local")
  return ("%-" .. widths.project .. "s  %-" .. widths.name .. "s  %-8s  %s"):format(
    -- The GROUP, not the daemon's project: a `ws` workspace is registered as
    -- its own top-level project named after itself. See `workspaces.group`.
    (ws.group or ws.project or "?"):sub(1, widths.project),
    (ws.name or "?"):sub(1, widths.name),
    shape,
    agents.summary(ws.directory or "")
  )
end

---Said once per session, at the only moment it is relevant.
---
---A HINT, NEVER AN INSTALL. Writing into `~/.claude/skills` changes the
---behaviour of a DIFFERENT program, and no Neovim plugin gets to do that as a
---side effect of a command about worktrees. The plugin's own stance is the
---opposite one: `:Paseo ws init` shows you the manifest and makes you `:w` it.
---The problem was only ever discovery, and one line of it is the whole fix.
local hinted = false

---@param plan paseo.Strategy|nil
local function hint_skills(plan)
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
      .. "`:Paseo skills install`",
    vim.log.levels.INFO
  )
end

---Create a workspace by name.
---
---"creating", not "assembling": assembly is one of three shapes this may turn
---out to be, and which one is not settled until `workspaces.strategy` has
---looked at the directory. The shape is reported AFTERWARDS, when it is known.
---@param name string
---@param root? string
---@param after? fun()
function M.named(name, root, after)
  if name:find "[/\\ ]" then
    return vim.notify("paseo: names may not contain slashes or spaces", vim.log.levels.ERROR)
  end

  vim.notify("paseo: creating " .. name .. "…", vim.log.levels.INFO)
  workspaces.create({ name = name, root = root }, function(_, err, plan)
    if err then
      return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    end
    -- No id, no error, no plan: the manifest dialog was dismissed, so nothing
    -- was written and nothing was created. Said out loud only because the
    -- "creating…" above it would otherwise be the last word on screen, and a
    -- message that never completed reads as a hang.
    if not plan then
      return vim.notify("paseo: cancelled — nothing was written", vim.log.levels.INFO)
    end
    vim.notify(
      ("paseo: created %s — %s"):format(name, workspaces.describe(plan)),
      vim.log.levels.INFO
    )
    hint_skills(plan)
    if after then
      vim.schedule(after)
    end
  end)
end

---Prompt for a name, then create.
---@param root? string
---@param after? fun()
function M.create(root, after)
  vim.ui.input({ prompt = "New workspace name: " }, function(name)
    if not name or name == "" then
      return
    end
    M.named(name, root, after)
  end)
end

---@param opts? table
function M.open(opts)
  opts = opts or {}

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return vim.notify("paseo: telescope is not available", vim.log.levels.ERROR)
  end
  local finders = require "telescope.finders"
  local actions = require "telescope.actions"
  local state = require "telescope.actions.state"
  local conf = require("telescope.config").values

  -- Start watching BEFORE the picker draws, so the first paint shows "…"
  -- rather than a wrong "0 idle".
  agents.watch(function() end)

  workspaces.list(function(list, err)
    if err then
      return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    end

    vim.schedule(function()
      if #list == 0 then
        vim.notify("paseo: no workspaces yet", vim.log.levels.INFO)
        return M.create(nil, function()
          M.open(opts)
        end)
      end

      local widths = { project = 0, name = 0 }
      for _, ws in ipairs(list) do
        widths.project = math.min(22, math.max(widths.project, #(ws.group or ws.project or "")))
        widths.name = math.min(38, math.max(widths.name, #(ws.name or "")))
      end

      local picker
      picker = pickers.new(opts, {
        prompt_title = "Workspaces  ·  <CR> open  <C-s> sessions  <C-n> new  <C-d> archive",
        finder = finders.new_table {
          results = list,
          entry_maker = function(ws)
            return {
              value = ws,
              display = function()
                return display(ws, widths)
              end,
              ordinal = ("%s %s"):format(ws.group or ws.project or "", ws.name or ""),
              path = ws.directory,
            }
          end,
        },
        sorter = conf.generic_sorter(opts),
        attach_mappings = function(bufnr, map)
          local function reopen()
            M.open(opts)
          end

          actions.select_default:replace(function()
            local entry = state.get_selected_entry()
            actions.close(bufnr)
            if entry then
              workspaces.open(entry.value)
            end
          end)

          -- The sessions inside it -- the tabs, in the app's terms.
          map({ "i", "n" }, "<C-s>", function()
            local entry = state.get_selected_entry()
            actions.close(bufnr)
            if entry then
              require("paseo.pickers.sessions").open(entry.value)
            end
          end)

          map({ "i", "n" }, "<C-n>", function()
            local entry = state.get_selected_entry()
            actions.close(bufnr)
            M.create(entry and entry.value.projectRoot or nil, reopen)
          end)

          map({ "i", "n" }, "<C-d>", function()
            local entry = state.get_selected_entry()
            actions.close(bufnr)
            if entry then
              workspaces.confirm_archive(entry.value, reopen)
            end
          end)

          -- Review it without leaving this window: tcd into the workspace so
          -- the repo list widens to the member worktrees, then hand off.
          --
          -- WHAT "review" MEANS IS NOT OURS TO DECIDE. The quickfix list and
          -- the changed-files picker live in your config now, so this fires a
          -- `User PaseoReview` autocmd with the root in `data` and stops there.
          map({ "i", "n" }, "<C-r>", function()
            local entry = state.get_selected_entry()
            actions.close(bufnr)
            if entry and entry.value.directory then
              vim.cmd.tcd(vim.fn.fnameescape(entry.value.directory))
              require("paseo.repos").invalidate()
              -- `focus = false` even on the full-screen surface: <C-r> is a
              -- handoff to the review autocmd, and the cursor belongs in
              -- whatever that opens.
              require("paseo.ui.chat").follow(entry.value.directory, { focus = false })
              vim.api.nvim_exec_autocmds("User", {
                pattern = "PaseoReview",
                data = { root = entry.value.directory },
              })
            end
          end)

          return true
        end,
      })

      -- Push, not polling: the status column updates while the picker is open.
      agents.on_change(function()
        vim.schedule(function()
          local prompt = picker and picker.prompt_bufnr
          if prompt and vim.api.nvim_buf_is_valid(prompt) then
            -- reset_prompt = false: a column changing under you must not throw
            -- away what you have typed.
            pcall(picker.refresh, picker, picker.finder, { reset_prompt = false })
          end
        end)
      end)

      picker:find()
    end)
  end)
end

return M
