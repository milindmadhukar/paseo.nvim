--- The first screen: what to start in a directory with nothing in it.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_start()
  local start = require "paseo.start"
  local workspaces = require "paseo.workspaces"
  local chat = require "paseo.ui.chat"
  local create = require "paseo.ui.create"
  local newterm = require "paseo.ui.newterm"
  local prompt = require "paseo.ui.prompt"
  local bridge = require "paseo.bridge"

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
    prompt = prompt.open,
    draft = chat.draft,
    discard = chat.discard,
    request = bridge.request,
  }

  local ok, failure = pcall(function()
    local menu, picked, name_answer
    local prompt_answer = "Fix the invoice rounding"
    local created, opened, chat_opened, session_in, terminal_in, reviewed
    local drafted, discarded, requested, prompted

    local function reset()
      created, opened, chat_opened = nil, nil, nil
      session_in, terminal_in, reviewed = nil, nil, nil
      drafted, discarded, requested, prompted = nil, nil, nil, nil
    end

    -- The draft the editor would show: the conversation view, with the
    -- settings on it and a way to start it.
    chat.draft = function(opts)
      drafted = opts
      drafted.chat = { draft = { settings = opts.settings } }
      return drafted.chat
    end
    chat.discard = function(c)
      discarded = c
    end
    bridge.request = function(op, args, done)
      requested = { op = op, args = args }
      done(nil, { id = "agent-here" })
    end

    ---Send the draft's first message, as the composer would.
    local function send_first(text, images)
      local answer = {}
      drafted.start(text, images or {}, function(err, agent_id)
        answer = { err = err, agent_id = agent_id }
      end)
      vim.wait(200, function()
        return answer.err ~= nil or answer.agent_id ~= nil or chat_opened ~= nil
      end)
      return answer
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
    prompt.open = function(_, done)
      prompted = true
      done(prompt_answer)
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
        -- The agent the first prompt created, in the same request.
        agent_id = opts.first and "agent-new" or nil,
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
      return drafted ~= nil
    end)
    -- THE ORDINARY VIEW, AT ONCE. No box asking for the prompt first: that
    -- could not be dictated into, and showed nothing until it was answered.
    eq("start: no prompt box is asked for", prompted, nil)
    eq("start: nothing is created before the first message", created, nil)
    eq("start: a draft opens in this directory instead", drafted.root, "/work/here")
    eq("start: with the settings chosen", drafted.settings.provider, "codex/gpt")
    -- `moved` is what tells the caller to give up its own empty window rather
    -- than adopt an agent that is not in its directory.
    eq("start: the caller is told it moved", { result.kind, result.moved }, { "agent", true })

    send_first(prompt_answer, { { data = "png", mimeType = "image/png" } })
    eq("start: the workspace is cut from this directory", created.root, "/work/here")
    eq("start: under the name you gave", created.name, "billing")
    eq("start: and is a distinct one even in a shared checkout", created.new, true)
    -- THE PROMPT RIDES THE CREATE. It is the only request the daemon names a
    -- workspace from; creating it bare and starting the agent after left it
    -- called by its slug for good.
    eq("start: the first message goes with the workspace", created.first.prompt, prompt_answer)
    eq("start: images and all", #created.first.images, 1)
    eq("start: and so do the settings", {
      created.first.provider,
      created.first.modeId,
    }, { "codex/gpt", "auto" })
    eq("start: no second request starts the agent", session_in, nil)
    eq("start: the draft is let go", discarded, drafted.chat)
    eq("start: the editor moves to it", opened.id, "ws-new")
    eq("start: and opens it", {
      chat_opened.root,
      chat_opened.agent_id,
    }, { "/work/new", "agent-new" })

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
    local here = { root = "/work/here", workspace_id = "ws-here" }

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
      return drafted ~= nil
    end)
    eq("start: here is a draft too", drafted.root, "/work/here")
    eq("start: with nothing made yet", { requested, session_in, created }, {})
    local sent = send_first "Add a test"
    eq("start: the first message makes the agent", requested.op, "agent.create")
    eq("start: in the workspace you are in", requested.args.workspaceId, "ws-here")
    eq("start: with your words as its prompt", requested.args.prompt, "Add a test")
    eq("start: and binds it to the draft", sent.agent_id, "agent-here")

    -- Without a known workspace, the default start (`agent.start`) decides.
    reset()
    start.agent({ root = "/work/here" }, function() end)
    vim.wait(200, function()
      return drafted ~= nil
    end)
    eq("start: no workspace id, no start of our own", drafted.start, nil)

    reset()
    picked, name_answer = "workspace", "otp"
    start.agent(here, function(value)
      result = value
    end)
    vim.wait(200, function()
      return drafted ~= nil
    end)
    send_first "Rotate the OTP secret"
    eq("start: elsewhere cuts one", created.name, "otp")
    eq("start: and the agent lands in it, not in the one you were in", {
      session_in,
      requested,
      chat_opened.agent_id,
      chat_opened.root,
    }, { nil, nil, "agent-new", "/work/new" })

    -- -------------------------------------------- the dashboard's `<C-n>`

    reset()
    picked = "terminal"
    start.new({ root = "/work/here" })
    eq("start: new offers all three", vim.tbl_map(function(item)
      return item.id
    end, menu.items), { "here", "workspace", "terminal" })
    eq("start: and a terminal starts here", terminal_in.root, "/work/here")

    reset()
    start.new({ root = "/work/here", workspace_id = "ws-here" }, "here")
    vim.wait(200, function()
      return drafted ~= nil
    end)
    eq("start: a kind skips the menu", drafted.root, "/work/here")
  end)

  vim.ui.select, vim.ui.input = old.select, old.input
  workspaces.create, workspaces.open, workspaces.get = old.create, old.open, old.get
  workspaces.new_agent_session = old.session
  workspaces.new_session = old.session
  chat.open = old.chat
  create.review = old.review
  prompt.open = old.prompt
  newterm.open = old.newterm
  chat.draft, chat.discard, bridge.request = old.draft, old.discard, old.request
  truthy("start: cases completed", ok, failure)
end

return { { "start", test_start } }
