--- Starting something: an agent here, an agent in a worktree of its own, or a
--- terminal -- the one way in, whichever key or command it came from.
---
--- THIS IS THE MODEL, NOT THE SCREEN. |paseo.ui.newtask| draws the choices
--- and the box you type the first prompt in; this module remembers what you
--- chose last and does the creating. They are apart so the creating can be
--- driven, and tested, with no window at all.
---
--- WHAT IS NOT ASKED: the project and the host. Both are where you already
--- are -- the directory this Neovim (or the Paseo tab) is in, and the host
--- it is on -- so asking would only be a chance to pick something else by
--- mistake. And not the workspace's NAME: the daemon names a worktree, its
--- branch and its title from the first prompt, as the app does. See
--- |paseo-new|.

local config = require "paseo.config"

local M = {}

-- ------------------------------------------------------------- remembering

---@class paseo.NewChoice
---@field kind "chat"|"terminal"
---@field where "here"|"worktree"
---@field base? string  A branch, or nil for "whatever is checked out".
---@field provider? string  `provider/model`
---@field modeId? string
---@field thinkingOptionId? string
---@field featureValues? table<string, boolean>
---@field preset? string  A terminal preset's label.

---@return string
local function state_path()
  return vim.fs.joinpath(vim.fn.stdpath "state", "paseo", "new.json")
end

---@return table
local function read()
  local fd = io.open(state_path(), "r")
  if not fd then
    return {}
  end
  local text = fd:read "*a"
  fd:close()
  local ok, parsed = pcall(vim.json.decode, text)
  return (ok and type(parsed) == "table") and parsed or {}
end

---@param state table
local function write(state)
  local path = state_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if fd then
    fd:write(vim.json.encode(state))
    fd:close()
  end
end

---What a choice is remembered UNDER: the host and the project, so a repo you
---always start worktrees in keeps starting them, and one you only ever open a
---shell in keeps doing that.
---@param ctx { root: string, local_root?: string, host_id?: string }
---@return string
function M.key(ctx)
  local root = ctx.local_root or ctx.root
  local ok, project = pcall(function()
    return require("paseo.workspaces").here(root)
  end)
  return ("%s|%s"):format(ctx.host_id or "local", ok and project or root)
end

---What to prefill: this project's last choice, else the last choice anywhere,
---else nothing (and the screen falls back to the config and the daemon).
---@param ctx { root: string, local_root?: string, host_id?: string }
---@return paseo.NewChoice|table
function M.remembered(ctx)
  local state = read()
  local projects = type(state.projects) == "table" and state.projects or {}
  local hit = projects[M.key(ctx)]
  if type(hit) == "table" then
    return hit
  end
  return type(state.last) == "table" and state.last or {}
end

---Remember `choice` for this project, and as the last choice anywhere.
---
---Written when something is CREATED, not on every chip you move across: a
---choice you looked at and backed out of is not one you made.
---@param ctx { root: string, local_root?: string, host_id?: string }
---@param choice paseo.NewChoice
function M.remember(ctx, choice)
  local state = read()
  state.projects = type(state.projects) == "table" and state.projects or {}
  state.projects[M.key(ctx)] = choice
  state.last = choice
  pcall(write, state)
end

-- ---------------------------------------------------------------- creating

---@param message string
local function notify(message)
  vim.notify("paseo: " .. message, vim.log.levels.ERROR)
end

---Open a workspace that was just made, by id when its directory did not come
---back with it.
---@param id string
---@param workspace table|nil
---@param host_id? string
---@param callback fun(resolved: table|nil, err: string|nil)
local function resolve(id, workspace, host_id, callback)
  if workspace and workspace.directory then
    return callback(workspace, nil)
  end
  require("paseo.workspaces").get(id, function(resolved, err)
    vim.schedule(function()
      callback(resolved, resolved and nil or (err or "could not resolve the created workspace"))
    end)
  end, host_id)
end

---A new worktree, and (for a chat) its first agent with `first`.
---@param ctx paseo.StartContext
---@param choice paseo.NewChoice
---@param first paseo.FirstAgent|nil
---@param callback fun(workspace: table|nil, err: string|nil)
local function new_worktree(ctx, choice, first, callback)
  require("paseo.workspaces").create({
    root = ctx.local_root or ctx.root,
    host_id = ctx.host_id,
    new = true,
    base = choice.base,
    first = first,
  }, function(id, err, plan, workspace)
    vim.schedule(function()
      if err then
        return callback(nil, err)
      end
      -- An assembled workspace: the one moment the bundled skills are worth
      -- mentioning (once a session).
      pcall(function()
        require("paseo.pickers.workspaces").hint_skills(plan)
      end)
      if not id then
        return callback(nil, "cancelled")
      end
      resolve(id, workspace, ctx.host_id, function(resolved, resolve_err)
        if resolved then
          resolved.agent_id = resolved.agent_id or (workspace and workspace.agent_id)
          resolved.id = resolved.id or id
        end
        callback(resolved, resolve_err)
      end)
    end)
  end)
end

---A terminal, here or in a new worktree, on screen once it runs.
---@param ctx paseo.StartContext
---@param choice paseo.NewChoice
---@param preset table  `{ command?, args?, label? }`
---@param callback fun(id: string|nil, err: string|nil)
function M.terminal(ctx, choice, preset, callback)
  local function run(cwd, workspace_id)
    require("paseo.terminals").create(cwd, preset, nil, function(id, err)
      if err or not id then
        return callback(nil, err or "the daemon started no terminal")
      end
      -- ON SCREEN: a terminal is a session like an agent.
      require("paseo.ui.native").show_session { kind = "terminal", id = id }
      callback(id, nil)
    end, ctx.host_id, workspace_id)
  end
  if choice.where ~= "worktree" then
    return run(ctx.root, ctx.workspace_id)
  end
  new_worktree(ctx, choice, nil, function(workspace, err)
    if not workspace then
      return callback(nil, err)
    end
    run(workspace.directory, workspace.id)
  end)
