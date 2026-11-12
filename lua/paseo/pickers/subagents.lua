--- The subagents of the agent session in the chat -- both kinds, one list.
---
--- What `<CR>` does depends on the kind, because what you can do with one does:
--- a Paseo subagent is an ordinary agent and opens as an ordinary chat, where
--- the composer talks to IT; a provider subagent (Claude's Task tool) can only
--- be watched, and opens read-only -- see |paseo.ui.subagent|.
---
--- The list itself is |paseo.ui.subagents|; this is what its `<CR>` calls.

local subagents = require "paseo.subagents"

local M = {}

---Open one row: a chat for a Paseo subagent, the viewer for a provider one.
---@param s paseo.Subagent
---@param parent table  The parent's chat.
function M.open_one(s, parent)
  if s.kind == "paseo" then
    return require("paseo.ui.chat").open {
      root = s.cwd or parent.root,
      remote = true,
      agent_id = s.id,
      title = s.title,
      host_id = parent.host_id,
    }
  end
  require("paseo.ui.subagent").open(s, { host_id = parent.host_id, parent_chat = parent })
end

---The live list -- see |paseo.ui.subagents|. Not a telescope picker any more:
---a picker is a snapshot, and a list of things that are running has to move.
---@param parent? table  The parent's chat; the current one when absent.
function M.open(parent)
  parent = parent or require("paseo.ui.chat").current()
  if not (parent and parent.agent_id) then
    return vim.notify("paseo: no agent session in the chat to list subagents of", vim.log.levels.WARN)
  end
  if #subagents.list(parent.agent_id, parent.host_id) == 0 then
    return vim.notify("paseo: this agent session has no subagents", vim.log.levels.INFO)
  end
  return require("paseo.ui.subagents").open(parent)
end

return M
