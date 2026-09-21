--- Setting a session up before it exists.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

---Never `nvim_buf_get_lines`: volt draws with extmark virtual text over a
---buffer of blank rows, so the lines are spaces and a check against them
---passes whatever is on screen. Two assertions about the new-session screen
---were vacuous for exactly that reason.
---@param buf integer
---@return string
local function volt_text(buf)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    for _, cell in ipairs(mark[4] and mark[4].virt_text or {}) do
      out[#out + 1] = cell[1]
    end
    out[#out + 1] = "\n"
  end
  return table.concat(out)
end

local function test_provider_setup()
  local bridge = require "paseo.bridge"
  local create = require "paseo.ui.create"
  local session = require "paseo.ui.session"
  local chat = require "paseo.ui.chat"
  local config = require "paseo.config"
  local sidebar = require "paseo.ui.sidebar"
  local old_ensure, old_request = bridge.ensure, bridge.request
  local old_select, old_current = vim.ui.select, chat.current
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
    vim.ui.select = function(items, _, callback)
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

    -- The review screen is the Agent tab's view over a DRAFT, so it is
    -- driven the way that view is driven -- through the model and the bound
    -- handlers -- rather than by aiming feedkeys at a row of plain text. The
    -- old screen was `nvim_buf_set_lines` and these assertions read it back.
    local reviewed
    create.review({ cwd = "/work", preferred = "codex/gpt-5.6-sol" }, function(value)
      reviewed = value
    end)
    truthy(
      "provider: review screen opens",
      vim.wait(1000, function()
        return vim.bo[vim.api.nvim_get_current_buf()].filetype == "paseo-create"
      end)
    )
    local review_buf = vim.api.nvim_get_current_buf()
    truthy(
      "provider: with a Provider card the Agent tab does not have",
      volt_text(review_buf):find("Provider", 1, true) ~= nil
    )
    truthy(
      "provider: and its footer survives a short editor",
      volt_text(review_buf):find("create", 1, true) ~= nil
    )

    -- Changing model refetches that model's features, and the draft is the
    -- thing that knows it.
    hold_features = true
    chosen_model = "gpt-5.6-luna"
    vim.api.nvim_feedkeys(vim.keycode "s", "x", false)
    vim.api.nvim_feedkeys("j", "x", false)
    vim.api.nvim_feedkeys(vim.keycode "<CR>", "x", false)
    truthy(
      "provider: changing model re-fetches its features",
      vim.wait(1000, function()
        local found = 0
        for _, request in ipairs(requests) do
          if request.op == "providers.features" then
            found = found + 1
          end
        end
        return found >= 2
      end)
    )
    vim.api.nvim_feedkeys("c", "x", false)
    eq("provider: cannot create before the model features arrive", reviewed, nil)
    hold_features = false
    truthy(
      "provider: the features card says so while it waits",
      vim.wait(1000, function()
        return volt_text(review_buf):find("loading", 1, true) ~= nil
      end)
    )
    held_feature_callback(nil, {
      features = {
        { id = "plan_mode", type = "toggle", label = "Plan", value = false },
      },
    })
    truthy(
      "provider: model features finish loading",
      vim.wait(1000, function()
        return volt_text(review_buf):find("loading", 1, true) == nil
      end)
    )
    vim.api.nvim_feedkeys("c", "x", false)
    truthy(
      "provider: review creates a draft",
      vim.wait(1000, function()
        return reviewed ~= nil
      end)
    )
    eq(
      "provider: reviewed model is the changed model",
      reviewed and reviewed.provider,
      "codex/gpt-5.6-luna"
    )
    eq(
      "provider: changed model drops absent features",
      reviewed and reviewed.featureValues.fast_mode,
      nil
    )
    eq("provider: and closes its window", vim.api.nvim_buf_is_valid(review_buf), false)

    -- Cancel. `q` is volt's, routed through `after_close`, so the callback has
    -- to be answered from the teardown rather than from a keymap of ours --
    -- otherwise closing the window creates nothing AND reports nothing.
    local cancelled = false
    create.review({ cwd = "/work" }, function(selection, review_err)
      cancelled = selection == nil and review_err == nil
    end)
    truthy(
      "provider: the cancel screen opens",
      vim.wait(1000, function()
        return vim.bo[vim.api.nvim_get_current_buf()].filetype == "paseo-create"
      end)
    )
    vim.api.nvim_feedkeys("q", "x", false)
    truthy(
      "provider: cancel creates nothing",
      vim.wait(1000, function()
        return cancelled
      end)
    )

    -- A daemon with no ready provider has nothing to put on a screen, so it
    -- must not open one.
    local ready = catalogue.entries
    catalogue.entries = { { provider = "pi", status = "unavailable", models = {} } }
    local wins_before_empty = #vim.api.nvim_list_wins()
    local empty_err
    create.review({ cwd = "/work" }, function(selection, review_err)
      empty_err = review_err
    end)
    truthy(
      "provider: no ready provider is an error",
      vim.wait(1000, function()
        return empty_err ~= nil
      end)
    )
    eq("provider: and opens no window to say so", #vim.api.nvim_list_wins(), wins_before_empty)
    catalogue.entries = ready

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
  vim.ui.select, chat.current = old_select, old_current
  session.toggle, chat.load_settings = old_toggle, old_load
  config.get().paseo.provider = old_preference
  if not ok then
    error(err)
  end
end

return {
  { "provider", test_provider_setup },
}
