--- Tokens, context window and cost.
---
--- The numbers arrive push-driven on `usage_updated`, so this is current
--- without polling. The context-window bar is the one worth having in front of
--- you: it is the difference between finishing a session and being compacted
--- halfway through a thought.

local M = {}

M.title = "Usage"

---@param n number|nil
---@return string
local function thousands(n)
  if not n then
    return "—"
  end
  local text = tostring(math.floor(n))
  local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

---A horizontal fill bar, in the volt style.
---@param pct number
---@param w integer
---@return table[]
local function bar(pct, w)
  local filled = math.floor(w * math.min(100, math.max(0, pct)) / 100)
  local group = pct >= 90 and "PaseoToolFail"
    or pct >= 70 and "PaseoToolRunning"
    or "PaseoAgent"
  return {
    { string.rep("┃", filled), group },
    { string.rep("┃", w - filled), "PaseoBorder" },
  }
end

---@param chat table
---@param width integer
---@return table[][]
function M.lines(chat, width)
  local usage = chat.usage or (chat.config_snapshot and chat.config_snapshot.usage)
  if not usage then
    return {
      { { "  no usage reported yet", "PaseoDim" } },
      {},
      { { "  the daemon sends this once a turn has run", "PaseoDim" } },
    }
  end

  local lines = {}
  local barw = math.max(20, math.min(60, width - 20))

  local used = usage.contextWindowUsedTokens
  local max = usage.contextWindowMaxTokens
  if used and max and max > 0 then
    local pct = (used / max) * 100
    lines[#lines + 1] = { { "  Context window", "PaseoHeader" } }
    lines[#lines + 1] = {}
    local row = { { "  " } }
    vim.list_extend(row, bar(pct, barw))
    row[#row + 1] = {
      ("  %d%%  %s / %s"):format(math.floor(pct), thousands(used), thousands(max)),
      "PaseoDim",
    }
    lines[#lines + 1] = row
    lines[#lines + 1] = {}
  end

  lines[#lines + 1] = { { "  This turn", "PaseoHeader" } }
  lines[#lines + 1] = {}
  for _, row in ipairs {
    { "input", thousands(usage.inputTokens) },
    { "cached", thousands(usage.cachedInputTokens) },
    { "output", thousands(usage.outputTokens) },
  } do
    lines[#lines + 1] = {
      { ("  %-10s"):format(row[1]), "PaseoDim" },
      { row[2], nil },
    }
  end

  if usage.totalCostUsd then
    lines[#lines + 1] = {}
    lines[#lines + 1] = {
      { ("  %-10s"):format "cost", "PaseoDim" },
      { ("$%.4f"):format(usage.totalCostUsd), "PaseoKey" },
    }
  end

  return lines
end

return M
