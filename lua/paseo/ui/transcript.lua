--- The conversation buffer: real lines, tracked in blocks.
---
--- Real lines rather than volt's virtual text, so `y`, `/`, `gg`, folds and
--- soft-wrap all keep working on an agent's reply. Volt draws the chrome around
--- this; it does not draw this.
---
--- A BLOCK is one rendered item -- a message, a tool card, a reasoning step.
--- Blocks are anchored by extmark rather than by line number, because a tool
--- call that starts at line 40 and finishes after three more messages have
--- arrived is no longer at line 40. `nvim_buf_set_lines` shifts extmarks for
--- us, so the anchor stays correct without any bookkeeping on our side.

local hl = require "paseo.ui.hl"
local render = require "paseo.ui.render"
local timeline = require "paseo.ui.timeline"

local api = vim.api

local M = {}

---How wide to render. Falls back to a sane fixed width when the chat has no
---window yet -- history can land before the split is made.
---@param chat table
---@return integer
function M.width(chat)
  local win = chat.win_conversation
  if win and api.nvim_win_is_valid(win) then
    -- Leave a column for the sign/fold gutter so a full-width card does not
    -- wrap and break the box drawing.
    return math.max(30, api.nvim_win_get_width(win) - 2)
  end
  return 72
end

---Make sure a chat has its block tables.
---
---`reset` runs in `initialise`, which happens AFTER the window is laid out --
---and the sidebar redraws on open. Without this, opening a chat onto an agent
---that already exists crashed on a nil `chat.order` before it drew anything.
---@param chat table
function M.ensure(chat)
  chat.blocks = chat.blocks or {}
  chat.order = chat.order or {}
  chat.by_call = chat.by_call or {}
  chat.next_id = chat.next_id or 1
end

---Reset a chat's block bookkeeping. Called on open and by `replaced`.
---@param chat table
function M.reset(chat)
  chat.blocks = {}
  chat.order = {}
  chat.by_call = {}
  chat.next_id = 1
  chat.open_text = nil
  chat.seq, chat.epoch = nil, nil

  if chat.conversation and api.nvim_buf_is_valid(chat.conversation) then
    vim.bo[chat.conversation].modifiable = true
    api.nvim_buf_set_lines(chat.conversation, 0, -1, false, {})
    api.nvim_buf_clear_namespace(chat.conversation, hl.ns, 0, -1)
    api.nvim_buf_clear_namespace(chat.conversation, hl.ns_anchor, 0, -1)
    vim.bo[chat.conversation].modifiable = false
  end
end

---Scroll to the bottom, but ONLY if we were already there.
---
---Scrolling back to reread something must not be yanked away by the next
---chunk. This is the one behaviour worth keeping verbatim from the old UI.
---@param chat table
local function follow(chat)
  local win = chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local total = api.nvim_buf_line_count(chat.conversation)
  if api.nvim_win_get_cursor(win)[1] >= total - 3 then
    pcall(api.nvim_win_set_cursor, win, { total, 0 })
  end
end

M.follow = follow

---@param chat table
---@param block table
---@return integer|nil row  0-indexed, or nil if the anchor is gone
local function row_of(chat, block)
  local mark = api.nvim_buf_get_extmark_by_id(chat.conversation, hl.ns_anchor, block.mark, {})
  return mark and mark[1]
end

---Draw a block's lines at `row`, replacing `height` existing lines.
---@param chat table
---@param block table
---@param row integer
---@param old_height integer
local function draw(chat, block, row, old_height)
  local card = timeline.card(block.item, {
    width = M.width(chat),
    expanded = block.expanded,
  })
  block.collapsible = card.collapsible

  -- Clear only THIS block's highlights. The anchor lives in a different
  -- namespace precisely so this does not delete it.
  api.nvim_buf_clear_namespace(chat.conversation, hl.ns, row, row + old_height)
  block.height = render.to_buffer(chat.conversation, hl.ns, row, row + old_height, card.lines)
end

