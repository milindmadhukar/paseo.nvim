--- What to do in a directory with nothing running in it -- and every other way
--- of starting something.
---
--- THIS USED TO BE A CHAIN OF QUESTIONS: what (agent / agent in a new
--- workspace / terminal), then where, then a name, then the settings. It is
--- one screen now -- |paseo.ui.newtask|, over |paseo.new| -- and this module is
--- the names the rest of the plugin already calls it by: `new` for a key that
--- already knows what it wants (the rail's `a`, `w`, `t`), `open` for a
--- directory with nothing in it, and `context` for "from the chat on screen".

local config = require "paseo.config"

local M = {}

---@class paseo.StartContext
---@field root string           Where it starts, as the daemon sees it.
---@field local_root? string    The same directory on this machine.
---@field host_id? string
---@field preferred? string     The provider the screen opens on, when nothing is remembered.
---@field workspace_id? string  The workspace "here" means, when known.
---@field project? string       The multi-repo project `root` belongs to.

---What the old kinds open the screen on.
---@type table<string, { kind: "chat"|"terminal", where?: "here"|"worktree" }>
M.KINDS = {
  here = { kind = "chat", where = "here" },
  workspace = { kind = "chat", where = "worktree" },
  worktree = { kind = "chat", where = "worktree" },
  terminal = { kind = "terminal" },
}

---Start something: the new-task screen, opened on `kind` when the key that
---got here already says (the rail's `a` `w` `t`), else on what you chose last.
---@param ctx paseo.StartContext
---@param kind? "here"|"workspace"|"worktree"|"terminal"
function M.new(ctx, kind)
  require("paseo.new").open(ctx, kind and M.KINDS[kind] or {})
end

---Nothing is running in `opts.root`: offer to start something there.
---@param opts paseo.StartContext
function M.open(opts)
  require("paseo.new").open(opts, {})
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
