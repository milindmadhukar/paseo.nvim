--- Full-conversation forks, into a session or into a workspace.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

---The fork context the daemon hands back, for every case below.
local function context()
  return {
    cwd = "/work/source",
    workspaceId = "ws-source",
    title = "Source agent",
    attachment = {
      type = "text",
      mimeType = "text/plain",
      contextKind = "chat_history",
      text = "everything",
    },
    config = {
      provider = "codex/old",
      modeId = "full-access",
      thinkingOptionId = "high",
      featureValues = { fast_mode = true, removed = true },
    },
  }
end

local function test_fork()
  local bridge = require "paseo.bridge"
  local fork = require "paseo.fork"
  local workspaces = require "paseo.workspaces"
  local prompt = require "paseo.ui.prompt"
  local chat = require "paseo.ui.chat"
  local create = require "paseo.ui.create"

  local old = {
    ensure = bridge.ensure,
    request = bridge.request,
    input = vim.ui.input,
    select = vim.ui.select,
    prompt = prompt.open,
    create = workspaces.create,
    open = workspaces.open,
    get = workspaces.get,
    for_dir = workspaces.for_dir,
    chat = chat.open,
    catalogue = create.catalogue,
  }

  local ok, failure = pcall(function()
    local created, opened, chat_opened, agent_args, for_dir_asked
    local input_answer, prompt_answer, destination = nil, nil, nil
    local menu

    local function reset()
      created, opened, chat_opened, agent_args, for_dir_asked = nil, nil, nil, nil, nil
    end

    bridge.ensure = function(done)
      done(nil)
    end
    vim.ui.input = function(_, done)
      done(input_answer)
    end
    -- The destination menu. Answered BY ID rather than by index, so the test
    -- says which fork it is asking for and keeps saying it if the order
    -- changes.
    vim.ui.select = function(items, opts, done)
      menu = { items = items, opts = opts }
      for _, item in ipairs(items) do
        if item.id == destination then
          return done(item)
        end
      end
      done(nil)
    end
    prompt.open = function(_, done)
      done(prompt_answer)
    end
    workspaces.create = function(opts, done)
      created = opts
      done("ws-fork", nil, { kind = "worktree" }, {
        id = "ws-fork",
        name = opts.name,
        directory = "/work/fork",
      })
    end
    workspaces.open = function(ws)
      opened = ws
      return true
    end
    workspaces.for_dir = function(root, done)
      for_dir_asked = root
      done({ id = "ws-found", directory = "/work/source" }, nil)
    end
    chat.open = function(opts)
      chat_opened = opts
    end
    bridge.request = function(op, args, done)
      if op == "agent.forkContext" then
        done(nil, context())
      elseif op == "agent.create" then
        agent_args = args
        done(nil, { id = "agent-fork" })
      else
        error("unexpected op: " .. op)
      end
    end

    -- ------------------------------------------------------- the menu

    reset()
    destination = nil
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(50)
    eq("fork: dismissing the destination menu creates nothing", { created, agent_args }, {})
    eq("fork: the menu names both destinations and a way out", vim.tbl_map(function(item)
      return item.id
    end, menu.items), { "session", "workspace", "cancel" })
    truthy(
      "fork: the menu says which conversation it is forking",
      menu.opts.prompt:find "Source agent" ~= nil,
      menu.opts.prompt
    )
    truthy(
      "fork: each destination says what it does to your files",
      menu.opts.format_item(menu.items[2]):find "directory of its own" ~= nil,
      menu.opts.format_item(menu.items[2])
    )

    reset()
    destination = "cancel"
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(50)
    eq("fork: cancel is not a destination", { created, agent_args }, {})

    -- --------------------------------------------- into a new session

    reset()
    destination, prompt_answer = "session", nil
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(50)
    eq("fork: cancelling the first prompt creates no session", agent_args, nil)

    reset()
    prompt_answer = "Carry on from here"
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq("fork: a session fork never asks for a workspace name", created, nil)
    eq(
      "fork: a session fork lands in the source's own workspace",
      agent_args.workspaceId,
      "ws-source"
    )
    eq("fork: a session fork carries the complete history", agent_args.attachments, {
      {
        type = "text",
        mimeType = "text/plain",
        contextKind = "chat_history",
        text = "everything",
      },
    })
    eq("fork: a session fork sends the first prompt atomically", agent_args.prompt, prompt_answer)
    -- `workspaces.open` is a `:tcd`. There is nowhere to go: the fork is in
    -- the directory you are already standing in.
    eq("fork: a session fork moves you nowhere", opened, nil)
    eq("fork: a session fork opens beside the source", {
      chat_opened.agent_id,
      chat_opened.root,
    }, { "agent-fork", "/work/source" })

    -- A daemon too old to report the workspace still forks: the directory is
    -- the one thing there always is.
    reset()
    bridge.request = function(op, args, done)
      if op == "agent.forkContext" then
        local ctx = context()
        ctx.workspaceId = nil
        done(nil, ctx)
      elseif op == "agent.create" then
        agent_args = args
        done(nil, { id = "agent-fallback" })
      else
        error("unexpected op: " .. op)
      end
    end
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq(
      "fork: an unreported workspace is resolved from the directory",
      for_dir_asked,
      "/work/source"
    )
    eq("fork: and the fork still lands in it", agent_args.workspaceId, "ws-found")

    bridge.request = function(op, args, done)
      if op == "agent.forkContext" then
        done(nil, context())
      elseif op == "agent.create" then
        agent_args = args
        done(nil, { id = "agent-fork" })
      else
        error("unexpected op: " .. op)
      end
    end

    -- ------------------------------------------- into a new workspace

    reset()
    destination, input_answer = "workspace", nil
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(50)
    eq("fork: cancelling the workspace name creates nothing", created, nil)

    reset()
    input_answer, prompt_answer = "source-fork", nil
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(50)
    eq("fork: cancelling the first prompt still creates nothing", created, nil)

    reset()
    input_answer, prompt_answer = "source-fork", "Continue with the new model"
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq("fork: creates from the source workspace root", created.root, "/work/source")
    eq("fork: uses the requested workspace name", created.name, "source-fork")
    eq("fork: requires a distinct workspace even for a shared directory", created.new, true)
    eq("fork: creates the first prompt atomically", agent_args.prompt, prompt_answer)
    eq("fork: attaches the complete chat history atomically", agent_args.attachments, {
      {
        type = "text",
        mimeType = "text/plain",
        contextKind = "chat_history",
        text = "everything",
      },
    })
    eq("fork: preserves source settings", {
      agent_args.provider,
      agent_args.modeId,
      agent_args.thinkingOptionId,
      agent_args.featureValues.fast_mode,
    }, { "codex/old", "full-access", "high", true })
    eq("fork: opens the exact created workspace", opened.id, "ws-fork")
    eq("fork: opens the new agent session", chat_opened.agent_id, "agent-fork")

    -- A caller that has already asked skips the menu. The model dialog does.
    reset()
    destination = nil
    fork.start({ agent_id = "source", root = "/work/source" }, { destination = "workspace" })
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq("fork: a declared destination is not asked about again", created.name, "source-fork")

    -- ----------------------------------------------------- settings

    -- A target model gets only settings that model/provider still supports.
    create.catalogue = function(_, done)
      done({
        {
          provider = "codex",
          status = "ready",
          defaultModeId = "auto",
          modes = { { id = "auto" }, { id = "full-access" } },
          models = {
            {
              id = "new",
              defaultThinkingOptionId = "medium",
              thinkingOptions = { { id = "medium" } },
            },
          },
        },
      }, nil)
    end
    bridge.request = function(op, args, done)
      eq("fork: asks features for the selected model", args.provider, "codex/new")
      done(nil, {
        features = {
          { id = "fast_mode", type = "toggle", value = false },
          { id = "new_feature", type = "toggle", value = true },
          { id = "effort", type = "select", value = "medium" },
        },
      })
    end
    local resolved
    fork.resolve_config(
      {
        cwd = "/work/source",
        config = {
          provider = "codex/old",
          modeId = "full-access",
          thinkingOptionId = "high",
          featureValues = { fast_mode = true, removed = true },
        },
      },
      "new",
      function(value)
        resolved = value
      end
    )
    eq("fork: retains a compatible mode but recalculates thinking", {
      resolved.modeId,
      resolved.thinkingOptionId,
    }, { "full-access", "medium" })
    eq("fork: retains supported features and defaults new ones", resolved.featureValues, {
      fast_mode = true,
      new_feature = true,
      effort = "medium",
    })
  end)

  bridge.ensure, bridge.request = old.ensure, old.request
  vim.ui.input, vim.ui.select = old.input, old.select
  prompt.open = old.prompt
  workspaces.create, workspaces.open, workspaces.get = old.create, old.open, old.get
  workspaces.for_dir = old.for_dir
  chat.open = old.chat
  create.catalogue = old.catalogue
  truthy("fork: cases completed", ok, failure)
end

return { { "fork", test_fork } }
