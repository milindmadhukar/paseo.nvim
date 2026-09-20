--- One line vocabulary, two sinks.
---
--- A CELL is `{ text, highlight }` and a LINE is a list of cells -- exactly the
--- shape volt's `draw` consumes, so the same builder feeds both surfaces:
---
---   * `to_volt`   -- hand the lines to volt, which draws them as `virt_text`
---                    extmarks. Used for the header, the panels and the
---                    permission dialog: fixed-size chrome.
---   * `to_buffer` -- write the lines as REAL buffer text and colour them with
---                    one extmark per cell. Used for the transcript.
---
--- Why the transcript is not volt: volt renders virtual text, and virtual text
--- cannot be yanked, searched with `/`, or soft-wrapped. For a header that is
--- irrelevant; for an agent's reply with a code block in it, it is the
--- difference between a UI and a picture of one.

local M = {}

local api = vim.api
local strwidth = api.nvim_strwidth

-- ------------------------------------------------------------------ hygiene

---Collapse a cell's text onto ONE line.
---
---Not defensive padding: a real multi-line shell command comes back with
---newlines in `display.summary`, and both sinks reject them --
---`nvim_buf_set_lines` errors with "'replacement string' item contains
---newlines", and a `virt_text` chunk containing one is equally invalid. A
---single agent history with a heredoc in it was enough to hit this.
---
---Tabs go too: they render as a variable number of columns, so a line
---containing one is never the width it was measured at, and every box drawn
---around it is ragged.
---@param text string
---@return string
local function flatten(text)
  if not text:find "[\n\r\t]" then
    return text
  end
  return (text:gsub("[\n\r]+", " ⏎ "):gsub("\t", "  "))
end

---Normalise a whole line's cells. Idempotent and cheap on the common path.
---@param line table[]
---@return table[]
function M.flatten(line)
  local out = {}
  for i, cell in ipairs(line) do
    out[i] = { flatten(cell[1] or ""), cell[2], cell[3] }
  end
  return out
end

-- ------------------------------------------------------------------- measuring

---Display width of a line, in columns.
---@param line table[]
---@return integer
function M.width(line)
  local w = 0
  for _, cell in ipairs(line) do
    w = w + strwidth(cell[1] or "")
  end
  return w
end

---The plain text of a line, with the highlights dropped.
---@param line table[]
---@return string
function M.concat(line)
  local parts = {}
  for i, cell in ipairs(line) do
    parts[i] = cell[1] or ""
  end
  return table.concat(parts)
end

