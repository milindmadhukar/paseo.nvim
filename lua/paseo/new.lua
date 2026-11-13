--- Starting something: a new SESSION (a workspace, Local or in a worktree of
--- its own), or a new AGENT in a session that already exists -- and a
--- terminal in either.
---
--- TWO VERBS, AS THE APP HAS THEM. Its sidebar `+` makes a session in a
--- project; the `+` on a session's row of tabs adds an agent to that one
--- session. They used to be one verb here, whose "Local" meant "the workspace
--- you happen to be in" -- so starting something new from the rail put a tab
--- in whatever session was on screen. Now neither guesses: `M.session` always
--- makes a workspace, and `M.agent` only ever goes into the session it was
--- pointed at (`ctx.workspace_id`), never one found by directory.
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

---Where a LOCAL session lives: the project's own directory, as the daemon
---sees it -- what the app's sidebar `+` means by Local.
---
---Not the directory of the session you are looking at: from a worktree Paseo
---cut, Local is the checkout it was cut from, and from inside an assembled
---multi-repo workspace it is the project that holds them (|paseo.workspaces|
---.here, which the rail groups by too). A plain directory is its own project.
---On a remote host the daemon's own `projectRoot` answers, when the session
---came with one.
---@param ctx paseo.StartContext
---@return string
function M.project_root(ctx)
  local hosts = require "paseo.hosts"
  local host = hosts.get(ctx.host_id)
  local remote = host and not host.local_host
  if remote and ctx.project_root then
    return ctx.project_root
  end
  local local_dir = ctx.local_root or (not remote and ctx.root) or nil
  if local_dir then
    local ok, project = pcall(function()
      return require("paseo.workspaces").here(local_dir)
    end)
    if ok and project then
      if not remote then
        return project
      end
      local mapped = hosts.to_remote(host.id, project)
      if mapped then
        return mapped
      end
    end
  end
  return ctx.project_root or ctx.root
end

---A new LOCAL session: a workspace of its own on the project's directory,
---beside the sessions already there -- and, with `first`, its first agent in
---the same request, so the daemon names the session from the prompt.
---
---Through `workspace.create` with `project`: a `directory` source WITH the
---project's id, which is what the app sends. Never `workspace.open`, which
---hands back the session already on that directory.
---@param ctx paseo.StartContext
---@param first paseo.FirstAgent|nil
---@param callback fun(workspace: table|nil, err: string|nil)
local function new_local(ctx, first, callback)
  local root = M.project_root(ctx)
  local args = { cwd = root, project = root }
  if first and first.prompt and first.prompt ~= "" then
    args.prompt = first.prompt
    args.provider = first.provider
    args.modeId = first.modeId
    args.thinkingOptionId = first.thinkingOptionId
    args.featureValues = first.featureValues
    args.images = first.images
  end
  require("paseo.bridge").request("workspace.create", args, function(err, result)
    vim.schedule(function()
      if err or not (result and result.id) then
        return callback(nil, err or "the daemon made no session")
      end
      callback({
        id = result.id,
        name = result.name,
        agent_id = result.agentId,
        directory = result.directory or root,
        hostId = ctx.host_id,
      }, nil)
    end)
  end, ctx.host_id)
end

---A new session of either kind, as `choice.where` says.
---@param ctx paseo.StartContext
---@param choice paseo.NewChoice
---@param first paseo.FirstAgent|nil
---@param callback fun(workspace: table|nil, err: string|nil)
local function new_session(ctx, choice, first, callback)
  if choice.where == "worktree" then
    return new_worktree(ctx, choice, first, callback)
  end
  new_local(ctx, first, callback)
end

