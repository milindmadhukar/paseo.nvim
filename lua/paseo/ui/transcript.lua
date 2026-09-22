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
  -- The blocks are gone, so nothing is drawn at that width any more. Without
  -- this, a chat reset and refetched at the SAME width -- which is every
  -- `replaced` -- guards itself out of ever drawing its new history.
  chat.rendered_width = nil

  -- The permission bookkeeping goes with the blocks it points at.
  --
  -- `chat.permission_blocks` maps a request id to a BLOCK id, and every block
  -- just went away. Leaving the map behind left it naming blocks that no
  -- longer exist, so the resolution badge could never be written again; and
  -- leaving `chat.permissions` behind meant the re-offer that follows a reset
  -- hit the de-duplicate and returned early, taking the inline card with it.
  -- The requests themselves are not lost -- `reconcile` puts back whatever the
  -- daemon still considers pending, which is the authority on that anyway.
  -- And the half-finished answers with them: `chat.answer_state` is keyed by
  -- request id, and a reset means a different conversation. Picks resumed into a
  -- request the daemon no longer has are answers to a question nobody asked.
  chat.permissions = {}
  chat.permission_blocks = {}
  chat.answer_state = {}

  if chat.conversation and api.nvim_buf_is_valid(chat.conversation) then
    vim.bo[chat.conversation].modifiable = true
    api.nvim_buf_set_lines(chat.conversation, 0, -1, false, {})
    api.nvim_buf_clear_namespace(chat.conversation, hl.ns, 0, -1)
    api.nvim_buf_clear_namespace(chat.conversation, hl.ns_anchor, 0, -1)
    vim.bo[chat.conversation].modifiable = false
  end
end

---Is the window showing the END of the transcript?
---
---By VIEWPORT, not by cursor. This window is never the focused one -- the
---dashboard opens it with `enter = false` and the sidebar hands focus straight
---to the composer -- so its cursor is not where you are looking. It is only
---ever wherever `to_bottom` last parked it.
---
---The old test was `cursor >= line_count - 3`, and that is why following
---stopped working: once `to_bottom` puts the cursor on line N, the next append
---makes the count `N + h`, and `N >= N + h - 3` holds only while `h <= 3`. One
---tool card is taller than three lines, and after it the cursor can never
---catch up on its own -- the lock was gone for the rest of the session, which
---looked exactly like there being no auto-scroll at all.
---
---MUST be called before the buffer is written. Afterwards the answer is always
---"no", because the new lines are the ones below the fold.
---@param chat table
---@return boolean
local function at_bottom(chat)
  local win = chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return false
  end
  -- `w$` is the last line VISIBLE in the window. A buffer shorter than the
  -- window has it equal to the count, so a fresh chat follows from the start.
  return vim.fn.line("w$", win) >= api.nvim_buf_line_count(chat.conversation)
end

---Scroll to the bottom. Unconditional -- the caller decides.
---@param chat table
local function to_bottom(chat)
  local win = chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(chat.conversation), 0 })
end

---Scroll to the bottom, but ONLY if we were already there.
---
---Scrolling back to reread something must not be yanked away by the next
---chunk. Kept for callers outside this file; inside it the two halves are used
---separately, because the question has to be asked before the write and
---answered after it.
---@param chat table
local function follow(chat)
  if at_bottom(chat) then
    to_bottom(chat)
  end
end

M.follow = follow
M.at_bottom = at_bottom
M.to_bottom = to_bottom

---@param chat table
---@param block table
---@return integer|nil row  0-indexed, or nil if the anchor is gone
local function row_of(chat, block)
  local mark = api.nvim_buf_get_extmark_by_id(chat.conversation, hl.ns_anchor, block.mark, {})
  return mark and mark[1]
end

