--- What a running session is set to, and how to change it.
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
---
--- THIS FILE IS THE MODEL, NOT A VIEW. It used to be a second, parallel
--- implementation of the Session panel -- four `vim.ui.select` prompts with
--- their own copy of the apply-and-report logic, drifting against the panel's
--- copy of the same thing. Now `M.groups` normalises the daemon's four
--- differently-shaped lists into one shape, `M.apply` is the only place a
--- change is written, and both the dashboard panel and the standalone popup
--- draw from here.

local bridge = require "paseo.bridge"

local M = {}

-- ------------------------------------------------------------------ the data

---How loudly a mode should be drawn.
---
---Not decoration. Until now `bypassPermissions` rendered identically to
---`plan`, and those two are the extreme ends of "how much can this thing do
---without asking me". Matched on the id rather than listed literally, because
---the set is per provider and codex spells its own version `full-access`.
---@param id string
---@return string|nil  A key of `widgets.CHIP`.
function M.tone(id)
  local lowered = id:lower()
  if lowered:find "bypass" or lowered:find "full%-access" or lowered:find "danger" then
    return "danger"
  end
  if lowered:find "accept" or lowered:find "^auto" then
    return "warn"
  end
  return nil
end

---The mnemonic that jumps to each group.
---
---A constant rather than something read back off `M.groups`, because the
---panel binds these keys the moment you arrive at the tab -- which is usually
---before the daemon has answered. Deriving them from a config that has not
---landed yet bound nothing, and nothing is what the keys then did for the
---rest of the session.
M.KEYS = { mode = "m", thinking = "t", features = "f", model = "s" }

---The settings of a session, in ONE shape.
---
---The daemon reports four lists that agree about nothing: modes carry a
---description, thinking options carry `isDefault`, models carry both, and
---features are booleans with no selection at all. Normalising here is what
---lets the renderer draw a group without knowing which group it is.
---@param chat table
---@return table[]|nil  nil when no config has been fetched yet.
function M.groups(chat)
  local config = chat and chat.config_snapshot
  if not config then
    return nil
  end

  local function entries(list, note)
    local out = {}
    for _, entry in ipairs(list or {}) do
      out[#out + 1] = {
        id = entry.id,
        label = entry.label or entry.id,
        description = entry.description,
        note = note and note(entry) or nil,
        value = entry.value,
        tone = nil,
      }
    end
    return out
  end

  local function default_note(entry)
    return entry.isDefault and "default" or nil
  end

  local modes = entries(config.availableModes)
  for _, entry in ipairs(modes) do
    entry.tone = M.tone(entry.id)
  end

  -- Only the toggles. A feature the provider reports as something other than a
  -- boolean has no sensible checkbox, and drawing one that does nothing is
  -- worse than leaving it out.
  local toggles = {}
  for _, feature in ipairs(config.features or {}) do
    if feature.type == nil or feature.type == "toggle" then
      toggles[#toggles + 1] = {
        id = feature.id,
        label = feature.label or feature.id,
        description = feature.description,
        value = feature.value and true or false,
      }
    end
  end

  return {
    {
      id = "mode",
      key = M.KEYS.mode,
      icon = "",
      label = "Permission mode",
      kind = "chips",
      entries = modes,
      current = config.modeId,
      op = "agent.setMode",
      arg = "modeId",
    },
    {
      id = "thinking",
      key = M.KEYS.thinking,
      icon = "󰧑",
      label = "Thinking",
      kind = "chips",
      entries = entries(config.thinkingOptions, default_note),
      current = config.thinkingOptionId,
      op = "agent.setThinking",
      arg = "thinkingOptionId",
    },
    {
      id = "features",
      key = M.KEYS.features,
      icon = "⚡",
      label = "Features",
      kind = "toggles",
      entries = toggles,
      op = "agent.setFeature",
      arg = "featureId",
    },
    {
      id = "model",
      key = M.KEYS.model,
      icon = "",
      label = "Model",
      kind = "radio",
      entries = entries(config.models, default_note),
      current = config.model,
      op = "agent.setModel",
      arg = "modelId",
    },
  }
end

---@param groups table[]|nil
---@param id string
---@return table|nil, integer|nil
function M.group(groups, id)
  for i, group in ipairs(groups or {}) do
    if group.id == id then
      return group, i
    end
  end
  return nil, nil
end

-- -------------------------------------------------------------- round trips

