--- Agent sessions in a workspace.
---
--- A Paseo workspace holds several agent sessions at once -- in the app they are
--- tabs. Here they are agents you can open a chat on, switch between, and add
--- to. They all share the workspace's working directory: isolation is a
--- property of the WORKSPACE, not of an agent session.

local workspaces = require "paseo.workspaces"

local M = {}

---@param agent table
---@return paseo.ChooseItem
local function item(agent)
  local icons = require "paseo.ui.icons"
  local state = agent.requiresAttention and icons.status.permission
    or (agent.status == "idle" and " " or icons.status.running)
  return {
    id = agent.id,
    value = agent,
    cells = {
      { state .. " ", agent.requiresAttention and "PaseoBadge" or "PaseoToolRunning" },
      { agent.title or agent.id:sub(1, 12), "PaseoText" },
    },
    right = { { agent.provider or "?", "PaseoDim" } },
  }
end

---@param ws paseo.PaseoWorkspace
function M.open(ws)
  workspaces.agent_sessions(ws, function(agent_sessions, err)
    if err then
      return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    end

    vim.schedule(function()
      local function start_new()
        -- A new agent IN this workspace, by id: the tab row's `+`. The
        -- daemon titles the agent from the prompt.
        local ctx = require("paseo.new").context() or {}
        require("paseo.new").open({
          root = ws.directory,
          local_root = ws.local_directory or ws.directory,
          host_id = ws.hostId or ctx.host_id,
          preferred = ctx.preferred,
          workspace_id = ws.id,
          title = ws.name,
          project_root = ws.projectRoot,
        }, { scope = "agent", kind = "chat" })
      end

      if #agent_sessions == 0 then
        vim.notify("paseo: no agent sessions in this workspace yet", vim.log.levels.INFO)
        return start_new()
      end

      local items = {}
      for i, agent in ipairs(agent_sessions) do
        items[i] = item(agent)
      end

      require("paseo.ui.choose").open {
        title = "Agents · " .. (ws.name or ws.directory),
        items = items,
        on_pick = function(row)
          -- An EXISTING agent session: the chat fetches its timeline, so you
          -- land in the conversation as it stands.
          require("paseo.ui.chat").open {
            root = ws.directory,
            agent_id = row.value.id,
            title = row.value.title,
          }
        end,
        verbs = {
          { "n", "new", function(_, handle)
            handle.close()
            start_new()
          end },
          { "y", "copy id", function(row)
            if row then
              require("paseo.agents").copy_id(row.value)
            end
          end },
          { "d", "archive", function(row, handle)
            if not row then
              return
            end
            handle.close()
            require("paseo.bridge").request("agent.archive", { agentId = row.value.id }, function(archive_err)
              vim.notify(
                archive_err and ("paseo: " .. archive_err)
                  or ("paseo: archived " .. (row.value.title or "agent session")),
                archive_err and vim.log.levels.ERROR or vim.log.levels.INFO
              )
            end)
          end },
        },
      }
    end)
  end)
end

---Agent sessions in whichever workspace contains the cwd.
function M.here()
  workspaces.for_dir(assert(vim.uv.cwd()), function(ws, err)
    vim.schedule(function()
      if not ws then
        return vim.notify("paseo: " .. tostring(err), vim.log.levels.WARN)
      end
      M.open(ws)
    end)
  end)
end

return M
