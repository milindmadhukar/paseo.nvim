--- Active-agent quit protection.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_quit()
  local quit = require "paseo.quit"
  local agents = require "paseo.agents"
  local bridge = require "paseo.bridge"
  local config = require "paseo.config"
  local daemon = require "paseo.daemon"
  local old_running, old_ready, old_active = bridge.running, agents.ready, agents.active
  local old_started = daemon.started_here
  local old_select = vim.ui.select

  local ok, failure = pcall(function()
    eq("quit: active-agent warnings default on", config.defaults().quit.warn_active_agents, true)
    agents._apply {
      kind = "snapshot",
      entries = {
        { id = "running", status = "running" },
        { id = "starting", status = "starting" },
        { id = "initializing", status = "initializing" },
        { id = "queued", status = "queued" },
        { id = "attention", status = "idle", requiresAttention = true },
        { id = "idle", status = "idle" },
        { id = "failed", status = "failed" },
        { id = "closed", status = "closed" },
      },
    }
    eq("quit: only live or attention agent sessions are active", #agents.active(), 5)

    bridge.running = function()
      return true
    end
    agents.ready = function()
      return true
    end
    daemon.started_here = function()
      return true
    end
    local active = {}
    agents.active = function()
      return active
    end
    local choice, prompts = nil, 0
    vim.ui.select = function(_, opts, done)
      prompts = prompts + 1
      truthy(
        "quit: explains that daemon work continues",
        opts.prompt:find("will continue on the daemon", 1, true) ~= nil,
        opts.prompt
      )
      done(choice)
    end

    local proceeded = 0
    quit.guard(function()
      proceeded = proceeded + 1
    end)
    eq("quit: no active work proceeds without a prompt", { proceeded, prompts }, { 1, 0 })

    active = { { id = "a", status = "running" } }
    choice = "Cancel"
    quit.guard(function()
      proceeded = proceeded + 1
    end)
    eq("quit: cancelling prevents the exit", proceeded, 1)
    choice = "Quit Neovim"
    quit.guard(function()
      proceeded = proceeded + 1
    end)
    eq("quit: confirming continues the original route", proceeded, 2)

    quit.guard(function()
      proceeded = proceeded + 1
    end, { force = true })
    eq("quit: force is an explicit bypass", proceeded, 3)

    config.setup { quit = { warn_active_agents = false } }
    choice = "Cancel"
    quit.guard(function()
      proceeded = proceeded + 1
    end)
    eq("quit: the warning can be disabled", proceeded, 4)
    config.setup {}

    -- A DAEMON WE ONLY ATTACHED TO IS NOT OURS TO WARN ABOUT. It was running
    -- before this Neovim and goes on running after it, so there is nothing
    -- here to lose and nothing to ask about -- however busy its agents are.
    daemon.started_here = function()
      return false
    end
    choice = "Cancel"
    local before = prompts
    quit.guard(function()
      proceeded = proceeded + 1
    end)
    eq("quit: attaching to someone else's daemon exits silently", proceeded, 5)
    eq("quit: with nothing asked", prompts, before)
    daemon.started_here = function()
      return true
    end

    truthy("quit: qall is always an editor exit", quit.would_exit "qall")
    truthy("quit: a forced all-exit remains detectable as an exit", quit.would_exit "qall!")

    vim.cmd.tabnew()
    eq("quit: closing one Neovim tab page does not count as exiting", quit.would_exit "q", false)
    vim.cmd.tabclose()

    local float_buf = vim.api.nvim_create_buf(false, true)
    local float_win = vim.api.nvim_open_win(float_buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 2,
    })
    eq("quit: closing a float does not count as exiting", quit.would_exit "q", false)
    vim.api.nvim_win_close(float_win, true)
    vim.api.nvim_buf_delete(float_buf, { force = true })
  end)

  bridge.running, agents.ready, agents.active = old_running, old_ready, old_active
  daemon.started_here = old_started
  vim.ui.select = old_select
  config.setup {}
  truthy("quit: cases completed", ok, failure)
end

return { { "quit", test_quit } }
