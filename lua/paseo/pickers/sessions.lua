--- Agent sessions in a workspace.
---
--- A Paseo workspace holds several agent sessions at once -- in the app they are
--- tabs. Here they are agents you can open a chat on, switch between, and add
--- to. They all share the workspace's working directory: isolation is a
--- property of the WORKSPACE, not of an agent session.

local workspaces = require "paseo.workspaces"

local M = {}

---@param agent table
---@param width integer
---@return string
local function display(agent, width)
  local icons = require "paseo.ui.icons"
  local state = agent.requiresAttention and icons.status.permission
    or (agent.status == "idle" and " " or icons.status.running)
  return ("%s %-" .. width .. "s  %s"):format(
    state,
    agent.provider or "?",
    agent.title or agent.id:sub(1, 12)
  )
end

---@param ws paseo.PaseoWorkspace
---@param opts? table
function M.open(ws, opts)
  opts = opts or {}

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return vim.notify("paseo: telescope is not available", vim.log.levels.ERROR)
  end
  local finders = require "telescope.finders"
  local actions = require "telescope.actions"
  local state = require "telescope.actions.state"
  local conf = require("telescope.config").values

  workspaces.agent_sessions(ws, function(agent_sessions, err)
    if err then
      return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
    end

    vim.schedule(function()
      local width = 0
      for _, agent in ipairs(agent_sessions) do
        width = math.max(width, #(agent.provider or "?"))
      end

      local function start_new(bufnr)
        if bufnr then
          actions.close(bufnr)
        end
        vim.ui.input(
          { prompt = "New agent session in " .. (ws.name or "workspace") .. ": " },
          function(title)
            if title == nil then
              return
            end
            workspaces.new_agent_session(
              ws,
              { title = title ~= "" and title or nil },
              function(id, create_err)
                if create_err == "cancelled" then
                  return
                end
                if create_err then
                  return vim.notify("paseo: " .. create_err, vim.log.levels.ERROR)
                end
                vim.schedule(function()
                  require("paseo.ui.chat").open {
                    root = ws.directory,
                    agent_id = id,
                    title = title ~= "" and title or nil,
                  }
                end)
              end
            )
          end
        )
      end

      if #agent_sessions == 0 then
        vim.notify("paseo: no agent sessions in this workspace yet", vim.log.levels.INFO)
        return start_new(nil)
      end

      pickers
        .new(opts, {
          prompt_title = "Agent sessions · " .. (ws.name or ws.directory),
          finder = finders.new_table {
            results = agent_sessions,
            entry_maker = function(agent)
              return {
                value = agent,
                display = display(agent, width),
                ordinal = (agent.title or "") .. " " .. (agent.provider or ""),
              }
            end,
          },
          sorter = conf.generic_sorter(opts),
          attach_mappings = function(bufnr, map)
            actions.select_default:replace(function()
              local entry = state.get_selected_entry()
              actions.close(bufnr)
              if entry then
                -- Opening an EXISTING agent session: the chat fetches its timeline,
                -- so you land in the conversation as it stands rather than a
                -- blank window.
                require("paseo.ui.chat").open {
                  root = ws.directory,
                  agent_id = entry.value.id,
                  title = entry.value.title,
                }
              end
            end)

            map({ "i", "n" }, "<C-n>", function()
              start_new(bufnr)
            end)

            map({ "i", "n" }, "<C-y>", function()
              local entry = state.get_selected_entry()
              if entry then
                require("paseo.agents").copy_id(entry.value)
              end
            end)

            map({ "i", "n" }, "<C-d>", function()
              local entry = state.get_selected_entry()
              if not entry then
                return
              end
              actions.close(bufnr)
              require("paseo.bridge").request(
                "agent.archive",
                { agentId = entry.value.id },
                function(archive_err)
                  vim.notify(
                    archive_err and ("paseo: " .. archive_err)
                      or ("paseo: archived " .. (entry.value.title or "agent session")),
                    archive_err and vim.log.levels.ERROR or vim.log.levels.INFO
                  )
                end
              )
            end)

            return true
          end,
        })
        :find()
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
