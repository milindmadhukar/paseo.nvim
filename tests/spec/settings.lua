--- Mode, model, thinking level and usage.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_settings()
  local chat_mod = require "paseo.ui.chat"
  local float = require "paseo.ui.float"
  local render = require "paseo.ui.render"
  local sidebar = require "paseo.ui.sidebar"

  local modes = {
    { id = "plan", label = "Plan Mode" },
    { id = "default", label = "Always Ask" },
    { id = "acceptEdits", label = "Accept File Edits" },
    { id = "auto", label = "Auto mode" },
  }
  local chat = {
    root = assert(vim.uv.cwd()),
    agent_id = "spec-settings",
    mode = "Always Ask",
    config_snapshot = {
      modeId = "default",
      availableModes = modes,
      thinkingOptions = {},
      models = {},
      features = {},
    },
  }

  -- Rebuilding the dashboard is a full volt regeneration, so count the calls.
  local rebuilds = 0
  local real_rebuild = float.rebuild
  float.rebuild = function()
    rebuilds = rebuilds + 1
  end

  chat_mod.apply_settings(
    chat,
    { agentId = "spec-settings", modeId = "auto", availableModes = modes }
  )

  -- THE BUG: this stored the raw id, while `agent.config` stored the label, so
  -- one session read "Plan Mode" or "plan" in the header depending on which
  -- had spoken last.
  eq("settings: a pushed mode is stored as its label", chat.mode, "Auto mode")
  truthy(
    "settings: and the header says so",
    render.concat(sidebar.header(chat)):find("Auto mode", 1, true) ~= nil,
    render.concat(sidebar.header(chat))
  )
  -- The Agent panel draws its `●` from the snapshot, which nothing patched:
  -- the header could report a mode the panel below it still marked elsewhere.
  eq("settings: the panel's snapshot is patched too", chat.config_snapshot.modeId, "auto")
  eq("settings: a real change redraws the panel", rebuilds, 1)

  -- This payload arrives on every usage tick -- seven times in one short turn,
  -- measured against a live daemon -- and the mode is in all of them. A panel
  -- rebuild behind each would be a regeneration per token count.
  for used = 1000, 2000, 1000 do
    chat_mod.apply_settings(chat, {
      agentId = "spec-settings",
      modeId = "auto",
      availableModes = modes,
      usage = { contextWindowUsedTokens = used, contextWindowMaxTokens = 200000 },
    })
  end
  eq("settings: an unchanged mode does not redraw it again", rebuilds, 1)
  eq("settings: but the usage still lands", chat.usage.contextWindowUsedTokens, 2000)

  -- Features are compared by VALUE, not by the table they arrived in.
  chat_mod.apply_settings(chat, {
    agentId = "spec-settings",
    features = { { id = "fast_mode", value = true } },
  })
  eq("settings: a changed feature redraws the panel", rebuilds, 2)
  chat_mod.apply_settings(chat, {
    agentId = "spec-settings",
    features = { { id = "fast_mode", value = true } },
  })
  eq("settings: the same feature again does not", rebuilds, 2)

  -- A mode the provider did not report is still better shown than dropped.
  chat_mod.apply_settings(
    chat,
    { agentId = "spec-settings", modeId = "invented", availableModes = modes }
  )
  eq("settings: an unknown id falls back to itself", chat.mode, "invented")

  float.rebuild = real_rebuild

  -- Every live-agent model selector comes through `session.apply`. Selecting
  -- the current model is a no-op; an actual change asks whether to branch or
  -- affect future turns on the source agent.
  local session = require "paseo.ui.session"
  local bridge = require "paseo.bridge"
  local old_select, old_request = vim.ui.select, bridge.request
  local old_fork = package.loaded["paseo.fork"]
  local old_chat = package.loaded["paseo.ui.chat"]
  local prompts, forks, mutations = 0, 0, 0
  local choice
  package.loaded["paseo.fork"] = {
    start = function(fork_chat, opts)
      eq("settings: a model fork targets this agent", fork_chat.agent_id, chat.agent_id)
      eq("settings: a model fork carries the selected model", opts.model_id, "new")
      forks = forks + 1
    end,
  }
  package.loaded["paseo.ui.chat"] = { load_settings = function() end }
  vim.ui.select = function(_, _, done)
    prompts = prompts + 1
    done(choice)
  end
  bridge.request = function(op, _, done)
    if op == "agent.setModel" then
      mutations = mutations + 1
      return done(nil, {})
    end
    if op == "agent.config" then
      return done(nil, chat.config_snapshot)
    end
    error("unexpected operation " .. op)
  end
  local model_group = {
    id = "model",
    kind = "radio",
    current = "old",
    op = "agent.setModel",
    arg = "modelId",
  }
  session.apply(chat, model_group, { id = "old" })
  eq("settings: reselecting the current model asks nothing", prompts, 0)

  choice = { id = "cancel" }
  session.apply(chat, model_group, { id = "new" })
  eq("settings: cancelling a model change mutates nothing", { forks, mutations }, { 0, 0 })
  choice = { id = "fork" }
  session.apply(chat, model_group, { id = "new" })
  eq("settings: the fork outcome leaves the source untouched", { forks, mutations }, { 1, 0 })
  choice = { id = "future" }
  local completed = false
  session.apply(chat, model_group, { id = "new" }, function()
    completed = true
  end)
  vim.wait(100, function()
    return completed
  end)
  eq("settings: future turns uses the in-place model change", mutations, 1)

  vim.ui.select, bridge.request = old_select, old_request
  package.loaded["paseo.fork"] = old_fork
  package.loaded["paseo.ui.chat"] = old_chat
end

return {
  { "settings", test_settings },
}
