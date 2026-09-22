--- The dashboard's row budget, in one place.
---
--- The chrome is a fixed stack -- a tab bar, a rule, the body, a footer -- and
--- three separate files were each doing the arithmetic for it
--- from first principles. `float.body_lines` knew the body was `height - 4`,
--- `float.panes` knew the first body row was `row + 3` and that the footer
--- owned the last row, and `panels/terminals.lua` knew both AND carried a bare
--- `local at = row - 5` to turn a cursor line back into a list index.
---
--- Three copies of one number that must agree, none of which mentions the
--- others. Adding a row to the chrome meant finding all three, and the one
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
---parts rather than written down. The session strip is what made that
---difference real, twice: adding a row to the chrome and then taking it away
---again were both a change to this table and to nothing else.
---
---There is no header among them, and no strip either. The session's model,
---mode, usage and directory are drawn on the bar over the composer; WHICH
---session that is, is drawn at the right-hand end of the tab bar. A row of
---chips under the tabs was a second navigation bar directly beneath the first
---one, and the two disagreed about what they were for.
M.PARTS = { tabs = 1, rule = 1, footer = 1 }

---Rows the chrome spends on itself, above and below the body.
---
---Above: the tab bar and the rule under it.
---Below: the footer.
M.CHROME = {
  above = M.PARTS.tabs + M.PARTS.rule,
  below = M.PARTS.footer,
}

---@class paseo.Layout.Rows
---@field tabs integer      Buffer row of the tab bar.
---@field rule integer      Buffer row of the rule under the tabs.
---@field body_first integer  First buffer row the active panel gets.
---@field body_last integer   Last one.
---@field body_height integer
---@field footer integer

---Where each part of the chrome lives, in 1-based BUFFER rows.
---
---The same on every tab. The tab bar is the first row of the dashboard, and
---the body starts at the same place whichever tab you are on -- so switching
---tabs moves nothing under you.
---@param height integer  The chrome window's height, in cells.
---@return paseo.Layout.Rows
function M.rows(height)
  local above = M.CHROME.above
  local body_height = math.max(0, height - above - M.CHROME.below)
  return {
    tabs = 1,
    rule = 2,
    body_first = above + 1,
    body_last = above + body_height,
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
---first line of the body, which on the Chat tab is blank by construction. A
---panel drawing real content there is what turns that into a row you can only
---see the last three columns of.
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
---@param opts? { framed?: boolean }  The composer has a drawn box, which only
---                   `ui.style`'s `rounded` and `square` give it. Unframed it
---                   still costs one row more than its content: the bar above
---                   it, which is a `winbar` and therefore inside the window.
---@return { top: integer, col: integer, width: integer, conversation: integer, composer_row: integer, composer: integer, frame: integer, body: { row: integer, col: integer, width: integer, height: integer } }
function M.panes(g, composer_h, opts)
  -- The panes only ever cover the Chat tab, and the chrome's rows are the
  -- same on every tab.
  local rows = M.rows(g.height)
  local top = M.screen_row(g, rows.body_first)
  composer_h = math.max(1, math.min(composer_h or g.composer, g.composer))

  -- WHAT THE BOX COSTS BESIDE ITS TEXT. The bar above it is a `winbar`, so it
  -- is INSIDE the window and comes out of the window's height -- that is the
  -- `+ 1` every caller adds to `composer`. A FRAME is outside it: two more
  -- rows, and `nvim_open_win` is handed the border's row rather than the
  -- content's. Either way the bottom of the box lands on the last body row,
  -- never a row lower, because a row lower is the footer -- which is the row
  -- that says which keys the surface has.
  local frame = (opts and opts.framed) and 2 or 0
  local composer_row = M.screen_row(g, rows.body_last) - composer_h - frame

  local col, width = g.col + 2, g.width - 4
  return {
    top = top,
    col = col,
    width = width,
    -- One row of gap between the conversation and the top of the box.
    conversation = math.max(5, composer_row - 1 - top),
    composer_row = composer_row,
    -- TEXT rows. The window is one taller than this -- the bar -- and, when
    -- the style frames it, two rows wider than the window on screen.
    composer = composer_h,
    frame = frame,
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
