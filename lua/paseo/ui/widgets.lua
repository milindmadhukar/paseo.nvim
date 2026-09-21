--- The component vocabulary: cards, chips, keycaps, tiles, bars, charts, rows.
---
--- `render.lua` gives us a LINE -- a list of `{ text, highlight, click }`
--- cells. That is the alphabet. This is the vocabulary built on top of it, and
--- it exists because every panel had been spelling the same words out by hand:
--- `active and "  ● " or "  ○ "` in `panels/settings.lua`, `mine and "  ▌ " or
--- "    "` in two more, `string.rep("─", width - 2)` in a fourth, and the same
--- footer hint row copied verbatim into five files.
---
--- Where volt already has the component, we USE volt's -- `grid_col` is a real
--- column layout engine, `table` is a real ruled grid, and reimplementing
--- either would be silly. Where volt's does not fit, ours is here and the
--- comment says why.
---
--- THE `"_pad_"` TRAP. volt's `hpad` expands a cell whose text is the literal
--- string `"_pad_"` to fill the remaining width, and `volt.ui.line_w` skips it
--- when measuring. `render.width` does NOT -- to it that cell is five columns
--- of text. So `hpad` must always run BEFORE `render.truncate`, never after.
--- `M.row` is the only thing here that emits `"_pad_"`, and it resolves it
--- before returning, so nothing downstream ever sees one.

local render = require "paseo.ui.render"
local icons = require "paseo.ui.icons"
local style = require "paseo.ui.style"
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
  -- The same two tones on an UNSELECTED option: neutral plate, accent text.
  warn_off = "PaseoChipWarnOff",
  danger_off = "PaseoChipDangerOff",
}

---Selection markers. The registry is `ui/icons.lua` now -- this is the name
---the panels already reach for, kept pointing at it.
M.icons = icons.marker

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

---How many columns of a card's width the content actually gets.
---
---`render`'s, re-exported: the two card renderers must agree on this or a
---panel card and a tool card wrap to different widths under the same style.
M.card_inner = render.card_inner

