--- The conversation buffer: real lines, tracked in blocks.
---
--- Real lines rather than virtual text, so `y`, `/`, `gg`, folds and
--- soft-wrap all keep working on an agent's reply.
---
--- A BLOCK is one rendered item -- a message, a tool card, a reasoning step.
--- Blocks are anchored by extmark rather than by line number, because a tool
--- call that starts at line 40 and finishes after three more messages have
--- arrived is no longer at line 40. `nvim_buf_set_lines` shifts extmarks for
--- us, so the anchor stays correct without any bookkeeping on our side.

local hl = require "paseo.ui.hl"
local pending = require "paseo.ui.pending"
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
  -- What was waiting to be drawn belongs to the blocks about to go.
  chat.stream_pending = nil
  M.flush(chat)
  chat.blocks = {}
  chat.order = {}
  chat.by_call = {}
  chat.next_id = 1
  chat.open = nil
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
  -- And the "thinking…" line, put back under the now-empty buffer: a chat
  -- reset mid-turn -- every first message, between the agent being made and
  -- its history landing -- is exactly the wait the line is there for.
  pending.forget(chat)
  pending.pin(chat)
end

---Is the window showing the END of the transcript?
---
---By VIEWPORT, not by cursor. This window is usually not the focused one --
---the native surface and the sidebar both hand focus straight to the
---composer -- so its cursor is not where you are looking. It is only
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
    -- Off screen, the answer is what it was when you last looked. It used to
    -- be "no", so a chat that was following stopped the moment another agent
    -- took the window, and came back at the line it had been parked on.
    return chat.sticky ~= false
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
  -- The cursor on the last line leaves a virtual line under it clipped.
  pending.reveal(chat)
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

-- ------------------------------------------------------------ where you were

---Conversation buffer -> chat, for the one `WinScrolled` that serves them all.
---@type table<integer, table>
local tracked = setmetatable({}, { __mode = "v" })

---Remember where `win` is: following (its last line on screen) or not, and
---the view to put back when the chat comes back.
---
---YOUR SCROLLING DECIDES, nothing else. `G` reaches the bottom, so the chat
---follows again; `<C-u>`, `k` past the top, the wheel, all leave it, so it
---stays where you put it. `to_bottom` scrolls too, and only confirms "yes".
---@param chat table
---@param win integer
local function note(chat, win)
  if not (api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == chat.conversation) then
    return
  end
  chat.sticky = vim.fn.line("w$", win) >= api.nvim_buf_line_count(chat.conversation)
  chat.view = api.nvim_win_call(win, vim.fn.winsaveview)
end

---Follow `chat`'s conversation buffer around the windows it is shown in.
---Safe to call repeatedly.
---@param chat table
function M.track(chat)
  local buf = chat.conversation
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  if chat.sticky == nil then
    chat.sticky = true
  end
  if tracked[buf] == nil then
    tracked[buf] = chat
  end
  if M._augroup then
    return
  end
  M._augroup = api.nvim_create_augroup("paseo.transcript", { clear = true })
  api.nvim_create_autocmd("WinScrolled", {
    group = M._augroup,
    desc = "paseo: a transcript remembers where you scrolled it",
    callback = function(args)
      -- One event for every window that moved: `v:event` names them all,
      -- `<amatch>` only the first (and is all there is when it was fired
      -- by hand).
      local wins = { [args.match] = true }
      for id in pairs(vim.v.event or {}) do
        wins[id] = true
      end
      for id in pairs(wins) do
        local win = tonumber(id)
        if win and api.nvim_win_is_valid(win) then
          local chat_ = tracked[api.nvim_win_get_buf(win)]
          if chat_ then
            note(chat_, win)
          end
        end
      end
    end,
  })
end

---Put a chat that is back in its window where you left it.
---
---Following, it goes to the end, which has moved on while you were away.
---Scrolled up, it stays scrolled up: switching agent, workspace or window and
---back is not asking to lose your place.
---@param chat table
function M.restore(chat)
  local win = chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  if chat.sticky ~= false or not chat.view then
    to_bottom(chat)
    return
  end
  local view = vim.deepcopy(chat.view)
  local count = api.nvim_buf_line_count(chat.conversation)
  view.lnum = math.min(view.lnum or 1, count)
  view.topline = math.min(view.topline or 1, count)
  api.nvim_win_call(win, function()
    vim.fn.winrestview(view)
  end)
end

