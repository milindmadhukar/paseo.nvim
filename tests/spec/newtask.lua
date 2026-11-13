--- The new-task screen: one screen, the prompt box focused, every choice
--- prefilled -- and the worktree named by the daemon, not by us.

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

---A git repo of its own, so "Where" is offered.
---@return string
local function repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for _, args in ipairs {
    { "init", "-q", "-b", "main", "." },
    { "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "i" },
  } do
    vim.system(vim.list_extend({ "git", "-C", dir }, args)):wait()
  end
  return dir
end

---@param buf integer
---@return string
local function text(buf)
  return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function test_newtask()
  local new = require "paseo.new"
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
    create = workspaces.create,
    request = bridge.request,
    chat_open = chats.open,
    current = chats.current(),
  }
  local dir = repo()

  local ok, failure = pcall(function()
    create.catalogue = function(_, cb)
      cb(ENTRIES, nil)
    end
    terminals.presets = function(_, cb)
      cb { { label = "Shell" }, { label = "claude", command = "claude" } }
    end
    workspaces.branches = function(_, cb)
      cb { "main", "dev", "feat/x" }
    end
    local requested
    bridge.request = function(op, args, cb)
      requested = { op = op, args = args }
      if op == "providers.features" then
        return cb(nil, { features = {} })
      end
      cb(nil, { id = "agent-new", agentId = "agent-new" })
    end
    local created
    workspaces.create = function(opts, cb)
      created = opts
      cb("wks_1", nil, nil, { id = "wks_1", directory = dir .. "-wt", agent_id = "agent-wt", name = "frail-squid" })
    end
    local opened
    chats.open = function(opts)
      opened = opts
    end

    local ctx = { root = dir, local_root = dir, host_id = "local" }
    local chat = newtask.open(ctx, {})
    local task = newtask.task(chat)
    truthy("newtask: it is a draft chat", chat.draft ~= nil)
    truthy("newtask: on the full-screen surface", native.has(chat))
    vim.wait(500, function()
      return task.draft ~= nil and not task.draft.loading and task.branches ~= nil
    end)

    local conv = api.nvim_win_get_buf(chat.win_conversation)
    eq("newtask: the conversation window shows the choices", vim.bo[conv].filetype, "paseo-new")
    local shown = text(conv)
    for _, want in ipairs { "Chat", "Terminal", "Here", "New worktree", "Test", "Big" } do
      truthy("newtask: it offers " .. want, shown:find(want, 1, true) ~= nil, shown)
    end
    truthy("newtask: no base until it is a worktree", not shown:find("Base", 1, true))
    eq("newtask: the cursor is in the box you type in", api.nvim_get_current_win(), chat.win_composer)

    -- A worktree, off `dev`: no name asked, the daemon's to name.
    task.where = "worktree"
    task.base = "dev"
    task.view.redraw()
    vim.wait(50)
    truthy("newtask: a worktree shows its base", text(conv):find("Base", 1, true) ~= nil)
    local answer
    chat.draft.start("Fix the invoice rounding", {}, function(err, agent_id)
      answer = { err = err, agent_id = agent_id }
    end)
    vim.wait(500, function()
      return answer ~= nil
    end)
    eq("newtask: no error", answer and answer.err, nil)
    eq("newtask: a worktree was asked for with NO name", created and created.name, nil)
    eq("newtask: off the base chosen", created and created.base, "dev")
    eq("newtask: with the prompt as its first message", created and created.first.prompt, "Fix the invoice rounding")
    eq("newtask: and the model chosen", created and created.first.provider, "test/big")
    eq("newtask: then its agent opened", opened and opened.agent_id, "agent-wt")
    truthy("newtask: and the draft went away", not native.has(chat))

    -- REMEMBERED: the next one here opens where this one went.
    local again = new.remembered(ctx)
    eq("newtask: where is remembered", again.where, "worktree")
    eq("newtask: the base is remembered", again.base, "dev")
    eq("newtask: the model is remembered", again.provider, "test/big")

    -- HERE, with the screen opened on a terminal by the caller: the kind
    -- asked for wins over the remembered one.
    local chat2 = newtask.open(ctx, { kind = "terminal" })
    local task2 = newtask.task(chat2)
    eq("newtask: opened on what was asked for", task2.kind, "terminal")
    eq("newtask: but where it went last time", task2.where, "worktree")
    native.close(chat2)
    chats.discard(chat2)

    -- A chat HERE becomes the agent in place, and the conversation is back.
    local chat3 = newtask.open(ctx, { kind = "chat", where = "here" })
    local task3 = newtask.task(chat3)
    vim.wait(500, function()
      return task3.draft ~= nil and not task3.draft.loading
    end)
    answer = nil
    chat3.draft.start("hello", {}, function(err, agent_id)
      answer = { err = err, agent_id = agent_id }
    end)
    vim.wait(500, function()
      return answer ~= nil
    end)
    eq("newtask: here, the agent is this chat", answer and answer.agent_id, "agent-new")
    eq("newtask: through agent.start", requested and requested.op, "agent.start")
    eq(
      "newtask: and the conversation is back in its window",
      api.nvim_win_get_buf(chat3.win_conversation),
      chat3.conversation
    )
    native.close(chat3)
    chats.discard(chat3)
  end)

  create.catalogue, terminals.presets = old.catalogue, old.presets
  workspaces.branches, workspaces.create = old.branches, old.create
  bridge.request, chats.open = old.request, old.chat_open
  chats.set_current(old.current)
  native.reset()
  vim.fn.delete(dir, "rf")
  if not ok then
    error(failure, 0)
  end
end

local function test_isolation()
  local new = require "paseo.new"
  local dir = repo()
  local iso = new.isolation { root = dir, local_root = dir, host_id = "local" }
  eq("isolation: a git repo can have a worktree", iso and iso.kind, "worktree")
  eq("isolation: off what is checked out", iso and iso.base, "main")
  local plain = vim.fn.tempname()
  vim.fn.mkdir(plain, "p")
  eq("isolation: a plain directory cannot", new.isolation { root = plain, local_root = plain, host_id = "local" }, nil)
  vim.fn.delete(dir, "rf")
  vim.fn.delete(plain, "rf")
end

return {
  { "newtask.screen", test_newtask },
  { "newtask.isolation", test_isolation },
}
