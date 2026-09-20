--- A session that does not exist yet, in the shape the settings View draws.
---
--- Sibling to |paseo.ui.session|, and the same doctrine: `groups` normalises
--- the daemon's differently-shaped lists into ONE shape, and `apply` is the
--- only place a change is written.
---
--- It exists because the screen shown before an agent is created was a second
--- renderer of the same settings -- `("%-15s %s"):format(label, value)` into a
--- plain buffer, with a `vim.ui.select` for every choice -- while the Session
--- tab drew those settings as cards. One of the two had to go, and the one to
--- keep is obviously the one you can see.
---
--- Two groups the running-session model does not have: PROVIDER and MODEL are
--- settings here and are not settings there. Switching model on a live agent is
--- `agent.setModel`; switching it here replaces the thinking options and the
--- feature list, because both are per model and nothing has been created yet.

local bridge = require "paseo.bridge"
local session = require "paseo.ui.session"

local M = {}

---@class paseo.Draft
---@field cwd string
---@field entries table[]  The provider catalogue, as `providers` reports it.
---@field provider string  `"claude/opus-5"` -- provider and model, the way the daemon wants it.
---@field entry table  The catalogue entry for the selected provider.
---@field model table
---@field modeId string|nil
---@field thinkingOptionId string|nil
---@field features table[]
---@field featureValues table<string, boolean>
---@field loading boolean
---@field request integer  Generation counter: a stale features reply is dropped.
---@field feature_rows integer  Toggles last reported, so the card holds its height.

M.KEYS = { provider = "p", model = "s", mode = "m", thinking = "t", features = "f" }

---The id a list means by "no explicit choice": the one flagged default, else
---the first. Unchanged from the screen this replaces.
---@param entries table[]|nil
---@param explicit string|nil
---@return string|nil
local function default_id(entries, explicit)
  if explicit then
    return explicit
  end
  for _, item in ipairs(entries or {}) do
    if item.isDefault then
      return item.id
    end
  end
  return entries and entries[1] and entries[1].id or nil
end

M.default_id = default_id

---A provider entry is offerable when the daemon says it is ready AND it has a
---model. A ready provider with no models cannot start anything, and drawing a
---chip that produces an empty Model card is worse than not drawing it.
---@param entry table
---@return boolean
local function offerable(entry)
  return entry.status == "ready" and #(entry.models or {}) > 0
end

M.offerable = offerable

---@param cwd string
---@param entries table[]
---@param selection { provider: string, entry: table, model: table }
---@return paseo.Draft
function M.new(cwd, entries, selection)
  return {
    cwd = cwd,
    entries = entries,
    provider = selection.provider,
    entry = selection.entry,
    model = selection.model,
    modeId = default_id(selection.entry.modes, selection.entry.defaultModeId),
    thinkingOptionId = default_id(
      selection.model.thinkingOptions,
      selection.model.defaultThinkingOptionId
    ),
    features = {},
    featureValues = {},
    loading = false,
    request = 0,
    feature_rows = 0,
  }
end

---The first provider that can start something, as a selection.
---@param entries table[]
---@return table|nil
function M.first(entries)
  for _, entry in ipairs(entries or {}) do
    if offerable(entry) then
      local model = entry.models[1]
      for _, candidate in ipairs(entry.models) do
        if candidate.isDefault then
          model = candidate
        end
      end
      return { provider = entry.provider .. "/" .. model.id, entry = entry, model = model }
    end
  end
  return nil
end

-- ------------------------------------------------------------------ groups

---@param list table[]|nil
---@param note? fun(entry: table): string|nil
---@return table[]
local function entries_of(list, note)
  local out = {}
  for _, entry in ipairs(list or {}) do
    out[#out + 1] = {
      id = entry.id,
      label = entry.label or entry.id,
      description = entry.description,
      note = note and note(entry) or nil,
    }
  end
  return out
end

---@param entry table
---@return string|nil
local function default_note(entry)
  return entry.isDefault and "default" or nil
end