---Pad a line out to `w` columns.
---@param line table[]
---@param w integer
---@param hl? string
---@return table[]
function M.pad(line, w, hl)
  local gap = w - M.width(line)
  if gap > 0 then
    line[#line + 1] = { string.rep(" ", gap), hl }
  end
  return line
end

---Truncate a line to `w` columns, with an ellipsis if anything was cut.
---@param line table[]
---@param w integer
---@return table[]
function M.truncate(line, w)
  -- Flatten BEFORE measuring. Doing it at the sink instead would widen a line
  -- after the box around it had already been sized, and every card whose
  -- summary contained a newline would draw ragged.
  line = M.flatten(line)
  if M.width(line) <= w then
    return line
  end
  local out, used = {}, 0
  for _, cell in ipairs(line) do
    local cw = strwidth(cell[1] or "")
    if used + cw <= w - 1 then
      out[#out + 1] = cell
      used = used + cw
    else
      -- Cut INSIDE this cell, by display width rather than bytes, so a
      -- multibyte path does not get sliced mid-character.
      local room = w - 1 - used
      if room > 0 then
        local text = cell[1] or ""
        local taken = ""
        for _, char in ipairs(vim.fn.split(text, "\\zs")) do
          if strwidth(taken .. char) > room then
            break
          end
          taken = taken .. char
        end
        out[#out + 1] = { taken, cell[2] }
      end
      out[#out + 1] = { require("paseo.ui.icons").marker.ellipsis, "PaseoDim" }
      return out
    end
  end
  return out
end

-- -------------------------------------------------------------------- wrapping

---Split plain text into lines of cells, wrapped at `w` columns on word
---boundaries. Used for assistant prose and permission descriptions.
---@param text string
---@param w integer
---@param hl? string
---@param prefix? table[]  Cells repeated at the start of every wrapped line.
---@return table[][]
function M.wrap(text, w, hl, prefix)
  local lines = {}
  local lead = prefix and M.width(prefix) or 0
  local room = math.max(8, w - lead)

  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    if paragraph == "" then
      lines[#lines + 1] = vim.deepcopy(prefix or {})
    else
      local current = ""
      for word in paragraph:gmatch "%S+" do
        local candidate = current == "" and word or (current .. " " .. word)
        if strwidth(candidate) > room and current ~= "" then
          local line = vim.deepcopy(prefix or {})
          line[#line + 1] = { current, hl }
          lines[#lines + 1] = line
          current = word
        else
          current = candidate
        end
      end
      if current ~= "" then
        local line = vim.deepcopy(prefix or {})
        line[#line + 1] = { current, hl }
        lines[#lines + 1] = line
      end
    end
  end

  return lines
end

-- ----------------------------------------------------------------------- cards

---How many columns a card's body actually gets at `w`.
---
---A framed card spends two columns on its sides that an unframed one does not,
---so anything wrapping text to fit inside a card has to ask rather than
---assume: hardcoding either number truncates under the other style.
---@param w integer
---@param kind? string
---@return integer
function M.card_inner(w, kind)
  kind = kind or require("paseo.ui.style").get().card
  local framed = kind == "rounded" or kind == "square"
  return math.max(4, w - (framed and 4 or 2))
end

---A card: a header line, then a body.
---
---Used for tool calls in the transcript AND for the `detail` of a permission
---request, which is the point of having one builder -- approving a command
---shows you the same card you would have seen it run as.
---
---Honours `ui.style` like every other card, so the transcript and the
---dashboard cannot drift apart again. The two framed styles put the header IN
---the top border; the two unframed ones replace the frame with a one-column
---accent bar down the left edge, carrying the same colour the border would
---have -- which is how a failed card still reads as failed without a box
---around it. That bar is the same shape as the `▌` gutter a user message
---already gets, so the transcript has one visual grammar rather than two.
---
---A COLLAPSED card -- no body -- is always exactly one line. A transcript full
---of three-line boxes for "read a file" is unreadable, and that is true in
---every style.
---@param header table[]
---@param body table[][]
---@param opts { width: integer, hl?: string, kind?: string }
---@return table[][]
function M.card(header, body, opts)
  local style = require "paseo.ui.style"
  local hl = opts.hl or "PaseoBorder"
  local w = opts.width
  local collapsed = #body == 0
  local kind = opts.kind or style.get().card
  local box = style.BOX[kind]

  local lines = {}

  if not box then
    -- Unframed. The accent bar is two columns -- the glyph and a space -- so
    -- the content lines up with the framed styles' "│ " to the cell.
    local bar = { require("paseo.ui.icons").marker.mine .. " ", hl }
    local inner = math.max(10, M.card_inner(w, kind))

    local head = { vim.deepcopy(bar) }
    vim.list_extend(head, M.truncate(vim.deepcopy(header), inner))
    lines[#lines + 1] = head

    if collapsed then
      return lines
    end

    if kind == "rule" then
      lines[#lines + 1] = {
        vim.deepcopy(bar),
        { string.rep(style.BOX.square.h, math.max(0, w - 3)), "PaseoCardRule" },
      }
    end

    for _, line in ipairs(body) do
      local row = { vim.deepcopy(bar) }
      vim.list_extend(row, M.truncate(vim.deepcopy(line), inner))
      lines[#lines + 1] = row
    end

    return lines
  end

  local inner = math.max(10, M.card_inner(w, kind))

  -- The header sits IN the top border, so a collapsed card is ONE line of
  -- box-drawing rather than three lines wrapped around one fact.
  -- The header's budget is NOT `inner`: it has to leave room for the opening
  -- "╭─ ", the space before the rule, and the closing corner. Giving it
  -- `inner` made every card whose summary was long enough to truncate come out
  -- exactly one column too wide.
  local top = { { box.tl .. box.h .. " ", hl } }
  vim.list_extend(top, M.truncate(vim.deepcopy(header), math.max(8, w - 5)))
  -- `w - 2` leaves room for the closing corner and the space that separates
  -- the header text from the rule, so it reads "✓ Shell  ls -la ─────╮".
  local rule = math.max(0, w - 2 - M.width(top))
  top[#top + 1] = { " " .. string.rep(box.h, rule) .. (collapsed and box.br or box.tr), hl }
  lines[#lines + 1] = top

  if collapsed then
    return lines
  end

  for _, line in ipairs(body) do
    local row = { { box.v .. " ", hl } }
    vim.list_extend(row, M.truncate(vim.deepcopy(line), inner))
    M.pad(row, w - 1)
    row[#row + 1] = { box.v, hl }
    lines[#lines + 1] = row
  end

  lines[#lines + 1] = { { box.bl .. string.rep(box.h, math.max(0, w - 2)) .. box.br, hl } }
  return lines
end

-- ------------------------------------------------------------------- the sinks

---Hand lines to volt.
---
---This DEEP COPIES, and that is not defensive style -- it is required.
---`volt/draw.lua:42` runs `table.remove(marks, 3)` over the lines it is given,
---permanently stripping the third element from every cell. Hand volt a table
---you intend to reuse and the actions vanish from it after the first draw, so
---the second redraw of a panel silently loses every click target.
---@param lines table[][]
---@return table[][]
function M.to_volt(lines)
  local out = {}
  for i, line in ipairs(lines) do
    -- flatten() already builds new cell tables, so this is the deep copy too.
    out[i] = M.flatten(line)
  end
  return out
end

---Render one line into a `winbar`/`statusline` string.
---
---The third sink, and the cheapest: the sidebar's header needs no window and no
---buffer of its own, which also means it cannot collide with volt's
---`modifiable = false`.
---@param line table[]
---@return string
function M.to_winbar(line)
  local parts = {}
  for _, cell in ipairs(M.flatten(line)) do
    -- `%` is the statusline escape character, so a path or a command
    -- containing one would be read as a format item and eat the rest.
    local text = (cell[1] or ""):gsub("%%", "%%%%")
    parts[#parts + 1] = cell[2] and ("%%#%s#%s%%*"):format(cell[2], text) or text
  end
  return table.concat(parts)
end

---Write lines as REAL buffer text, coloured with one extmark per cell.
---
---Replaces rows `[first, last)`. Pass `first == last` to insert without
---removing. Returns how many lines were written, which is what the caller needs
---to know to replace this block again later (a tool card changes height when it
---finishes).
---@param buf integer
---@param ns integer
---@param first integer  0-indexed, inclusive
---@param last integer   0-indexed, exclusive; -1 for "to the end"
---@param lines table[][]
---@return integer written
function M.to_buffer(buf, ns, first, last, lines)
  if not api.nvim_buf_is_valid(buf) then
    return 0
  end

  local text = {}
  local safe = {}
  for i, line in ipairs(lines) do
    safe[i] = M.flatten(line)
    text[i] = M.concat(safe[i])
  end
  lines = safe

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, first, last, false, text)

  for i, line in ipairs(lines) do
    local row = first + i - 1
    -- Extmark columns are BYTE offsets, not display columns -- using
    -- `strwidth` here would misplace every highlight after a multibyte
    -- character, which the box-drawing borders guarantee there will be.
    local col = 0
    for _, cell in ipairs(line) do
      local bytes = #(cell[1] or "")
      if cell[2] and bytes > 0 then
        pcall(api.nvim_buf_set_extmark, buf, ns, row, col, {
          end_col = col + bytes,
          hl_group = cell[2],
          -- The transcript buffer is `filetype=markdown`, so treesitter is also
          -- highlighting it. Its captures sit at the default priority of 100,
          -- and without this our tool-card borders and role labels lose to
          -- whatever markdown thinks a line beginning with `│` is.
          priority = 200,
        })
      end
      col = col + bytes
    end
  end

  vim.bo[buf].modifiable = modifiable
  return #lines
end

return M