---Whether an item draws open before anyone has touched it.
---
---A tool card that is collapsed by default shows `◐ Shell  ls -la` and hides
---the output, which is precisely the thing you opened the window to watch. But
---leaving every card open forever turns a long turn into a wall. So under the
---default `"running"` a command is open WHILE it runs and folds when it
---succeeds, and a failure stays open, because a failure is the one you wanted
---to read.
---@param item table
---@return boolean
local function default_expanded(item)
  local mode = require("paseo.config").get().ui.expand
  if mode == "never" then
    return false
  end
  if mode == "always" then
    return true
  end
  -- A question you have not answered yet draws OPEN, whatever `ui.expand`
  -- says about tool cards: it is the one card on the transcript that is asking
  -- you for something, and the options are the ask. Once it is answered the
  -- header carries the answer and the rest folds away.
  if item.kind == "permission" then
    return item.resolution == nil
  end
  if item.kind ~= "tool" then
    return false
  end
  return item.status == "running" or item.status == "failed"
end

---A card long enough that keeping it costs more than rebuilding it. A
---four-hundred-line expanded shell output is both the most memory and the
---least likely to be wanted again at a width it has already been drawn at.
local CACHE_MAX_LINES = 200

---Two slots. The ping-pong worth having is sidebar width <-> float width,
---which `<C-f>` walks between and which is exactly two.
local CACHE_SLOTS = 2

---Throw away a block's cached rendering.
---
---MUST be called by anything that mutates `block.item` IN PLACE rather than
---replacing it -- `M.stream` appending a chunk to `item.text`, `permission`
---writing a resolution onto the item it already handed us. Replacement is
---covered by `rerender` itself; in-place mutation is invisible from here and
---is the only way the cache can lie.
---@param block table
function M.invalidate(block)
  block.rev = (block.rev or 0) + 1
  block.drawn = nil
end

---The card for a block, from its cache when the cache is honest.
---
---`timeline.card` is pure in `(item, width, expanded)` with ONE exception:
---`tool_card` asks `animate.flash_stop`, which is a clock. So the flash's
---on/off joins the key -- and because every frame of a settle flash renders
---identically (the stop index picks no colour; `flashing` is used as a
---boolean), that turns a twelve-frame flash from twelve full rebuilds into
---two.
---@param block table
---@param width integer
---@return { key: string, lines: table[][], collapsible: boolean }
local function card_for(block, width)
  local flashing = require("paseo.ui.animate").flash_stop(timeline.flash_key(block.item)) ~= nil
  local key = ("%d|%s|%d|%s"):format(
    width,
    tostring(block.expanded),
    block.rev or 0,
    tostring(flashing)
  )

  local cache = block.cards
  if cache then
    for i, entry in ipairs(cache) do
      if entry.key == key then
        -- Most recent to the front, so two slots really do hold the two
        -- widths rather than one width and whatever was drawn last.
        if i > 1 then
          table.remove(cache, i)
          table.insert(cache, 1, entry)
        end
        return entry
      end
    end
  end

  local card = timeline.card(block.item, { width = width, expanded = block.expanded })
  local entry = { key = key, lines = card.lines, collapsible = card.collapsible }
  -- Safe to hold on to: `render.to_buffer` flattens its input into fresh
  -- tables and never writes back into the cells it was handed, unlike volt's
  -- `draw`, which strips the click handler out of `cell[3]`.
  if #card.lines <= CACHE_MAX_LINES then
    cache = cache or {}
    table.insert(cache, 1, entry)
    while #cache > CACHE_SLOTS do
      table.remove(cache)
    end
    block.cards = cache
  end
  return entry
end

