--- What to do in a directory with nothing running in it.
---
--- THE FIRST SCREEN ANYONE SEES, and for a long time it was a model picker.
--- `:Paseo` in a workspace with no agent went straight to "which provider,
--- which model, which reasoning level" -- four questions about an agent,
--- asked before anything had established that an agent is what you wanted.
--- A terminal was reachable only from a tab of a surface you had to create an
--- agent in order to open, which is a circle.
---
--- So the question is asked in the order it actually arises: WHAT, then
--- WHERE, then the settings. Three answers, and the middle one is the one
--- Paseo's own vocabulary makes hard to see -- an agent "here" shares this
--- directory with everything else working in it, and an agent in a new
--- workspace gets a directory of its own. That is the same distinction the
--- fork menu draws, in the same words. See |paseo.fork|.
---
--- WHAT THIS MODULE DOES NOT DO is create the agent for the "here" case. That
--- belongs to whoever asked -- |paseo.ui.chat| has an `agent.ensure` call with
--- a title, a cwd and an adopt path already, and a second creation path beside
--- it is how two agents in one directory start disagreeing about which of them
--- the window is pointed at. This hands back the settings and lets the caller
--- do what it already did.

local config = require "paseo.config"

local M = {}

---The three things there are to start, in menu order.
---
---PASEO'S OWN NOUNS, with the consequence beside each. "Workspace" and
---"session" are the vocabulary the Sessions and Workspaces tabs are named
---after, and a menu that invented friendlier words for them would be teaching
---two vocabularies for one product.
M.CHOICES = {
  { id = "agent", label = "new agent", note = "here, in this directory" },
  { id = "workspace", label = "new agent in a new workspace", note = "a directory of its own" },
  { id = "terminal", label = "new terminal", note = "a shell here, in this directory" },
  { id = "cancel", label = "cancel" },
}

---@param choice table
---@return string
local function spell(choice)
  return choice.note and ("%s  (%s)"):format(choice.label, choice.note) or choice.label
end

---Ask what to start.
---@param opts { root: string }
---@param callback fun(id: string|nil)
function M.choose(opts, callback)
  vim.ui.select(M.CHOICES, {
    prompt = ("Nothing is running in %s. Start…"):format(vim.fn.fnamemodify(opts.root, ":~")),
    format_item = spell,
  }, function(choice)
    callback(choice and choice.id ~= "cancel" and choice.id or nil)
  end)
end

---A default name for the workspace an agent is about to get.
---@param root string
---@return string
local function slug(root)
  local value = vim.fs.basename(root):lower():gsub("[^%w_-]+", "-")
  value = value:gsub("%-+", "-"):gsub("^[-_]+", ""):gsub("[-_]+$", "")
  return value ~= "" and value or "work"
end

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify("paseo: " .. message, level or vim.log.levels.ERROR)
end

---The settings screen, then a DRAFT: the ordinary conversation view with
---nothing created yet. The first message creates it -- `start` says how.
---@param ctx paseo.StartContext
---@param start? fun(chat: table): fun(prompt: string, images: table[], done: fun(err: string|nil, agent_id: string|nil))
---@param callback fun(result: table|nil, err: string|nil)
---@param banner? string
local function draft(ctx, start, callback, banner)
  require("paseo.ui.create").review({
    cwd = ctx.local_root or ctx.root,
    preferred = ctx.preferred,
    host_id = ctx.host_id,
  }, function(settings, review_err)
    if review_err then
      return callback(nil, review_err)
    end
    if not settings then
      return callback(nil, nil)
    end
    vim.schedule(function()
      local chat
      chat = require("paseo.ui.chat").draft {
        root = ctx.root,
        local_root = ctx.local_root,
        host_id = ctx.host_id,
        settings = settings,
        banner = banner,
        -- Late-bound: the start needs the chat, and the chat is made with it.
        start = start and function(prompt, images, done)
          return start(chat)(prompt, images, done)
        end or nil,
      }
      callback({ kind = "agent", draft = true, moved = true, chat = chat }, nil)
    end)
  end)
end

---@class paseo.StartContext
---@field root string           Where it starts, as the daemon sees it.
---@field local_root? string    The same directory on this machine.
---@field host_id? string
---@field preferred? string     The provider the settings screen opens on.
---@field workspace_id? string  The workspace "here" means, when known.