---Append a new block to the end of the transcript.
---@param chat table
---@param item table
---@return table block
function M.append(chat, item)
  M.ensure(chat)
  local buf = chat.conversation
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return {}
  end

  local row = api.nvim_buf_line_count(buf)
  -- A brand-new scratch buffer reports one line that is actually empty;
  -- appending after it would leave a blank first row forever.
  if row == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    row = 0
  end

  local block = {
    id = chat.next_id,
    kind = item.kind,
    call_id = item.callId,
    item = item,
    expanded = false,
    height = 0,
  }
  chat.next_id = chat.next_id + 1

  -- `right_gravity = false` keeps the anchor ON this block's first line when
  -- text is inserted at exactly that position, rather than being pushed down
  -- ahead of it.
  vim.bo[buf].modifiable = true
  block.mark = api.nvim_buf_set_extmark(buf, hl.ns_anchor, row, 0, { right_gravity = false })
  vim.bo[buf].modifiable = false

  draw(chat, block, row, 0)

  chat.blocks[block.id] = block
  chat.order[#chat.order + 1] = block.id
  if block.call_id then
    chat.by_call[block.call_id] = block.id
  end

  follow(chat)
  return block
end

---Re-render an existing block in place.
---@param chat table
---@param block table
---@param item table|nil  New item data; keeps the old if omitted.
function M.rerender(chat, block, item)
  if item then
    block.item = item
  end
  local row = row_of(chat, block)
  if not row then
    return
  end
  draw(chat, block, row, block.height)
  follow(chat)
end

---The single entry point for an incoming item.
---
---A tool call arrives TWICE -- running, then completed -- under one `callId`.
---The second one must replace the first rather than append, or every command
---appears in the transcript twice.
---@param chat table
---@param item table
---@return table block
function M.upsert(chat, item)
  M.ensure(chat)
  if item.callId and chat.by_call[item.callId] then
    local block = chat.blocks[chat.by_call[item.callId]]
    if block then
      -- Anything other than assistant text ends the open reply, so the next
      -- chunk starts a new paragraph below the card instead of being spliced
      -- onto the sentence that preceded it.
      chat.open_text = nil
      M.rerender(chat, block, item)
      return block
    end
  end

  if item.kind ~= "text" then
    chat.open_text = nil
  end
  return M.append(chat, item)
end

---Assistant text, which arrives in PIECES.
---
---A reply delivered as "READ" + "Y" must render as READY. The old code
---concatenated onto the last BUFFER line, which was fine when the transcript
---was nothing but messages and silently corrupts a tool card that arrived
---mid-reply. Here it appends to the open text block's own data and re-renders
---just that block.
---@param chat table
---@param text string
function M.stream(chat, text)
  if text == "" then
    return
  end

  local block = chat.open_text and chat.blocks[chat.open_text]
  if not block then
    block = M.append(chat, { kind = "text", text = text })
    chat.open_text = block.id
    return
  end

  block.item.text = (block.item.text or "") .. text
  M.rerender(chat, block)
end

---Expand or collapse the block under the cursor.
---@param chat table
function M.toggle_at_cursor(chat)
  M.ensure(chat)
  local win = chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local row = api.nvim_win_get_cursor(win)[1] - 1

  -- Walk BACKWARDS from the cursor to the nearest anchor: the cursor is
  -- usually in the middle of a card, not on its first line.
  local marks = api.nvim_buf_get_extmarks(
    chat.conversation,
    hl.ns_anchor,
    { row, 0 },
    { 0, 0 },
    { limit = 1 }
  )
  local mark_id = marks[1] and marks[1][1]
  if not mark_id then
    return
  end

  for _, block in pairs(chat.blocks) do
    if block.mark == mark_id then
      if not block.collapsible then
        return
      end
      block.expanded = not block.expanded
      M.rerender(chat, block)
      -- Put the cursor back on the card's header, so repeated <Tab> toggles the
      -- same card rather than walking off the end of a shrinking one.
      local at = row_of(chat, block)
      if at then
        pcall(api.nvim_win_set_cursor, win, { at + 1, 0 })
      end
      return
    end
  end
end

---Re-render everything at the current width. For a window resize.
---@param chat table
function M.redraw(chat)
  M.ensure(chat)
  if not (chat.conversation and api.nvim_buf_is_valid(chat.conversation)) then
    return
  end
  for _, id in ipairs(chat.order) do
    local block = chat.blocks[id]
    if block then
      M.rerender(chat, block)
    end
  end
end

return M
