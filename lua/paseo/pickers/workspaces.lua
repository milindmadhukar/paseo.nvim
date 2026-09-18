--- The workspace picker: the Conductor-style dashboard.
---
--- Rows come from `ws`'s registry, read directly because a picker cannot afford
--- a fork. The status column is decorated from the LIVE agent directory and
--- refreshed by push, which is the payoff for the sidecar.

local agents = require "paseo.agents"
local registry = require "paseo.registry"

local M = {}

---Open a workspace in a NEW WINDOW rather than chdir'ing this one.
---
---Switching workspaces by chdir leaves this instance's buffers, LSP clients and
---jumplist pointing into the workspace you just left. A separate window is the
---honest model: one window, one unit of work.
---
---`utils.gui.spawn` is this config's own detached-Neovide launcher, which
---already handles the four things that make a spawned Neovide come up
---windowless. It is optional -- the plugin must install for people who do not
---have it -- so its absence falls back to `tcd`.
---Tell the daemon about the workspace before opening it.
---
---THE SEAM: `ws` assembles the composite directory, and this hands it to Paseo
---as an ordinary LOCAL workspace. Paseo never learns it is six worktrees; it
---sees a directory with agents in it -- which is what makes a multi-repo
---project work at all, since Paseo's own worktree isolation requires a git
---repository.
---
---Best-effort and asynchronous: a daemon that is down must not stop you opening
---a workspace whose worktrees are already on disk. `workspaces.open()` reuses
---the active workspace for a directory, so repeating this is free.
---@param root string
local function register(root)
  local bridge = require "paseo.bridge"
  bridge.ensure(function(err)
    if err then
      return
    end
    bridge.request("workspace.open", { cwd = root }, function() end)
  end)
end

---@param root string
local function open_workspace(root)
  register(root)

  local ok, gui = pcall(require, "utils.gui")
  if ok and type(gui.spawn) == "function" then
    gui.spawn { cwd = root }
    return
  end

  if vim.fn.executable "neovide" == 1 then
    vim.fn.jobstart({ "neovide" }, { cwd = root, detach = true, stdin = "null" })
    return
  end

  vim.cmd.tcd(vim.fn.fnameescape(root))
  require("paseo.repos").invalidate()
  vim.notify("paseo: tab cwd is now " .. vim.fn.fnamemodify(root, ":~"), vim.log.levels.INFO)
end

---@param ws paseo.Workspace
---@param width integer
---@return string
local function display(ws, width)
  local active = #registry.active(ws)
  local status = agents.summary(ws.root)
  return ("%-" .. width .. "s  %d repo%s  %s"):format(
    ws.name,
    active,
    active == 1 and " " or "s",
    status
  )
end

---@param opts? table
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

  local workspaces = registry.list()
  if #workspaces == 0 then
    vim.notify("paseo: no workspaces yet -- `ws create <name>` makes one", vim.log.levels.INFO)
    return
  end

  local width = 0
  for _, ws in ipairs(workspaces) do
    width = math.max(width, #ws.name)
  end

  -- Start watching BEFORE the picker draws. The first paint then shows "…"
  -- rather than a wrong "0 idle", and the refresh below fills it in.
  agents.watch(function() end)

  local picker
  picker = pickers.new(opts, {
    prompt_title = "Workspaces",
    finder = finders.new_table {
      results = workspaces,
      entry_maker = function(ws)
        return {
          value = ws,
          display = function()
            return display(ws, width)
          end,
          ordinal = ws.name .. " " .. ws.project,
          path = ws.root,
        }
      end,
    },
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(bufnr, map)
      actions.select_default:replace(function()
        local entry = state.get_selected_entry()
        actions.close(bufnr)
        if entry then
          open_workspace(entry.value.root)
        end
      end)

      -- Review the workspace without leaving this window: the repo list widens
      -- to the member worktrees on its own, because `repos.list()` returns a
      -- list and always did.
      map({ "i", "n" }, "<C-r>", function()
        local entry = state.get_selected_entry()
        actions.close(bufnr)
        if entry then
          vim.cmd.tcd(vim.fn.fnameescape(entry.value.root))
          require("paseo.repos").invalidate()
          require("paseo.qf").all()
        end
      end)

      return true
    end,
  })

  -- Push, not polling. The status column updates while the picker is open,
  -- which is the entire difference between a dashboard and a list.
  agents.on_change(function()
    vim.schedule(function()
      local prompt = picker and picker.prompt_bufnr
      if prompt and vim.api.nvim_buf_is_valid(prompt) then
        -- reset_prompt = false: the column changing under you must not throw
        -- away what you have typed.
        pcall(picker.refresh, picker, picker.finder, { reset_prompt = false })
      end
    end)
  end)

  picker:find()
end

return M
