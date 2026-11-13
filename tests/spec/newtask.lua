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
    for _, want in ipairs { "Chat", "Terminal", "Local", "New worktree", "Test", "Big" } do
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

    -- LOCAL IS A NEW SESSION: a workspace of its own on the project's
    -- directory, never an agent in whichever one is on screen -- even when
    -- the context knows one.
    local real = vim.uv.fs_realpath
    local chat3 = newtask.open(vim.tbl_extend("force", ctx, { workspace_id = "wks_on_screen" }), { kind = "chat", where = "here" })
    local task3 = newtask.task(chat3)
    eq("newtask: `a` is a new session", task3.scope, "session")
    vim.wait(500, function()
      return task3.draft ~= nil and not task3.draft.loading
    end)
    truthy("newtask: the footer says it is a new session", text(api.nvim_win_get_buf(chat3.win_conversation)):find("a new session in", 1, true) ~= nil)
    answer, opened = nil, nil
    chat3.draft.start("hello", {}, function(err, agent_id)
      answer = { err = err, agent_id = agent_id }
    end)
    vim.wait(500, function()
      return answer ~= nil
    end)
    eq("newtask: Local made a session, no error", answer and answer.err, nil)
    eq("newtask: through workspace.create", requested and requested.op, "workspace.create")
    eq("newtask: not in the session on screen", requested and requested.args.workspaceId, nil)
    eq("newtask: on the project's directory", real(requested.args.cwd), real(dir))
    eq("newtask: inside that project", real(requested.args.project), real(dir))
    eq("newtask: with the first message", requested.args.prompt, "hello")
    eq("newtask: and the model chosen", requested.args.provider, "test/big")
    eq("newtask: the new session's agent opened", opened and opened.agent_id, "agent-new")
    eq("newtask: the draft did not become it", answer and answer.agent_id, nil)
    truthy("newtask: and the draft went away", not native.has(chat3))
    chats.discard(chat3)

    -- AN AGENT IN A SESSION: into the one it was opened on, by id. No Where.
    local in_session = vim.tbl_extend("force", ctx, { workspace_id = "wks_9", title = "invoice fix" })
    local chat4 = new.open(in_session, { scope = "agent", kind = "chat" })
    local task4 = newtask.task(chat4)
    eq("newtask: `A` is an agent in the session", task4.scope, "agent")
    vim.wait(500, function()
      return task4.draft ~= nil and not task4.draft.loading
    end)
    local shown4 = text(api.nvim_win_get_buf(chat4.win_conversation))
    truthy("newtask: no Local for an agent", not shown4:find("Local", 1, true), shown4)
    truthy("newtask: no New worktree for an agent", not shown4:find("New worktree", 1, true), shown4)
    truthy("newtask: it names the session", shown4:find("a new agent in invoice fix", 1, true) ~= nil, shown4)
    answer = nil
    chat4.draft.start("and the tests", {}, function(err, agent_id)
      answer = { err = err, agent_id = agent_id }
    end)
    vim.wait(500, function()
      return answer ~= nil
    end)
    eq("newtask: the agent is this chat", answer and answer.agent_id, "agent-new")
    eq("newtask: through agent.create", requested and requested.op, "agent.create")
    eq("newtask: into that session", requested and requested.args.workspaceId, "wks_9")
    eq(
      "newtask: and the conversation is back in its window",
      api.nvim_win_get_buf(chat4.win_conversation),
      chat4.conversation
    )
    native.close(chat4)
    chats.discard(chat4)

    -- An agent with NO session to go into is a new session, not a guess.
    local chat5 = new.open(ctx, { scope = "agent", kind = "chat" })
    eq("newtask: no session, so a new one", newtask.task(chat5).scope, "session")
    native.close(chat5)
    chats.discard(chat5)
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

---`:Paseo settings mode` (and thinking, model) on a draft: the draft's own
---list, straight in the picker -- not "no chat is open".
local function test_draft_pick()
  local newtask = require "paseo.ui.newtask"
  local session = require "paseo.ui.session"
  local create = require "paseo.ui.create"
  local terminals = require "paseo.terminals"
  local workspaces = require "paseo.workspaces"
  local bridge = require "paseo.bridge"
  local pick = require "paseo.ui.pick"
  local chats = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  local old = {
    catalogue = create.catalogue,
    presets = terminals.presets,
    branches = workspaces.branches,
    request = bridge.request,
    select = pick.select,
    current = chats.current(),
  }
  local dir = repo()
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
      cb(nil, {})
    end
    local asked
    pick.select = function(items, opts, on_choice)
      asked = { items = items, opts = opts }
      for i, item in ipairs(items) do
        if item.id == "plan" or item.id == "high" then
          return on_choice(item, i)
        end
      end
      on_choice(nil, nil)
    end

    local chat = newtask.open({ root = dir, local_root = dir, host_id = "local" }, {})
    local task = newtask.task(chat)
    vim.wait(500, function()
      return task.draft ~= nil and not task.draft.loading
    end)
    eq("draft pick: the draft is the current chat", chats.current(), chat)

    session.mode()
    eq("draft pick: the mode list opened at once", asked and asked.opts.kind, "paseo.mode")
    eq("draft pick: and the draft took the mode", task.draft.modeId, "plan")
    eq("draft pick: its bar says so", chat.mode, "plan")

    asked = nil
    session.thinking()
    eq("draft pick: thinking too", asked and asked.opts.kind, "paseo.thinking")
    eq("draft pick: the draft took the level", task.draft.thinkingOptionId, "high")

    native.close(chat)
    chats.discard(chat)
  end)
  create.catalogue, terminals.presets = old.catalogue, old.presets
  workspaces.branches, bridge.request, pick.select = old.branches, old.request, old.select
  chats.set_current(old.current)
  native.reset()
  -- Later: a PR lookup the surface scheduled still runs in it.
  vim.defer_fn(function()
    vim.fn.delete(dir, "rf")
  end, 5000)
  if not ok then
    error(failure, 0)
  end
