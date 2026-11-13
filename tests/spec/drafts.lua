--- Drafts kept across restarts: the store, and the new-session screen
--- filling it and coming back from it.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

local ENTRIES = {
  {
    provider = "test",
    label = "Test",
    status = "ready",
    enabled = true,
    defaultModeId = "default",
    modes = { { id = "default", label = "Default" }, { id = "plan", label = "Plan" } },
    models = {
      {
        id = "big",
        label = "Big",
        isDefault = true,
        thinkingOptions = { { id = "low", label = "Low" }, { id = "high", label = "High" } },
        defaultThinkingOptionId = "low",
      },
    },
  },
}

---@return table
local function on_disk()
  local drafts = require "paseo.drafts"
  local fd = io.open(drafts.path(), "r")
  if not fd then
    return {}
  end
  local text = fd:read "*a"
  fd:close()
  local ok, parsed = pcall(vim.json.decode, text)
  return ok and type(parsed) == "table" and type(parsed.drafts) == "table" and parsed.drafts or {}
end

local function test_store()
  local drafts = require "paseo.drafts"
  drafts.reset()
  os.remove(drafts.path())
  local delay = drafts.DELAY
  drafts.DELAY = 20
  local ok, failure = pcall(function()
    drafts.save { id = "a", ctx = { root = "/x" }, prompt = { "one" }, choice = {} }
    eq("drafts: not written on every key", on_disk().a, nil)
    vim.wait(500, function()
      return on_disk().a ~= nil
    end)
    eq("drafts: written a moment later", on_disk().a and on_disk().a.prompt[1], "one")

    drafts.save { id = "b", ctx = { root = "/y" }, prompt = { "two" }, choice = {} }
    drafts.flush()
    eq("drafts: flush writes at once", on_disk().b and on_disk().b.prompt[1], "two")

    -- Read back fresh, as the next Neovim does.
    drafts.reset()
    local all = drafts.all()
    eq("drafts: both come back", #all, 2)
    eq("drafts: in the order they were first kept", all[1].id, "a")

    drafts.remove "a"
    drafts.flush()
    eq("drafts: a removed one leaves the file", on_disk().a, nil)
    truthy("drafts: the other stays", on_disk().b ~= nil)

    -- QUITTING is not throwing away.
    drafts.save { id = "c", ctx = { root = "/z" }, prompt = { "three" }, choice = {} }
    api.nvim_exec_autocmds("VimLeavePre", { group = "paseo.drafts" })
    eq("drafts: what was pending is written on the way out", on_disk().c and on_disk().c.prompt[1], "three")
    drafts.remove "c"
    drafts.flush()
    truthy("drafts: and what tears the chats down after keeps it", on_disk().c ~= nil)
  end)
  drafts.DELAY = delay
  drafts.reset()
  os.remove(drafts.path())
  if not ok then
    error(failure, 0)
  end
end

local function test_round_trip()
  local drafts = require "paseo.drafts"
  local newtask = require "paseo.ui.newtask"
  local create = require "paseo.ui.create"
  local terminals = require "paseo.terminals"
  local workspaces = require "paseo.workspaces"
  local bridge = require "paseo.bridge"
  local chats = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  local old = {
    catalogue = create.catalogue,
    presets = terminals.presets,
    branches = workspaces.branches,
    request = bridge.request,
    chat_open = chats.open,
    current = chats.current(),
  }
  drafts.reset()
  os.remove(drafts.path())
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local ok, failure = pcall(function()
    create.catalogue = function(_, cb)
      cb(ENTRIES, nil)
    end
    terminals.presets = function(_, cb)
      cb { { label = "Shell" } }
    end
    workspaces.branches = function(_, cb)
      cb { "main" }
    end
    bridge.request = function(op, _, cb)
      if op == "providers.features" then
        return cb(nil, { features = {} })
      end
      cb(nil, { id = "agent-new", agentId = "agent-new" })
    end
    chats.open = function() end
    local ctx = { root = dir, local_root = dir, host_id = "local" }
    local function loaded(task)
      vim.wait(500, function()
        return task.draft ~= nil and not task.draft.loading
      end)
    end

    -- Untouched: nothing to keep.
    local empty = newtask.open(ctx, {})
    loaded(newtask.task(empty))
    drafts.flush()
    eq("drafts: an untouched draft is not kept", vim.tbl_count(on_disk()), 0)

    -- A choice made, and words typed.
    local a = newtask.open(ctx, {})
    local ta = newtask.task(a)
    loaded(ta)
    local mode
    for _, g in ipairs(ta.view:groups()) do
      if g.id == "mode" then
        mode = g
      end
    end
    ta.view.source:apply(mode, { id = "plan" }, function() end)
    api.nvim_buf_set_lines(a.composer, 0, -1, false, { "fix the invoice", "rounding" })
    api.nvim_exec_autocmds("TextChanged", { buffer = a.composer })
    drafts.flush()
    local kept = on_disk()[ta.id]
    truthy("drafts: a draft with a choice and words is kept", kept ~= nil, vim.inspect(on_disk()))
    eq("drafts: its words", kept and kept.prompt, { "fix the invoice", "rounding" })
    eq("drafts: its mode", kept and kept.choice.modeId, "plan")
    eq("drafts: its provider", kept and kept.choice.provider, "test/big")
    eq("drafts: where it was opened", kept and kept.ctx.root, dir)

    -- A NEW NEOVIM: nothing in memory, the file read again.
    native.remove(empty)
    chats.dispose(empty)
    local id = ta.id
    -- Gone from memory the way quitting takes it: the file keeps it.
    api.nvim_exec_autocmds("VimLeavePre", { group = "paseo.drafts" })
    native.remove(a)
    chats.dispose(a)
    native.reset()
    drafts.reset()
    truthy("drafts: still on disk after the chats went with Neovim", on_disk()[id] ~= nil)

    local other = newtask.open(ctx, {})
    loaded(newtask.task(other))
    vim.wait(500, function()
      for _, c in ipairs(native.listed()) do
        if c.draft_id == id then
          return true
        end
      end
    end)
    local back
    for _, c in ipairs(native.listed()) do
      if c.draft_id == id then
        back = c
      end
    end
    truthy("drafts: it came back onto the new Paseo tab", back ~= nil)
    if back then
      local tb = newtask.task(back)
      loaded(tb)
      eq("drafts: with its words", api.nvim_buf_get_lines(back.composer, 0, -1, false), { "fix the invoice", "rounding" })
      eq("drafts: and its mode", tb.draft.modeId, "plan")
      eq("drafts: what you opened is still in the middle", native.chat(), other)
    end

    -- SENT: out of the file.
    if back then
      local answer
      back.draft.start("fix the invoice\nrounding", {}, function(err)
        answer = { err = err }
      end)
      vim.wait(500, function()
        return answer ~= nil
      end)
      eq("drafts: sent", answer and answer.err, nil)
      drafts.flush()
      eq("drafts: a sent draft leaves the file", on_disk()[id], nil)
    end
    native.remove(other)
    chats.dispose(other)
  end)
  chats.open = old.chat_open
  create.catalogue, terminals.presets = old.catalogue, old.presets
  workspaces.branches, bridge.request = old.branches, old.request
  chats.set_current(old.current)
  native.reset()
  drafts.reset()
  os.remove(drafts.path())
  vim.defer_fn(function()
    vim.fn.delete(dir, "rf")
  end, 5000)
  if not ok then
    error(failure, 0)
  end
end

return {
  { "drafts.store", test_store },
  { "drafts.round_trip", test_round_trip },
}