end

---A chat's first message: the agent, and (for a worktree) the workspace it
---works in, in one request -- the only request the daemon names a workspace
---from.
---
---`done(err)` on failure, so the draft can hand the words back.
---`done(nil, agent_id)` when the agent is HERE and the draft becomes it.
---`done(nil, nil)` when the editor has moved to a new worktree's chat.
---@param ctx paseo.StartContext
---@param choice paseo.NewChoice
---@param prompt string
---@param images table[]
---@param done fun(err: string|nil, agent_id: string|nil)
---@param opts? { switch?: boolean }  `switch`: point this Neovim at the new
---       worktree too (|paseo.workspaces|.open). Off on the full-screen
---       surface, where the Paseo tab is `tcd`'d into it when its row switches
---       to that workspace, and moving the tab you came from as well would
---       move your code.
function M.chat(ctx, choice, prompt, images, done, opts)
  local first = {
    prompt = prompt,
    images = #images > 0 and images or nil,
    provider = choice.provider,
    modeId = choice.modeId,
    thinkingOptionId = choice.thinkingOptionId,
    featureValues = choice.featureValues,
  }

  if choice.where == "worktree" then
    return new_worktree(ctx, choice, first, function(workspace, err)
      if not workspace then
        return done(err)
      end
      if not workspace.agent_id then
        -- The workspace is real and on disk. Saying so is the difference
        -- between "try again" and "go and find out what that directory is".
        return done(("the workspace %q was created, but no agent started in it"):format(workspace.name or "?"))
      end
      config.get().paseo.provider = choice.provider
      if opts and opts.switch then
        require("paseo.workspaces").open(workspace)
      end
      -- `working`: its first turn is already under way -- the prompt rode the
      -- request that made it.
      require("paseo.ui.chat").open { root = workspace.directory, agent_id = workspace.agent_id, working = true }
      done(nil, nil)
    end)
  end

  -- HERE: into the workspace on screen by id when it is known, so a second
  -- agent beside the first lands beside it. Without one, `agent.start` joins
  -- a named workspace or makes one named from the prompt.
  local bridge = require "paseo.bridge"
  if ctx.workspace_id then
    return bridge.request("agent.create", {
      workspaceId = ctx.workspace_id,
      provider = first.provider,
      modeId = first.modeId,
      thinkingOptionId = first.thinkingOptionId,
      featureValues = first.featureValues,
      prompt = prompt,
      images = first.images,
    }, function(err, result)
      vim.schedule(function()
        if err or not (result and result.id) then
          return done(err or "no agent was created")
        end
        done(nil, result.id)
      end)
    end, ctx.host_id)
  end
  bridge.request("agent.start", {
    cwd = ctx.root,
    project = ctx.project,
    provider = first.provider,
    modeId = first.modeId,
    thinkingOptionId = first.thinkingOptionId,
    featureValues = first.featureValues,
    prompt = prompt,
    images = first.images,
  }, function(err, result)
    vim.schedule(function()
      if err or not (result and result.agentId) then
        return done(err or "no agent")
      end
      done(nil, result.agentId)
    end)
  end, ctx.host_id)
end

---Can a NEW worktree be made from here? A git checkout, yes (Paseo cuts it);
---a multi-repo project, yes, on this machine (it is assembled); a plain
---directory, no -- there is nothing to isolate it with.
---@param ctx paseo.StartContext
---@return { kind: string, label: string, base?: string }|nil
function M.isolation(ctx)
  local ok, plan =
    pcall(require("paseo.workspaces").strategy, ctx.local_root or ctx.root, { peek = true })
  if not ok or not plan then
    return nil
  end
  if plan.kind == "worktree" then
    return { kind = "worktree", label = "New worktree", base = plan.base, repo = plan.repo }
  end
  local host = require("paseo.hosts").get(ctx.host_id)
  if (plan.kind == "assemble" or plan.kind == "discover") and host and host.local_host then
    return { kind = plan.kind, label = "New workspace" }
  end
  return nil
end

---Start something, from wherever you are. The screen, with `opts` choosing
---what it opens on (the rail's `w` opens on a worktree, `t` on a terminal).
---@param ctx paseo.StartContext|nil  nil: from the current directory.
---@param opts? { kind?: "chat"|"terminal", where?: "here"|"worktree" }
function M.open(ctx, opts)
  ctx = ctx or M.context()
  if not ctx then
    return notify "nowhere to start anything"
  end
  require("paseo.ui.newtask").open(ctx, opts or {})
end

---The context, from the chat on screen if there is one, else from where this
---tab is standing.
---@param chat? table
---@return paseo.StartContext|nil
function M.context(chat)
  chat = chat or require("paseo.ui.chat").current()
  if chat then
    return require("paseo.start").context(chat)
  end
  local host = require("paseo.hosts").get(nil)
  if not host then
    return nil
  end
  local root = require("paseo.ui.chat").here()
  return {
    root = host.local_host and root or (require("paseo.hosts").to_remote(host.id, root) or root),
    local_root = root,
    host_id = host.id,
    preferred = host.provider or config.get().paseo.provider,
  }
end

return M
