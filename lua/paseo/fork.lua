--- Fork an agent's complete conversation into a newly-created workspace.
---
--- The daemon owns the transcript snapshot. Neovim asks for one before it
--- creates anything, then creates the new agent with its first prompt and the
--- chat-history attachment in the same request.

local bridge = require "paseo.bridge"

local M = {}

local function notify(message, level)
  vim.notify("paseo: " .. message, level or vim.log.levels.ERROR)
end

local function default_id(entries, preferred, declared)
  if preferred then
    for _, entry in ipairs(entries or {}) do
      if entry.id == preferred then
        return preferred
      end
    end
  end
  if declared then
    for _, entry in ipairs(entries or {}) do
      if entry.id == declared then
        return declared
      end
    end
  end
  for _, entry in ipairs(entries or {}) do
    if entry.isDefault then
      return entry.id
    end
  end
  return entries and entries[1] and entries[1].id or nil
end

local function slug(value)
  value = tostring(value or "agent"):lower():gsub("[^%w_-]+", "-")
  value = value:gsub("%-+", "-"):gsub("^[-_]+", ""):gsub("[-_]+$", "")
  return (value ~= "" and value or "agent") .. "-fork"
end

---Resolve settings for a fork. A model override keeps compatible values and
---lets the target model/provider supply defaults for everything incompatible.
---@param fork table
---@param model_id string|nil
---@param callback fun(config: table|nil, err: string|nil)
function M.resolve_config(fork, model_id, callback)
  local source = fork.config or {}
  if not model_id or model_id == "" then
    return callback(vim.deepcopy(source), nil)
  end

  local provider_id = source.provider and source.provider:match "^([^/]+)/"
  if not provider_id then
    return callback(nil, "the source agent has no provider information")
  end

  require("paseo.ui.create").catalogue(fork.cwd, function(entries, err)
    if err then
      return callback(nil, err)
    end
    local provider, model
    for _, candidate in ipairs(entries or {}) do
      if candidate.provider == provider_id and candidate.status == "ready" then
        provider = candidate
        for _, candidate_model in ipairs(candidate.models or {}) do
          if candidate_model.id == model_id then
            model = candidate_model
          end
        end
      end
    end
    if not provider or not model then
      return callback(nil, "the selected model is no longer available")
    end

    local mode_id = default_id(provider.modes, source.modeId, provider.defaultModeId)
    local thinking_id =
      default_id(model.thinkingOptions, source.thinkingOptionId, model.defaultThinkingOptionId)
    local combined = provider.provider .. "/" .. model.id
    bridge.request("providers.features", {
      provider = combined,
      cwd = fork.cwd,
      modeId = mode_id,
    }, function(feature_err, result)
      if feature_err then
        return callback(nil, feature_err)
      end
      local feature_values = {}
      for _, feature in ipairs(result and result.features or {}) do
        local value = source.featureValues and source.featureValues[feature.id]
        if value == nil then
          value = feature.value
        end
        if value ~= nil then
          feature_values[feature.id] = value and true or false
          if feature.type and feature.type ~= "toggle" then
            feature_values[feature.id] = value
          end
        end
      end
      callback({
        provider = combined,
        modeId = mode_id,
        thinkingOptionId = thinking_id,
        featureValues = feature_values,
      }, nil)
    end)
  end)
end

local function create_agent(fork, workspace, prompt, settings)
  bridge.request("agent.create", {
    workspaceId = workspace.id,
    provider = settings.provider,
    modeId = settings.modeId,
    thinkingOptionId = settings.thinkingOptionId,
    featureValues = settings.featureValues,
    title = fork.title and ("Fork of " .. fork.title) or nil,
    prompt = prompt,
    attachments = { fork.attachment },
  }, function(err, result)
    vim.schedule(function()
      if err or not (result and result.id) then
        return notify(
          ("could not create the forked agent; the empty workspace %q was retained — %s"):format(
            workspace.name or workspace.id,
            tostring(err or "unknown error")
          )
        )
      end
      require("paseo.workspaces").open(workspace)
      require("paseo.ui.chat").open {
        root = workspace.directory,
        agent_id = result.id,
        title = fork.title and ("Fork of " .. fork.title) or nil,
      }
    end)
  end)
end

---@param chat table
---@param opts? { model_id?: string }
function M.start(chat, opts)
  opts = opts or {}
  if not (chat and chat.agent_id) then
    return notify("there is no live agent session to fork", vim.log.levels.WARN)
  end

  bridge.ensure(function(ensure_err)
    if ensure_err then
      return notify(ensure_err)
    end
    bridge.request("agent.forkContext", { agentId = chat.agent_id }, function(err, fork)
      vim.schedule(function()
        if err or not fork then
          return notify(err or "Paseo did not return fork context")
        end
        fork.cwd = fork.cwd or chat.root
        M.resolve_config(fork, opts.model_id, function(settings, settings_err)
          vim.schedule(function()
            if settings_err or not settings then
              return notify(settings_err or "could not resolve fork settings")
            end
            vim.ui.input({
              prompt = "New workspace name: ",
              default = slug(fork.title or vim.fs.basename(fork.cwd)),
            }, function(name)
              if not name or name == "" then
                return
              end
              require("paseo.ui.prompt").open({
                title = "First prompt for the fork",
                root = fork.cwd,
              }, function(prompt)
                if not prompt then
                  return
                end
                require("paseo.workspaces").create({
                  name = name,
                  root = fork.cwd,
                  new = true,
                }, function(id, create_err, _, workspace)
                  vim.schedule(function()
                    if create_err then
                      return notify(create_err)
                    end
                    if not id then
                      return
                    end
                    local function finish(resolved)
                      resolved.name = resolved.name or name
                      create_agent(fork, resolved, prompt, settings)
                    end
                    if workspace and workspace.directory then
                      return finish(workspace)
                    end
                    require("paseo.workspaces").get(id, function(resolved, get_err)
                      vim.schedule(function()
                        if not resolved then
                          return notify(get_err or "could not resolve the created workspace")
                        end
                        finish(resolved)
                      end)
                    end)
                  end)
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

return M
