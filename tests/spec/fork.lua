--- Full-conversation workspace forks.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

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
    prompt = prompt.open,
    create = workspaces.create,
    open = workspaces.open,
    get = workspaces.get,
    chat = chat.open,
    catalogue = create.catalogue,
  }

  local ok, failure = pcall(function()
    local created, opened, chat_opened
    local input_answer, prompt_answer = nil, nil
    bridge.ensure = function(done)
      done(nil)
    end
    vim.ui.input = function(_, done)
      done(input_answer)
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
    chat.open = function(opts)
      chat_opened = opts
    end
    bridge.request = function(op, args, done)
      if op == "agent.forkContext" then
        done(nil, {
          cwd = "/work/source",
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
        })
      elseif op == "agent.create" then
        created.agent = args
        done(nil, { id = "agent-fork" })
      else
        error("unexpected op: " .. op)
      end
    end

    -- Cancellation happens before any workspace exists.
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(50)
    eq("fork: cancelling the workspace name creates nothing", created, nil)

    input_answer = "source-fork"
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(50)
    eq("fork: cancelling the first prompt still creates nothing", created, nil)

    input_answer, prompt_answer = "source-fork", "Continue with the new model"
    fork.start { agent_id = "source", root = "/work/source" }
    vim.wait(200, function()
      return chat_opened ~= nil
    end)
    eq("fork: creates from the source workspace root", created.root, "/work/source")
    eq("fork: uses the requested workspace name", created.name, "source-fork")
    eq("fork: requires a distinct workspace even for a shared directory", created.new, true)
    eq("fork: creates the first prompt atomically", created.agent.prompt, prompt_answer)
    eq("fork: attaches the complete chat history atomically", created.agent.attachments, {
      {
        type = "text",
        mimeType = "text/plain",
        contextKind = "chat_history",
        text = "everything",
      },
    })
    eq("fork: preserves source settings", {
      created.agent.provider,
      created.agent.modeId,
      created.agent.thinkingOptionId,
      created.agent.featureValues.fast_mode,
    }, { "codex/old", "full-access", "high", true })
    eq("fork: opens the exact created workspace", opened.id, "ws-fork")
    eq("fork: opens the new agent session", chat_opened.agent_id, "agent-fork")

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
  vim.ui.input = old.input
  prompt.open = old.prompt
  workspaces.create, workspaces.open, workspaces.get = old.create, old.open, old.get
  chat.open = old.chat
  create.catalogue = old.catalogue
  truthy("fork: cases completed", ok, failure)
end

return { { "fork", test_fork } }