---A new agent in a workspace of its own: a name for its directory and
---branch, the settings -- and then the ordinary conversation view, empty.
---
---NOTHING IS CREATED until you send the first message, and then everything
---is, in one request: the workspace and its agent, with your words as the
---agent's first prompt. That is the only request the daemon names a
---workspace from. This used to ask for the prompt in a box of its own before
---it would show you anything, which also meant the first prompt could not be
---dictated, pasted as an image, or written with the composer's keys.
---@param ctx paseo.StartContext
---@param callback fun(result: table|nil, err: string|nil)
local function into_workspace(ctx, callback)
  local root = ctx.local_root or ctx.root
  vim.ui.input({ prompt = "New workspace name: ", default = slug(root) }, function(name)
    if not name or name == "" then
      return callback(nil, nil)
    end
    draft(ctx, function(chat)
      return function(prompt, images, done)
        local settings = chat.draft and chat.draft.settings or {}
        require("paseo.workspaces").create({
          name = name,
          root = root,
          host_id = ctx.host_id,
          new = true,
          first = {
            prompt = prompt,
            images = #images > 0 and images or nil,
            provider = settings.provider,
            modeId = settings.modeId,
            thinkingOptionId = settings.thinkingOptionId,
            featureValues = settings.featureValues,
          },
        }, function(id, create_err, _, workspace)
          vim.schedule(function()
            if create_err then
              return done(create_err)
            end
            if not id then
              return done "cancelled"
            end
            local agent_id = workspace and workspace.agent_id
            if not agent_id then
              -- The workspace is real and on disk. Saying so is the
              -- difference between "try again" and "go and find out what
              -- that directory is".
              return done(("the workspace %q was created, but no agent started in it"):format(name))
            end
            config.get().paseo.provider = settings.provider

            local function finish(resolved)
              resolved.name = resolved.name or name
              local chats = require "paseo.ui.chat"
              chats.discard(chat)
              require("paseo.workspaces").open(resolved)
              chats.open { root = resolved.directory, agent_id = agent_id }
              done(nil)
            end
            if workspace.directory then
              return finish(workspace)
            end
            require("paseo.workspaces").get(id, function(resolved, get_err)
              vim.schedule(function()
                if not resolved then
                  return done(get_err or "could not resolve the created workspace")
                end
                finish(resolved)
              end)
            end)
          end)
        end)
      end
    end, callback, ("new workspace %s — your first message creates it, and names it"):format(name))
  end)
end

---A new agent in the workspace you are in, as a draft: the conversation view
---at once, and the agent made by your first message, with it as its prompt.
---
---Into THAT workspace by id when it is known -- the one the agent on screen
---belongs to -- so a second agent beside the first lands beside it, not in a
---fresh workspace on the same directory.
---@param ctx paseo.StartContext
---@param callback fun(result: table|nil, err: string|nil)
local function into_here(ctx, callback)
  if not ctx.workspace_id then
    -- `agent.start`: joins a named workspace, or makes one named from the
    -- prompt where there is only an untitled checkout.
    return draft(ctx, nil, callback)
  end
  draft(ctx, function(chat)
    return function(prompt, images, done)
      local settings = chat.draft and chat.draft.settings or {}
      require("paseo.bridge").request("agent.create", {
        workspaceId = ctx.workspace_id,
        provider = settings.provider,
        modeId = settings.modeId,
        thinkingOptionId = settings.thinkingOptionId,
        featureValues = settings.featureValues,
        prompt = prompt,
        images = #images > 0 and images or nil,
      }, function(err, result)
        if err or not (result and result.id) then
          return done(err or "no agent was created")
        end
        done(nil, result.id)
      end, ctx.host_id)
    end
  end, callback)
end

---Where an agent goes, when WHAT it is has already been settled.
---
---The same two places `M.CHOICES` offers and the same words for them.
M.WHERE = {
  { id = "here", label = "here", note = "in this workspace" },
  { id = "workspace", label = "a new workspace", note = "a directory of its own" },
  { id = "cancel", label = "cancel" },
}

