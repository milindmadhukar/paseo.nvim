--- Setting a session up before it exists.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_provider_setup()
  local bridge = require "paseo.bridge"
  local create = require "paseo.ui.create"
  local session = require "paseo.ui.session"
  local chat = require "paseo.ui.chat"
  local config = require "paseo.config"
  local sidebar = require "paseo.ui.sidebar"
  local old_ensure, old_request = bridge.ensure, bridge.request
  local old_select, old_current = require("paseo.ui.choose").select, chat.current
  local old_toggle, old_load = session.toggle, chat.load_settings
  local old_preference = config.get().paseo.provider
  local requests = {}
  local hold_features, held_feature_callback = false, nil
  local catalogue = {
    entries = {
      {
        provider = "claude",
        status = "ready",
        label = "Claude",
        defaultModeId = "default",
        modes = { { id = "plan", label = "Plan" }, { id = "default", label = "Ask" } },
        models = { { id = "opus", label = "Opus", isDefault = true } },
      },
      {
        provider = "codex",
        status = "ready",
        label = "Codex",
        defaultModeId = "auto-review",
        modes = { { id = "auto-review", label = "Auto-review" } },
        models = {
          {
            id = "gpt-5.6-sol",
            label = "GPT-5.6-Sol",
            isDefault = true,
            thinkingOptions = { { id = "high", label = "High", isDefault = true } },
          },
          {
            id = "gpt-5.6-luna",
            label = "GPT-5.6-Luna",
            thinkingOptions = { { id = "medium", label = "Medium", isDefault = true } },
          },
        },
      },
    },
  }
  local ok, err = pcall(function()
    bridge.ensure = function(callback)
      callback(nil)
    end
    bridge.request = function(op, args, callback)
      requests[#requests + 1] = { op = op, args = args }
      if op == "providers" then
        callback(nil, catalogue)
      elseif op == "providers.features" then
        if hold_features then
          held_feature_callback = callback
          return
        end
        callback(nil, {
          features = args.provider:find("luna", 1, true)
              and { { id = "plan_mode", type = "toggle", label = "Plan", value = false } }
            or {
              { id = "fast_mode", type = "toggle", label = "Fast", value = false },
              { id = "plan_mode", type = "toggle", label = "Plan", value = false },
            },
        })
      elseif op == "agent.config" then
        callback(nil, chat.test_config)
      elseif op == "agent.setMode" then
        callback(nil, {})
      else
        error("unexpected bridge op: " .. op)
      end
    end

    local chosen, select_count
    local chosen_model = "gpt-5.6-sol"
    select_count = 0
    require("paseo.ui.choose").select = function(items, _, callback)
      select_count = select_count + 1
      if items[1] and items[1].provider then
        return callback(items[#items])
      end
      for _, item in ipairs(items) do
        if item.id == chosen_model then
          return callback(item)
        end
      end
      callback(items[1])
    end
    create.select_model({ cwd = "/work" }, function(selection)
      chosen = selection
    end)
    truthy(
      "provider: picker completes",
      vim.wait(1000, function()
        return chosen ~= nil
      end)
    )
    eq("provider: separate provider and model selections", select_count, 2)
    eq("provider: labeled Codex model is selected", chosen and chosen.provider, "codex/gpt-5.6-sol")
    eq(
      "provider: direct model ids are validated",
      create.find(catalogue.entries, "codex/nope"),
      nil
    )
    local draft = create.draft(chosen)
    eq("provider: default permissions come from daemon", draft.modeId, "auto-review")
    eq("provider: default reasoning comes from model", draft.thinkingOptionId, "high")

    create.preference("codex/gpt-5.6-sol", function() end)
    eq(
      "provider: preference changes without creating an agent",
      config.get().paseo.provider,
      "codex/gpt-5.6-sol"
    )
    truthy(
      "provider: no creation op was sent",
      vim.iter(requests):all(function(request)
        return request.op ~= "agent.ensure" and request.op ~= "agent.create"
      end)
    )

    local fake_chat = { agent_id = "agent", root = "/work" }
    chat.current = function()
      return fake_chat
    end
    local toggled
    session.toggle = function(id)
      toggled = id
    end
    chat.test_config = {
      provider = "codex",
      modeId = "auto-review",
      features = { { id = "plan_mode", type = "toggle", label = "Plan", value = false } },
      availableModes = { { id = "auto-review" } },
    }
    session.plan()
    vim.wait(1000, function()
      return toggled ~= nil
    end)
    eq("provider: Codex Plan uses feature toggle", toggled, "plan_mode")

    chat.test_config = {
      provider = "claude",
      modeId = "default",
      features = {},
      availableModes = { { id = "plan" }, { id = "default" } },
    }
    chat.load_settings = function() end
    session.plan()
    vim.wait(1000, function()
      return requests[#requests].op == "agent.setMode"
    end)
    eq("provider: Claude Plan uses its mode", requests[#requests].args.modeId, "plan")

    local header = sidebar.header {
      provider = "codex/gpt-5.6-sol",
      root = "/work",
      features = { plan_mode = true, fast_mode = true },
      feature_list = {
        { id = "fast_mode", label = "Fast", type = "toggle" },
        { id = "plan_mode", label = "Plan", type = "toggle" },
      },
    }
    local text = {}
    for _, cell in ipairs(header) do
      text[#text + 1] = cell[1]
    end
    text = table.concat(text)
    truthy(
      "provider: header shows all enabled feature labels",
      text:find("Fast", 1, true) and text:find("Plan", 1, true)
    )
  end)
  bridge.ensure, bridge.request = old_ensure, old_request
  require("paseo.ui.choose").select, chat.current = old_select, old_current
  session.toggle, chat.load_settings = old_toggle, old_load
  config.get().paseo.provider = old_preference
  if not ok then
    error(err)
  end
end

return {
  { "provider", test_provider_setup },
}
