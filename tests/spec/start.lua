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
    vim.cmd "Paseo wcreate"
    eq(":Paseo wcreate opens it on a new worktree, no name asked", seen and seen.opts, { where = "worktree" })
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
