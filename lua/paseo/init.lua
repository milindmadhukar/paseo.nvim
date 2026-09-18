--- paseo.nvim -- review every hunk by hand, and ask an agent when one is opaque.
---
--- Entry point. Holds `setup()`, the `:Paseo` command, and nothing else:
--- submodules are required lazily from the dispatch table below so that loading
--- this file costs a config merge and one autocmd.

local M = {}

M.config = require "paseo.config"

---@type table<string, { run: fun(args: string[]), desc: string }>
local commands = {}

commands.repos = {
  desc = "List the repos in the current unit of work",
  run = function()
    local repos = require("paseo.repos").list()
    if #repos == 0 then
      vim.notify("paseo: not inside a git repository", vim.log.levels.WARN)
      return
    end
    local lines = {}
    for i, repo in ipairs(repos) do
      local where = vim.fn.fnamemodify(repo.worktree, ":~")
      lines[#lines + 1] = ("%d. %s  %s"):format(i, repo.name, where)
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "paseo: repos" })
  end,
}

commands.health = {
  desc = "Run :checkhealth paseo",
  run = function()
    vim.cmd "checkhealth paseo"
  end,
}

---@param opts? table See `paseo.Config`.
function M.setup(opts)
  M.config.setup(opts)

  local repos = require "paseo.repos"

  -- Resolved-repo paths are cached, and a chdir is the one event that reliably
  -- means "the answer may have changed" -- project.nvim chdirs on every buffer
  -- switch, and switching workspaces is a chdir into a different worktree.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = vim.api.nvim_create_augroup("paseo.repos", { clear = true }),
    callback = function()
      repos.invalidate()
    end,
  })

  vim.api.nvim_create_user_command("Paseo", function(args)
    local sub = args.fargs[1] or "repos"
    local cmd = commands[sub]
    if not cmd then
      vim.notify(("paseo: unknown subcommand `%s`"):format(sub), vim.log.levels.ERROR)
      return
    end
    cmd.run(vim.list_slice(args.fargs, 2))
  end, {
    nargs = "*",
    desc = "paseo.nvim",
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, vim.tbl_keys(commands))
    end,
  })
end

return M
