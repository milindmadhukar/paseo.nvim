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

commands.changes = {
  desc = "Changed-files picker for this unit of work",
  run = function()
    require("paseo.pickers.changes").open()
  end,
}

commands.hunks = {
  desc = "Every hunk in this unit of work, as a quickfix list",
  run = function()
    require("paseo.qf").all()
  end,
}

commands.stage = {
  desc = "Stage the hunk the quickfix list is on, then advance",
  run = function()
    require("paseo.qf").stage()
  end,
}

commands.review = {
  desc = "Diff panel, one tab per repo",
  run = function(args)
    require("paseo.review").open({ unified = args[1] == "unified" }, function(opened)
      if opened == 0 then
        vim.notify("paseo: no diff panel opened", vim.log.levels.WARN)
      end
    end)
  end,
}

commands.workspaces = {
  desc = "Workspace picker, with a live agent status column",
  run = function()
    require("paseo.pickers.workspaces").open()
  end,
}

commands.explain = {
  desc = "Explain the hunk under the cursor",
  run = function(args)
    require("paseo.explain").explain(args[1])
  end,
}

commands.ask = {
  desc = "Ask a question about the hunk under the cursor",
  run = function(args)
    require("paseo.explain").ask(args[1])
  end,
}

commands.agent = {
  desc = "Sidecar status; `agent stop` shuts it down",
  run = function(args)
    local b = require "paseo.bridge"
    if args[1] == "stop" then
      b.stop()
      vim.notify("paseo: sidecar stopped", vim.log.levels.INFO)
      return
    end
    if not b.running() then
      vim.notify("paseo: sidecar is not running", vim.log.levels.INFO)
      return
    end
    b.request("agents.list", {}, function(err, result)
      if err then
        vim.notify("paseo: " .. err, vim.log.levels.ERROR)
        return
      end
      local lines = {}
      for _, agent in ipairs(result.entries or {}) do
        lines[#lines + 1] = ("%s  %s  %s"):format(
          agent.status,
          agent.provider or "?",
          agent.title or agent.id
        )
      end
      vim.notify(#lines > 0 and table.concat(lines, "\n") or "no agents", vim.log.levels.INFO, {
        title = "paseo: agents",
      })
    end)
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
      require("paseo.registry").invalidate()
    end,
  })

  -- Streaming events have to be wired before anything can arrive on them.
  require("paseo.explain").attach()

  -- The sidecar is a child process; leaving it behind on :qa would leak one per
  -- session.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("paseo.bridge", { clear = true }),
    callback = function()
      require("paseo.bridge").stop()
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
