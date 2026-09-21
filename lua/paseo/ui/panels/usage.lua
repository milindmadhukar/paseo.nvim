--- Tokens, context window, cost -- and what is left of the plan.
---
--- Two different questions, and they come from two different places. The top
--- of the panel is about THIS SESSION: how full the context window is, what
--- the last turn cost. That rides the agent snapshot, push-driven, no polling.
---
--- The bottom is about the ACCOUNT: which plan, how much of the five-hour
--- window is gone, when the weekly one resets. That is `providers.usage`, a
--- daemon-wide answer the daemon fetches from each provider's own usage
--- endpoint, and it is the one that actually answers "can I keep going today"
--- -- which is what the context bar looked like it was answering and was not.
---
--- Drawn as a dashboard rather than as a list of labelled numbers. Tiles across
--- the top carry the figures, and the breakdown underneath is a real table
--- rather than `("  %-10s"):format(label)`, which is what column alignment
--- looked like before `volt.ui.table` was reached for.

local animate = require "paseo.ui.animate"
local icons = require "paseo.ui.icons"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Usage"

---Module-level rather than per-chat: plan limits are the ACCOUNT's, identical
---for every chat on this daemon, and a fetch per chat would be a round trip
---per chat for the same answer.
---@type { list: table[]|nil, err: string|nil, fetched_at: string|nil }|nil
local limits
local loading = false

