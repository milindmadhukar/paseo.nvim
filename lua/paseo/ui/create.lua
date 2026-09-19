--- Provider selection and the settings review shown before a new agent exists.
--- The daemon supplies every choice. This module owns no persistent preference:
--- :Paseo model stores one in config for the current Neovim process.

local bridge = require "paseo.bridge"
local config = require "paseo.config"

local M = {}

local function current_root()
  local chat = require("paseo.ui.chat").current()
  return chat and chat.root or assert(vim.uv.cwd())
end

local function fetch_catalogue(cwd, callback)
  bridge.ensure(function(err)
    if err then
      return callback(nil, err)
    end
    bridge.request("providers", { cwd = cwd }, function(fetch_err, result)
      callback(result and result.entries or nil, fetch_err)
    end)
  end)
end

---Resolve the first slash only: some model ids themselves contain slashes.
function M.find(entries, value)
  if type(value) ~= "string" then
    return nil
  end
  local provider, model_id = value:match "^([^/]+)/(.+)$"
  if not provider then
    return nil
  end
  for _, entry in ipairs(entries or {}) do
    if entry.provider == provider and entry.status == "ready" then
      for _, model in ipairs(entry.models or {}) do
        if model.id == model_id then
          return { provider = value, entry = entry, model = model }
        end
      end
    end
  end
  return nil
end