---Draw a block's lines at `row`, replacing `height` existing lines, and put
---this block's anchor back on the first of them.
---
---RE-ANCHORED AFTER THE WRITE, rather than trusting a mark to survive it,
---because neither gravity survives alone -- measured, not reasoned about.
---`nvim_buf_set_lines(row, row + height)` spans `(row,0)`-`(row+height,0)`, so:
---
---  * a LEFT-gravity mark at the FAR boundary -- which is exactly where the
---    next block's anchor sits -- collapses onto `row`;
---  * a RIGHT-gravity mark at the NEAR boundary -- this block's own -- is
---    pushed to the end of whatever was just written.
---
---Every anchor was left-gravity, so the first of those was live: the moment a
---card SHRANK, every block under it moved onto the shrinking card's first line
---and the next redraw wrote over it. A tool card shrinks when it folds on
---success, so any successful call with something below it -- which is every
---call in a parallel batch -- silently ate the card above it. Two sub-agents
---launched together left one card and a wrecked one.
---
---So the blocks below get right gravity, which moves them correctly, and this
---one is simply put back where we already know it belongs.
---@param chat table
---@param block table
---@param row integer
---@param old_height integer
local function draw(chat, block, row, old_height)
  local card = card_for(block, M.width(chat))
  block.collapsible = card.collapsible

  -- Already on screen, byte for byte. This is what makes a settle flash free
  -- rather than merely cheap: it skips the buffer write too, not just the
  -- card build. Sound because `draw` replaces exactly `[row, row + height)`
  -- and nothing else writes into another block's rows -- if that ever stops
  -- being true, delete these three lines and the memo above still stands.
  if block.drawn == card.key and block.height > 0 then
    return
  end

  -- Clear only THIS block's highlights. The anchor lives in a different
  -- namespace precisely so this does not delete it.
  api.nvim_buf_clear_namespace(chat.conversation, hl.ns, row, row + old_height)
  block.height = render.to_buffer(chat.conversation, hl.ns, row, row + old_height, card.lines)
  block.drawn = card.key

  local modifiable = vim.bo[chat.conversation].modifiable
  vim.bo[chat.conversation].modifiable = true
  block.mark = api.nvim_buf_set_extmark(chat.conversation, hl.ns_anchor, row, 0, {
    id = block.mark,
    right_gravity = true,
  })
  vim.bo[chat.conversation].modifiable = modifiable
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

  -- Asked BEFORE the write: afterwards the new lines are below the fold and
  -- the answer is always no.
  local stick = at_bottom(chat)

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
    expanded = default_expanded(item),
    height = 0,
  }
  chat.next_id = chat.next_id + 1

  -- The anchor is `draw`'s to place, and it places it AFTER the lines exist --
  -- see there for why neither gravity does the job on its own.
  draw(chat, block, row, 0)

  chat.blocks[block.id] = block
  chat.order[#chat.order + 1] = block.id
  if block.call_id then
    chat.by_call[block.call_id] = block.id
  end

  if stick then
    to_bottom(chat)
  end
  return block
end

---Re-render an existing block in place.
---@param chat table
---@param block table
---@param item table|nil  New item data; keeps the old if omitted.
---@param opts? { follow?: boolean }  `follow = false` to leave the view alone.
function M.rerender(chat, block, item, opts)
  -- Caught BEFORE `block.item` is replaced: the flash marks the TRANSITION
  -- from running to settled, and once the new item is in place there is
  -- nothing left to compare against. A card that arrives already completed --
  -- a replayed timeline, a reconnect -- does not flash, which is right: it did
  -- not just happen.
  local settled = item
    and item.status
    and item.status ~= "running"
    and block.item
    and block.item.status == "running"

  if item then
    block.item = item
    M.invalidate(block)
    -- The running->completed replacement is where a card earns its fold. Only
    -- re-derive it if you have not had an opinion: a card you opened by hand
    -- must not snap shut the moment the command finishes, which is exactly
    -- when you are reading it.
    if not block.pinned then
      block.expanded = default_expanded(item)
    end
  end
  local row = row_of(chat, block)
  if not row then
    return
  end
  -- Before the draw, for the same reason as in `append`. This is the call that
  -- matters most: `M.stream` re-renders the open text block on every chunk, so
  -- it is the one doing the following during a reply.
  local stick = (not opts or opts.follow ~= false) and at_bottom(chat)
  draw(chat, block, row, block.height)
  if stick then
    to_bottom(chat)
  end

  if settled then
    -- `on_frame` rather than a section name: this is a real buffer, so the
    -- repaint is one block redrawn by id. `follow = false` so a flash cannot
    -- drag the window to the bottom while you are reading further up.
    require("paseo.ui.animate").flash {
      key = require("paseo.ui.timeline").flash_key(item),
      buf = chat.conversation,
      on_frame = function()
        local at = row_of(chat, block)
        if at then
          draw(chat, block, at, block.height)
        end
      end,
    }
  end
end

---A later event for one call must not know LESS than the one before it.
---
---THE LIVE STREAM IS NOT THE PROJECTED ONE. `timeline.history` asks the daemon
---for `projection = "projected"`, which is also what the Paseo app renders; the
---subscription delivers raw events, and for a sub-agent those go:
---
---    Agent  detail=unknown   input={}        while the call's input streams
---    Task   detail=sub_agent subAgentType=…  for the whole of its run
---    Agent  detail=unknown   input={prompt…} its TERMINAL event
---
---The last one is a regression -- the daemon hands the finished call back in
---its raw shape, and the projection is what folds it into the `sub_agent` the
---history returns. Taking each event whole meant a card that read
---`Explore  Find RSS feed fetching` for a minute fell back, at the instant the
---sub-agent SUCCEEDED, to `Agent` over a dump of the prompt. Reopening the same
---chat drew it correctly, which is exactly the pair of screenshots this came
---from: the app on the left, right; Neovim on the right, wrong.
---
---So the new event's `status` and `error` always win -- those are the news --
---and a `detail` that has gone back to `unknown` does not.
---@param old table|nil
---@param new table
---@return table
local function merge(old, new)
  if not (old and old.kind == "tool" and new.kind == "tool") then
    return new
  end

  local known = old.detail and old.detail.type ~= "unknown"
  local regressed = known and (new.detail == nil or new.detail.type == "unknown")
  if not regressed then
    return new
  end

  local merged = vim.tbl_extend("force", {}, new)
  merged.detail = old.detail
  -- `display` is DERIVED from `detail` in the sidecar, so a detail that went
  -- back to unknown arrived with a display that says less -- "Agent" for what
  -- was "Explore". The two travel together or not at all.
  merged.display = vim.deepcopy(old.display or {})
  -- Except the error text, which only exists on the terminal event and is the
  -- one thing it knows that its predecessors did not.
  local incoming = new.display or {}
  if incoming.errorText then
    merged.display.errorText = incoming.errorText
  end
  return merged
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
      M.rerender(chat, block, merge(block.item, item))
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
  -- IN PLACE, so `rerender` sees the same table it cached against.
  M.invalidate(block)
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
      -- From here on this card is yours, and `default_expanded` stops having a
      -- say in it.
      block.pinned = true
      -- Explicitly NOT following. You are up in the history with the cursor on
      -- a card; scrolling to the bottom and then being yanked back by the two
      -- lines below is a flicker with no purpose.
      M.rerender(chat, block, nil, { follow = false })
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
---
---CHEAP WHEN THE WIDTH HAS NOT CHANGED, and that is the point of it. A drag on
---the sidebar separator fires `WinResized` per column, the composer growing
---fires it for a HEIGHT change, and `<C-f>` fires it on every toggle -- and
---each one used to re-render every block in the transcript. The lines in the
---buffer are a pure function of the width, so when the width is the same the
---work is provably redundant.
---
---This also covers the surface swap for free: the sidebar pane and the float's
---pane are different widths, so a real swap redraws. If they ever do coincide,
---the bytes would have been identical anyway.
---@param chat table
---@param opts? { force?: boolean }  `force` for a change the width cannot see.
function M.redraw(chat, opts)
  M.ensure(chat)
  if not (chat.conversation and api.nvim_buf_is_valid(chat.conversation)) then
    return
  end
  local width = M.width(chat)
  if chat.rendered_width == width and not (opts and opts.force) then
    return
  end
  -- Once around the whole loop, not per block: every block but the last is
  -- re-rendered somewhere above the fold, so a per-block test would answer
  -- "no" for all of them and a resize would lose your place.
  local stick = at_bottom(chat)
  for _, id in ipairs(chat.order) do
    local block = chat.blocks[id]
    if block then
      -- `force` has to reach the memo too, or it is not a force: the cache key
      -- knows about width, expansion and the item, and nothing about
      -- `ui.style` or `ui.expand` changing under a live session -- which is
      -- the only reason this flag exists.
      if opts and opts.force then
        M.invalidate(block)
      end
      M.rerender(chat, block, nil, { follow = false })
    end
  end
  chat.rendered_width = width
  if stick then
    to_bottom(chat)
  end
end

return M
