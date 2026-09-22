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

---Start an agent in a workspace of its own, and point the editor at it.
---
---The whole thing, unlike the "here" case: there is nothing for the caller to
---adopt, because the agent is not in the caller's directory and the chat it
---belongs to is a different chat.
---@param root string
---@param callback fun(result: table|nil, err: string|nil)
local function into_workspace(root, callback)
  vim.ui.input({ prompt = "New workspace name: ", default = slug(root) }, function(name)
    if not name or name == "" then
      return callback(nil, nil)
    end
    require("paseo.workspaces").create({
      name = name,
      root = root,
      new = true,
    }, function(id, create_err, _, workspace)
      vim.schedule(function()
        if create_err then
          return callback(nil, create_err)
        end
        if not id then
          return callback(nil, nil)
        end

        local function finish(resolved)
          resolved.name = resolved.name or name
          require("paseo.workspaces").new_agent_session(resolved, {
            title = "paseo.nvim · " .. (resolved.name or name),
          }, function(agent_id, agent_err)
            vim.schedule(function()
              if agent_err and agent_err ~= "cancelled" then
                -- The workspace is real and on disk. Saying so is the
                -- difference between "try again" and "go and find out what
                -- that directory is".
                return callback(
                  nil,
                  ("the workspace %q was created, but no agent started in it — %s"):format(
                    resolved.name or name,
                    agent_err
                  )
                )
              end
              if not agent_id then
                return callback(nil, nil)
              end
              require("paseo.workspaces").open(resolved)
              require("paseo.ui.chat").open {
                root = resolved.directory,
                agent_id = agent_id,
                title = resolved.name,
              }
              callback({ kind = "agent", id = agent_id, moved = true }, nil)
            end)
          end)
        end

        if workspace and workspace.directory then
          return finish(workspace)
        end
        require("paseo.workspaces").get(id, function(resolved, get_err)
          vim.schedule(function()
            if not resolved then
              return callback(nil, get_err or "could not resolve the created workspace")
            end
            finish(resolved)
          end)
        end)
      end)
    end)
  end)
end

---Where an agent goes, when WHAT it is has already been settled.
---
---The same two places `M.CHOICES` offers and the same words for them. A
---surface that already has a key meaning "agent" -- the Sessions panel's `a`
----- has answered the first question and should not be asked it again; what it
---could never ask before is this one, so starting an agent from there always
---put it in the workspace you were already in.
M.WHERE = {
  { id = "here", label = "here", note = "in this workspace" },
  { id = "workspace", label = "a new workspace", note = "a directory of its own" },
  { id = "cancel", label = "cancel" },
}

---Start an agent, having asked only where it goes.
---
---@param opts { root: string, workspace: table }  `workspace` is the Paseo
---        workspace `root` is in, which the caller already resolved.
---@param callback fun(result: table|nil, err: string|nil)
function M.agent(opts, callback)
  vim.ui.select(M.WHERE, {
    prompt = "Start an agent…",
    format_item = spell,
  }, function(choice)
    if not choice or choice.id == "cancel" then
      return callback(nil, nil)
    end
    if choice.id == "workspace" then
      return into_workspace(opts.root, callback)
    end
    require("paseo.workspaces").new_agent_session(opts.workspace, {}, function(id, err)
      vim.schedule(function()
        if err and err ~= "cancelled" then
          return callback(nil, err)
        end
        if not id then
          return callback(nil, nil)
        end
        require("paseo.ui.chat").open {
          root = opts.workspace.directory or opts.root,
          agent_id = id,
        }
        callback({ kind = "agent", id = id, moved = true }, nil)
      end)
    end)
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
---@param opts { root: string, preferred?: string }
---@param callback fun(result: table|nil, err: string|nil)
---        `result.kind` is `"agent"` or `"terminal"`.
---        For an agent started HERE, `result.draft` carries the settings and
---        nothing has been created -- the caller creates it.
---        For one started in a new workspace, `result.moved` is true and the
---        editor is already pointed at it.
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
      return into_workspace(opts.root, function(result, err)
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

return M
