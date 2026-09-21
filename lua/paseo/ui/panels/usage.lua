--- Tokens, context window and cost.
---
--- The numbers arrive push-driven on `usage_updated`, so this is current
--- without polling. The context-window figure is the one worth having in front
--- of you: it is the difference between finishing an agent session and being
--- compacted halfway through a thought.
---
--- Drawn as a dashboard rather than as a list of labelled numbers. Three tiles
--- across the top carry the figures that answer "can I keep going" -- context,
--- tokens, cost -- and the breakdown underneath is a real table rather than
--- `("  %-10s"):format(label)`, which is what column alignment looked like
--- before `volt.ui.table` was reached for.

local animate = require "paseo.ui.animate"
local icons = require "paseo.ui.icons"
local widgets = require "paseo.ui.widgets"

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

  local used = usage.contextWindowUsedTokens
  local max = usage.contextWindowMaxTokens
  local pct = (used and max and max > 0) and (used / max) * 100 or nil

  local turn = (usage.inputTokens or 0) + (usage.cachedInputTokens or 0) + (usage.outputTokens or 0)

  -- Three tiles across, or stacked when there is not room for three readable
  -- columns. 26 is where the value stops fitting beside its label.
  local columns = width >= 3 * 26 and 3 or 1
  local tile_w = math.floor((width - (columns - 1) * 2) / columns)

  local tiles = {
    {
      icon = icons.ui.context,
      label = "Context",
      value = pct and ("%d%%"):format(math.floor(pct)) or "—",
      -- Eased, so a jump from 40% to 70% reads as the window filling rather
      -- than as a glitch. The tween is keyed per panel, not per chat, because
      -- only one Usage panel is ever on screen.
      val = pct and animate.tween {
        key = "usage.context",
        buf = require("paseo.ui.float").chrome_buf() or 0,
        section = "body",
        target = pct,
      },
      hl = pct and widgets.pressure_hl(pct) or "PaseoDim",
    },
    {
      icon = icons.ui.tokens,
      label = "This turn",
      value = thousands(turn > 0 and turn or nil),
      hl = "PaseoBlue0",
    },
    {
      icon = icons.ui.cost,
      label = "Cost",
      value = usage.totalCostUsd and ("$%.4f"):format(usage.totalCostUsd) or "—",
      hl = "PaseoYellow0",
    },
  }

  local lines = {}

  if columns == 3 then
    local rendered, tallest = {}, 0
    for i, tile in ipairs(tiles) do
      local card = widgets.card {
        title = "",
        w = tile_w,
        lines = widgets.tile(vim.tbl_extend("force", tile, { w = widgets.card_inner(tile_w) })),
      }
      -- The title row is empty: a tile says what it is with its icon and its
      -- label, and a card heading above that would be the same word twice.
      table.remove(card, 1)
      rendered[i] = card
      tallest = math.max(tallest, #card)
    end

    -- Squared up. Only the Context tile has a bar, so without this the three
    -- plates end on three different rows and the row reads as a layout bug
    -- rather than as three tiles of different content.
    local columns_in = {}
    for i, card in ipairs(rendered) do
      widgets.card_to_height(card, tallest, tile_w)
      columns_in[i] = { lines = card, w = tile_w, pad = i < 3 and 2 or 0 }
    end
    vim.list_extend(lines, widgets.grid_col(columns_in))
  else
    for _, tile in ipairs(tiles) do
      vim.list_extend(
        lines,
        widgets.card {
          title = "",
          w = tile_w,
          lines = widgets.tile(vim.tbl_extend("force", tile, { w = widgets.card_inner(tile_w) })),
        }
      )
    end
  end

  lines[#lines + 1] = {}

  -- The breakdown.
  local rows = {
    { "input", "cached", "output" },
    {
      thousands(usage.inputTokens),
      thousands(usage.cachedInputTokens),
      thousands(usage.outputTokens),
    },
  }
  -- `"fit"` rather than a share of the width: three short numbers stretched
  -- across a wide dashboard read as three unrelated figures.
  local table_lines = widgets.table(rows, "fit", {
    header = "PaseoCardDim",
    title = { "  " .. icons.ui.tokens .. "  Tokens this turn" },
  })
  for _, line in ipairs(table_lines) do
    local row = { { "  " } }
    vim.list_extend(row, line)
    lines[#lines + 1] = row
  end

  if used and max then
    lines[#lines + 1] = {}
    lines[#lines + 1] = {
      { "  " },
      { thousands(used) .. " of " .. thousands(max) .. " context tokens used", "PaseoDim" },
    }
  end

  return lines
end

return M