---How long until an ISO-8601 instant, as "2h 14m". Nil when there is none.
---
---Both sides are built the SAME WRONG WAY on purpose: `os.time` reads a table
---as local time, and the daemon speaks UTC, so `epoch_of` is off by the zone
---offset -- and so is `now`, because `os.date "!*t"` hands `os.time` UTC
---fields too. The offset cancels in the subtraction, which is the only thing
---either number is ever used for. Parsing a timezone properly in Lua to get
---the same answer would be more code and more to get wrong.
---@param iso string|nil
---@return string|nil
local function until_text(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec = iso:match "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
  if not y then
    return nil
  end
  local at = os.time {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(sec),
    isdst = false,
  }
  local utc = os.date "!*t"
  utc.isdst = false
  local left = at - os.time(utc)
  if left <= 0 then
    return "now"
  end
  local days = math.floor(left / 86400)
  if days >= 1 then
    return ("%dd %dh"):format(days, math.floor((left % 86400) / 3600))
  end
  local hours = math.floor(left / 3600)
  if hours >= 1 then
    return ("%dh %02dm"):format(hours, math.floor((left % 3600) / 60))
  end
  return ("%dm"):format(math.max(1, math.floor(left / 60)))
end

---Ask the daemon for the plan windows, then redraw.
---
---Idempotent and self-throttling: `nextRefreshAt` is the daemon's own opinion
---about when its cached answer goes stale, and it is honoured rather than
---second-guessed, because the fetch behind it hits the provider's servers.
function M.load()
  if loading then
    return
  end
  loading = true
  local bridge = require "paseo.bridge"
  bridge.ensure(function(err)
    if err then
      loading = false
      limits = { err = err }
      return
    end
    bridge.request("providers.usage", {}, function(request_err, result)
      loading = false
      limits = {
        list = result and result.providers or nil,
        err = request_err,
        fetched_at = result and result.fetchedAt or nil,
      }
      vim.schedule(function()
        require("paseo.ui.float").rebuild()
      end)
    end)
  end)
end

---Forget what we fetched, so the next draw asks again.
---
---Clears the in-flight flag too. A request that never calls back -- a sidecar
---that died mid-fetch -- would otherwise pin the panel on "loading plan
---limits…" for the rest of the session with no way to ask again.
function M.invalidate()
  limits = nil
  loading = false
end

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

---@param balance table
---@return string
local function amount(balance)
  local value = balance.remaining or balance.used or balance.limit
  if not value then
    return "—"
  end
  if balance.unit == "usd" then
    return ("$%.2f"):format(value)
  end
  if balance.unit == "tokens" then
    return thousands(value)
  end
  return ("%s %s"):format(thousands(value), balance.unit or "")
end

---One provider's plan, as a card.
---
---DENSE ON PURPOSE: two rows per window, a label line and a bar, with the
---reset time on the label line rather than under it. The body of this panel is
---TRUNCATED, not scrolled (`float.body_lines`), so every row this spends is a
---row the provider below it does not get -- and a `widgets.tile` per window
---costs three, plus a blank, plus a reset row. Four windows of that is the
---whole panel.
---@param usage table
---@param width integer
---@return table[][]
local function limits_card(usage, width)
  local inner = widgets.card_inner(width)
  local lines = {}

  if usage.status ~= "available" then
    -- The error is the content. A provider you are not signed in to draws one
    -- line saying so, rather than an empty box that looks like a layout bug.
    lines[1] = {
      { usage.error or ("no plan data (" .. (usage.status or "unknown") .. ")"), "PaseoDim" },
    }
  end

  for _, window in ipairs(usage.windows or {}) do
    local pct = window.usedPct or (window.remainingPct and (100 - window.remainingPct)) or nil
    local hl = pct and widgets.pressure_hl(pct) or "PaseoDim"

    local right = {}
    local resets = until_text(window.resetsAt)
    if resets then
      right[#right + 1] = { resets .. "   ", "PaseoDim" }
    end
    right[#right + 1] = { pct and ("%d%%"):format(math.floor(pct)) or "—", "PaseoCardTitle" }

    lines[#lines + 1] = widgets.row({
      { icons.ui.clock .. "  ", hl },
      { window.label or window.id or "window", "PaseoCardText" },
    }, right, inner)
    lines[#lines + 1] = widgets.bar { w = inner, val = pct or 0, hl = hl, thin = true }
  end

  for _, balance in ipairs(usage.balances or {}) do
    lines[#lines + 1] = widgets.row({
      { icons.ui.cost .. "  ", "PaseoYellow0" },
      { balance.label or balance.id or "", "PaseoCardText" },
    }, { { amount(balance), "PaseoCardTitle" } }, inner)
  end

  for _, detail in ipairs(usage.details or {}) do
    lines[#lines + 1] = widgets.row(
      { { detail.label or detail.id or "", "PaseoDim" } },
      { { detail.value or "", "PaseoDim" } },
      inner
    )
  end

  if #lines == 0 then
    lines[1] = { { "no windows reported", "PaseoDim" } }
  end

  local title = { { usage.displayName or usage.providerId or "provider", "PaseoCardTitle" } }
  if usage.planLabel and usage.planLabel ~= "" then
    title[#title + 1] = { "  " .. usage.planLabel, "PaseoBadge" }
  end

  return widgets.card { title = title, icon = icons.ui.limits, w = width, lines = lines }
end

---The Limits section: every provider the daemon can fetch a quota for.
---@param chat table
---@param width integer
---@return table[][]
local function limits_lines(chat, width)
  if not limits then
    M.load()
    return { { { "  loading plan limits…", "PaseoDim" } } }
  end
  if limits.err then
    return { { { "  " .. limits.err, "PaseoDim" } } }
  end

  -- THE PROVIDER THIS SESSION IS ON, and only that one. The daemon will
  -- happily report on every provider it can authenticate -- a dozen of them,
  -- if you have a dozen configured -- and a wall of other people's quotas is
  -- not what "can I keep going" looks like. It is also rows: the body of this
  -- panel is truncated rather than scrolled, so every card for a provider you
  -- are not using is a card pushing yours off the bottom.
  --
  -- `chat.provider` is `"<provider>/<model>"`.
  local mine = (chat.provider or ""):match "^([^/]+)"
  local usage
  for _, entry in ipairs(limits.list or {}) do
    if entry.providerId == mine then
      usage = entry
    end
  end

  if not usage then
    -- Said rather than left blank. Many providers have no quota fetcher in the
    -- daemon at all -- fable and gemini among them -- and an absence with no
    -- explanation reads as a panel that is broken.
    return {
      {
        { "  no plan limits reported for ", "PaseoDim" },
        { mine or "this provider", "PaseoCardText" },
      },
    }
  end

  return limits_card(usage, width)
end

---How many rows the Limits section is about to want.
---
---Measured by building it, which is cheap -- it is a few dozen table rows and
---no window calls -- and is the only honest answer: the alternative is a
---second formula for the section's height that can disagree with the first.
---@param chat table
---@param width integer
---@return integer
local function limits_height(chat, width)
  return #limits_lines(chat, width)
end

---@param chat table
---@param width integer
---@param height? integer  Rows the panel is being given. See `M.lines`.
---@return table[][]
function M.lines(chat, width, height)
  local usage = chat.usage or (chat.config_snapshot and chat.config_snapshot.usage)
  local last = chat.last_turn_usage

  local used = usage and usage.contextWindowUsedTokens
  local max = usage and usage.contextWindowMaxTokens
  local pct = (used and max and max > 0) and (used / max) * 100 or nil

  -- THE FIGURES THE DAEMON THROWS AWAY. `usage_updated` replaces `lastUsage`
  -- wholesale with a payload carrying only the context window, so within a
  -- second of a turn ending the tokens and the cost are gone from the
  -- snapshot. `chat.last_turn_usage` is the copy `chat.lua` kept off the event
  -- that did carry them; when it is what we are drawing, the tile says so.
  local live = usage
      and ((usage.inputTokens or 0) + (usage.cachedInputTokens or 0) + (usage.outputTokens or 0))
    or 0
  local turn_usage, turn_label = usage, "This turn"
  if live == 0 and last then
    turn_usage, turn_label = last, "Last turn"
  end
  local turn = turn_usage
      and ((turn_usage.inputTokens or 0) + (turn_usage.cachedInputTokens or 0) + (turn_usage.outputTokens or 0))
    or 0
  local cost = (usage and usage.totalCostUsd) or (last and last.totalCostUsd)

  -- ONLY WHAT HAS A VALUE. An empty card is not information; it is a box
  -- occupying a third of the row to tell you nothing, and two of them sat
  -- there for most of every session because of the overwrite above.
  local tiles = {}
  if pct then
    tiles[#tiles + 1] = {
      icon = icons.ui.context,
      label = "Context",
      value = ("%d%%"):format(math.floor(pct)),
      -- Eased, so a jump from 40% to 70% reads as the window filling rather
      -- than as a glitch. The tween is keyed per panel, not per chat, because
      -- only one Usage panel is ever on screen.
      val = animate.tween {
        key = "usage.context",
        buf = require("paseo.ui.float").chrome_buf() or 0,
        section = "body",
        target = pct,
      },
      hl = widgets.pressure_hl(pct),
    }
  end
  if turn > 0 then
    tiles[#tiles + 1] = {
      icon = icons.ui.tokens,
      label = turn_label,
      value = thousands(turn),
      hl = "PaseoBlue0",
    }
  end
  if cost then
    tiles[#tiles + 1] = {
      icon = icons.ui.cost,
      label = "Cost",
      value = ("$%.4f"):format(cost),
      hl = "PaseoYellow0",
    }
  end

  local lines = {}

  -- As many across as there is room for. 26 is where the value stops fitting
  -- beside its label.
  local columns = math.max(1, math.min(#tiles, math.floor(width / 26)))
  local tile_w = math.floor((width - (columns - 1) * 2) / columns)

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

  local column = {}
  for i, card in ipairs(rendered) do
    -- Squared up. Only the Context tile has a bar, so without this the plates
    -- end on different rows and the row reads as a layout bug rather than as
    -- tiles of different content.
    widgets.card_to_height(card, tallest, tile_w)
    column[#column + 1] = { lines = card, w = tile_w, pad = #column + 1 < columns and 2 or 0 }
    if #column == columns then
      vim.list_extend(lines, widgets.grid_col(column))
      column = {}
    end
  end
  if #column > 0 then
    vim.list_extend(lines, widgets.grid_col(column))
  end

  -- THE BODY IS TRUNCATED, NOT SCROLLED (`float.body_lines`), so the rows this
  -- section is prepared to give up have to be decided here rather than found
  -- out by having them silently cut. Both of these say again, at length, what
  -- a tile above already said in one line -- so they are what goes when the
  -- plan limits need the room, and the limits are the half you cannot read
  -- anywhere else.
  local room = height and (height - #lines - 4 - limits_height(chat, width)) or math.huge
  local detail = room > 0

  -- The breakdown, when there is one. All-nil rows are three em dashes under
  -- three headings, which is the table equivalent of an empty card.
  if detail and turn_usage and turn > 0 then
    lines[#lines + 1] = {}
    local table_lines = widgets.table(
      {
        { "input", "cached", "output" },
        {
          thousands(turn_usage.inputTokens),
          thousands(turn_usage.cachedInputTokens),
          thousands(turn_usage.outputTokens),
        },
        -- `"fit"` rather than a share of the width: three short numbers
        -- stretched across a wide dashboard read as three unrelated figures.
      },
      "fit",
      {
        header = "PaseoCardDim",
        title = { "  " .. icons.ui.tokens .. "  Tokens, " .. turn_label:lower() },
      }
    )
    for _, line in ipairs(table_lines) do
      local row = { { "  " } }
      vim.list_extend(row, line)
      lines[#lines + 1] = row
    end
  end

  if detail and used and max then
    lines[#lines + 1] = {}
    lines[#lines + 1] = {
      { "  " },
      { thousands(used) .. " of " .. thousands(max) .. " context tokens used", "PaseoDim" },
    }
  end

  if #lines == 0 then
    lines[#lines + 1] = { { "  no usage reported yet", "PaseoDim" } }
    lines[#lines + 1] = {}
    lines[#lines + 1] = { { "  the daemon sends this once a turn has run", "PaseoDim" } }
  end

  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  " .. icons.ui.limits .. "  ", "PaseoBlue1" },
    { "Plan limits", "PaseoHeader" },
  }
  lines[#lines + 1] = {}
  vim.list_extend(lines, limits_lines(chat, width))

  return lines
end

return M
