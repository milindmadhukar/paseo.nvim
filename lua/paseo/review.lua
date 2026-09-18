--- The diff panel.
---
--- `:Gitsigns diff` is per-tab and single-repo BY DESIGN: it resolves its repo
--- from `fn.getcwd()` (`actions/diff.lua:1118`) and names its buffer
--- `gitsigns-diff://<gitdir>//<tab>`. So a workspace gets one tab per member
--- repo, each `tcd`'d into that repo -- which is the only arrangement in which
--- the panel can show more than one of them at once.

local repos = require "paseo.repos"

local M = {}

---True when a tab holds nothing but one empty, unmodified buffer -- i.e. it is
---the staging tab we made and gitsigns then opened its panel elsewhere.
---@param tab integer
---@return boolean
local function is_scratch(tab)
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  if #wins ~= 1 then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(wins[1])
  return vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
end

---Tab-scoped chdir is load-bearing here and project.nvim fights it:
---`silent_chdir` with `scope_chdir = "global"` re-chdirs on buffer switches,
---which would repoint every panel at whichever repo was touched last. Rather
---than reconfigure a plugin the user may want global, the tcd is re-asserted
---whenever the tab is entered.
---@param worktree string
local function pin_cwd(worktree)
  vim.cmd.tcd(vim.fn.fnameescape(worktree))

  local tab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_create_autocmd("TabEnter", {
    group = vim.api.nvim_create_augroup("paseo.review." .. tab, { clear = true }),
    callback = function()
      if not vim.api.nvim_tabpage_is_valid(tab) then
        return true
      end
      if vim.api.nvim_get_current_tabpage() == tab and vim.fn.getcwd() ~= worktree then
        vim.cmd.tcd(vim.fn.fnameescape(worktree))
      end
    end,
  })
end

---Open a diff panel per repo, each in its own tab.
---
---SERIALISED, and that is not a style choice. `gitsigns.diff()` runs its body
---asynchronously and reads `fn.getcwd()` *inside* it (`actions/diff.lua:1118`),
---so firing one per repo in a loop means every panel resolves its repo from
---whatever tab happened to be current when its body finally ran -- which is the
---last one. Observed directly: two tabs, two `tcd`s, zero panels. Each panel
---now waits for the previous one's callback before the next tab is created.
---@param opts? { unified?: boolean }
---@param callback? fun(opened: integer)
function M.open(opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local list = repos.list()
  if #list == 0 then
    vim.notify("paseo: not inside a git repository", vim.log.levels.WARN)
    return callback(0)
  end

  if not pcall(require, "gitsigns") then
    vim.notify("paseo: gitsigns is not available", vim.log.levels.ERROR)
    return callback(0)
  end

  local gs = require "gitsigns"
  local opened, index = 0, 0

  local function step()
    index = index + 1
    local repo = list[index]
    if not repo then
      if opened > 1 then
        vim.cmd.tabfirst()
      end
      return callback(opened)
    end

    -- A staging tab, purely to own a cwd for the panel to resolve against.
    -- The panel opens in a tab of its own, so this one is discarded after.
    vim.cmd.tabnew()
    vim.cmd.tcd(vim.fn.fnameescape(repo.worktree))
    local staging = vim.api.nvim_get_current_tabpage()

    -- The Lua API rather than `:Gitsigns diff`, because only this form takes a
    -- callback -- and without the callback there is nothing to serialise on.
    gs.diff(nil, nil, { diff = opts.unified and "unified" or nil }, function(err)
      local panel = vim.api.nvim_get_current_tabpage()

      if err then
        vim.notify(("paseo: %s: %s"):format(repo.name, err), vim.log.levels.ERROR)
      else
        opened = opened + 1
        -- The panel inherits the staging tab's cwd, so re-pin it there; that is
        -- the tab that has to survive project.nvim's global chdir.
        if panel ~= staging then
          pin_cwd(repo.worktree)
        end
      end

      -- Drop the staging tab, but only if it is still the empty scratch we
      -- made -- never if the panel landed in it, and never if something else
      -- claimed it.
      if panel ~= staging and vim.api.nvim_tabpage_is_valid(staging) and is_scratch(staging) then
        pcall(vim.cmd, ("tabclose %d"):format(vim.api.nvim_tabpage_get_number(staging)))
      elseif err and panel == staging and is_scratch(staging) then
        pcall(vim.cmd, ("tabclose %d"):format(vim.api.nvim_tabpage_get_number(staging)))
      end

      vim.schedule(step)
    end)
  end

  step()
end

return M
