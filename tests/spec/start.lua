--- Starting something: every old way in lands on the one screen.
---
--- The menus this file used to drive -- what, then where, then a name, then
--- the settings -- are gone; |paseo.new| and |paseo.ui.newtask| are tested in
--- `newtask.lua`. What is left to hold is that the keys that already know
--- what they want open the screen ON it.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_start()
  local start = require "paseo.start"
  local new = require "paseo.new"
  local old_open = new.open

  local seen
  new.open = function(ctx, opts)
    seen = { ctx = ctx, opts = opts }
  end
  local ok, failure = pcall(function()
    local ctx = { root = "/code/kora", host_id = "local" }

    start.new(ctx, "here")
    eq("start: the rail's `a` opens on a chat here", seen.opts, { kind = "chat", where = "here" })
    eq("start: for the context it was given", seen.ctx, ctx)

    start.new(ctx, "workspace")
    eq("start: `w` opens on a chat in a new worktree", seen.opts, { kind = "chat", where = "worktree" })

    start.new(ctx, "terminal")
    eq("start: `t` opens on a terminal", seen.opts, { kind = "terminal" })

    start.new(ctx)
    eq("start: no kind opens on what you chose last", seen.opts, {})

    seen = nil
    start.open(ctx)
    truthy("start: an empty directory gets the screen", seen ~= nil)
    eq("start: on what you chose last", seen.opts, {})
  end)
  new.open = old_open
  if not ok then
    error(failure, 0)
  end
end

local function test_commands()
  local new = require "paseo.new"
  local old_open = new.open
  local seen
  new.open = function(ctx, opts)
    seen = { ctx = ctx, opts = opts }
  end
  local ok, failure = pcall(function()
    vim.cmd "Paseo new"
    truthy(":Paseo new opens the screen", seen ~= nil)
    eq(":Paseo new opens it on what you chose last", seen.opts, nil)
    seen = nil
    vim.cmd "Paseo new worktree"
    eq(":Paseo new worktree opens it on a new worktree, no name asked", seen and seen.opts, { where = "worktree" })

    -- THE WHOLE SET. Anything else is a key in the chat or a Lua function.
    eq(
      ":Paseo completes to the nine commands",
      vim.fn.getcompletion("Paseo ", "cmdline"),
      { "agents", "ask", "explain", "new", "settings", "stop", "workspaces", "ws" }
    )
    eq(":Paseo ask completes qf too", vim.fn.getcompletion("Paseo ask q", "cmdline"), { "qf" })
    eq(":Paseo settings completes its groups", vim.fn.getcompletion("Paseo settings th", "cmdline"), { "thinking" })

    -- Bare is the toggle.
    local chat = require "paseo.ui.chat"
    local old_toggle, toggled = chat.toggle, false
    chat.toggle = function()
      toggled = true
    end
    vim.cmd "Paseo"
    chat.toggle = old_toggle
    truthy(":Paseo with nothing after it toggles the chat", toggled)

    -- A removed name says what there is instead.
    local old_notify, said = vim.notify, nil
    vim.notify = function(msg)
      said = msg
    end
    vim.cmd "Paseo image"
    vim.notify = old_notify
    truthy("an unknown subcommand lists the real ones", said and said:find("workspaces", 1, true), said)
  end)
  new.open = old_open
  if not ok then
    error(failure, 0)
  end
end

return {
  { "start", test_start },
  { "start.commands", test_commands },
}
