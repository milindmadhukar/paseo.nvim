--- The "thinking…" line under the transcript while the agent works.
---
--- WHY IN THE BUFFER. The spinner on the composer bar and the winbar says the
--- same thing, but it is small and off to one side. Between your first message
--- and the first word back there is often a long pause, and with the rail shut
--- the conversation itself showed nothing -- a chat that is working looked
--- exactly like one that had died. This puts the answer where you are looking:
--- right under the last thing said.
---
--- VIRTUAL, NOT A REAL LINE. The transcript's real lines are blocks, and
--- |paseo.ui.transcript| does line arithmetic on them (`append` writes at the
--- line count, a lone empty line is overwritten). A line belonging to no block
--- would break both. So this is one extmark in its own namespace, carrying a
--- virtual line BELOW the buffer's last line, moved down whenever a block
--- lands.
---
--- Neovim does not scroll a virtual line below the last buffer line into view
--- on its own -- a cursor on the last line is "at the bottom" with the virtual
--- line still clipped under it. `reveal` scrolls the difference, and only for a
--- window that was already following the end.

local api = vim.api
local hl = require "paseo.ui.hl"

local M = {}

---What the line says. One table so the test and the draw agree.
M.TEXT = "thinking…"

---@param chat table
---@return integer|nil
local function buffer(chat)
  local buf = chat.conversation
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
end

---@param chat table
---@return integer|nil
local function window(chat)
  local win, buf = chat.win_conversation, buffer(chat)
  if win and buf and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    return win
  end
end

---Should the line be there? Working, by the same flag the bar spins on.
---@param chat table
---@return boolean
function M.wanted(chat)
  return chat.streaming == true and buffer(chat) ~= nil
end

---The virtual line itself.
---@return table[]
local function line()
  local widgets = require "paseo.ui.widgets"
  return {
    -- Flush left, where every block's first glyph is.
    { widgets.spinner() .. " ", "PaseoToolRunning" },
    { M.TEXT, "PaseoThinking" },
  }
end

---Put the line under the buffer's last line, or take it away. No scrolling:
---this is what a block's redraw calls, and the redraw decides that.
---@param chat table
function M.pin(chat)
  local buf = buffer(chat)
  if not buf then
    chat.pending_mark = nil
    return
  end
  if not M.wanted(chat) then
    if chat.pending_mark then
      pcall(api.nvim_buf_del_extmark, buf, hl.ns_pending, chat.pending_mark)
      chat.pending_mark = nil
    end
    return
  end
  local last = api.nvim_buf_line_count(buf) - 1
  local ok, id = pcall(api.nvim_buf_set_extmark, buf, hl.ns_pending, last, 0, {
    id = chat.pending_mark,
    virt_lines = { line() },
    virt_lines_above = false,
  })
  chat.pending_mark = ok and id or nil
end

---How many virtual lines hang BELOW the buffer's last line, from anyone:
---this line, and a thumbnail under the last message (|paseo.ui.images|).
---@param buf integer
---@param last integer  0-indexed
---@return integer
local function below_last(buf, last)
  local rows = 0
  local ok, marks = pcall(api.nvim_buf_get_extmarks, buf, -1, { last, 0 }, { last, -1 }, {
    details = true,
    type = "virt_lines",
  })
  for _, mark in ipairs(ok and marks or {}) do
    local details = mark[4] or {}
    if details.virt_lines and not details.virt_lines_above then
      rows = rows + #details.virt_lines
    end
  end
  return rows
end

---Scroll just far enough that the line is on screen, when the window is
---showing the end of the transcript. A window you scrolled up in is left
---alone.
---
---Everything virtual under the last line counts, not only this one: a picture
---under the last message is clipped by exactly the same rule.
---@param chat table
function M.reveal(chat)
  local win = window(chat)
  if not win then
    return
  end
  local buf = chat.conversation
  local count = api.nvim_buf_line_count(buf)
  if vim.fn.line("w$", win) < count then
    return
  end
  local below = below_last(buf, count - 1)
  if below == 0 then
    return
  end
  local top = vim.fn.line("w0", win)
  -- `nvim_win_text_height` stops at the end of `end_row` and does not count
  -- the virtual lines below it, which are exactly the ones in question.
  local ok, size = pcall(api.nvim_win_text_height, win, { start_row = top - 1, end_row = count - 1 })
  if not ok then
    return
  end
  local over = size.all + below - api.nvim_win_get_height(win)
  if over > 0 then
    api.nvim_win_call(win, function()
      vim.cmd(("noautocmd normal! %d\5"):format(over))
    end)
  end
end

---Pin, then reveal. For the streaming flag changing and the spinner's tick --
---the moments nothing was written, so asking "at the bottom?" now is sound.
---@param chat table
function M.draw(chat)
  M.pin(chat)
  M.reveal(chat)
end

---Forget the mark: the buffer it was in has just been emptied.
---@param chat table
function M.forget(chat)
  local buf = buffer(chat)
  if buf then
    api.nvim_buf_clear_namespace(buf, hl.ns_pending, 0, -1)
  end
  chat.pending_mark = nil
end

return M
