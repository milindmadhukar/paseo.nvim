--- The first screen: what to start in a directory with nothing in it.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_start()
  local start = require "paseo.start"
  local workspaces = require "paseo.workspaces"
  local chat = require "paseo.ui.chat"
  local create = require "paseo.ui.create"
  local newterm = require "paseo.ui.newterm"

  local old = {
    select = vim.ui.select,
    input = vim.ui.input,
    create = workspaces.create,
    open = workspaces.open,
    get = workspaces.get,
    session = workspaces.new_agent_session,
    chat = chat.open,
    review = create.review,
    newterm = newterm.open,
  }

  local ok, failure = pcall(function()
    local menu, picked, name_answer
    local created, opened, chat_opened, session_in, terminal_in, reviewed

    local function reset()
      created, opened, chat_opened = nil, nil, nil
      session_in, terminal_in, reviewed = nil, nil, nil
    end

    -- Answered BY ID, so a reordered menu does not silently pick a different
    -- entry than the one the case is about.
    vim.ui.select = function(items, opts, done)
      menu = { items = items, opts = opts }
      for _, item in ipairs(items) do
        if item.id == picked then
          return done(item)
        end
      end
      done(nil)
    end
    vim.ui.input = function(_, done)
      done(name_answer)
    end
    create.review = function(opts, done)
      reviewed = opts
      done({ provider = "codex/gpt", modeId = "auto" }, nil)
    end
    newterm.open = function(opts, done)
      terminal_in = opts
      done("term-1", nil)
    end
    workspaces.create = function(opts, done)
      created = opts
      done("ws-new", nil, { kind = "worktree" }, {
        id = "ws-new",
        name = opts.name,
        directory = "/work/new",
      })
    end
    workspaces.open = function(ws)
      opened = ws
    end
    workspaces.new_agent_session = function(ws, _, done)
      session_in = ws
      done("agent-new", nil)
    end
    chat.open = function(opts)
      chat_opened = opts
    end

    -- ------------------------------------------------------------- the menu

    reset()
    picked = nil
    local result, err = "untouched", "untouched"
    start.open({ root = "/work/here" }, function(value, problem)
      result, err = value, problem
    end)
    eq("start: dismissing the menu starts nothing", { result, err, created }, {})
    eq("start: the menu offers all three, and a way out", vim.tbl_map(function(item)
      return item.id
    end, menu.items), { "agent", "workspace", "terminal", "cancel" })
    truthy(
      "start: and says which directory it is talking about",
      menu.opts.prompt:find "/work/here" ~= nil,
      menu.opts.prompt
    )
    -- The whole reason this screen exists: a terminal is on it. It used to be
    -- reachable only from a tab of a surface you had to create an agent in
    -- order to see.
    truthy(
      "start: a terminal is a first-class answer here",
      menu.opts.format_item(menu.items[3]):find "shell" ~= nil,
      menu.opts.format_item(menu.items[3])
    )

    -- ------------------------------------------------------ an agent, here

    reset()
    picked = "agent"
    start.open({ root = "/work/here", preferred = "codex/gpt" }, function(value)
      result = value
    end)
    eq("start: an agent here asks for settings in this directory", reviewed.cwd, "/work/here")
    eq("start: and carries the preferred provider through", reviewed.preferred, "codex/gpt")
    -- NOTHING IS CREATED. The caller owns `agent.ensure`; a second creation
    -- path beside it is how two agents in one directory start disagreeing
    -- about which of them the window is pointed at.
    eq("start: nothing is created for the caller", { created, session_in }, {})
    eq("start: the settings come back instead", {
      result.kind,
      result.draft.provider,
      result.moved,
    }, { "agent", "codex/gpt" })

    -- -------------------------------------------- an agent, somewhere new

    reset()
    picked, name_answer = "workspace", nil
    start.open({ root = "/work/here" }, function(value)
      result = value
    end)
    eq("start: cancelling the workspace name creates nothing", created, nil)

    reset()
    name_answer = "billing"
    start.open({ root = "/work/here" }, function(value)
      result = value
    end)
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq("start: the workspace is cut from this directory", created.root, "/work/here")
    eq("start: under the name you gave", created.name, "billing")
    eq("start: and is a distinct one even in a shared checkout", created.new, true)
    eq("start: the agent goes in the workspace that was just made", session_in.id, "ws-new")
    eq("start: the editor moves to it", opened.id, "ws-new")
    eq("start: and opens it", {
      chat_opened.root,
      chat_opened.agent_id,
    }, { "/work/new", "agent-new" })
    -- `moved` is what tells the caller to give up its own empty window rather
    -- than adopt an agent that is not in its directory.
    eq("start: the caller is told it moved", { result.kind, result.moved }, { "agent", true })

    -- ---------------------------------------------------------- a terminal

    reset()
    picked = "terminal"
    start.open({ root = "/work/here" }, function(value)
      result = value
    end)
    eq("start: a terminal is started in this directory", terminal_in.root, "/work/here")
    eq("start: and comes back as a terminal, not an agent", {
      result.kind,
      result.id,
    }, { "terminal", "term-1" })
    eq("start: without creating a workspace or an agent", { created, session_in }, {})

    -- ------------------------------------------ where, when what is settled

    -- The workspace the caller resolved for us. `start.agent` never looks one
    -- up: a surface with a key meaning "agent" on it already has one.
    local here = { root = "/work/here", workspace = { id = "ws-here", directory = "/work/here" } }

    reset()
    picked = nil
    result = "untouched"
    start.agent(here, function(value)
      result = value
    end)
    eq("start: dismissing the where menu starts nothing", { result, session_in }, {})
    eq("start: which offers here, elsewhere, and a way out", vim.tbl_map(function(item)
      return item.id
    end, menu.items), { "here", "workspace", "cancel" })

    reset()
    picked = "here"
    start.agent(here, function(value)
      result = value
    end)
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq("start: here means the workspace you are in", session_in.id, "ws-here")
    eq("start: no new workspace is cut for it", created, nil)
    eq("start: and it opens where it was made", chat_opened.root, "/work/here")

    reset()
    picked, name_answer = "workspace", "otp"
    start.agent(here, function(value)
      result = value
    end)
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq("start: elsewhere cuts one", created.name, "otp")
    eq("start: and the agent lands in it, not in the one you were in", session_in.id, "ws-new")
  end)

  vim.ui.select, vim.ui.input = old.select, old.input
  workspaces.create, workspaces.open, workspaces.get = old.create, old.open, old.get
  workspaces.new_agent_session = old.session
  workspaces.new_session = old.session
  chat.open = old.chat
  create.review = old.review
  newterm.open = old.newterm
  truthy("start: cases completed", ok, failure)
end

return { { "start", test_start } }
