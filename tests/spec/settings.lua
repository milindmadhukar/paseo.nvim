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
  -- The Session panel draws its `●` from the snapshot, which nothing patched:
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
end

return {
  { "settings", test_settings },
}