---A terminal: in the session `ctx` points at (`scope = "agent"`, the tab
---row's `+`), or in a new session of its own (`scope = "session"`), on screen
---once it runs.
---@param ctx paseo.StartContext
---@param choice paseo.NewChoice
---@param preset table  `{ command?, args?, label? }`
---@param callback fun(id: string|nil, err: string|nil)
---@param scope? "session"|"agent"  Default "agent", as it always was.
function M.terminal(ctx, choice, preset, callback, scope)
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
  if scope ~= "session" then
    return run(ctx.root, ctx.workspace_id)
  end
  new_session(ctx, choice, nil, function(workspace, err)
    if not workspace then
      return callback(nil, err)
    end
    run(workspace.directory, workspace.id)
  end)
end

---@param choice paseo.NewChoice
---@param prompt string
---@param images table[]
---@return paseo.FirstAgent
local function first_agent(choice, prompt, images)
  return {
    prompt = prompt,
    images = #images > 0 and images or nil,
    provider = choice.provider,
    modeId = choice.modeId,
    thinkingOptionId = choice.thinkingOptionId,
    featureValues = choice.featureValues,
  }
end

---A new SESSION, with its first agent and that agent's first message: Local
---(the project's own directory) or a new worktree, as `choice.where` says.
---The editor moves to its chat; the draft has nothing left to become.
---
---`done(err)` on failure, so the draft can hand the words back, and
---`done(nil, nil)` once the new session's chat is open.
---@param ctx paseo.StartContext
---@param choice paseo.NewChoice
---@param prompt string
---@param images table[]
---@param done fun(err: string|nil, agent_id: string|nil)
---@param opts? { switch?: boolean }  `switch`: point this Neovim at the new
---       session's directory too (|paseo.workspaces|.open), when it is not
---       the one it is already in. Off on the full-screen surface, where the
---       Paseo tab is `tcd`'d into it when its row switches to that workspace,
---       and moving the tab you came from as well would move your code.
function M.session(ctx, choice, prompt, images, done, opts)
  local first = first_agent(choice, prompt, images)
  new_session(ctx, choice, first, function(workspace, err)
    if not workspace then
      return done(err)
    end
    if not workspace.agent_id then
      -- The workspace is real and on disk. Saying so is the difference
      -- between "try again" and "go and find out what that directory is".
      return done(("the session %q was created, but no agent started in it"):format(workspace.name or "?"))
    end
    config.get().paseo.provider = choice.provider
    local moved = workspace.directory ~= (ctx.local_root or ctx.root) and workspace.directory ~= ctx.root
    if opts and opts.switch and moved then
      require("paseo.workspaces").open(workspace)
    end
    local host = require("paseo.hosts").get(ctx.host_id)
    -- `working`: its first turn is already under way -- the prompt rode the
    -- request that made it.
    require("paseo.ui.chat").open {
      root = workspace.directory,
      host_id = ctx.host_id,
      remote = host ~= nil and not host.local_host or nil,
      agent_id = workspace.agent_id,
      working = true,
    }
    done(nil, nil)
  end)
end

---A new AGENT in the session `ctx.workspace_id` names -- the tab row's `+`.
---It never makes a workspace, and never looks one up by directory: with no
---session to go into it says so, and the caller offers a new session instead.
---
---`done(nil, agent_id)`: the draft becomes the agent, in place.
---@param ctx paseo.StartContext
---@param choice paseo.NewChoice
---@param prompt string
---@param images table[]
---@param done fun(err: string|nil, agent_id: string|nil)
function M.agent(ctx, choice, prompt, images, done)
  if not ctx.workspace_id then
    return done "no session to add an agent to -- start a new session instead"
  end
  local first = first_agent(choice, prompt, images)
  require("paseo.bridge").request("agent.create", {
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

---Start something, from wherever you are: the screen, opened on `opts`.
---
---`scope` is the verb, and the key that got here decides it -- it is not
---remembered. "session" (the default: the rail's `a` `w`, `<C-n>`) makes a
---new workspace; "agent" (the rail's `A` `t`, the new-agent key) adds to the
---session `ctx.workspace_id` names. An agent asked for with no session to
---put it in -- the rail's project line, a buffer of code -- gets the new
---session screen, and a word saying why.
---@param ctx paseo.StartContext|nil  nil: from the current directory.
---@param opts? { scope?: "session"|"agent", kind?: "chat"|"terminal", where?: "here"|"worktree", surface?: "sidebar"|"native" }
---@return table|nil chat  The draft chat the screen is on.
function M.open(ctx, opts)
  ctx = ctx or M.context()
  if not ctx then
    notify "nowhere to start anything"
    return nil
  end
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.scope == "agent" and not ctx.workspace_id then
    vim.notify("paseo: no session here to add an agent to -- a new session, then", vim.log.levels.INFO)
    opts.scope = "session"
  end
  opts.scope = opts.scope or "session"
  return require("paseo.ui.newtask").open(ctx, opts)
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