---A provider picker followed by that provider's models. An explicit value is
---validated against the same catalogue without opening either picker.
---@param opts? { cwd?: string, direct?: string }
---@param callback fun(selection: table|nil, err: string|nil)
function M.select_model(opts, callback)
  opts = opts or {}
  fetch_catalogue(opts.cwd or current_root(), function(entries, err)
    if err then
      return callback(nil, err)
    end
    if opts.direct then
      local selected = M.find(entries, opts.direct)
      return callback(selected, selected and nil or "provider/model is not ready: " .. opts.direct)
    end
    local ready = vim.tbl_filter(function(entry)
      return entry.status == "ready" and #(entry.models or {}) > 0
    end, entries or {})
    if #ready == 0 then
      return callback(nil, "no provider model is ready on this daemon")
    end
    vim.schedule(function()
      vim.ui.select(ready, {
        prompt = "Provider for new agents",
        format_item = function(entry)
          return ("%s  (%d models)"):format(entry.label or entry.provider, #(entry.models or {}))
        end,
      }, function(entry)
        if not entry then
          return callback(nil, nil)
        end
        vim.ui.select(entry.models, {
          prompt = (entry.label or entry.provider) .. " model",
          format_item = function(model)
            return ("%s%s  %s"):format(
              model.isDefault and "★ " or "  ",
              model.label or model.id,
              model.description or ""
            )
          end,
        }, function(model)
          if not model then
            return callback(nil, nil)
          end
          callback({
            provider = entry.provider .. "/" .. model.id,
            entry = entry,
            model = model,
          }, nil)
        end)
      end)
    end)
  end)
end

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

function M.draft(selection)
  return {
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
  }
end

---Show provider, model, permissions, reasoning, and all reported toggles in one
---floating buffer. <CR> edits a row; c creates and q/Esc cancels.
---@param opts { cwd: string, preferred?: string }
---@param callback fun(draft: table|nil, err: string|nil)
function M.review(opts, callback)
  local state = { done = false, loading = false, request = 0, win = nil, buf = nil, draft = nil, actions = {} }

  local function finish(draft, err)
    if state.done then
      return
    end
    state.done = true
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_delete(state.buf, { force = true })
    end
    callback(draft, err)
  end

  local render
  local function refresh_features(keep_values)
    local draft = state.draft
    if not draft then
      return
    end
    state.request = state.request + 1
    local request = state.request
    state.loading = true
    render()
    bridge.request("providers.features", {
      provider = draft.provider,
      cwd = opts.cwd,
      modeId = draft.modeId,
    }, function(err, result)
      if state.done or request ~= state.request then
        return
      end
      if err then
        return finish(nil, err)
      end
      vim.schedule(function()
        if state.done or request ~= state.request or state.draft ~= draft then
          return
        end
        local previous = keep_values and draft.featureValues or {}
        draft.features = result.features or {}
        draft.featureValues = {}
        for _, feature in ipairs(draft.features) do
          if feature.type == "toggle" then
            local value = previous[feature.id]
            draft.featureValues[feature.id] = value == nil and feature.value or value
          end
        end
        state.loading = false
        render()
      end)
    end)
  end

  local function set_selection(selection)
    state.draft = M.draft(selection)
    refresh_features(false)
  end

  local function choose_selection()
    M.select_model({ cwd = opts.cwd }, function(selection, err)
      if err then
        return finish(nil, err)
      end
      if selection then
        vim.schedule(function()
          if not state.done then
            set_selection(selection)
          end
        end)
      elseif not state.draft then
        finish(nil, nil)
      end
    end)
  end

  render = function()
    local draft = state.draft
    if state.done or not draft then
      return
    end
    if not state.buf then
      state.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[state.buf].bufhidden = "wipe"
      vim.keymap.set("n", "<CR>", function()
        local action = state.actions[vim.api.nvim_win_get_cursor(0)[1]]
        if action then
          action()
        end
      end, { buffer = state.buf, silent = true })
      vim.keymap.set("n", "c", function()
        local selected = state.draft
        if not selected or state.loading then
          return
        end
        finish({
          provider = selected.provider,
          modeId = selected.modeId,
          thinkingOptionId = selected.thinkingOptionId,
          featureValues = selected.featureValues,
        }, nil)
      end, { buffer = state.buf, silent = true })
      for _, key in ipairs { "q", "<Esc>" } do
        vim.keymap.set("n", key, function()
          finish(nil, nil)
        end, { buffer = state.buf, silent = true })
      end
    end

    local lines, actions = {}, {}
    local function row(label, value, action)
      lines[#lines + 1] = ("%-15s %s"):format(label, value or "(provider default)")
      actions[#lines] = action
    end
    lines[#lines + 1] = "New Paseo session · <CR> edit · c create · q cancel"
    lines[#lines + 1] = ""
    row("Provider", draft.entry.label or draft.entry.provider, choose_selection)
    row("Model", draft.model.label or draft.model.id, choose_selection)
    row("Permissions", (function()
      for _, mode in ipairs(draft.entry.modes or {}) do
        if mode.id == draft.modeId then
          return mode.label or mode.id
        end
      end
    end)(), function()
      vim.ui.select(draft.entry.modes or {}, {
        prompt = "Permissions / mode",
        format_item = function(mode)
          return ("%s  %s"):format(mode.label or mode.id, mode.description or "")
        end,
      }, function(mode)
        if mode and not state.done then
          draft.modeId = mode.id
          refresh_features(true)
        end
      end)
    end)
    local thinking_label = draft.thinkingOptionId
    for _, option in ipairs(draft.model.thinkingOptions or {}) do
      if option.id == draft.thinkingOptionId then
        thinking_label = option.label or option.id
      end
    end
    row("Reasoning", thinking_label, function()
      vim.ui.select(draft.model.thinkingOptions or {}, {
        prompt = "Reasoning",
        format_item = function(option)
          return option.label or option.id
        end,
      }, function(option)
        if option and not state.done then
          draft.thinkingOptionId = option.id
          render()
        end
      end)
    end)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Features"
    if state.loading then
      lines[#lines + 1] = "  Loading model features…"
    end
    for _, feature in ipairs(draft.features) do
      if feature.type == "toggle" then
        local item = feature
        row("  " .. (item.label or item.id), draft.featureValues[item.id] and "[x]" or "[ ]", function()
          draft.featureValues[item.id] = not draft.featureValues[item.id]
          render()
        end)
      end
    end
    lines[#lines + 1] = ""
    row("Create", "<CR> or c", function()
      if state.loading then
        return
      end
      finish({
        provider = draft.provider,
        modeId = draft.modeId,
        thinkingOptionId = draft.thinkingOptionId,
        featureValues = draft.featureValues,
      }, nil)
    end)
    state.actions = actions
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    local width = math.max(1, math.min(vim.o.columns - 4, 72))
    local height = math.max(1, math.min(vim.o.lines - 4, #lines))
    if not state.win or not vim.api.nvim_win_is_valid(state.win) then
      state.win = vim.api.nvim_open_win(state.buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2)),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        zindex = 40,
        title = "New session",
      })
    else
      vim.api.nvim_win_set_height(state.win, height)
    end
  end

  fetch_catalogue(opts.cwd, function(entries, err)
    if err then
      return finish(nil, err)
    end
    local selected = M.find(entries, opts.preferred)
    if selected then
      vim.schedule(function()
        set_selection(selected)
      end)
    else
      choose_selection()
    end
  end)
end

function M.preference(value, callback)
  M.select_model({ cwd = current_root(), direct = value }, function(selection, err)
    if selection then
      config.get().paseo.provider = selection.provider
    end
    callback(selection, err)
  end)
end

return M