end

---Two drafts, and switching between them: each one's choices are where you
---left them, not wiped the moment another buffer took the window.
local function test_draft_back()
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
    current = chats.current(),
  }
  local dir = repo()
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
      cb(nil, {})
    end
    local ctx = { root = dir, local_root = dir, host_id = "local" }

    local a = newtask.open(ctx, {})
    local ta = newtask.task(a)
    vim.wait(500, function()
      return ta.draft ~= nil and not ta.draft.loading
    end)
    ta.draft.modeId = "plan"
    api.nvim_buf_set_lines(a.composer, 0, -1, false, { "first draft" })

    local b = newtask.open(ctx, {})
    local tb = newtask.task(b)
    vim.wait(500, function()
      return tb.draft ~= nil and not tb.draft.loading
    end)
    local middle = a.win_conversation or b.win_conversation
    eq("draft back: the second draft is in the middle", api.nvim_win_get_buf(middle), tb.buf)
    truthy("draft back: the first one's choices were kept", ta.buf and api.nvim_buf_is_valid(ta.buf))
    eq("draft back: and the screen maps back to its chat", newtask.chat_of(ta.buf), a)
    eq("draft back: as the chat of that buffer", chats.by_buffer(ta.buf), a)

    native.show(a)
    eq("draft back: coming back shows its choices", api.nvim_win_get_buf(middle), ta.buf)
    eq("draft back: what was picked is still picked", ta.draft.modeId, "plan")
    eq("draft back: and what was typed", api.nvim_buf_get_lines(a.composer, 0, -1, false)[1], "first draft")
    truthy("draft back: drawn", text(ta.buf):find("Test", 1, true) ~= nil, text(ta.buf))

    -- CYCLING from a draft goes to its neighbour, whose choices show.
    native.cycle(1)
    vim.wait(200, function()
      return api.nvim_win_get_buf(middle) == tb.buf
    end)
    eq("draft back: the next buffer is the other draft, on its choices", api.nvim_win_get_buf(middle), tb.buf)

    -- Gone by another road: the task goes with it.
    native.remove(a)
    chats.dispose(a)
    eq("draft back: a disposed draft leaves no task", newtask.task(a), nil)
    truthy("draft back: nor its screen", not api.nvim_buf_is_valid(ta.buf or -1))

    native.close(b)
    chats.discard(b)
  end)
  create.catalogue, terminals.presets = old.catalogue, old.presets
  workspaces.branches, bridge.request = old.branches, old.request
  chats.set_current(old.current)
  native.reset()
  -- Later: a PR lookup the surface scheduled still runs in it.
  vim.defer_fn(function()
    vim.fn.delete(dir, "rf")
  end, 5000)
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

---LOCAL means the project's own directory, as the app's sidebar `+` does:
---from a worktree it is the checkout the worktree was cut from.
local function test_project_root()
  local new = require "paseo.new"
  local real = vim.uv.fs_realpath
  local dir = repo()
  local wt = dir .. "-wt"
  vim.system({ "git", "-C", dir, "worktree", "add", "-q", "-b", "side", wt }):wait()
  eq("project_root: a checkout is its own", real(new.project_root { root = dir, local_root = dir, host_id = "local" }), real(dir))
  eq(
    "project_root: a worktree's is the checkout it was cut from",
    real(new.project_root { root = wt, local_root = wt, host_id = "local" }),
    real(dir)
  )
  local plain = vim.fn.tempname()
  vim.fn.mkdir(plain, "p")
  eq("project_root: a plain directory is its own", real(new.project_root { root = plain, local_root = plain, host_id = "local" }), real(plain))
  vim.fn.delete(wt, "rf")
  vim.fn.delete(dir, "rf")
  vim.fn.delete(plain, "rf")
end

return {
  { "newtask.screen", test_newtask },
  { "newtask.draft_pick", test_draft_pick },
  { "newtask.draft_back", test_draft_back },
  { "newtask.isolation", test_isolation },
  { "newtask.project_root", test_project_root },
}
