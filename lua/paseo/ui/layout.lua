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
---`g.row` is the chrome's first CONTENT row -- its border is drawn outside the
---window -- so buffer line 1 is at `g.row`, not at `g.row + 1`.
---@param g table
---@param row integer
---@return integer
function M.screen_row(g, row)
  return g.row + row - 1
end

---Screen geometry for the panes floated over the body.
---
---`body` is the whole of it, which is what a session with no composer gets --
---a terminal fills the panel area outright. It shares `col` and `width` with
---the conversation deliberately: switching between an agent session and a
---terminal one must not shift the left edge under you.
---@param g table  The float's geometry.
---@return { top: integer, col: integer, width: integer, conversation: integer, composer_row: integer, composer: integer, body: { row: integer, col: integer, width: integer, height: integer } }
function M.panes(g)
  local rows = M.rows(g.height)
  local top = M.screen_row(g, rows.body_first)
  local composer_h = g.composer

  -- The composer is bordered, so its bottom border sits one row BELOW its last
  -- content row. Putting that border on the last body row -- rather than a row
  -- further down, where the footer is -- means the composer's content starts
  -- `composer_h` rows above it.
  local composer_row = M.screen_row(g, rows.body_last) - composer_h

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

return M
