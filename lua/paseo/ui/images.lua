--- Pictures in the transcript: a chip on what names one, and a float to see it.
---
--- THREE THINGS NAME A PICTURE in a conversation: an image you pasted, which
--- the prompt carries as `[Image #n]` and which is found again by the id the
--- message was sent with (the timeline carries no pictures); a markdown
--- `![alt](path)` the agent wrote; and a file it READ that is an image -- a
--- screenshot it took to look at. Each becomes an ENTRY: the file it means,
--- and the row it hangs under.
---
--- None of it is in the buffer's text. The lines stay what the agent said, so
--- `y` and `/` see words, not pictures; a chip is a highlight extmark, in a
--- namespace of its own so a block's redraw cannot wipe it. `<CR>` on a chip
--- (or anywhere on an image read's card) opens the picture full size in a
--- FLOAT -- never a tab -- and `gx` finds the one nearest the cursor.
---
--- THUMBNAILS, with snacks.nvim, in a terminal that speaks the kitty graphics
--- protocol with unicode placeholders (kitty, Ghostty). Each is a snacks
--- PLACEMENT that paseo owns: snacks' own markdown pass is kept off the
--- buffer (`vim.b.snacks_image_attached`), because it resolves paths against
--- Neovim's cwd and re-scans on every write. A placement hangs its picture
--- as virtual lines under one row, so no line of the transcript moves; its
--- row is worked out again from the block's anchor on every update, because
--- a block's redraw collapses snacks' extmarks onto its first line. Only
--- pictures near the window are placed -- a long history is not thirty
--- conversions at once -- and the rest as you scroll to them.
---
--- DEBOUNCED, NEVER IN THE WRITE. `transcript.draw` only calls `touch`, which
--- marks the block. One trailing timer per chat looks at every marked block
--- at once, so a history load of sixty items is one pass, and the reply still
--- streaming in is left until it is finished (`transcript.close`).

local api = vim.api

local M = {}

---Chips on the names of pictures. Its own namespace: `transcript.draw`
---clears `hl.ns` over a block's rows, and that must not take these with it.
M.ns = api.nvim_create_namespace "paseo.images"

---How long the transcript has to be quiet before the pass runs, and the
---longest a burst can put it off.
M.debounce_ms = 80
M.max_wait_ms = 250

---@class paseo.ImageEntry
---@field src string     Local, readable path.
---@field kind "pasted"|"link"|"read"
---@field row integer    Offset into the block of the row it hangs under.
---@field line? integer  Offset of the row its chip is on, when it has one.
---@field s? integer     Chip start column, 0-indexed bytes.
---@field e? integer     Chip end column, exclusive.

---@return table
local function cfg()
  local ui = require("paseo.config").get().ui
  return ui.images or {}
end

---@param chat table
---@return table
local function state(chat)
  chat.image_state = chat.image_state or { dirty = {}, chips = {}, placed = {}, unplaced = {} }
  return chat.image_state
end

-- ------------------------------------------------------------------ paths

---Percent-escapes, as a `file://` URL or a markdown link spells a space.
---@param s string
---@return string
local function unescape(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---Where a picture named in the conversation is ON THIS MACHINE, or nil.
---
---Relative to the AGENT's directory, not Neovim's: the agent wrote the link
---from where it works, and that is rarely where you started the editor. A
---remote agent's absolute paths go through the host's path mapping.
---@param chat table
---@param src string|nil
---@return string|nil
function M.resolve(chat, src)
  if type(src) ~= "string" or src == "" then
    return nil
  end
  src = vim.trim(src)
  src = src:gsub("^<(.*)>$", "%1")
  if src:match "^%a[%w+.-]*://" and not src:match "^file://" then
    return nil
  end
  src = unescape((src:gsub("^file://", "")))
  if src:sub(1, 1) == "~" then
    src = vim.fn.expand(src)
  end

  local path
  if src:sub(1, 1) == "/" then
    path = src
    if chat.host_id then
      local ok, mapped = pcall(require("paseo.hosts").to_local, chat.host_id, src)
      if ok and mapped then
        path = mapped
      end
    end
  else
    local root = chat.local_root or chat.root
    if not root then
      return nil
    end
    path = vim.fs.joinpath(root, src)
  end
  path = vim.fs.normalize(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "file" then
    return path
  end
  return nil
end

-- ---------------------------------------------------------------- entries

---`![alt](src "title")` -> src. The title, and `<...>` around the path, go.
---@param inside string
---@return string
local function link_target(inside)
  local angled = inside:match "^%s*<(.-)>"
  if angled then
    return angled
  end
  return inside:match "^%s*(%S+)" or inside
end

---The images YOU sent with a message, found again by the id it was sent with
---(|paseo.image|.store), under its last line, each with a chip on its
---`[Image #n]`.
---
---By number when the placeholders are exactly 1..N for N files; by order of
---appearance otherwise -- a queue flushed as one message joins prompts that
---each counted from `[Image #1]`.
---@param item table
---@param lines string[]
---@return paseo.ImageEntry[]
function M.pasted(item, lines)
  if cfg().pasted == false then
    return {}
  end
  local files = require("paseo.image").stored(item.clientMessageId or item.messageId)
  if #files == 0 then
    return {}
  end
  local last = 0
  for i = #lines, 1, -1 do
    if lines[i]:find "%S" then
      last = i - 1
      break
    end
  end

  local chips, numbers = {}, {}
  for i, line in ipairs(lines) do
    local from = 1
    while true do
      local s, e, n = line:find("%[Image #(%d+)%]", from)
      if not s then
        break
      end
      chips[#chips + 1] = { line = i - 1, s = s - 1, e = e, n = tonumber(n) }
      numbers[tonumber(n)] = (numbers[tonumber(n)] or 0) + 1
      from = e + 1
    end
  end
  local by_number = #chips == #files
  for n = 1, #files do
    if numbers[n] ~= 1 then
      by_number = false
    end
  end

  local found, used = {}, {}
  for k, chip in ipairs(chips) do
    local index = by_number and chip.n or k
    local src = files[index]
    if src then
      used[index] = true
      found[#found + 1] = { src = src, kind = "pasted", row = last, line = chip.line, s = chip.s, e = chip.e }
    end
  end
  -- A picture whose placeholder you deleted from the text before sending is
  -- not sent at all; but one sent from elsewhere with no placeholder still
  -- went with this message, so it still hangs under it.
  for index, src in ipairs(files) do
    if not used[index] then
      found[#found + 1] = { src = src, kind = "pasted", row = last }
    end
  end
  return found
end

---Every picture block `block` names, and where.
---@param chat table
---@param block table
---@param lines string[]  The block's rows, as they are in the buffer.
---@return paseo.ImageEntry[]
function M.entries(chat, block, lines)
  local opts = cfg()
  local item = block.item or {}
  local found = {}

  if item.kind == "tool" then
    local detail = item.detail
    if
      opts.read ~= false
      and detail
      and detail.type == "read"
      and item.status ~= "failed"
      and require("paseo.image").is_image_path(detail.filePath)
    then
      local src = M.resolve(chat, detail.filePath)
      if src then
        found[#found + 1] = { src = src, kind = "read", row = math.max(0, #lines - 1) }
      end
    end
    return found
  end

  if item.kind ~= "text" and item.kind ~= "user" then
    return found
  end

  if item.kind == "user" then
    vim.list_extend(found, M.pasted(item, lines))
  end

  local fenced = false
  for i, line in ipairs(lines) do
    if line:match "^%s*```" or line:match "^%s*~~~" then
      fenced = not fenced
    elseif not fenced and opts.links ~= false then
      local from = 1
      while true do
        local s, e, inside = line:find("!%[[^%]]*%]%(([^)]*)%)", from)
        if not s then
          break
        end
        local src = M.resolve(chat, link_target(inside))
        if src then
          found[#found + 1] = { src = src, kind = "link", row = i - 1, line = i - 1, s = s - 1, e = e }
        end
        from = e + 1
      end
    end
  end
  return found
end

-- ------------------------------------------------------------------ chips

---@param chat table
---@param block table
---@param row integer
---@param entries paseo.ImageEntry[]
local function paint(chat, block, row, entries)
  local buf = chat.conversation
  api.nvim_buf_clear_namespace(buf, M.ns, row, row + math.max(1, block.height or 1))
  for _, entry in ipairs(entries) do
    if entry.line then
      pcall(api.nvim_buf_set_extmark, buf, M.ns, row + entry.line, entry.s, {
        end_col = entry.e,
        hl_group = "PaseoRef",
        priority = 150,
      })
    end
  end
end

-- ------------------------------------------------------------- thumbnails

---snacks.nvim's image module, when it is installed.
---@return table|nil
local function snacks_image()
  local ok, snacks = pcall(require, "snacks")
  return ok and type(snacks) == "table" and snacks.image or nil
end

---Chats with pictures waiting for `available` to answer.
local waiting = setmetatable({}, { __mode = "k" })

---Is block's first row within a screen of a window showing the buffer?
---@param chat table
---@param row integer
---@param height integer
---@return boolean
local function near_view(chat, row, height)
  for _, win in ipairs(vim.fn.win_findbuf(chat.conversation)) do
    local top, bot = vim.fn.line("w0", win) - 1, vim.fn.line("w$", win) - 1
    local screen = api.nvim_win_get_height(win)
    if row + height - 1 >= top - screen and row <= bot + screen then
      return true
    end
  end
  return false
end

---@param entry paseo.ImageEntry
---@param seen table<string, integer>
---@return string
local function key_of(entry, seen)
  local base = ("%s@%d:%s"):format(entry.kind, entry.line or entry.row, entry.src)
  seen[base] = (seen[base] or 0) + 1
  return base .. "#" .. seen[base]
end

---Point a placement at the row it belongs under, now.
---@param chat table
---@param block table
---@param rec table
---@return boolean ok
local function aim(chat, block, rec)
  local row = require("paseo.ui.transcript").row_of(chat, block)
  if not row then
    return false
  end
  local at = row + rec.entry.row
  local line = api.nvim_buf_get_lines(chat.conversation, at, at + 1, false)[1]
  if not line then
    return false
  end
  -- The whole row as the range: nothing before it and nothing after, so
  -- snacks hangs the picture BELOW the row, flush left, rather than shrinking
  -- it to fit beside the text or indenting it by the text's width.
  rec.p.opts.pos = { at + 1, 0 }
  rec.p.opts.range = { at + 1, 0, at + 1, #line }
  return true
end

---Make the block's placements match its entries.
---@param chat table
---@param block table
---@param entries paseo.ImageEntry[]
local function place(chat, block, entries)
  local st = state(chat)
  local image = snacks_image()
  local opts = cfg()
  local have = st.placed[block.id] or {}
  local want, seen = {}, {}
  for _, entry in ipairs(entries) do
    want[key_of(entry, seen)] = entry
  end

  for key, rec in pairs(have) do
    if not want[key] then
      pcall(rec.p.close, rec.p)
      have[key] = nil
    end
  end
  for key, entry in pairs(want) do
    local rec = have[key]
    if rec then
      rec.entry = entry
      if aim(chat, block, rec) then
        rec.p._state = nil
        rec.p:update()
      end
    elseif image then
      rec = { entry = entry }
      local ok, p = pcall(image.placement.new, chat.conversation, entry.src, {
        inline = true,
        conceal = false,
        pos = { 1, 0 },
        max_height = opts.max_height,
        max_width = opts.max_width,
        on_update_pre = function()
          aim(chat, block, rec)
        end,
        on_update = function()
          if chat.sticky ~= false then
            require("paseo.ui.pending").reveal(chat)
          end
        end,
      })
      if ok and p then
        rec.p = p
        aim(chat, block, rec)
        have[key] = rec
      end
    end
  end
  st.placed[block.id] = next(have) and have or nil
end

-- ------------------------------------------------------------------- pass

---The block's rows in the buffer, and where they start.
---@param chat table
---@param block table
---@return integer|nil row
---@return string[] lines
local function rows_of(chat, block)
  local transcript = require "paseo.ui.transcript"
  local row = block.mark and transcript.row_of(chat, block)
  if not row or (block.height or 0) == 0 then
    return nil, {}
  end
  return row, api.nvim_buf_get_lines(chat.conversation, row, row + block.height, false)
end

---Is there anything in this block worth reading its lines for? Plain finds:
---this runs for every block the transcript draws.
---@param block table
---@return boolean
local function might(block)
  local item = block.item or {}
  if item.kind == "tool" then
    return item.detail ~= nil and item.detail.type == "read"
  end
  if item.kind == "user" and (item.clientMessageId or item.messageId) then
    return true
  end
  if item.kind == "text" or item.kind == "user" then
    return (item.text or ""):find("![", 1, true) ~= nil
  end
  return false
end

---Look at one marked block. False to keep it marked for a later pass.
---@param chat table
---@param block table
---@return boolean done
local function look(chat, block)
  if chat.open and chat.open.id == block.id and chat.streaming then
    -- Still being written. `transcript.close` marks it again when it ends,
    -- and so does the turn ending (`set_streaming`). Only WHILE a turn runs:
    -- a reply replayed into a reopened chat is the open block too, and no
    -- turn will end to close it.
    return false
  end
  local st = state(chat)
  if not might(block) then
    if st.chips[block.id] then
      local row = rows_of(chat, block)
      if row then
        paint(chat, block, row, {})
      end
      st.chips[block.id] = nil
    end
    if st.placed[block.id] then
      place(chat, block, {})
    end
    st.unplaced[block.id] = nil
    return true
  end
  local row, lines = rows_of(chat, block)
  if not row then
    return true
  end
  local entries = M.entries(chat, block, lines)
  paint(chat, block, row, entries)
  st.chips[block.id] = #entries > 0 or nil
  st.unplaced[block.id] = nil

  if #entries == 0 and not st.placed[block.id] then
    return true
  end
  if not M._env then
    -- The terminal has not been asked yet. Ask once, and come back.
    waiting[chat] = true
    st.unplaced[block.id] = true
    M.available(function()
      for c in pairs(waiting) do
        waiting[c] = nil
        M.refresh(c)
      end
    end)
    return true
  end
  if not M._env.inline then
    return true
  end
  if #entries > 0 and not near_view(chat, row, block.height) then
    -- Placed when you scroll to it (`M.scrolled`).
    st.unplaced[block.id] = true
    return true
  end
  place(chat, block, entries)
  return true
end

---Look at every marked block. Exported for the tests; otherwise only ever
---called by the timer.
---@param chat table
function M.sync(chat)
  local st = state(chat)
  st.timer_due = nil
  local buf = chat.conversation
  if not (buf and api.nvim_buf_is_valid(buf)) or cfg().enabled == false then
    st.dirty = {}
    return
  end
  -- A snapshot: a block can be marked again DURING the pass (the terminal
  -- answering, a refresh), and that mark is for the next one.
  local dirty = st.dirty
  st.dirty = {}
  for id in pairs(dirty) do
    local block = chat.blocks and chat.blocks[id]
    if block and not look(chat, block) then
      st.dirty[id] = true
    end
  end
  st.passes = (st.passes or 0) + 1
end

---@param chat table
local function arm(chat)
  local st = state(chat)
  local now = vim.uv.now()
  st.first = st.first or now
  local wait = math.min(M.debounce_ms, math.max(0, st.first + M.max_wait_ms - now))
  if st.timer then
    st.timer:stop()
  else
    st.timer = vim.uv.new_timer()
  end
  st.timer:start(
    wait,
    0,
    vim.schedule_wrap(function()
      st.first = nil
      local ok, err = pcall(M.sync, chat)
      if not ok then
        vim.notify_once("paseo: images: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  )
end

---Blocks whose pictures were left for later go back on the list.
---@param chat table
---@return boolean any
local function requeue(chat)
  local st = chat.image_state
  if not st then
    return false
  end
  local any = false
  for id in pairs(st.unplaced) do
    st.dirty[id] = true
    any = true
  end
  return any or next(st.dirty) ~= nil
end

---The window scrolled: place what came into view.
---@param chat table
function M.scrolled(chat)
  if requeue(chat) then
    arm(chat)
  end
end

---Show every placement again, at the window's size now.
---
---snacks HIDES a placement when no window in the current tab shows its
---buffer -- the chat went off screen, or you were on another tab -- and
---nothing shows it again. So: on the buffer coming back, the tab changing,
---or a window resizing.
---@param chat table
function M.refresh(chat)
  local st = chat.image_state
  if not st then
    return
  end
  for id, recs in pairs(st.placed) do
    local block = chat.blocks and chat.blocks[id]
    for _, rec in pairs(recs) do
      local p = rec.p
      if block and aim(chat, block, rec) then
        if p.hidden then
          pcall(p.show, p)
        else
          p._state = nil
          pcall(p.update, p)
        end
      end
    end
  end
  if requeue(chat) then
    arm(chat)
  end
end

---Follow the buffer in and out of windows. Once per buffer.
---@param chat table
local function attach(chat)
  local buf = chat.conversation
  local st = state(chat)
  if st.attached == buf then
    return
  end
  st.attached = buf
  local group = api.nvim_create_augroup("paseo.images." .. buf, { clear = true })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = vim.schedule_wrap(function()
      M.refresh(chat)
    end),
  })
  api.nvim_create_autocmd({ "TabEnter", "WinResized", "VimResized" }, {
    group = group,
    callback = vim.schedule_wrap(function()
      if not api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_del_augroup_by_id, group)
        return
      end
      if chat.image_state and next(chat.image_state.placed) and #vim.fn.win_findbuf(buf) > 0 then
        M.refresh(chat)
      end
    end),
  })
end

---A block was just written. Costs a table write and a timer reset.
---@param chat table
---@param block table
function M.touch(chat, block)
  if not (block and block.id) then
    return
  end
  local st = state(chat)
  st.dirty[block.id] = true
  attach(chat)
  arm(chat)
end

---Everything the buffer showed is about to go (`transcript.reset`).
---@param chat table
function M.clear(chat)
  local st = chat.image_state
  if st and st.timer then
    st.timer:stop()
    st.timer:close()
  end
  for _, recs in pairs(st and st.placed or {}) do
    for _, rec in pairs(recs) do
      pcall(rec.p.close, rec.p)
    end
  end
  local attached = st and st.attached
  chat.image_state = nil
  local buf = chat.conversation
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    if attached then
      state(chat).attached = attached
    end
  end
end

-- ------------------------------------------------------------- the cursor

---The picture under the cursor: a chip the cursor is on, else one hanging
---under this row, else -- on an image read's card -- that read. With
---`opts.nearest`, else the closest one in the block.
---@param chat table
---@param opts? { nearest?: boolean, win?: integer }
---@return paseo.ImageEntry|nil
function M.at_cursor(chat, opts)
  opts = opts or {}
  local win = opts.win or chat.win_conversation
  if not (win and api.nvim_win_is_valid(win)) then
    return nil
  end
  local cursor = api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local transcript = require "paseo.ui.transcript"
  local block, start = transcript.block_at(chat, row)
  if not block then
    return nil
  end
  local _, lines = rows_of(chat, block)
  local entries = M.entries(chat, block, lines)
  if #entries == 0 then
    return nil
  end
  local at = row - start

  for _, entry in ipairs(entries) do
    if entry.line == at and col >= entry.s and col < entry.e then
      return entry
    end
  end
  for _, entry in ipairs(entries) do
    if entry.line == at or (not entry.line and entry.row == at) then
      return entry
    end
  end
  for _, entry in ipairs(entries) do
    if entry.kind == "read" then
      return entry
    end
  end
  if not opts.nearest then
    return nil
  end
  local best, gap
  for _, entry in ipairs(entries) do
    local d = math.abs((entry.line or entry.row) - at)
    if not gap or d < gap then
      best, gap = entry, d
    end
  end
  return best
end

-- -------------------------------------------------------------- the float

---Width and height from a PNG's header, for the card a terminal without
---kitty graphics gets instead of the picture.
---@param path string
---@return integer|nil, integer|nil
local function png_size(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local head = fd:read(24)
  fd:close()
  if not head or #head < 24 or head:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  local function u32(at)
    local a, b, c, d = head:byte(at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

---@param bytes integer
---@return string
local function human(bytes)
  if bytes >= 1024 * 1024 then
    return ("%.1f MB"):format(bytes / 1024 / 1024)
  elseif bytes >= 1024 then
    return ("%.0f KB"):format(bytes / 1024)
  end
  return ("%d B"):format(bytes)
end

---What the float says when it cannot draw the picture.
---@param path string
---@return string[]
function M.card(path)
  local lines = { vim.fn.fnamemodify(path, ":t"), "", path }
  local stat = vim.uv.fs_stat(path)
  local facts = {}
  if stat then
    facts[#facts + 1] = human(stat.size)
  end
  local w, h = png_size(path)
  if w then
    facts[#facts + 1] = ("%d × %d"):format(w, h)
  end
  if #facts > 0 then
    lines[#lines + 1] = table.concat(facts, " · ")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "This terminal cannot draw it here. o opens it outside Neovim."
  return lines
end

---Can snacks.nvim draw pictures in this terminal? Asked once, without
---blocking: snacks' own `supports_terminal()` waits up to a second and a half
---for the terminal to answer, the first time.
---@param cb fun(env: { float: boolean, inline: boolean })
function M.available(cb)
  if M._env then
    return cb(M._env)
  end
  local none = { float = false, inline = false }
  local image = snacks_image()
  if not image or cfg().enabled == false or (image.config and image.config.enabled == false) then
    M._env = none
    return cb(none)
  end
  if M._waiting then
    table.insert(M._waiting, cb)
    return
  end
  M._waiting = { cb }
  local done = function()
    local okenv, env = pcall(image.terminal.env)
    env = okenv and env or {}
    M._env = { float = env.supported == true, inline = env.supported == true and env.placeholders == true }
    local waiting = M._waiting or {}
    M._waiting = nil
    for _, fn in ipairs(waiting) do
      fn(M._env)
    end
  end
  local started = pcall(image.terminal.detect, vim.schedule_wrap(done))
  if not started then
    M._waiting = nil
    M._env = none
    cb(none)
  end
end

---Open `path` full size, in a float over the editor.
---@param path string
---@return integer|nil win
function M.open(path)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width = math.max(20, math.floor(vim.o.columns * 0.9))
  local height = math.max(5, math.floor((vim.o.lines - vim.o.cmdheight - 2) * 0.9))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    title = " " .. vim.fn.fnamemodify(path, ":t") .. " ",
    title_pos = "center",
    style = "minimal",
    zindex = 150,
  })
  -- A `:bnext` in here must not load an agent into the picture's window.
  require("paseo.ui.style").pin(win)

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local map = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", map, { desc = "paseo: close the picture" }))
  vim.keymap.set("n", "<Esc>", close, vim.tbl_extend("force", map, { desc = "paseo: close the picture" }))
  vim.keymap.set("n", "o", function()
    vim.ui.open(path)
  end, vim.tbl_extend("force", map, { desc = "paseo: open it outside Neovim" }))
  vim.keymap.set("n", "y", function()
    vim.fn.setreg(vim.v.register, path)
    vim.notify("paseo: copied " .. path)
  end, vim.tbl_extend("force", map, { desc = "paseo: copy its path" }))

  local function fallback()
    if not api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, M.card(path))
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "paseo_image"
  end
  -- The card first, so the float is never blank while the terminal answers.
  fallback()
  M.available(function(env)
    if not (env.float and api.nvim_buf_is_valid(buf)) then
      return
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, {})
    local ok = pcall(function()
      snacks_image().buf.attach(buf, { src = path })
    end)
    if not ok then
      fallback()
    end
  end)
  return win
end

---Open the picture under the cursor. False when there is none, so `<CR>` can
---fall through to folding the card.
---@param chat table
---@param opts? { nearest?: boolean }
---@return boolean
function M.open_at_cursor(chat, opts)
  local entry = M.at_cursor(chat, opts)
  if not entry then
    return false
  end
  M.open(entry.src)
  return true
end

return M
