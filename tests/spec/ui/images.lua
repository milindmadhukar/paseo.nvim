--- Pictures in the transcript: chips, the hit test, the float.
---
--- snacks.nvim is not on the suite's runtimepath, so everything here is the
--- path a terminal without kitty graphics takes -- which is also the part
--- that has to work for everyone.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local api = vim.api

---A real PNG header, 80 x 60, and nothing after it.
local PNG = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\80\0\0\0\60\8\6\0\0\0"

local function write(path, bytes)
  local fd = assert(io.open(path, "wb"))
  fd:write(bytes)
  fd:close()
end

---A chat over a real buffer in a real window, rooted at `root`.
local function fake_chat(root)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 70,
    height = 20,
    style = "minimal",
  })
  local chat = { conversation = buf, win_conversation = win, root = root }
  require("paseo.ui.transcript").reset(chat)
  return chat
end

local function chips(chat)
  local images = require "paseo.ui.images"
  return api.nvim_buf_get_extmarks(chat.conversation, images.ns, 0, -1, { details = true })
end

local function test_images()
  local images = require "paseo.ui.images"
  local transcript = require "paseo.ui.transcript"

  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/shots", "p")
  local pic = root .. "/shots/pic.png"
  write(pic, PNG)
  local elsewhere = vim.fn.tempname() .. ".png"
  write(elsewhere, PNG)

  -- ----------------------------------------------------------- resolution
  local chat = fake_chat(root)
  eq("resolve: relative to the AGENT's directory", images.resolve(chat, "shots/pic.png"), pic)
  eq("resolve: not Neovim's cwd", images.resolve({ root = "/" }, "shots/pic.png"), nil)
  eq("resolve: an absolute path", images.resolve(chat, elsewhere), elsewhere)
  eq("resolve: a file:// URL", images.resolve(chat, "file://" .. pic), pic)
  eq("resolve: <angled>, as markdown allows", images.resolve(chat, "<shots/pic.png>"), pic)
  eq("resolve: a web address is not a file here", images.resolve(chat, "https://example.com/a.png"), nil)
  eq("resolve: a file that is not there", images.resolve(chat, "shots/gone.png"), nil)

  -- ---------------------------------------------------------------- chips
  transcript.upsert(chat, { kind = "user", text = "what is this" })
  transcript.upsert(chat, {
    kind = "text",
    text = table.concat({
      "Here it is:",
      "",
      "![the shot](shots/pic.png)",
      "",
      "```",
      "![not this](shots/pic.png)",
      "```",
      "and ![gone](shots/gone.png).",
    }, "\n"),
  })
  images.sync(chat)
  local marks = chips(chat)
  eq("chip: one, on the link that resolves outside a fence", #marks, 1)
  local lines = api.nvim_buf_get_lines(chat.conversation, 0, -1, false)
  local link_row
  for i, line in ipairs(lines) do
    if line == "![the shot](shots/pic.png)" then
      link_row = i - 1
    end
  end
  eq("chip: on the link's row", marks[1] and marks[1][2], link_row)
  eq("chip: from its first byte", marks[1] and marks[1][3], 0)
  eq("chip: to its last", marks[1] and marks[1][4].end_col, #"![the shot](shots/pic.png)")
  eq("chip: drawn as a reference", marks[1] and marks[1][4].hl_group, "PaseoRef")

  -- ------------------------------------------------------- the hit test
  api.nvim_win_set_cursor(chat.win_conversation, { link_row + 1, 3 })
  local hit = images.at_cursor(chat)
  eq("cursor: on the chip, the picture", hit and hit.src, pic)
  api.nvim_win_set_cursor(chat.win_conversation, { link_row, 0 })
  eq("cursor: a row away, nothing", images.at_cursor(chat), nil)
  local near = images.at_cursor(chat, { nearest = true })
  eq("cursor: but gx finds the nearest", near and near.src, pic)
  api.nvim_win_set_cursor(chat.win_conversation, { 1, 0 })
  eq("cursor: nothing on a block with no picture", images.at_cursor(chat, { nearest = true }), nil)

  -- -------------------------------------------------------- an image read
  transcript.upsert(chat, {
    kind = "tool",
    callId = "read-1",
    name = "Read",
    status = "completed",
    display = { summary = "shots/pic.png" },
    detail = { type = "read", filePath = pic, content = "iVBORw0KGgo=" },
  })
  local read_block = chat.blocks[chat.by_call["read-1"]]
  local read_row = transcript.row_of(chat, read_block)
  api.nvim_win_set_cursor(chat.win_conversation, { read_row + read_block.height, 0 })
  local read_hit = images.at_cursor(chat)
  eq("read: anywhere on the card is the picture", read_hit and read_hit.kind, "read")
  eq("read: the file it read", read_hit and read_hit.src, pic)
  local card = require("paseo.ui.timeline").card(read_block.item, { width = 60, expanded = true })
  local text = {}
  for _, line in ipairs(card.lines) do
    for _, cell in ipairs(line) do
      text[#text + 1] = cell[1]
    end
  end
  truthy(
    "read: the card does not dump the base64",
    not table.concat(text, "\n"):find("iVBORw0KGgo", 1, true)
  )

  -- ----------------------------------------------------- what you pasted
  local image = require "paseo.image"
  local saved_dir = image.cache_dir
  local cache = vim.fn.tempname()
  image.cache_dir = function()
    return cache
  end
  local id = image.message_id()
  image.store(id, {
    { data = vim.base64.encode(PNG), mimeType = "image/png" },
    { data = vim.base64.encode(PNG), mimeType = "image/png" },
  })
  local files = image.stored(id)
  local user = transcript.upsert(chat, {
    kind = "user",
    text = "first [Image #2]\nthen [Image #1]",
    clientMessageId = id,
  })
  local start = transcript.row_of(chat, user)
  local rows = api.nvim_buf_get_lines(chat.conversation, start, start + user.height, false)
  local pasted = images.pasted(user.item, rows)
  eq("pasted: one entry per placeholder", #pasted, 2)
  eq("pasted: by NUMBER when they are 1..N", { pasted[1].src, pasted[2].src }, { files[2], files[1] })
  eq("pasted: all hung under the message's last line", { pasted[1].row, pasted[2].row }, { #rows - 1, #rows - 1 })
  local queued = images.pasted({ kind = "user", clientMessageId = id }, { "a [Image #1]", "b [Image #1]" })
  eq("pasted: by ORDER when a merged queue repeats #1", { queued[1].src, queued[2].src }, { files[1], files[2] })
  eq("pasted: none for a message sent without an id", images.pasted({ kind = "user" }, rows), {})
  local first_chip
  for i, line in ipairs(rows) do
    local s_ = line:find("[Image #2]", 1, true)
    if s_ then
      first_chip = { start + i, s_ }
    end
  end
  api.nvim_win_set_cursor(chat.win_conversation, first_chip)
  eq("pasted: <CR> on a chip opens that picture", (images.at_cursor(chat) or {}).src, files[2])
  image.cache_dir = saved_dir
  vim.fn.delete(cache, "rf")

  -- ------------------------------------------------------------ the float
  local tabs = vim.fn.tabpagenr "$"
  local before = api.nvim_get_current_win()
  local win = images.open(pic)
  truthy("float: it is a float", win and api.nvim_win_get_config(win).relative ~= "")
  eq("float: never a tab", vim.fn.tabpagenr "$", tabs)
  local fbuf = api.nvim_win_get_buf(win)
  eq("float: without snacks, a card of its own", vim.bo[fbuf].filetype, "paseo_image")
  local said = table.concat(api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
  truthy("float: the card says how big it is", said:find("80 × 60", 1, true) ~= nil, said)
  api.nvim_feedkeys("q", "x", false)
  truthy("float: q closes it", not api.nvim_win_is_valid(win))
  eq("float: and it is gone with its buffer", api.nvim_buf_is_valid(fbuf), false)
  if api.nvim_win_is_valid(before) then
    api.nvim_set_current_win(before)
  end

  -- -------------------------------------------------- debounced, deferred
  images.clear(chat)
  local st_passes = function()
    return (chat.image_state and chat.image_state.passes) or 0
  end
  transcript.quietly(chat, function()
    for i = 1, 60 do
      transcript.upsert(chat, { kind = "text", text = ("line %d ![p](shots/pic.png)"):format(i) })
    end
  end)
  vim.wait(1000, function()
    return st_passes() > 0
  end, 10)
  vim.wait(300)
  eq("debounce: sixty writes are one pass", st_passes(), 1)
  eq("debounce: and every one of them has its chip", #chips(chat), 60)

  chat.streaming = true
  transcript.stream(chat, "streaming ![p](shots/pic.png)")
  local open = chat.open and chat.blocks[chat.open.id]
  images.sync(chat)
  local open_row = transcript.row_of(chat, open)
  -- Anywhere in the block: its first row is the gap above it.
  local function chip_on(row)
    local last = row + open.height - 1
    return #api.nvim_buf_get_extmarks(chat.conversation, images.ns, { row, 0 }, { last, -1 }, {}) > 0
  end
  eq("stream: the reply being written is left alone", chip_on(open_row), false)
  chat.streaming = false
  transcript.close(chat)
  images.sync(chat)
  eq("stream: and looked at once it ends", chip_on(open_row), true)

  -- A reply REPLAYED into a reopened chat is the open block too, and no turn
  -- will end to close it: not streaming, it is looked at all the same.
  transcript.stream(chat, "replayed ![p](shots/pic.png)")
  local replayed = chat.blocks[chat.open.id]
  images.sync(chat)
  local replayed_row = transcript.row_of(chat, replayed)
  eq(
    "stream: an open block with no turn running is not left waiting",
    #api.nvim_buf_get_extmarks(chat.conversation, images.ns, { replayed_row, 0 }, { replayed_row + replayed.height - 1, -1 }, {}) > 0,
    true
  )

  -- --------------------------------------------------- reset takes them all
  transcript.reset(chat)
  eq("reset: no chip outlives its block", #chips(chat), 0)

  api.nvim_win_close(chat.win_conversation, true)
  api.nvim_buf_delete(chat.conversation, { force = true })
  vim.fn.delete(root, "rf")
  vim.fn.delete(elsewhere)
end

---snacks.nvim, as far as paseo uses it: placements it can count.
local function fake_snacks()
  local created = {}
  local placement = {}
  placement.__index = placement
  function placement:update()
    if self.opts.on_update_pre then
      self.opts.on_update_pre(self)
    end
    self.updates = self.updates + 1
  end
  function placement:show()
    self.hidden = false
    self:update()
  end
  function placement:close()
    self.closed = true
  end
  local snacks = {
    image = {
      config = {},
      terminal = {
        detect = function(cb)
          cb()
        end,
        env = function()
          return { supported = true, placeholders = true }
        end,
      },
      placement = {
        new = function(buf, src, opts)
          local p = setmetatable({ buf = buf, src = src, opts = opts, updates = 0 }, placement)
          created[#created + 1] = p
          return p
        end,
        clean = function() end,
      },
      buf = {
        attach = function(buf)
          vim.bo[buf].filetype = "image"
        end,
      },
    },
  }
  return snacks, created
end

local function test_thumbnails()
  local images = require "paseo.ui.images"
  local transcript = require "paseo.ui.transcript"

  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/shots", "p")
  local pic = root .. "/shots/pic.png"
  write(pic, PNG)

  local snacks, created = fake_snacks()
  local saved = package.loaded.snacks
  package.loaded.snacks = snacks
  images._env = nil

  local ok, err = pcall(function()
    local chat = fake_chat(root)
    local live = function()
      local n = 0
      for _, p in ipairs(created) do
        n = n + (p.closed and 0 or 1)
      end
      return n
    end

    -- A running command, open while it runs, ABOVE the picture: when it
    -- finishes it folds, and everything under it moves up.
    transcript.upsert(chat, {
      kind = "tool",
      callId = "sh-1",
      name = "Bash",
      status = "running",
      display = { summary = "ls" },
      detail = { type = "shell", command = "ls", output = "a\nb\nc\nd\ne\nf" },
    })
    local block = transcript.upsert(chat, { kind = "text", text = "look\n![shot](shots/pic.png)" })
    vim.wait(1000, function()
      return #created > 0
    end, 10)
    eq("thumb: one placement for the one picture", #created, 1)
    local p = created[1]
    local function link_row()
      local start = transcript.row_of(chat, block)
      for i = start, start + block.height - 1 do
        if api.nvim_buf_get_lines(chat.conversation, i, i + 1, false)[1] == "![shot](shots/pic.png)" then
          return i
        end
      end
    end
    eq("thumb: the file it means", p and p.src, pic)
    eq("thumb: hung under the link's row", p and p.opts.pos, { link_row() + 1, 0 })
    eq(
      "thumb: the whole row as the range, so it hangs below and flush left",
      p and p.opts.range,
      { link_row() + 1, 0, link_row() + 1, #"![shot](shots/pic.png)" }
    )
    eq("thumb: capped at ui.images.max_height", p and p.opts.max_height, 12)
    eq("thumb: inline, the text left showing", p and { p.opts.inline, p.opts.conceal }, { true, false })

    local before = link_row()
    transcript.upsert(chat, {
      kind = "tool",
      callId = "sh-1",
      name = "Bash",
      status = "completed",
      display = { summary = "ls" },
      detail = { type = "shell", command = "ls", output = "a\nb\nc\nd\ne\nf", exitCode = 0 },
    })
    truthy("thumb: (the card above did fold)", link_row() < before)
    p:update()
    eq("thumb: and the picture follows its row up", p.opts.pos, { link_row() + 1, 0 })

    -- The same block drawn again is the same placement, not a second one.
    transcript.redraw(chat, { force = true })
    vim.wait(400, function()
      return false
    end, 10)
    eq("thumb: a redraw does not place it twice", live(), 1)

    -- FAR BELOW the window: left until you scroll to it.
    local filler = {}
    for i = 1, 120 do
      filler[i] = "filler " .. i
    end
    transcript.upsert(chat, { kind = "text", text = table.concat(filler, "\n") })
    -- Scrolled back to the top, so the window stops following the end.
    api.nvim_win_set_cursor(chat.win_conversation, { 1, 0 })
    vim.cmd "redraw"
    transcript.upsert(chat, { kind = "text", text = "![later](shots/pic.png)" })
    vim.wait(400, function()
      return false
    end, 10)
    eq("view: a picture three screens down is not placed yet", live(), 1)
    api.nvim_win_set_cursor(chat.win_conversation, { api.nvim_buf_line_count(chat.conversation), 0 })
    vim.cmd "redraw"
    images.scrolled(chat)
    vim.wait(1000, function()
      return live() == 2
    end, 10)
    eq("view: and is placed once it is scrolled to", live(), 2)

    -- HIDDEN while off screen, shown again when the buffer comes back.
    created[1].hidden = true
    images.refresh(chat)
    eq("refresh: a placement snacks hid is shown again", created[1].hidden, false)

    -- The float draws the picture itself.
    local win = images.open(pic)
    vim.wait(500, function()
      return vim.bo[api.nvim_win_get_buf(win)].filetype == "image"
    end, 10)
    eq("float: with snacks, snacks' image buffer", vim.bo[api.nvim_win_get_buf(win)].filetype, "image")
    api.nvim_win_close(win, true)

    transcript.reset(chat)
    eq("reset: every placement is closed", live(), 0)

    api.nvim_win_close(chat.win_conversation, true)
    api.nvim_buf_delete(chat.conversation, { force = true })
  end)

  package.loaded.snacks = saved
  images._env = nil
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
end

return {
  { "images", test_images },
  { "images thumbnails", test_thumbnails },
}