---The draft, as the five cards the View draws.
---@param draft paseo.Draft
---@return table[]
function M.groups(draft)
  local providers = {}
  for _, entry in ipairs(draft.entries or {}) do
    if offerable(entry) then
      providers[#providers + 1] = {
        id = entry.provider,
        label = entry.label or entry.provider,
        description = entry.description,
      }
    end
  end

  local modes = entries_of(draft.entry.modes)
  for _, entry in ipairs(modes) do
    entry.tone = session.tone(entry.id)
  end

  local toggles = {}
  if not draft.loading then
    for _, feature in ipairs(draft.features or {}) do
      if feature.type == nil or feature.type == "toggle" then
        toggles[#toggles + 1] = {
          id = feature.id,
          label = feature.label or feature.id,
          description = feature.description,
          value = draft.featureValues[feature.id] and true or false,
        }
      end
    end
  end

  return {
    {
      id = "provider",
      key = M.KEYS.provider,
      icon = "󱚠",
      label = "Provider",
      kind = "chips",
      entries = providers,
      current = draft.entry.provider,
    },
    {
      id = "model",
      key = M.KEYS.model,
      icon = "",
      label = "Model",
      kind = "radio",
      entries = entries_of(draft.entry.models, default_note),
      current = draft.model.id,
    },
    {
      id = "mode",
      key = M.KEYS.mode,
      icon = "",
      label = "Permission mode",
      kind = "chips",
      entries = modes,
      current = draft.modeId,
    },
    {
      id = "thinking",
      key = M.KEYS.thinking,
      icon = "󰧑",
      label = "Thinking",
      kind = "chips",
      entries = entries_of(draft.model.thinkingOptions, default_note),
      current = draft.thinkingOptionId,
    },
    {
      id = "features",
      key = M.KEYS.features,
      icon = "⚡",
      label = "Features",
      kind = "toggles",
      entries = toggles,
      -- The card keeps the height it had while the daemon is asked what the
      -- new mode supports. A features card that collapses to one row and
      -- springs back moves every card below it twice, and volt turns that
      -- into `Invalid 'line': out of range` on the next mouse move.
      rows = draft.loading and math.max(1, draft.feature_rows) or nil,
      placeholder = draft.loading and "loading…" or nil,
    },
  }
end

-- ------------------------------------------------------------- round trips

---What this provider and mode support, asked fresh.
---
---Guarded by a generation counter AND by identity: changing mode twice in
---quick succession leaves two requests in flight, and the first to come back
---is not necessarily the first that was sent.
---@param draft paseo.Draft
---Calls `done` TWICE on the happy path, and that is the point: once
---immediately, so the loading state is painted, and once when the answer
---lands. The View routes `done` to its redraw, which is idempotent.
---@param keep_values boolean  Carry over the values of features the new list still reports.
---@param done? fun()
function M.refresh_features(draft, keep_values, done)
  done = done or function() end
  draft.request = draft.request + 1
  local request = draft.request
  local entry, model = draft.entry, draft.model
  draft.loading = true
  done()

  bridge.request("providers.features", {
    provider = draft.provider,
    cwd = draft.cwd,
    modeId = draft.modeId,
  }, function(err, result)
    vim.schedule(function()
      if request ~= draft.request or entry ~= draft.entry or model ~= draft.model then
        return
      end
      if err then
        draft.loading = false
        vim.notify(
          "paseo: could not read this model's features — " .. tostring(err),
          vim.log.levels.WARN
        )
        return done()
      end

      local previous = keep_values and draft.featureValues or {}
      draft.features = result and result.features or {}
      draft.featureValues = {}
      local rows = 0
      for _, feature in ipairs(draft.features) do
        if feature.type == nil or feature.type == "toggle" then
          rows = rows + 1
          -- NOT `value == nil and feature.value or value`, which is what the
          -- screen this replaced did: a feature defaulting to `false` makes
          -- that expression `false or nil`, so every toggle that starts off
          -- came back absent rather than off -- and `keep_values` then cannot
          -- tell "you turned this off" from "nobody has said".
          local value = previous[feature.id]
          if value == nil then
            value = feature.value
          end
          draft.featureValues[feature.id] = value and true or false
        end
      end
      draft.feature_rows = rows
      draft.loading = false
      done()
    end)
  end)
end

