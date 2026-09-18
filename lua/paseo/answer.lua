--- The answer window.
---
--- The reply lands in a split, not in the agent's terminal. That is the whole
--- point of streaming it back: the loop is "find the hunk, read it, stage it or
--- ask about it, next hunk", and switching to a terminal to read the answer is
--- exactly the context switch that breaks it. You keep the quickfix list, the
--- diff and the answer on screen together.

local M = {}

local state = { buf = nil, win = nil }

---@return integer bufnr
local function buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_name(buf, "paseo://answer")
  vim.keymap.set("n", "q", function()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, false)
    end
  end, { buffer = buf, desc = "Close the answer" })
  state.buf = buf
  return buf
end

---Show the window without stealing the cursor: you asked the question from
---somewhere, and that is where you want to still be.
---@return integer winid
function M.open()
  local buf = buffer()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return state.win
  end

  local from = vim.api.nvim_get_current_win()
  vim.cmd "botright vsplit"
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, buf)
  vim.wo[state.win].wrap = true
  vim.wo[state.win].linebreak = true
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.api.nvim_set_current_win(from)
  return state.win
end

---Replace the contents and show a header.
---@param header string
function M.begin(header)
  local buf = buffer()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# " .. header, "", "_waiting…_" })
  vim.bo[buf].modifiable = false
  M.open()
end

---Append streamed text.
---
---Assistant messages arrive in PIECES, so this appends to the last line rather
---than adding one per event -- otherwise a sentence delivered in six chunks
---becomes six lines.
---@param text string
function M.append(text)
  local buf = buffer()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.bo[buf].modifiable = true
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if lines[#lines] == "_waiting…_" then
    table.remove(lines)
  end

  local incoming = vim.split(text, "\n", { plain = true })
  lines[#lines] = (lines[#lines] or "") .. incoming[1]
  for i = 2, #incoming do
    lines[#lines + 1] = incoming[i]
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Follow the output only while the cursor is already at the bottom, so
  -- scrolling back to reread something is not yanked away by the next chunk.
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    if cursor[1] >= #lines - #incoming then
      pcall(vim.api.nvim_win_set_cursor, state.win, { #lines, 0 })
    end
  end
end

---@param note string
function M.finish(note)
  M.append("\n\n---\n_" .. note .. "_\n")
end

return M
