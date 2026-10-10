--- The subagents of the agent session in the chat -- both kinds, one list.
---
--- What `<CR>` does depends on the kind, because what you can do with one does:
--- a Paseo subagent is an ordinary agent and opens as an ordinary chat, where
--- the composer talks to IT; a provider subagent (Claude's Task tool) can only
--- be watched, and opens read-only -- see |paseo.ui.subagent|.

local subagents = require "paseo.subagents"

local M = {}

---@param s paseo.Subagent
---@return string glyph, string hl
local function state(s)
  local icons = require "paseo.ui.icons"
  if s.running then
    return icons.status.running, "PaseoToolRunning"
  elseif s.status == "failed" then
    return icons.status.failed, "PaseoToolFail"
  elseif s.status == "canceled" then
    return icons.status.canceled, "PaseoDim"
  end
  return icons.status.completed, "PaseoDim"
end

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

---@param parent? table  The parent's chat; the current one when absent.
function M.open(parent)
  parent = parent or require("paseo.ui.chat").current()
  if not (parent and parent.agent_id) then
    return vim.notify("paseo: no agent session in the chat to list subagents of", vim.log.levels.WARN)
  end

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return vim.notify("paseo: telescope is not available", vim.log.levels.ERROR)
  end
  local finders = require "telescope.finders"
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local conf = require("telescope.config").values
  local entry_display = require "telescope.pickers.entry_display"

  local list = subagents.list(parent.agent_id, parent.host_id)
  if #list == 0 then
    return vim.notify("paseo: this agent session has no subagents", vim.log.levels.INFO)
  end

  local displayer = entry_display.create {
    separator = "  ",
    items = { { width = 2 }, { width = 9 }, { remaining = true } },
  }

  local picker
  picker = pickers.new({}, {
    prompt_title = "Subagents  ·  <CR> open (paseo: chat · provider: read-only)",
    finder = finders.new_table {
      results = list,
      entry_maker = function(s)
        return {
          value = s,
          ordinal = s.title .. " " .. (s.detail or ""),
          display = function()
            local glyph, hl = state(s)
            return displayer {
              { glyph, hl },
              { s.kind, "PaseoDim" },
              s.title .. (s.detail and ("  — " .. s.detail) or ""),
            }
          end,
        }
      end,
    },
    sorter = conf.generic_sorter {},
    attach_mappings = function(bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(bufnr)
        if entry then
          M.open_one(entry.value, parent)
        end
      end)
      return true
    end,
  })
  picker:find()
end

return M
