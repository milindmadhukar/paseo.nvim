--- The component vocabulary: cards, chips, keycaps, rows.
---
--- `render.lua` gives us a LINE -- a list of `{ text, highlight, click }`
--- cells. That is the alphabet. This is the vocabulary built on top of it, and
--- it exists because every panel had been spelling the same words out by hand:
--- `active and "  ● " or "  ○ "` in `panels/session.lua`, `mine and "  ▌ " or
--- "    "` in two more, `string.rep("─", width - 2)` in a fourth, and the same
--- footer hint row copied verbatim into five files.
---
--- Where volt already has the component, we USE volt's -- `grid_col` is a real
--- column layout engine and reimplementing it would be silly. Where volt's
--- does not fit, ours is here and the comment says why.
---
--- THE `"_pad_"` TRAP. volt's `hpad` expands a cell whose text is the literal
--- string `"_pad_"` to fill the remaining width, and `volt.ui.line_w` skips it
--- when measuring. `render.width` does NOT -- to it that cell is five columns
--- of text. So `hpad` must always run BEFORE `render.truncate`, never after.
--- `M.row` is the only thing here that emits `"_pad_"`, and it resolves it
--- before returning, so nothing downstream ever sees one.

local render = require "paseo.ui.render"
local voltui = require "volt.ui"

local M = {}

-- Straight through from volt: these already do the job.
M.grid_col = voltui.grid_col
M.grid_row = voltui.grid_row
M.separator = voltui.separator
M.progressbar = voltui.progressbar
M.checkbox = voltui.checkbox
M.line_w = voltui.line_w

---Highlight for each chip state.
---
---A table rather than an `if` chain because the panel computes the state name
---from data (`tone(entry)` returns `"danger"` for `bypassPermissions`) and
---then hands it straight here.
M.CHIP = {
  on = "PaseoChipOn",
  off = "PaseoChipOff",
  focus = "PaseoChipFocus",
  warn = "PaseoChipWarn",
  danger = "PaseoChipDanger",
}

M.icons = {
  radio_on = "●",
  radio_off = "○",
  -- Geometric Shapes rather than nerd-font glyphs, and that is not a style
  -- choice: these two were EMPTY STRINGS -- the codepoints had been lost out of
  -- the file at some point -- so the Session panel's feature toggles and every
  -- multi-select question drew their marker as nothing at all. A marker that
  -- depends on a patched font is a marker that is sometimes absent, and absent
  -- is indistinguishable from "off".
  check_on = "▣",
  check_off = "□",
  card_tl = "╭",
  card_tr = "╮",
  card_bl = "╰",
  card_br = "╯",
}

-- ------------------------------------------------------------------- layout