---@param chat table
---@param block table
---@return integer|nil row  0-indexed, or nil if the anchor is gone
local function row_of(chat, block)
  local mark = api.nvim_buf_get_extmark_by_id(chat.conversation, hl.ns_anchor, block.mark, {})
  return mark and mark[1]
end

M.row_of = row_of

---Put the cursor on the message at timeline `seq`, at the top of the window,
---and stop following: a chat opened onto something you searched for is a chat
---you are reading, and the next chunk must not drag you back to the end.
---
---The message is the first block AT OR AFTER `seq` -- a prompt's index seq and
---the seq its block carries need not be the same number, but nothing sits
---between them.
---`opts.loaded` says everything that could be fetched back to it has been, so
---the first block counts even when its seq is past `seq`.
---@param chat table
---@param seq integer
---@param opts? { loaded?: boolean }
---@return boolean found  False when that message is older than what is loaded.
function M.reveal_seq(chat, seq, opts)
  local buf, win = chat.conversation, chat.win_conversation
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return false
  end
  local target, first
  for _, id in ipairs(chat.order or {}) do
    local block = chat.blocks[id]
    local at = block and block.item and tonumber(block.item.seq)
    if at then
      first = first or at
      if at >= seq then
        target = block
        break
      end
    end
  end
  -- Nothing loaded reaches back to it: the caller fetches further back.
  if not target or (first and first > seq and not (opts and opts.loaded)) then
    return false
  end
  local row = row_of(chat, target)
  if not row then
    return false
  end
  chat.sticky = false
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    pcall(api.nvim_win_set_cursor, win, { row + 1, 0 })
    api.nvim_win_call(win, function()
      vim.cmd "normal! zt"
    end)
    chat.view = api.nvim_win_call(win, vim.fn.winsaveview)
  else
    -- Off screen: where `restore` puts it back when it comes up.
    chat.view = { lnum = row + 1, topline = row + 1, col = 0 }
  end
  return true
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
---@param markdown? boolean  Prose as raw markdown -- see |paseo.ui.native|.
---@return { key: string, lines: table[][], collapsible: boolean }
local function card_for(block, width, markdown)
  local flashing = require("paseo.ui.animate").flash_stop(timeline.flash_key(block.item)) ~= nil
  -- `stacked` is in the key because it changes the card's FIRST LINE -- it is
  -- the leading blank, present or not -- and a key that ignored it would serve
  -- a stale rendering to the one block whose spacing had just been decided.
  -- RAW MARKDOWN PROSE IS WIDTH-FREE: soft wrap fits it to the window, so the
  -- same lines serve every width. Keying it on width rebuilt and REWROTE every
  -- prose block on each resize -- the rail going on or off -- and each write
  -- sent render-markdown round the whole buffer again. Only the boxed cards
  -- really change with width.
  local kind = block.item and block.item.kind
  local free = markdown and (kind == "text" or kind == "user")
  local key = ("%d|%s|%d|%s|%s|%s"):format(
    free and 0 or width,
    tostring(block.expanded),
    block.rev or 0,
    tostring(flashing),
    tostring(block.stacked),
    tostring(markdown == true)
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

  local card = timeline.card(block.item, {
    width = width,
    expanded = block.expanded,
    gap = not block.stacked,
    markdown = markdown,
  })
  local entry = { key = key, lines = card.lines, collapsible = card.collapsible }
  -- Safe to hold on to: `render.to_buffer` flattens its input into fresh
  -- tables and never writes back into the cells it was handed (volt's `draw`,
  -- which this used to go through, stripped the click handler out of
  -- `cell[3]`).
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
  local card = card_for(block, M.width(chat), chat.markdown)
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
  -- namespace precisely so this does not delete it. Quietly: see `M.quietly`
  -- -- a no-op inside a burst that is already quiet.
  M.quietly(chat, function()
    api.nvim_buf_clear_namespace(chat.conversation, hl.ns, row, row + old_height)
    block.height = render.to_buffer(chat.conversation, hl.ns, row, row + old_height, card.lines)
  end)
  block.drawn = card.key

  local modifiable = vim.bo[chat.conversation].modifiable
  vim.bo[chat.conversation].modifiable = true
  block.mark = api.nvim_buf_set_extmark(chat.conversation, hl.ns_anchor, row, 0, {
    id = block.mark,
    right_gravity = true,
  })
  vim.bo[chat.conversation].modifiable = modifiable
  -- The "thinking…" line goes under whatever is last now. Before the caller's
  -- `to_bottom`, which is what scrolls it into view.
  pending.pin(chat)
end

-- ------------------------------------------------------------ writing

---Run `fn` -- some writes to the conversation -- with its windows' conceal
---off, and put it back after.
---
---WHY: with `conceallevel` 2 and a markdown parser whose queries use
---`conceal_lines` (Neovim's own do), EVERY `nvim_buf_set_lines` calls the
---treesitter highlighter's conceal-line hook, which re-parses the buffer and
---re-runs its injection queries on the spot -- 14 ms a write at a few hundred
---lines, more as the conversation grows. A history load is sixty writes; a
---resize rewrites every card. Nothing is drawn in between (this is one
---synchronous call), so turning conceal off for the duration changes nothing
---on screen, and the highlighter parses once, at the next redraw, as it would
---have anyway.
---
---`noautocmd`, so an OptionSet listener (render-markdown has one) does not
---see a flip that never reaches the screen.
---@param chat table
---@param fn fun()
function M.quietly(chat, fn)
  local buf = chat.conversation
  if chat.quiet_depth or not (buf and api.nvim_buf_is_valid(buf)) then
    return fn()
  end
  local restore = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local level = vim.wo[win].conceallevel
    if level >= 2 then
      restore[win] = level
      api.nvim_win_call(win, function()
        vim.cmd "noautocmd setlocal conceallevel=0"
      end)
    end
  end
  chat.quiet_depth = true
  local ok, err = pcall(fn)
  chat.quiet_depth = nil
  for win, level in pairs(restore) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_call(win, function()
        vim.cmd("noautocmd setlocal conceallevel=" .. level)
      end)
    end
  end
  if not ok then
    error(err, 0)
  end
end

-- ------------------------------------------------------------- streaming

---Draw what has streamed into the open block since it was last drawn.
---
---Chunks are applied to the block's text the moment they arrive and DRAWN at
---most once per frame budget (`M.stream`). Every write to the conversation
---costs a treesitter pass -- markdown's `conceal_lines` query re-parses the
---buffer and re-runs its injections on each one, 14 ms at a few hundred
---lines and growing with the conversation -- so drawing every chunk of a
---two-thousand-chunk reply was twenty seconds of a frozen editor.
---
---Anything else that touches the transcript draws the pending text first, so
---nothing is ever drawn out of order: a card appended after a sentence lands
---under the WHOLE sentence.
---@param chat table
function M.flush(chat)
  local id = chat.stream_pending
  if chat.stream_timer then
    local timer = chat.stream_timer
    chat.stream_timer = nil
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
  if not id then
    return
  end
  chat.stream_pending = nil
  local block = chat.blocks and chat.blocks[id]
  if block then
    local t0 = vim.uv.hrtime()
    M.quietly(chat, function()
      M.rerender(chat, block)
    end)
    chat.stream_cost = (vim.uv.hrtime() - t0) / 1e6
  end
  vim.uv.update_time()
  chat.stream_at = vim.uv.now()
end

---How long to leave between two draws of a streaming block: three times what
---the last one cost, so a reply never takes more than about a quarter of the
---editor's time, and never less than a frame or more than a quarter second.
---@param chat table
---@return integer ms
local function budget(chat)
  return math.floor(math.min(250, math.max(16, (chat.stream_cost or 0) * 3)))
end

---Append a new block to the end of the transcript.
---@param chat table
---@param item table
---@return table block
function M.append(chat, item)
  M.ensure(chat)
  M.flush(chat)
  local buf = chat.conversation
  if not (buf and api.nvim_buf_is_valid(buf)) then
    return {}
  end

  -- Asked BEFORE the write: afterwards the new lines are below the fold and
  -- the answer is always no.
  local stick = at_bottom(chat)

  local row = api.nvim_buf_line_count(buf)
  -- A brand-new scratch buffer -- and one `reset` has just emptied -- reports
  -- one line that is actually empty. The first block OVERWRITES it rather
  -- than being inserted above it: inserted, the empty line survives as a row
  -- belonging to no block, directly under the first one, and the transcript
  -- opened with a doubled gap between the first message and the reply to it
  -- for the rest of the session.
  local over = 0
  if row == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    row, over = 0, 1
  end

  -- WHETHER THIS ONE HUGS THE ONE ABOVE IT, decided once, here, because here
  -- is the only place that knows what is above it -- a block renders from its
  -- own item and nothing else. Safe to decide once: blocks are only ever
  -- appended to the end, and a block's KIND never changes after it is made --
  -- a tool call goes running -> completed under one kind.
  local above = chat.blocks[chat.order[#chat.order]]
  local block = {
    id = chat.next_id,
    kind = item.kind,
    call_id = item.callId,
    item = item,
    expanded = default_expanded(item),
    stacked = timeline.stacks(above and above.kind, item.kind),
    height = 0,
  }
  chat.next_id = chat.next_id + 1

  -- The anchor is `draw`'s to place, and it places it AFTER the lines exist --
  -- see there for why neither gravity does the job on its own.
  draw(chat, block, row, over)

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
  M.flush(chat)
  if item.callId and chat.by_call[item.callId] then
    local block = chat.blocks[chat.by_call[item.callId]]
    if block then
      -- Anything that is not a streamed chunk ends the open block, so the
      -- next chunk starts a new paragraph below the card instead of being
      -- spliced onto the sentence that preceded it.
      chat.open = nil
      M.rerender(chat, block, merge(block.item, item))
      return block
    end
  end

  -- A whole item -- history, or a live card -- is never extended by the
  -- chunk after it: the next chunk opens a block of its own below it.
  chat.open = nil
  return M.append(chat, item)
end

---End the block being streamed into, so the next chunk starts a new one.
---Called when a turn ends: the next reply is a new answer, not more of this.
---@param chat table
function M.close(chat)
  M.flush(chat)
  chat.open = nil
end

---Assistant text and reasoning, which both arrive in PIECES.
---
---A reply delivered as "READ" + "Y" must render as READY. The old code
---concatenated onto the last BUFFER line, which was fine when the transcript
---was nothing but messages and silently corrupts a tool card that arrived
---mid-reply. Here it appends to the open block's own data and re-renders just
---that block.
---
---REASONING TOO, and that was the bug. Only text came through here; every
---reasoning delta went through `upsert`, which appends, so one thought drew as
---`I'm` / `looking at what` / `the` -- a block per chunk, fourteen for a slow
---one -- while a reopened chat showed it whole, because history is fetched
---projected and the daemon had merged it there.
---
---The rule is the daemon's projection and the app's reducer (`appendThought`
---in packages/app/src/types/stream.ts): a chunk extends the block it follows
---while nothing else has come in between. A tool card, a todo, a notice -- any
---whole item -- or a chunk of the OTHER kind closes it, so a thought that
---resumes after a tool call is a second thought, below the card, exactly as
---the projection draws it.
---@param chat table
---@param text string
---@param kind? "text"|"thinking"  Default "text".
function M.stream(chat, text, kind)
  if text == "" then
    return
  end
  kind = kind or "text"

  local open = chat.open
  local block = open and open.kind == kind and chat.blocks and chat.blocks[open.id]
  if not block then
    M.ensure(chat)
    block = M.append(chat, { kind = kind, text = text })
    chat.open = block.id and { id = block.id, kind = kind } or nil
    return
  end

  block.item.text = (block.item.text or "") .. text
  -- IN PLACE, so `rerender` sees the same table it cached against.
  M.invalidate(block)

  -- Drawn now if the last draw was long enough ago, else once the budget is
  -- up -- with everything that arrived in between. See `M.flush`.
  if chat.stream_pending and chat.stream_pending ~= block.id then
    M.flush(chat)
  end
  chat.stream_pending = block.id
  if chat.stream_timer then
    return
  end
  local wait = budget(chat) - (vim.uv.now() - (chat.stream_at or 0))
  if wait <= 0 then
    return M.flush(chat)
  end
  chat.stream_timer = vim.defer_fn(function()
    chat.stream_timer = nil
    M.flush(chat)
  end, wait)
end

---Expand or collapse the block under the cursor.
---@param chat table
function M.toggle_at_cursor(chat)
  M.ensure(chat)
  M.flush(chat)
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
---This also covers the surface swap for free: the sidebar pane and the native
---tab's conversation are different widths, so a real swap redraws. If they ever
---do coincide, the bytes would have been identical anyway.
---@param chat table
---@param opts? { force?: boolean }  `force` for a change the width cannot see.
function M.redraw(chat, opts)
  M.ensure(chat)
  M.flush(chat)
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
  M.quietly(chat, function()
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
  end)
  chat.rendered_width = width
  if stick then
    to_bottom(chat)
  end
end

return M
