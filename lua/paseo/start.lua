--- What to do in a directory with nothing running in it -- and every other way
--- of starting something.
---
--- THIS USED TO BE A CHAIN OF QUESTIONS: what (agent / agent in a new
--- workspace / terminal), then where, then a name, then the settings. It is
--- one screen now -- |paseo.ui.newtask|, over |paseo.new| -- and this module is
--- the names the rest of the plugin already calls it by: `new` for a key that
--- already knows what it wants (the rail's `a`, `A`, `w`, `t`), `open` for a
--- directory with nothing in it, and `context` for "from the chat on screen".

local config = require "paseo.config"

local M = {}

---@class paseo.StartContext
---@field root string           Where it starts, as the daemon sees it.
---@field local_root? string    The same directory on this machine.
---@field host_id? string
---@field preferred? string     The provider the screen opens on, when nothing is remembered.
---@field workspace_id? string  The session a new AGENT goes into, when there is one.
---@field title? string         That session's name, for the screen to say.
---@field project_root? string  The daemon's root for that session's project.
---@field project? string       The multi-repo project `root` belongs to.

---What each key opens the screen on. A SESSION is a new workspace (the app's
---sidebar `+`); an AGENT goes into the session the key was pressed on (the
---`+` on that session's row of tabs), and so does a terminal.
---@type table<string, { scope: "session"|"agent", kind: "chat"|"terminal", where?: "here"|"worktree" }>
M.KINDS = {
  session = { scope = "session", kind = "chat", where = "here" },
  worktree = { scope = "session", kind = "chat", where = "worktree" },
  agent = { scope = "agent", kind = "chat" },
  terminal = { scope = "agent", kind = "terminal" },
}
-- The names the rail and the pickers used before there were two verbs.
M.KINDS.here = M.KINDS.session
M.KINDS.workspace = M.KINDS.worktree

---Start something: the new-task screen, opened on `kind` when the key that
---got here already says (the rail's `a` `A` `w` `t`), else a new session on
---what you chose last.
---@param ctx paseo.StartContext
---@param kind? "session"|"worktree"|"agent"|"terminal"|"here"|"workspace"
---@return table|nil chat
function M.new(ctx, kind)
  return require("paseo.new").open(ctx, kind and M.KINDS[kind] or {})
end

---Nothing is running in `opts.root`: offer to start something there.
---@param opts paseo.StartContext
function M.open(opts)
  return require("paseo.new").open(opts, {})
end

---The context `M.new` needs, from the chat on screen.
---@param chat table
---@return paseo.StartContext
function M.context(chat)
  local agent = chat.agent_id and require("paseo.agents").get(chat.agent_id, chat.host_id)
  local workspace_id = agent and agent.workspaceId or nil
  -- Its session's name and project, from the list the rail already holds.
  local rail = package.loaded["paseo.ui.rail"]
  local ws = workspace_id and rail and rail.workspace(workspace_id) or nil
  return {
    root = chat.root,
    local_root = chat.local_root,
    host_id = chat.host_id,
    preferred = (require("paseo.hosts").get(chat.host_id) or {}).provider or config.get().paseo.provider,
    workspace_id = workspace_id,
    title = ws and ws.name or nil,
    project_root = ws and ws.projectRoot or nil,
  }
end

return M