---`left … right`, justified to `w` columns.
---
---Resolves the `"_pad_"` sentinel before returning, so the result is an
---ordinary line that `render.truncate` and `render.width` both measure
---correctly.
---@param left table[]
---@param right table[]
---@param w integer
---@param hl? string  Highlight for the filler, so it keeps the card's background.
---@return table[]
function M.row(left, right, w, hl)
  local line = {}
  vim.list_extend(line, left)
  line[#line + 1] = { "_pad_", hl or "PaseoCardText" }
  vim.list_extend(line, right)
  return voltui.hpad(line, w)
end

---A bordered, background-filled card. EVERY row is exactly `w` columns.
---
---Not `volt.ui.border`: that one sizes itself to its content, mutates the
---table it is given and returns `nil`, and paints no background -- three
---things that are all wrong for a panel laid out in fixed columns, where a
---card one cell narrower than its neighbour is immediately visible.
---
---The title sits IN the top border, which is the same shape `render.card`
---uses for tool calls, so the two read as the same family.
---@param opts { title: string|table[], icon?: string, lines: table[][], w: integer, rule?: string }
---@return table[][]
function M.card(opts)
  local w = opts.w
  local rule = opts.rule or "PaseoCardRule"
  -- "│ " on the left and " │" on the right.
  local inner = math.max(4, w - 4)

  local title = {}
  if opts.icon and opts.icon ~= "" then
    title[#title + 1] = { opts.icon .. "  ", "PaseoCardTitle" }
  end
  -- A string for the common case; cells when the title carries something of
  -- its own -- the group's mnemonic key, drawn as a cap rather than written
  -- out as three spaces and a letter.
  if type(opts.title) == "string" then
    title[#title + 1] = { opts.title, "PaseoCardTitle" }
  else
    vim.list_extend(title, opts.title)
  end

  local top = { { M.icons.card_tl .. "─ ", rule } }
  vim.list_extend(top, render.truncate(title, math.max(4, w - 6)))
  -- `w - used - 2` leaves room for the space before the rule and the corner
  -- after it, so the row lands on exactly `w`.
  local used = render.width(top)
  top[#top + 1] = { " " .. string.rep("─", math.max(0, w - used - 2)) .. M.icons.card_tr, rule }

  local lines = { top }

  for _, line in ipairs(opts.lines) do
    local row = { { "│ ", rule } }
    vim.list_extend(row, render.truncate(vim.deepcopy(line), inner))
    -- Padded in the card's own background, not `nil` -- a `nil` highlight here
    -- would leave the right-hand side of every short row transparent and the
    -- card would look like it had a bite taken out of it.
    render.pad(row, w - 1, "PaseoCardText")
    row[#row + 1] = { "│", rule }
    lines[#lines + 1] = row
  end

  lines[#lines + 1] = {
    { M.icons.card_bl .. string.rep("─", math.max(0, w - 2)) .. M.icons.card_br, rule },
  }

  return lines
end

---Grow a rendered card to `h` rows.
---
---Two cards side by side that stop at different rows read as a layout bug
---rather than as two cards of different content, and `grid_col` pads the short
---column with UNhighlighted space -- so the gap is not just uneven, it is a
---hole in the background.
---@param lines table[][]
---@param h integer
---@param w integer  The card's width.
---@param rule? string
---@return table[][]
function M.card_to_height(lines, h, w, rule)
  rule = rule or "PaseoCardRule"
  while #lines < h do
    table.insert(lines, #lines, {
      { "│ ", rule },
      { string.rep(" ", math.max(0, w - 3)), "PaseoCardText" },
      { "│", rule },
    })
  end
  return lines
end

---`n` blank rows, filled with a background so they belong to what is above.
---@param n integer
---@param hl? string
---@return table[][]
function M.blanks(n, hl)
  local lines = {}
  for _ = 1, n do
    lines[#lines + 1] = { { "", hl } }
  end
  return lines
end

-- -------------------------------------------------------------------- chips

---One chip: a pill of text whose background carries its state.
---
---Padded with a space on each side so the background reads as a shape rather
---than as highlighted text. The click action goes on the whole cell, padding
---included, so the target is the pill and not just the letters.
---@param text string
---@param state string  A key of `M.CHIP`.
---@param click? function|table
---@return table
function M.chip(text, state, click)
  return { " " .. text .. " ", M.CHIP[state] or M.CHIP.off, click }
end

---A row of chips, wrapped to `w` columns.
---
---Returns LINES, not a line: five permission modes do not fit across a narrow
---dashboard, and the alternative to wrapping is truncating away the one you
---were looking for.
---@param chips table[]  Cells, as returned by `M.chip`.
---@param w integer
---@param gap? string
---@return table[][]
function M.chiprow(chips, w, gap)
  gap = gap or " "
  local gap_w = vim.api.nvim_strwidth(gap)

  local lines = {}
  local line, used = {}, 0

  for _, chip in ipairs(chips) do
    local cw = vim.api.nvim_strwidth(chip[1])
    if #line > 0 and used + gap_w + cw > w then
      lines[#lines + 1] = line
      line, used = {}, 0
    end
    if #line > 0 then
      line[#line + 1] = { gap, "PaseoCardText" }
      used = used + gap_w
    end
    line[#line + 1] = chip
    used = used + cw
  end

  if #line > 0 then
    lines[#lines + 1] = line
  end
  return lines
end

---A radio row: marker, label, and something right-aligned.
---
---The GAP between the label and the right-hand text carries the click action
---too. That is what makes the whole row a target instead of just the two words
---on it -- `menu/ui.lua` does the same thing, and it is the difference between
---a list you click and a list you aim at.
---@param opts { label: string, right?: string, active: boolean, focused: boolean, w: integer, click?: function }
---@return table[]
function M.radio(opts)
  local hl = opts.focused and "PaseoChipFocus" or opts.active and "PaseoChipOn" or "PaseoCardText"
  local marker = opts.active and M.icons.radio_on or M.icons.radio_off

  local left = {
    { " " .. marker .. " ", opts.active and "PaseoChipOn" or "PaseoCardDim", opts.click },
    { opts.label .. " ", hl, opts.click },
  }
  local right = opts.right and { { opts.right .. " ", "PaseoCardDim", opts.click } } or {}

  local line = M.row(left, right, opts.w)
  -- `row` inserts the filler cell itself; give it the action as well.
  for _, cell in ipairs(line) do
    cell[3] = cell[3] or opts.click
  end
  return line
end

-- ----------------------------------------------------------------- keycaps

---A key, drawn as a physical cap.
---@param key string
---@param dim? boolean
---@return table
function M.keycap(key, dim)
  return { " " .. key .. " ", dim and "PaseoKeycapDim" or "PaseoKeycap" }
end

---The hint bar: ` h l ` move  ` ⏎ ` apply …
---
---One builder, because this row was copy-pasted verbatim into five files and
---they had already drifted -- the float advertised `1-5` while there were six
---tabs.
---@param pairs_ table[]  `{ { "h l", "move" }, … }`
---@param hl? string  Background for the gaps, when drawn inside a card.
---@return table[]
function M.hints(pairs_, hl)
  local line = {}
  for i, pair in ipairs(pairs_) do
    if i > 1 then
      line[#line + 1] = { "   ", hl }
    end
    line[#line + 1] = M.keycap(pair[1])
    line[#line + 1] = { " " .. pair[2], hl or "PaseoDim" }
  end
  return line
end

return M