---A card. EVERY row is exactly `w` columns, and there are always exactly
---`#opts.lines + 2` of them.
---
---That height invariant is load-bearing, not tidiness. volt records each
---section's start row when the layout is MEASURED and never recomputes it on
---redraw, so a card whose height depends on the frame style would move every
---section below it the moment someone changed `ui.style`. Holding all four
---styles to the same height means the preset is purely a repaint: two cards
---paired side by side still square up, `card_to_height` still works, and
---nothing downstream has to know which style is live.
---
---The four styles spend those two rows differently:
---
---  plate    title row, body, one padded blank -- NO frame at all. Depth comes
---           from the card sitting an elevation tier above its surface. This
---           is the default, and it is the answer to three frame weights
---           competing inside one window.
---  rule     title row, an INSET hairline, body. Inset rather than full-bleed
---           because a rule that runs edge to edge reads as a table border.
---  rounded  the old look: title in the top border, sides, bottom.
---  square   the same with square corners.
---
---Not `volt.ui.border` for the framed cases either: that one sizes itself to
---its content, mutates the table it is given and returns `nil`, and paints no
---background -- three things that are all wrong for a panel laid out in fixed
---columns, where a card one cell narrower than its neighbour is immediately
---visible.
---@param opts { title: string|table[], icon?: string, lines: table[][], w: integer, rule?: string, kind?: string }
---@return table[][]
function M.card(opts)
  local w = opts.w
  local rule = opts.rule or "PaseoCardRule"
  local kind = opts.kind or style.get().card
  local box = style.BOX[kind]
  local inner = M.card_inner(w, kind)

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

  local lines = {}

  if box then
    -- The title sits IN the top border, which is the same shape a tool card
    -- uses, so the two read as the same family.
    local top = { { box.tl .. box.h .. " ", rule } }
    vim.list_extend(top, render.truncate(title, math.max(4, w - 6)))
    -- `w - used - 2` leaves room for the space before the rule and the corner
    -- after it, so the row lands on exactly `w`.
    local used = render.width(top)
    top[#top + 1] = { " " .. string.rep(box.h, math.max(0, w - used - 2)) .. box.tr, rule }
    lines[#lines + 1] = top

    for _, line in ipairs(opts.lines) do
      local row = { { box.v .. " ", rule } }
      vim.list_extend(row, render.truncate(vim.deepcopy(line), inner))
      -- Padded in the card's own background, not `nil` -- a `nil` highlight
      -- here would leave the right-hand side of every short row transparent
      -- and the card would look like it had a bite taken out of it.
      render.pad(row, w - 1, "PaseoCardText")
      row[#row + 1] = { box.v, rule }
      lines[#lines + 1] = row
    end

    lines[#lines + 1] = {
      { box.bl .. string.rep(box.h, math.max(0, w - 2)) .. box.br, rule },
    }

    return lines
  end

  -- Unframed: the title is a row of its own, and every row is one space in
  -- from each edge so the background reads as a plate rather than as a strip
  -- of colour butted against whatever is next to it.
  local header = { { " ", "PaseoCardText" } }
  vim.list_extend(header, render.truncate(title, inner))
  render.pad(header, w, "PaseoCardText")
  lines[#lines + 1] = header

  if kind == "rule" then
    lines[#lines + 1] = {
      { " " .. string.rep(style.BOX.square.h, math.max(0, w - 2)) .. " ", rule },
    }
  end

  for _, line in ipairs(opts.lines) do
    local row = { { " ", "PaseoCardText" } }
    vim.list_extend(row, render.truncate(vim.deepcopy(line), inner))
    render.pad(row, w, "PaseoCardText")
    lines[#lines + 1] = row
  end

  if kind ~= "rule" then
    -- The trailing pad, which is what keeps the height at `n + 2` and what
    -- stops the last row of text sitting hard on the plate's edge.
    lines[#lines + 1] = { { string.rep(" ", w), "PaseoCardText" } }
  end

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
  local box = style.BOX[style.get().card]

  while #lines < h do
    -- Inserted one from the end, so the filler lands INSIDE the card: above
    -- the bottom border when there is one, above the trailing pad when there
    -- is not.
    table.insert(lines, #lines, box and {
      { box.v .. " ", rule },
      { string.rep(" ", math.max(0, w - 3)), "PaseoCardText" },
      { box.v, rule },
    } or { { string.rep(" ", w), "PaseoCardText" } })
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
---
---The key is spelled the way a keyboard spells it rather than the way Vim
---does -- `<C-f>` reads `Ctrl + f` -- because a hint bar is scanned, not
---parsed. `ui/icons.lua` owns that mapping.
---@param key string
---@param dim? boolean
---@return table
function M.keycap(key, dim)
  return { " " .. icons.spell(key) .. " ", dim and "PaseoKeycapDim" or "PaseoKeycap" }
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

-- ---------------------------------------------------------------- readouts

---Threshold colour for a fill that means "how much is left".
---
---The thresholds are the ones `panels/usage.lua` already used for the context
---window; they are here so the Usage panel, a token budget and anything else
---measuring pressure all agree on when amber becomes red.
---@param pct number  0-100.
---@return string
function M.pressure_hl(pct)
  if pct >= 90 then
    return "PaseoToolFail"
  end
  if pct >= 70 then
    return "PaseoToolRunning"
  end
  return "PaseoAgent"
end

---A progress bar: a two-tone track.
---
---The filled and empty glyph are the SAME character and only the highlight
---differs. That is the whole difference between a bar that reads as a solid
---track and the `┃`-then-spaces meter this replaces -- spaces have no weight,
---so the unfilled part of the old bar was a hole rather than a track.
---@param opts { w: integer, val: number, hl?: string, track?: string, thin?: boolean }
---@return table[]
function M.bar(opts)
  local glyph = opts.thin and style.BAR.thin or style.BAR.thick
  return voltui.progressbar {
    w = math.max(1, math.floor(opts.w)),
    -- Clamped rather than trusted: a context window can report over 100% once
    -- the overhead is counted, and `string.rep` with a negative count is an
    -- error rather than an empty string.
    val = math.max(0, math.min(100, opts.val or 0)),
    icon = { on = glyph, off = glyph },
    hl = { on = opts.hl or "PaseoAgent", off = opts.track or "PaseoTrack" },
  }
end

---A KPI tile: an accented icon, a neutral label, a value, and a bar.
---
---Colour lives in the ICON, not in the label. That restraint is most of why
---typr's dashboard reads as designed -- a coloured label competes with the
---number beside it, and the number is the thing you came to read.
---@param opts { icon: string, label: string, value: string, w: integer, val?: number, hl?: string, track?: string }
---@return table[][]
function M.tile(opts)
  local hl = opts.hl or "PaseoAgent"

  local head = {
    { opts.icon .. "  ", hl },
    { opts.label, "PaseoCardText" },
  }
  local value = { { opts.value, "PaseoCardTitle" } }

  local lines = { M.row(head, value, opts.w) }

  if opts.val then
    lines[#lines + 1] = { { "", "PaseoCardText" } }
    lines[#lines + 1] = M.bar { w = opts.w, val = opts.val, hl = hl, track = opts.track }
  end

  return lines
end

---A ruled table. Straight through to volt's, which is a real one.
---
---`w` may be the string `"fit"`, which shrinks to content -- measure the
---result with `M.line_w(result[1])` when the remaining columns have to be
---sized around it. A cell is either a plain value, centred and drawn in one
---highlight, or a LINE, which keeps its own -- that is how a column gets an
---icon or a colour without a second table.
---@param rows table[]
---@param w integer|string
---`title` is a CELL -- `{ text }` or `{ text, hl }` -- not a line. volt wraps
---it in a line itself, so handing it one produces a line whose first cell is a
---table, and the first thing that concatenates a cell's text throws.
---@param opts? { header?: string, title?: table }
---@return table[][]
function M.table(rows, w, opts)
  opts = opts or {}
  local lines = voltui.table(rows, w, opts.header or "PaseoCardTitle", opts.title)

  -- volt draws its rules in `linenr`, which on most themes is the same weight
  -- as the numbers inside the table. Repainted faint, so the grid recedes and
  -- the figures are what you see -- a rule at content weight is the commonest
  -- way a terminal UI ends up looking busy.
  for _, line in ipairs(lines) do
    for _, cell in ipairs(line) do
      if cell[2] and cell[2]:lower() == "linenr" then
        cell[2] = opts.rule or "PaseoTextFaint"
      end
    end
  end

  return lines
end

---A bar or dot chart, ten rows tall.
---
---Ten rows because that is volt's quantisation: a value is bucketed to a
---decile and the height of the column carries the magnitude. Resolution comes
---from the ROW, and colour from `format_hl` -- which is why there is no
---`▁▂▃▄▅▆▇█` ramp here and does not need to be.
---@param values number[]  Each 0-100.
---@param opts? { dot?: boolean, w?: integer, gap?: integer, hl?: string|fun(v: number): string, labels?: fun(v: number): string, footer?: table[], sidelabels?: boolean }
---@return table[][]
function M.chart(values, opts)
  opts = opts or {}

  local baropts = {
    w = opts.w or 1,
    gap = opts.gap or 1,
    sidelabels = opts.sidelabels ~= false,
  }

  if type(opts.hl) == "function" then
    baropts.format_hl = opts.hl
  elseif opts.dot then
    baropts.hl = { on = opts.hl or "PaseoAgent", off = "PaseoTextFaint" }
  else
    baropts.hl = opts.hl or "PaseoAgent"
  end

  if opts.dot then
    -- The `off` glyph is drawn on every cell the value does not occupy, so the
    -- chart has a dot-grid background rather than empty space. That grid is
    -- most of why a sparse series still reads as a chart.
    baropts.icons = { on = " " .. style.BAR.dot_on, off = " " .. style.BAR.dot_off }
  else
    baropts.icon = style.BAR.block
  end

  local data =
    { val = values, baropts = baropts, format_labels = opts.labels, footer_label = opts.footer }
  return opts.dot and voltui.graphs.dot(data) or voltui.graphs.bar(data)
end

-- ---------------------------------------------------------------- accents

---A stable identity colour for an arbitrary name.
---
---Same repo, same colour, every redraw and every session -- which is the only
---property that makes a colour-coded list worth having. Hashed rather than
---assigned by position, because position changes when something is archived
---and a legend you have learned should not be reshuffled by that.
---@param name string
---@return integer  1-based index into the swatch palette.
function M.accent_for(name)
  local count = require("paseo.ui.theme").SWATCHES
  -- sha256 rather than a rolling `sum * 31 + byte`. That hash has almost no
  -- avalanche on short similar strings, and "paseo" and "paseo.nvim" -- which
  -- is exactly the pair a multi-repo unit of work puts next to each other --
  -- landed on the same colour.
  local digest = vim.fn.sha256(name)
  return (tonumber(digest:sub(1, 8), 16) % count) + 1
end

---A colour swatch for a name: the little dot that says which repo a row is in.
---
---From the SWATCH palette, not from the semantic accents. Four accents gave
---collisions in a list of four, and half of them already mean something --
---a repo drawn red read as a repo with a problem.
---@param name string
---@return table
function M.swatch(name)
  return { M.icons.swatch, "PaseoSwatch" .. M.accent_for(name) }
end

-- -------------------------------------------------------------- scrollbar

---A scrollbar as a column of cells, one per visible row.
---
---There was no scroll affordance anywhere except two ad-hoc `↑ N more` rows in
---the answer overlay, so a list longer than its pane looked exactly like a
---list that ended.
---
---Returns `h` cells rather than lines, so the caller appends one to the end of
---each row it is already drawing -- a separate gutter window would have to be
---kept in sync with the pane's scroll position, and this cannot fall out of
---step because it is drawn from the same numbers as the rows.
---@param offset integer  Rows scrolled past, 0-based.
---@param total integer   Rows in the whole list.
---@param h integer       Rows visible.
---@return table[]
function M.scrollbar(offset, total, h)
  local cells = {}

  -- Nothing to scroll: an empty gutter, not a full-height thumb. A thumb that
  -- fills the track says "there is more" as loudly as one that does not move.
  if total <= h or h <= 0 then
    for _ = 1, math.max(0, h) do
      cells[#cells + 1] = { " ", "PaseoTextFaint" }
    end
    return cells
  end

  local thumb = math.max(1, math.floor(h * h / total))
  local span = h - thumb
  local top = span > 0 and math.floor((offset / (total - h)) * span + 0.5) or 0
  top = math.max(0, math.min(span, top))

  for i = 0, h - 1 do
    local on = i >= top and i < top + thumb
    cells[#cells + 1] = on and { style.SCROLL.thumb, "PaseoBorder" }
      or { style.SCROLL.track, "PaseoTextFaint" }
  end
  return cells
end

-- ------------------------------------------------------------------ hover

---Actions for something that lights up under the pointer.
---
---volt's hover is four lines per widget and nothing in this plugin used it
---except the tab bar -- so every row in Sessions, Changes, Workspaces and
---Terminals was clickable but dead under the mouse, which reads as "not a
---button" right up until you click it and something happens.
---@param id string      Unique; volt stores it in `vim.g.nvmark_hovered`.
---@param redraw string|string[]  Section(s) to repaint on enter and leave.
---@param click? function|string
---@return table
function M.hover(id, redraw, click)
  return { click = click, hover = { id = id, redraw = redraw } }
end

---True while the pointer is over the thing with this id.
---@param id string
---@return boolean
function M.hovered(id)
  return vim.g.nvmark_hovered == id
end

---The background a list row should be drawn in.
---
---Hover and keyboard focus deliberately paint the SAME -- pointing at a row
---and moving to it are the same state, and showing them differently invites
---the reading that they mean different things.
---@param id string
---@param active? boolean
---@return string|nil
function M.row_hl(id, active)
  if active then
    return "PaseoRowActive"
  end
  if M.hovered(id) then
    return "PaseoRowHover"
  end
  return nil
end

---Paint a whole row in one background, action and all.
---
---The gaps carry the highlight and the action too, which is what makes the
---row a target across its full width rather than only where the text is --
---`menu/ui.lua` does the same, and it is the difference between a list you
---click and a list you aim at.
---@param line table[]
---@param w integer
---@param hl string|nil
---@param click? function|table
---@return table[]
function M.fill_row(line, w, hl, click)
  local out = {}
  for _, cell in ipairs(line) do
    out[#out + 1] = { cell[1], hl or cell[2], cell[3] or click }
  end
  render.pad(out, w, hl)
  for _, cell in ipairs(out) do
    cell[3] = cell[3] or click
  end
  return out
end

return M