---Fetch `agent.config` into `chat.config_snapshot`.
---
---Cheap enough to call on every panel open: modes, models and thinking levels
---are all per-provider and can change under us when the Paseo app switches
---something.
---@param chat table
---@param done? fun(config: table|nil, err: string|nil)
function M.load(chat, done)
  done = done or function() end
  if not (chat and chat.agent_id) then
    return done(nil, "no agent")
  end
  bridge.request("agent.config", { agentId = chat.agent_id }, function(err, config)
    vim.schedule(function()
      if err or not config then
        return done(nil, err or "no config")
      end
      chat.config_snapshot = config
      done(config, nil)
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

---Apply one change, then reload from what the daemon reports back.
---
---Not from what we asked for: a provider may accept a change and still have
---something to say about it, and `agent.config` is the only honest answer.
---@param chat table
---@param group table
---@param entry table
---@param done? fun()
function M.apply(chat, group, entry, done)
  done = done or function() end
  if not (chat and chat.agent_id and group and entry) then
    return done()
  end

  local args = { agentId = chat.agent_id }
  args[group.arg] = entry.id
  if group.kind == "toggles" then
    args.value = not entry.value
  end

  bridge.request(group.op, args, function(err, result)
    vim.schedule(function()
      if err then
        vim.notify("paseo: " .. err, vim.log.levels.ERROR)
        return done()
      end
      report(result and result.notice)
      M.load(chat, function()
        -- The header, the winbar and `chat.features` all read their own
        -- copies; this is what keeps them from disagreeing with the panel.
        require("paseo.ui.chat").load_settings(chat)
        done()
      end)
    end)
  end)
end

-- ------------------------------------------------------------------ source

---@class paseo.SettingsSource
---@field groups fun(self): table[]|nil
---@field apply fun(self, group: table, entry: table, done: fun())
---@field load fun(self, done: fun())
---@field keys table<string, string>

---This module, as the interface |paseo.ui.panels.session| draws.
---
---The View used to call `session.groups`, `session.apply` and `session.load`
---by name, which tied it to a RUNNING agent -- and that is why the screen
---shown before an agent exists was a second, hand-rolled renderer of the same
---four settings. The View is already generic over "a list of groups"; this is
---the three-method seam that lets |paseo.ui.draft| hand it a session that does
---not exist yet.
---@param chat table
---@return paseo.SettingsSource
function M.source(chat)
  return {
    chat = chat,
    keys = M.KEYS,
    pairs = { { "thinking", "features" } },
    groups = function()
      return M.groups(chat)
    end,
    apply = function(_, group, entry, done)
      M.apply(chat, group, entry, done)
    end,
    load = function(_, done)
      M.load(chat, function()
        done()
      end)
    end,
  }
end

-- ---------------------------------------------------------------- commands

---The chat to act on: the focused one.
---@return table|nil
local function target()
  local chat = require("paseo.ui.chat").current()
  if chat and chat.agent_id then
    return chat
  end
  vim.notify("paseo: no chat is open — <leader>aa first", vim.log.levels.WARN)
  return nil
end

---Open the settings popup, focused on one group.
---@param group_id? string
local function popup(group_id)
  local chat = target()
  if not chat then
    return
  end
  require("paseo.ui.settings").open(chat, group_id)
end

---Permission / operating mode.
function M.mode()
  popup "mode"
end

---Reasoning level. Per MODEL, so the list changes with the model.
function M.thinking()
  popup "thinking"
end

---Switch model on the running session, without starting a new one.
function M.model()
  popup "model"
end

---Everything about the session, in one window.
function M.status()
  popup()
end

---Toggle a boolean feature. Defaults to `fast_mode` -- the lightning bolt.
---
---Stays a direct toggle rather than a popup: `:Paseo fast` is a one-keystroke
---convenience and putting a window in front of it would defeat the point. The
---popup is the fallback for when this provider has no such feature.
---@param feature_id? string
function M.toggle(feature_id)
  local chat = target()
  if not chat then
    return
  end

  M.load(chat, function(config)
    if not config then
      return vim.notify("paseo: could not read the session config", vim.log.levels.ERROR)
    end

    local groups = M.groups(chat)
    local features = M.group(groups, "features")
    local wanted = feature_id or "fast_mode"

    local entry
    for _, candidate in ipairs(features and features.entries or {}) do
      if candidate.id == wanted then
        entry = candidate
      end
    end

    if not entry then
      -- Not every provider has every feature, and `fast_mode` is Opus-specific.
      -- Show what this one DOES have rather than reporting nothing.
      if not features or #features.entries == 0 then
        return vim.notify("paseo: this session has no feature toggles", vim.log.levels.WARN)
      end
      return require("paseo.ui.settings").open(chat, "features")
    end

    M.apply(chat, features, entry, function()
      vim.notify(
        ("paseo: %s %s"):format(entry.label, (not entry.value) and "on" or "off"),
        vim.log.levels.INFO
      )
    end)
  end)
end

---Plan is a feature on Codex and a mode on Claude. Follow what this running
---agent actually advertises, while leaving its permission mode untouched when
---the feature form is available.
---
---Reads its config through `M.load` now that `with_config` is gone, but WRITES
---the way it always did -- straight to `agent.setMode` rather than through
---`M.apply`. `apply` reloads from the daemon on success, which would make the
---last request on the wire an `agent.config` rather than the mode change, and
---the mode here is only half the operation: `mode_before_plan` has to be
---recorded in the same breath so leaving Plan knows where to go back to.
function M.plan()
  local chat = target()
  if not chat then
    return
  end

  M.load(chat, function(config)
    if not config then
      return vim.notify("paseo: could not read the session config", vim.log.levels.ERROR)
    end

    for _, feature in ipairs(config.features or {}) do
      if feature.id == "plan_mode" and feature.type == "toggle" then
        return M.toggle "plan_mode"
      end
    end

    local function has(id)
      for _, mode in ipairs(config.availableModes or {}) do
        if mode.id == id then
          return true
        end
      end
      return false
    end

    if not has "plan" then
      return vim.notify("paseo: this session has no Plan control", vim.log.levels.WARN)
    end

    -- Leaving Plan goes back to whatever you were in, remembered on the way
    -- in -- not to a hardcoded mode, because the provider may not have one by
    -- that name.
    local entering = config.modeId ~= "plan"
    local wanted = entering and "plan" or (chat.mode_before_plan or "default")
    if not has(wanted) then
      return vim.notify(
        "paseo: this provider cannot leave Plan through this command",
        vim.log.levels.WARN
      )
    end

    bridge.request(
      "agent.setMode",
      { agentId = chat.agent_id, modeId = wanted },
      function(err, result)
        if err then
          return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
        end
        vim.schedule(function()
          report(result and result.notice)
          chat.mode_before_plan = entering and config.modeId or nil
          require("paseo.ui.chat").load_settings(chat)
        end)
      end
    )
  end)
end

return M