---Start an agent, having asked only where it goes.
---@param ctx paseo.StartContext
---@param callback fun(result: table|nil, err: string|nil)
function M.agent(ctx, callback)
  vim.ui.select(M.WHERE, {
    prompt = "Start an agent…",
    format_item = spell,
  }, function(choice)
    if not choice or choice.id == "cancel" then
      return callback(nil, nil)
    end
    if choice.id == "workspace" then
      return into_workspace(ctx, callback)
    end
    into_here(ctx, callback)
  end)
end

---@param root string
---@param callback fun(result: table|nil, err: string|nil)
local function into_terminal(root, callback)
  local float = require "paseo.ui.float"
  require("paseo.ui.newterm").open({
    root = root,
    -- The PTY is sized to the surface it will be drawn on. Absent on the
    -- sidebar, where there is no terminal pane to size it to and
    -- |paseo.terminals| picks a default.
    size = float.mount() and float.body_size() or nil,
  }, function(id, err)
    if err then
      return callback(nil, err)
    end
    if not id then
      return callback(nil, nil)
    end
    -- ON SCREEN IF THERE IS A SCREEN FOR IT. `show_session` is the dashboard's
    -- own "point the Chat tab at this"; on the sidebar there is no Chat tab to
    -- point, and a terminal nobody can see is worse than one you were told
    -- where to find.
    float.show_session { kind = "terminal", id = id }
    callback({ kind = "terminal", id = id }, nil)
  end)
end

---Ask, then do it.
---
---@param opts paseo.StartContext
---@param callback fun(result: table|nil, err: string|nil)
---        `result.kind` is `"agent"` or `"terminal"`.
---        For an agent started HERE, `result.draft` carries the settings and
---        nothing has been created -- the caller makes its own chat the draft.
---        For one started in a new workspace, `result.moved` is true and the
---        editor is already showing that workspace's draft.
---        Both `result` and `err` nil means cancelled, which is not an error.
function M.open(opts, callback)
  M.choose(opts, function(choice)
    if not choice then
      return callback(nil, nil)
    end
    if choice == "terminal" then
      return into_terminal(opts.root, callback)
    end
    if choice == "workspace" then
      return into_workspace(opts, function(result, err)
        if err then
          notify(err)
        end
        callback(result, err)
      end)
    end
    require("paseo.ui.create").review(
      { cwd = opts.root, preferred = opts.preferred },
      function(draft, review_err)
        if review_err then
          return callback(nil, review_err)
        end
        if not draft then
          return callback(nil, nil)
        end
        callback({ kind = "agent", draft = draft }, nil)
      end
    )
  end)
end

---What `<C-n>` offers on the dashboard: everything there is to start, from
---wherever you are on it.
M.NEW = {
  { id = "here", label = "new agent", note = "in this workspace" },
  { id = "workspace", label = "new agent in a new workspace", note = "a directory of its own" },
  { id = "terminal", label = "new terminal", note = "a shell in this workspace" },
}

---Start something from the dashboard -- `kind` says what, or a menu asks.
---
---THE ONE WAY IN, whichever key or click it came from: `<C-n>` and the
---footer's `new` ask; the session tree's `a`, `w` and `t` already know.
---@param ctx paseo.StartContext
---@param kind? "here"|"workspace"|"terminal"
function M.new(ctx, kind)
  local function report(_, err)
    if err and err ~= "cancelled" then
      notify(err)
    end
  end
  local function go(id)
    if id == "terminal" then
      return into_terminal(ctx.root, report)
    end
    if id == "workspace" then
      return into_workspace(ctx, report)
    end
    if id == "here" then
      return into_here(ctx, report)
    end
  end
  if kind then
    return go(kind)
  end
  vim.ui.select(M.NEW, { prompt = "Start…", format_item = spell }, function(choice)
    if choice then
      go(choice.id)
    end
  end)
end

---The context `M.new` needs, from the chat on screen.
---@param chat table
---@return paseo.StartContext
function M.context(chat)
  local agent = chat.agent_id and require("paseo.agents").get(chat.agent_id, chat.host_id)
  return {
    root = chat.root,
    local_root = chat.local_root,
    host_id = chat.host_id,
    preferred = (require("paseo.hosts").get(chat.host_id) or {}).provider or config.get().paseo.provider,
    workspace_id = agent and agent.workspaceId or nil,
  }
end

return M
