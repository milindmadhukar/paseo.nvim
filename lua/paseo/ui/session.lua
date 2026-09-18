--- Adjusting a running session: mode, thinking level, model, feature toggles.
---
--- These are the controls under the composer in the Paseo app. They belong here
--- for the same reason the composer does: needing the app to change permission
--- mode means needing the app.
---
--- Everything is discovered from the daemon. Modes are per PROVIDER (claude has
--- plan/default/acceptEdits/auto/bypassPermissions; codex has
--- auto/auto-review/full-access), thinking options are per MODEL, and features
--- are per AGENT with their current values. Hardcoding any of it would be wrong
--- on the next provider.

local bridge = require "paseo.bridge"

local M = {}

---The agent to act on: the focused chat's, or the one for this directory.
---@param callback fun(agent_id: string|nil, chat: table|nil)
local function target(callback)
  local chat = require("paseo.ui.chat").current()
  if chat and chat.agent_id then
    return callback(chat.agent_id, chat)
  end
  vim.notify("paseo: no chat is open — <leader>aa first", vim.log.levels.WARN)
  callback(nil, nil)
end

---@param callback fun(config: table|nil, agent_id: string|nil, chat: table|nil)
local function with_config(callback)
  target(function(agent_id, chat)
    if not agent_id then
      return
    end
    bridge.request("agent.config", { agentId = agent_id }, function(err, config)
      if err then
        return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
      end
      vim.schedule(function()
        callback(config, agent_id, chat)
      end)
    end)
  end)
end

---A notice is the provider having something to say about a change it accepted.
---@param notice any
local function report(notice)
  if type(notice) == "table" and notice.message then
    vim.notify("paseo: " .. tostring(notice.message), vim.log.levels.WARN)
  elseif type(notice) == "string" and notice ~= "" then
    vim.notify("paseo: " .. notice, vim.log.levels.WARN)
  end
end

---Permission / operating mode.
function M.mode()
  with_config(function(config, agent_id, chat)
    local modes = config.availableModes or {}
    if #modes == 0 then
      return vim.notify("paseo: this provider reports no modes", vim.log.levels.WARN)
    end

    vim.ui.select(modes, {
      prompt = "Mode",
      format_item = function(mode)
        local marker = mode.id == config.modeId and "● " or "  "
        return ("%s%-18s %s"):format(marker, mode.label or mode.id, mode.description or "")
      end,
    }, function(choice)
      if not choice then
        return
      end
      bridge.request(
        "agent.setMode",
        { agentId = agent_id, modeId = choice.id },
        function(err, result)
          if err then
            return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
          end
          vim.schedule(function()
            report(result and result.notice)
            if chat then
              chat.mode = choice.label or choice.id
              require("paseo.ui.chat").refresh(chat)
            end
            vim.notify("paseo: mode → " .. (choice.label or choice.id), vim.log.levels.INFO)
          end)
        end
      )
    end)
  end)
end

---Reasoning level. Per MODEL, so the list changes with the model.
function M.thinking()
  with_config(function(config, agent_id, chat)
    local options = config.thinkingOptions or {}
    if #options == 0 then
      return vim.notify(
        ("paseo: %s reports no thinking levels"):format(config.model or "this model"),
        vim.log.levels.WARN
      )
    end

    vim.ui.select(options, {
      prompt = "Thinking",
      format_item = function(option)
        local marker = option.id == config.thinkingOptionId and "● " or "  "
        return ("%s%s%s"):format(
          marker,
          option.label or option.id,
          option.isDefault and "  (default)" or ""
        )
      end,
    }, function(choice)
      if not choice then
        return
      end
      bridge.request(
        "agent.setThinking",
        { agentId = agent_id, thinkingOptionId = choice.id },
        function(err, result)
          if err then
            return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
          end
          vim.schedule(function()
            report(result and result.notice)
            if chat then
              chat.thinking = choice.label or choice.id
              require("paseo.ui.chat").refresh(chat)
            end
            vim.notify("paseo: thinking → " .. (choice.label or choice.id), vim.log.levels.INFO)
          end)
        end
      )
    end)
  end)
end

---Switch model on the running session, without starting a new one.
function M.model()
  with_config(function(config, agent_id, chat)
    local models = config.models or {}
    if #models == 0 then
      return vim.notify("paseo: no models reported for this provider", vim.log.levels.WARN)
    end

    vim.ui.select(models, {
      prompt = "Model",
      format_item = function(model)
        local marker = model.id == config.model and "● " or "  "
        return ("%s%s"):format(marker, model.label or model.id)
      end,
    }, function(choice)
      if not choice then
        return
      end
      bridge.request("agent.setModel", { agentId = agent_id, modelId = choice.id }, function(err)
        if err then
          return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
        end
        vim.schedule(function()
          if chat then
            chat.provider = (config.provider or "?") .. "/" .. choice.id
            require("paseo.ui.chat").refresh(chat)
          end
          vim.notify("paseo: model → " .. (choice.label or choice.id), vim.log.levels.INFO)
        end)
      end)
    end)
  end)
end

---Toggle a boolean feature. Defaults to `fast_mode` -- the lightning bolt.
---@param feature_id? string
function M.toggle(feature_id)
  with_config(function(config, agent_id, chat)
    local features = config.features or {}
    local wanted = feature_id or "fast_mode"

    local target_feature
    for _, feature in ipairs(features) do
      if feature.id == wanted then
        target_feature = feature
      end
    end

    if not target_feature then
      -- Not every provider has every feature, and `fast_mode` is Opus-specific.
      -- Offer whatever this one does have rather than reporting nothing.
      local toggles = vim.tbl_filter(function(feature)
        return feature.type == "toggle"
      end, features)
      if #toggles == 0 then
        return vim.notify("paseo: this session has no feature toggles", vim.log.levels.WARN)
      end
      return vim.ui.select(toggles, {
        prompt = "Toggle",
        format_item = function(feature)
          return ("%s %s"):format(feature.value and "[x]" or "[ ]", feature.label or feature.id)
        end,
      }, function(choice)
        if choice then
          M.toggle(choice.id)
        end
      end)
    end

    local value = not target_feature.value
    bridge.request(
      "agent.setFeature",
      { agentId = agent_id, featureId = wanted, value = value },
      function(err)
        if err then
          return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
        end
        vim.schedule(function()
          if chat then
            chat.features = chat.features or {}
            chat.features[wanted] = value
            require("paseo.ui.chat").refresh(chat)
          end
          vim.notify(
            ("paseo: %s %s"):format(target_feature.label or wanted, value and "on" or "off"),
            vim.log.levels.INFO
          )
        end)
      end
    )
  end)
end

---Everything about the session, in one notification.
function M.status()
  with_config(function(config)
    local lines = {
      ("provider  %s/%s"):format(config.provider or "?", config.model or "?"),
      ("mode      %s"):format(config.modeId or "?"),
      ("thinking  %s"):format(config.thinkingOptionId or "(provider default)"),
    }
    for _, feature in ipairs(config.features or {}) do
      lines[#lines + 1] = ("%-9s %s"):format(feature.label or feature.id, tostring(feature.value))
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "paseo: session" })
  end)
end

return M