---Select a provider by id, keeping nothing: its modes, models, thinking
---options and features are all its own.
---@param draft paseo.Draft
---@param provider_id string
---@return boolean  Whether anything changed.
local function set_provider(draft, provider_id)
  if draft.entry.provider == provider_id then
    return false
  end
  for _, entry in ipairs(draft.entries or {}) do
    if entry.provider == provider_id and offerable(entry) then
      local selection = M.first { entry }
      draft.entry = selection.entry
      draft.model = selection.model
      draft.provider = selection.provider
      draft.modeId = default_id(entry.modes, entry.defaultModeId)
      draft.thinkingOptionId =
        default_id(draft.model.thinkingOptions, draft.model.defaultThinkingOptionId)
      draft.feature_rows = 0
      return true
    end
  end
  return false
end

---Apply one change. The only place the draft is written.
---@param draft paseo.Draft
---@param group table
---@param entry table
---@param done? fun()
function M.apply(draft, group, entry, done)
  done = done or function() end
  if not (group and entry) then
    return done()
  end

  if group.id == "provider" then
    if not set_provider(draft, entry.id) then
      return done()
    end
    -- Not `keep_values`: a feature id means whatever the provider reporting it
    -- says it means, and carrying `fast_mode = true` from claude to codex is
    -- asserting they are the same switch.
    return M.refresh_features(draft, false, done)
  end

  if group.id == "model" then
    for _, model in ipairs(draft.entry.models or {}) do
      if model.id == entry.id then
        draft.model = model
        draft.provider = draft.entry.provider .. "/" .. model.id
        draft.thinkingOptionId = default_id(model.thinkingOptions, model.defaultThinkingOptionId)
        return M.refresh_features(draft, true, done)
      end
    end
    return done()
  end

  if group.id == "mode" then
    if draft.modeId == entry.id then
      return done()
    end
    draft.modeId = entry.id
    -- Features are per MODE as well as per model: codex reports a different
    -- set under full-access than under its default.
    return M.refresh_features(draft, true, done)
  end

  if group.id == "thinking" then
    draft.thinkingOptionId = entry.id
    return done()
  end

  if group.id == "features" then
    draft.featureValues[entry.id] = not draft.featureValues[entry.id]
    return done()
  end

  return done()
end

---Re-read the catalogue, so `r` means the same thing here as on the Session
---tab. The selection survives by id where it still exists.
---@param draft paseo.Draft
---@param done? fun()
function M.load(draft, done)
  done = done or function() end
  bridge.request("providers", { cwd = draft.cwd }, function(err, result)
    vim.schedule(function()
      if err then
        vim.notify(
          "paseo: could not re-read the providers — " .. tostring(err),
          vim.log.levels.WARN
        )
        return done()
      end
      draft.entries = result and result.entries or {}

      local kept
      for _, entry in ipairs(draft.entries) do
        if entry.provider == draft.entry.provider and offerable(entry) then
          for _, model in ipairs(entry.models) do
            if model.id == draft.model.id then
              kept = { entry = entry, model = model }
            end
          end
        end
      end
      local selection = kept or M.first(draft.entries)
      if not selection then
        return done()
      end
      draft.entry = selection.entry
      draft.model = selection.model
      draft.provider = draft.entry.provider .. "/" .. draft.model.id
      M.refresh_features(draft, true, done)
    end)
  end)
end

---What `M.review` hands back: exactly the four fields `agent.ensure` takes.
---@param draft paseo.Draft
---@return table
function M.result(draft)
  return {
    provider = draft.provider,
    modeId = draft.modeId,
    thinkingOptionId = draft.thinkingOptionId,
    featureValues = draft.featureValues,
  }
end

---The draft, as the interface |paseo.ui.panels.session| draws.
---@param draft paseo.Draft
---@return paseo.SettingsSource
function M.source(draft)
  return {
    draft = draft,
    keys = M.KEYS,
    -- Five cards, and a short editor has room for four rows of them. Provider
    -- and Permission mode are both one chip row, so they pair the way
    -- Thinking and Features do -- otherwise the screen is three rows too tall
    -- on 80x24 and the clamp takes the footer, which is where `c` is written.
    pairs = { { "provider", "mode" }, { "thinking", "features" } },
    groups = function()
      return M.groups(draft)
    end,
    apply = function(_, group, entry, done)
      M.apply(draft, group, entry, done)
    end,
    load = function(_, done)
      M.load(draft, done)
    end,
  }
end

return M
