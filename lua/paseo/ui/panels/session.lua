--- Session controls: mode, thinking level, model, feature toggles.
---
--- The same four things `ui/session.lua` drives, but shown all at once with the
--- current value marked, instead of four separate `vim.ui.select` prompts you
--- have to open one at a time to find out what is set.
---
--- The config is fetched into `chat.config_snapshot` and drawn from there, so
--- drawing never blocks on a round trip.

local bridge = require "paseo.bridge"

local M = {}

M.title = "Session"

---Ask the daemon, then redraw. Cheap enough to call on every panel open:
---modes, models and thinking levels are all per-provider and can change under
---us when the Paseo app switches something.
---@param chat table
function M.load(chat)
  if not chat.agent_id then
    return
  end
  bridge.request("agent.config", { agentId = chat.agent_id }, function(err, config)
    if err or not config then
      return
    end
    vim.schedule(function()
      chat.config_snapshot = config
      require("paseo.ui.float").rebuild()
    end)
  end)
end

---Apply a change, then redraw from what the daemon reports back.
---
---Not from what we asked for: a provider may accept a change and still have
---something to say about it, and `agent.config` is the only honest answer.
---@param chat table
---@param op string
---@param args table
local function apply(chat, op, args)
  args.agentId = chat.agent_id
  bridge.request(op, args, function(err, result)
    vim.schedule(function()
      if err then
        return vim.notify("paseo: " .. err, vim.log.levels.ERROR)
      end
      local notice = result and result.notice
      if type(notice) == "table" and notice.message then
        vim.notify("paseo: " .. tostring(notice.message), vim.log.levels.WARN)
      elseif type(notice) == "string" and notice ~= "" then
        vim.notify("paseo: " .. notice, vim.log.levels.WARN)
      end
      M.load(chat)
      require("paseo.ui.chat").load_settings(chat)
    end)
  end)
end

---One selectable group -- modes, thinking levels or models.
---
---Rows carry a `click` action as the cell's third element, which is volt's own
---convention; `volt.events.add` on the chrome buffer is what makes them
---respond to a mouse click, and `<CR>` works through the same path.
---@param chat table
---@param label string
---@param entries table[]
---@param current any
---@param op string
---@param arg_key string
---@return table[][]
local function group(chat, label, entries, current, op, arg_key)
  local lines = { { { label, "PaseoHeader" } } }
  if #entries == 0 then
    lines[#lines + 1] = { { "  (none reported by this provider)", "PaseoDim" } }
    lines[#lines + 1] = {}
    return lines
  end
  for _, entry in ipairs(entries) do
    local active = entry.id == current
    local click = function()
      apply(chat, op, { [arg_key] = entry.id })
    end
    lines[#lines + 1] = {
      { active and "  ● " or "  ○ ", active and "PaseoAgent" or "PaseoDim", click },
      { entry.label or entry.id, active and "PaseoAgent" or nil, click },
      { entry.description and ("   " .. entry.description) or "", "PaseoDim" },
    }
  end
  lines[#lines + 1] = {}
  return lines
end

---@param chat table
---@param width integer
---@return table[][]
function M.lines(chat, width)
  local config = chat.config_snapshot
  if not config then
    M.load(chat)
    return { { { "  loading session settings…", "PaseoDim" } } }
  end

  local lines = {}
  vim.list_extend(
    lines,
    group(chat, "  Mode", config.availableModes or {}, config.modeId, "agent.setMode", "modeId")
  )
  vim.list_extend(
    lines,
    group(
      chat,
      "󰧑  Thinking",
      config.thinkingOptions or {},
      config.thinkingOptionId,
      "agent.setThinking",
      "thinkingOptionId"
    )
  )
  vim.list_extend(
    lines,
    group(chat, "  Model", config.models or {}, config.model, "agent.setModel", "modelId")
  )

  lines[#lines + 1] = { { "⚡ Features", "PaseoHeader" } }
  for _, feature in ipairs(config.features or {}) do
    local click = function()
      apply(chat, "agent.setFeature", { featureId = feature.id, value = not feature.value })
    end
    lines[#lines + 1] = {
      {
        feature.value and "  [x] " or "  [ ] ",
        feature.value and "PaseoAgent" or "PaseoDim",
        click,
      },
      { feature.label or feature.id, feature.value and "PaseoAgent" or nil, click },
    }
  end
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  <CR>", "PaseoKey" },
    { " or click to change · also ", "PaseoDim" },
    { ":Paseo mode", "PaseoKey" },
    { " · ", "PaseoDim" },
    { ":Paseo thinking", "PaseoKey" },
    { " · ", "PaseoDim" },
    { ":Paseo fast", "PaseoKey" },
  }

  return lines
end

return M
