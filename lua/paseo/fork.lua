--- Fork an agent's complete conversation: a second agent that starts where
--- this one has got to.
---
--- The daemon owns the transcript snapshot. Neovim asks for one before it
--- creates anything, then creates the new agent with its first prompt and the
--- chat-history attachment in the same request.
---
--- TWO DESTINATIONS, and the difference between them is the files, not the
--- conversation. Both forks carry the same history; one runs in the directory
--- the source agent is already working in, and one gets a directory of its
--- own. That is the question, so that is what the menu asks -- see
--- `M.DESTINATIONS`.

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

---Where a fork goes.
---
---PASEO'S OWN TWO NOUNS. A workspace is a directory with agents in it; a
---session is one of those agents. So "new session" is a second agent in the
---directory this one is already working in, and "new workspace" is a second
---directory as well -- which is the whole difference, because two agents in
---one directory edit the same files.
---
---The note is not decoration. `f` used to do the second of these silently,
---and the surprise was never the fork -- it was arriving in a directory you
---did not ask for.
---
---A LIST, in menu order, so the menu and the tests read the same table.
M.DESTINATIONS = {
  { id = "session", label = "new session", note = "here, beside this one" },
  { id = "workspace", label = "new workspace", note = "a directory of its own" },
  { id = "cancel", label = "cancel" },
}

---@param choice table
---@return string
local function spell(choice)
  return choice.note and ("%s  (%s)"):format(choice.label, choice.note) or choice.label
end

---Ask where this fork goes.
---
---HANDED IN rather than reached for, so `M.start { destination = … }` drives
---the whole path with no window -- which is what the model-change menu does,
---having already asked the question in its own words.
---@param fork table
---@param callback fun(id: string|nil)
function M.choose(fork, callback)
  vim.ui.select(M.DESTINATIONS, {
    prompt = ("Fork %s into…"):format(fork.title and ("%q"):format(fork.title) or "this agent"),
    format_item = spell,
  }, function(choice)
    callback(choice and choice.id ~= "cancel" and choice.id or nil)
  end)
end

---The new agent, in whichever workspace it turned out to belong to.
---@param fork table
---@param workspace table  `{ id, name?, directory? }`
---@param prompt string
---@param settings table
---@param opts { created: boolean }  Whether this run MADE the workspace.
local function create_agent(fork, workspace, prompt, settings, opts)
  local title = fork.title and ("Fork of " .. fork.title) or nil
  bridge.request("agent.create", {
    workspaceId = workspace.id,
    provider = settings.provider,
    modeId = settings.modeId,
    thinkingOptionId = settings.thinkingOptionId,
    featureValues = settings.featureValues,
    title = title,
    prompt = prompt,
    attachments = { fork.attachment },
  }, function(err, result)
    vim.schedule(function()
      if err or not (result and result.id) then
        -- An empty workspace left behind is news; one that was already there
        -- is not, and saying it was "retained" of a directory this run did
        -- not create reads as though something had been done to it.
        if opts.created then
          return notify(
            ("could not create the forked agent; the empty workspace %q was retained — %s"):format(
              workspace.name or workspace.id,
              tostring(err or "unknown error")
            )
          )
        end
        return notify("could not create the forked agent — " .. tostring(err or "unknown error"))
      end
      -- Only a fork that MOVED you needs the workspace opened. A session fork
      -- is in the directory you are already standing in, and `workspaces.open`
      -- is a `:tcd` -- so calling it here would be a no-op with a chance of
      -- dragging the window somewhere on a resolved-symlink mismatch.
      if opts.created then
        require("paseo.workspaces").open(workspace)
      end
      require("paseo.ui.chat").open {
        root = workspace.directory or fork.cwd,
        agent_id = result.id,
        title = title,
      }
    end)
  end)
end

---Fork into a second agent in the workspace this one is already in.
---
---The workspace id comes from the fork context, which is the daemon's own
---answer for the source agent. `for_dir` is the fallback for a daemon too old
---to report it -- the directory is the one thing we always have.
---@param fork table
---@param settings table
local function into_session(fork, settings)
  local function go(workspace)
    require("paseo.ui.prompt").open({
      title = "First prompt for the fork",
      root = fork.cwd,
    }, function(prompt)
      if not prompt then
        return
      end
      create_agent(fork, workspace, prompt, settings, { created = false })
    end)
  end

  if fork.workspaceId then
    return go { id = fork.workspaceId, directory = fork.cwd }
  end
  require("paseo.workspaces").for_dir(fork.cwd, function(ws, err)
    vim.schedule(function()
      if not ws then
        return notify(err or "this directory is not in a Paseo workspace yet")
      end
      go(ws)
    end)
  end)
end

---Fork into a workspace of its own: new directory, new agent, same history.
---@param fork table
---@param settings table
local function into_workspace(fork, settings)
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
            create_agent(fork, resolved, prompt, settings, { created = true })
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
end

---Fork the conversation on `chat`.
---@param chat table
---@param opts? { model_id?: string, destination?: "session"|"workspace" }
---            `destination` skips the menu. The model-change dialog passes it:
---            it has already asked, in its own words, and asking twice for one
---            keystroke is worse than not asking at all.
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

            local function dispatch(destination)
              if destination == "session" then
                return into_session(fork, settings)
              end
              if destination == "workspace" then
                return into_workspace(fork, settings)
              end
            end

            if opts.destination then
              return dispatch(opts.destination)
            end
            M.choose(fork, dispatch)
          end)
        end)
      end)
    end)
  end)
end

return M
