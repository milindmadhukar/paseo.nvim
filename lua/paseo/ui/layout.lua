--- The dashboard's row budget, in one place.
---
--- The chrome is a fixed stack -- a header, a tab bar, a rule, the body, a
--- footer -- and three separate files were each doing the arithmetic for it
--- from first principles. `float.body_lines` knew the body was `height - 4`,
--- `float.panes` knew the first body row was `row + 3` and that the footer
--- owned the last row, and `panels/terminals.lua` knew both AND carried a bare
--- `local at = row - 5` to turn a cursor line back into a list index.
---
--- Three copies of one number that must agree, none of which mentions the
--- others. Adding a row to the header meant finding all three, and the one
--- that got missed would not error -- it would simply put the terminal list's
--- click targets one row off, which reads as "clicking does nothing" rather
--- than as a layout bug.
---
--- So: stated once, here, and derived from named parts rather than from
--- literals, so the next row added to the chrome is a change to `CHROME` and
--- nothing else.

local M = {}

---The chrome's parts, each one row tall.
---
---Named rather than summed into a literal, which is what `above = 3` was --
---in the file whose whole argument is that the number should be derived from
---parts rather than written down. Adding the session strip was the change that
---made that difference real: with a literal it is "find every 3 and hope".
M.PARTS = { header = 1, tabs = 1, rule = 1, strip = 1, footer = 1 }

---Rows the chrome spends on itself, above and below the body.
---
---Above: the header, the tab bar, the rule under it, the session strip.
---Below: the footer.
M.CHROME = {
  above = M.PARTS.header + M.PARTS.tabs + M.PARTS.rule + M.PARTS.strip,
  below = M.PARTS.footer,
}

---@class paseo.Layout.Rows
---@field header integer    Buffer row of the header.
---@field tabs integer      Buffer row of the tab bar.
---@field rule integer      Buffer row of the rule under the tabs.
---@field strip integer     Buffer row of the session strip.
---@field body_first integer  First buffer row the active panel gets.
---@field body_last integer   Last one.
---@field body_height integer
---@field footer integer

---Where each part of the chrome lives, in 1-based BUFFER rows.
---@param height integer  The chrome window's height, in cells.
---@return paseo.Layout.Rows
function M.rows(height)
  local body_height = math.max(0, height - M.CHROME.above - M.CHROME.below)
  return {
    header = 1,
    tabs = 2,
    rule = 3,
    strip = 4,
    body_first = M.CHROME.above + 1,
    body_last = M.CHROME.above + body_height,
    body_height = body_height,
    footer = height,
  }
end

---The screen row a 1-based BUFFER row of the chrome sits on.
---
---`g.row` is what `nvim_open_win` was HANDED, and for a bordered window that
---is the border's own row -- the frame is drawn from there and the first
---content row is one below it. So buffer line 1 sits at `g.row + 1` whenever
---the chrome has a border, which is every `ui.style` except `border = "none"`.
---
---This was off by one, and invisible for as long as the first row the panes
---covered was a row with nothing on it. `body_first` was 4, this answered
---`g.row + 3`, and the conversation was floated one row too high -- over the
---first line of the body, which on the Chat tab is blank by construction. The
---session strip put real content there and the bug became a strip you could
---only see the last three columns of.
---
---`g.border` says which: the caller knows what it opened the window with.
---@param g table
---@param row integer
---@return integer
function M.screen_row(g, row)
  return g.row + (g.border and 1 or 0) + row - 1
end

---Screen geometry for the panes floated over the body.
---
---`body` is the whole of it, which is what a session with no composer gets --
---a terminal fills the panel area outright. It shares `col` and `width` with
---the conversation deliberately: switching between an agent session and a
---terminal one must not shift the left edge under you.
---@param g table  The float's geometry.
---@param composer_h? integer  Rows the composer wants RIGHT NOW. Absent means
---                   the configured maximum. The composer grows with what you
---                   have typed rather than standing at its full height over
---                   an empty buffer, so this is a function of the content and
---                   not of the config alone -- see `float.composer_rows`.
---@return { top: integer, col: integer, width: integer, conversation: integer, composer_row: integer, composer: integer, body: { row: integer, col: integer, width: integer, height: integer } }
function M.panes(g, composer_h)
  local rows = M.rows(g.height)
  local top = M.screen_row(g, rows.body_first)
  composer_h = math.max(1, math.min(composer_h or g.composer, g.composer))

  -- The composer is BORDERED, and `nvim_open_win` is handed the border's row,
  -- not the content's -- so the window costs `composer_h + 2` rows and its
  -- bottom border sits at `row + composer_h + 1`. Putting that border on the
  -- last body row, rather than a row further down where the footer is, is what
  -- the `- 1` buys: without it the composer covers the footer, which is the
  -- row that says which keys the surface has.
  local composer_row = M.screen_row(g, rows.body_last) - composer_h - 1

  local col, width = g.col + 2, g.width - 4
  return {
    top = top,
    col = col,
    width = width,
    -- One row of gap between the conversation and the composer's top border.
    conversation = math.max(5, composer_row - 1 - top),
    composer_row = composer_row,
    composer = composer_h,
    body = { row = top, col = col, width = width, height = rows.body_height },
  }
end

---Rows the composer should get for what is in it, between `min` and `max`.
---
---Measured in SCREEN rows, not buffer lines. The composer soft-wraps, and a
---sixty-column sidebar turns one pasted sentence into three rows -- so a box
---that counted lines would say "1" while holding three rows of text, which is
---a box you type into blind. `prompt.lua` counts lines because its own box is
---78 columns wide and wrapping is the exception there; here it is the rule.
---
---Three ways of asking, best first, because the two surfaces ask at different
---moments: the float sizes the pane BEFORE opening it, and the sidebar fits a
---window that already exists.
---
---`nvim_win_text_height` measures against the window's WIDTH, so changing the
---height cannot change the answer. That is what makes the fit converge in one
---pass instead of oscillating against its own resize event.
---@param opts { buf: integer, win?: integer, width?: integer, min?: integer, max: integer }
---@return integer
function M.composer_rows(opts)
  if not (opts.buf and vim.api.nvim_buf_is_valid(opts.buf)) then
    return math.max(opts.min or 1, 1)
  end

  local rows
  -- The window's own answer, when there is a window. This is the only one that
  -- is exactly right: it knows about 'linebreak', tabs, and characters wider
  -- than one cell, none of which dividing a display width by a column count
  -- can account for.
  if opts.win and vim.api.nvim_win_is_valid(opts.win) then
    local ok, height = pcall(vim.api.nvim_win_text_height, opts.win, {})
    rows = ok and height and height.all or nil
  end

  -- Before the window exists -- `show_chat_panes` sizes the pane it is about
  -- to open -- the width it is ABOUT to have is the next best thing.
  if not rows and opts.width and opts.width > 0 then
    rows = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(opts.buf, 0, -1, false)) do
      rows = rows + math.max(1, math.ceil(vim.api.nvim_strwidth(line) / opts.width))
    end
  end

  rows = rows or vim.api.nvim_buf_line_count(opts.buf)
  return math.max(opts.min or 1, math.min(opts.max, rows))
end

return M
